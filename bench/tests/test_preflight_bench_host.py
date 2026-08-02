#!/usr/bin/env python3
"""Tests for schema-backed Vulkan host-profile preflight."""

from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from bench.runners import preflight_bench_host as preflight


REPO_ROOT = Path(__file__).resolve().parents[2]
PROFILE_POLICY = REPO_ROOT / "config" / "vulkan-host-profiles.json"


class VulkanHostProfileTests(unittest.TestCase):
    def test_dawn_adapter_parser_preserves_record_before_empty_driver(self) -> None:
        output = '''System adapters:
 - "Intel GPU" - "Mesa driver [Selected]"
   type: Integrated GPU, backend: Vulkan, compatibilityMode: false
   vendorId: 0x8086, deviceId: 0x9A78
 - "Null backend" - ""
   type: CPU, backend: Null, compatibilityMode: false
   vendorId: 0x0000, deviceId: 0x0000
'''

        adapters = preflight.parse_dawn_adapters(output)

        self.assertEqual(len(adapters), 2)
        self.assertEqual(adapters[0]["backend"], "Vulkan")
        self.assertEqual(adapters[0]["vendorId"].split(",")[0], "0x8086")
        self.assertEqual(adapters[1]["driver"], "")
        self.assertEqual(adapters[1]["backend"], "Null")

    def test_intel_tiger_lake_profile_matches_this_machine_contract(self) -> None:
        profile = preflight.resolve_vulkan_host_profile(
            PROFILE_POLICY,
            "linux_intel_tiger_lake_vulkan",
        )

        self.assertEqual(profile.vendor_id, "0x8086")
        self.assertEqual(
            profile.icd_path,
            Path("/usr/share/vulkan/icd.d/intel_icd.x86_64.json"),
        )
        self.assertEqual(profile.device_ids, ("0x9a78",))
        self.assertEqual(profile.driver_versions, ("24.2.8",))
        self.assertEqual(profile.runtime_vendor, "intel")
        self.assertEqual(profile.runtime_api, "vulkan")
        self.assertEqual(profile.runtime_family, "gen12")
        self.assertEqual(profile.runtime_driver, "24.2.8")
        self.assertEqual(profile.backend_lane, "vulkan_doe_comparable")

    def test_amd_compatibility_profile_keeps_device_selection_open(self) -> None:
        profile = preflight.resolve_vulkan_host_profile(
            PROFILE_POLICY,
            "linux_amd_vulkan",
        )

        self.assertEqual(profile.vendor_id, "0x1002")
        self.assertEqual(
            profile.icd_path,
            Path("/usr/share/vulkan/icd.d/radeon_icd.x86_64.json"),
        )
        self.assertEqual(profile.device_ids, ())
        self.assertEqual(profile.driver_versions, ())

    def test_unknown_profile_fails_with_available_ids(self) -> None:
        with self.assertRaisesRegex(
            ValueError,
            "linux_intel_tiger_lake_vulkan",
        ):
            preflight.resolve_vulkan_host_profile(PROFILE_POLICY, "missing")

    def test_pci_identifiers_normalize_across_tool_formats(self) -> None:
        self.assertEqual(preflight.normalize_pci_id("0x00009A78"), "0x9a78")
        self.assertEqual(preflight.normalize_pci_id("32902"), "0x8086")

    def test_doe_probe_uses_selected_profile_contract(self) -> None:
        profile = preflight.resolve_vulkan_host_profile(
            PROFILE_POLICY,
            "linux_intel_tiger_lake_vulkan",
        )
        with tempfile.TemporaryDirectory() as tmpdir:
            runtime_bin = Path(tmpdir) / "doe-zig-runtime"
            runtime_bin.write_bytes(b"runtime")

            def fake_run(command: list[str], **_: object) -> subprocess.CompletedProcess[str]:
                trace_meta_path = Path(command[command.index("--trace-meta") + 1])
                trace_meta_path.write_text(
                    json.dumps({"adapterOrdinal": 0}),
                    encoding="utf-8",
                )
                return subprocess.CompletedProcess(command, 0, "", "")

            with mock.patch.object(preflight.subprocess, "run", side_effect=fake_run) as run:
                payload, message = preflight.probe_doe_adapter(runtime_bin, profile)

        self.assertEqual(message, "ok")
        self.assertEqual(payload, {"adapterOrdinal": 0})
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--vendor") + 1], "intel")
        self.assertIn(
            "VK_DRIVER_FILES=/usr/share/vulkan/icd.d/intel_icd.x86_64.json",
            command,
        )
        self.assertIn(
            "VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/intel_icd.x86_64.json",
            command,
        )
        self.assertEqual(command[command.index("--family") + 1], "gen12")
        self.assertEqual(command[command.index("--driver") + 1], "24.2.8")
        self.assertEqual(
            command[command.index("--backend-lane") + 1],
            "vulkan_doe_comparable",
        )

    def test_vulkaninfo_probe_is_pinned_to_profile_icd(self) -> None:
        profile = preflight.resolve_vulkan_host_profile(
            PROFILE_POLICY,
            "linux_intel_tiger_lake_vulkan",
        )
        summary = """Devices:
========
GPU0:
    vendorID = 0x8086
    deviceID = 0x9a78
"""
        completed = subprocess.CompletedProcess(
            ["vulkaninfo", "--summary"],
            0,
            summary,
            "",
        )
        with mock.patch.object(
            preflight.subprocess,
            "run",
            return_value=completed,
        ) as run:
            devices, message = preflight.probe_vulkaninfo_gpus(profile)

        self.assertEqual(message, "ok")
        self.assertEqual(devices[0]["vendorID"], "0x8086")
        environment = run.call_args.kwargs["env"]
        self.assertEqual(
            environment["VK_DRIVER_FILES"],
            "/usr/share/vulkan/icd.d/intel_icd.x86_64.json",
        )
        self.assertEqual(
            environment["VK_ICD_FILENAMES"],
            "/usr/share/vulkan/icd.d/intel_icd.x86_64.json",
        )

    def test_software_or_wrong_driver_device_cannot_match_intel_profile(self) -> None:
        profile = preflight.resolve_vulkan_host_profile(
            PROFILE_POLICY,
            "linux_intel_tiger_lake_vulkan",
        )
        self.assertTrue(
            preflight.vulkan_device_matches_profile(
                {
                    "vendorID": "0x8086",
                    "deviceID": "0x9a78",
                    "driverVersion": "24.2.8",
                },
                profile,
            )
        )
        self.assertFalse(
            preflight.vulkan_device_matches_profile(
                {
                    "vendorID": "0x10005",
                    "deviceID": "0x0000",
                    "driverVersion": "24.2.8",
                    "deviceName": "llvmpipe",
                },
                profile,
            )
        )
        self.assertFalse(
            preflight.vulkan_device_matches_profile(
                {
                    "vendorID": "0x8086",
                    "deviceID": "0x9a78",
                    "driverVersion": "25.0.0",
                },
                profile,
            )
        )

    def test_profile_is_registered_in_cube_and_governed_vulkan_lanes(self) -> None:
        profile_id = "linux_intel_tiger_lake_vulkan"
        cube = json.loads(
            (REPO_ROOT / "config" / "benchmark-cube-policy.json").read_text(
                encoding="utf-8"
            )
        )
        governed = json.loads(
            (REPO_ROOT / "config" / "governed-lanes.json").read_text(
                encoding="utf-8"
            )
        )

        host_ids = {row["id"] for row in cube["hostProfiles"]}
        self.assertIn(profile_id, host_ids)
        backend_surface = next(
            row for row in cube["surfaces"] if row["id"] == "backend_native"
        )
        self.assertIn(profile_id, backend_surface["expectedHostProfiles"])
        vulkan_lanes = [
            row for row in governed["lanes"] if row["id"].startswith("vulkan_")
        ]
        self.assertGreater(len(vulkan_lanes), 0)
        for lane in vulkan_lanes:
            self.assertIn(profile_id, lane["hostProfiles"])


if __name__ == "__main__":
    unittest.main()
