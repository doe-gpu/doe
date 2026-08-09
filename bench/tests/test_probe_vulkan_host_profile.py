#!/usr/bin/env python3
"""Tests for profile-selected Vulkan hardware evidence."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from bench.runners.probe_vulkan_host_profile import probe_profile


class VulkanHostProfileProbeTests(unittest.TestCase):
    def test_probe_keeps_matching_physical_device_and_excludes_other_icds(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-vulkan-profile-probe-") as tmpdir:
            root = Path(tmpdir)
            icd_path = root / "radeon.json"
            icd_path.write_text("{}\n", encoding="utf-8")
            render_node = root / "renderD128"
            render_node.write_text("device\n", encoding="utf-8")
            policy_path = root / "profiles.json"
            policy_path.write_text(
                json.dumps(
                    {
                        "profiles": [
                            {
                                "id": "linux_amd_vulkan",
                                "displayName": "AMD Vulkan",
                                "cubeHostProfile": "amd-vulkan",
                                "os": "linux",
                                "arch": "x64",
                                "vendorId": "0x1002",
                                "icdPaths": [str(icd_path)],
                                "deviceIds": [],
                                "driverVersions": [],
                                "runtimeProfile": {
                                    "vendor": "amd",
                                    "api": "vulkan",
                                    "family": "rdna",
                                    "driver": "mesa",
                                },
                                "backendLane": "vulkan",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            physical = {
                "ordinal": "0",
                "vendorID": "0x1002",
                "deviceID": "0x1586",
                "deviceType": "PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU",
                "deviceName": "Radeon",
                "driverVersion": "26.0.3",
            }
            software = {
                "ordinal": "1",
                "vendorID": "0x10005",
                "deviceID": "0x0000",
                "deviceType": "PHYSICAL_DEVICE_TYPE_CPU",
                "deviceName": "llvmpipe",
                "driverVersion": "26.0.3",
            }
            with (
                mock.patch(
                    "bench.runners.probe_vulkan_host_profile.platform.machine",
                    return_value="x86_64",
                ),
                mock.patch(
                    "bench.runners.probe_vulkan_host_profile.shutil.which",
                    return_value="/usr/bin/vulkaninfo",
                ),
                mock.patch(
                    "bench.runners.probe_vulkan_host_profile.os.access",
                    return_value=True,
                ),
                mock.patch.object(Path, "is_char_device", return_value=True),
                mock.patch(
                    "bench.runners.probe_vulkan_host_profile.probe_vulkaninfo_gpus",
                    return_value=([physical, software], "ok"),
                ),
            ):
                receipt = probe_profile(
                    profile_id="linux_amd_vulkan",
                    policy_path=policy_path,
                    render_node=render_node,
                )

        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["matchingDevices"], [physical])
        self.assertNotIn("llvmpipe", json.dumps(receipt))


if __name__ == "__main__":
    unittest.main()
