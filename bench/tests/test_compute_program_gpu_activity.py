"""Adversarial DRM observation tests; fixtures are not physical GPU evidence."""

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import jsonschema

from bench.lib.compute_program_gpu_activity import (
    ACTIVITY_MODE,
    capture_activity,
    client_counters,
    detect_target,
    read_snapshot,
    reject_activity,
    validate_activity,
)

ROOT = Path(__file__).resolve().parents[2]
TARGET = {
    "renderNode": "/dev/dri/renderD128",
    "pciDevice": "0000:c2:00.0",
    "vendorId": 4098,
    "deviceId": 5510,
}
MODULE = "bench.lib.compute_program_gpu_activity"


def fdinfo(
    client: int, time_ns: int, *, pid: int = 12, fd: int = 3
) -> dict[str, object]:
    return {
        "pid": pid,
        "fd": fd,
        "contents": f"drm-driver: amdgpu\ndrm-pdev: {TARGET['pciDevice']}\n"
        f"drm-client-id: {client}\ndrm-engine-compute: {time_ns} ns\n"
        "drm-engine-capacity-compute: 4\n",
    }


def snapshot(tick: int, *records: dict[str, object]) -> dict[str, object]:
    return {"monotonicNs": tick, "fdinfo": list(records), "unreadableProcesses": []}


class GpuActivityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = self.root / "run.json"
        self.policy = {"gpuActivity": ACTIVITY_MODE}
        self.report = {
            "phase": "measure",
            "backend": "vulkan",
            "policyHash": "a" * 64,
            "provider": "doe-recorded",
            "adapter": {"vendorID": TARGET["vendorId"], "deviceID": TARGET["deviceId"]},
        }
        self.before = snapshot(1, fdinfo(9, 100))
        self.after = snapshot(2, fdinfo(9, 100))

    def capture(self) -> Path:
        with (
            patch(f"{MODULE}.detect_target", return_value=TARGET),
            patch(f"{MODULE}.read_snapshot", side_effect=[self.before, self.after]),
            capture_activity(self.output, self.policy, "a" * 64, "vulkan", "measure"),
        ):
            self.output.write_text(json.dumps(self.report), encoding="utf-8")
        return Path(f"{self.output}.gpu-activity.json")

    def test_duplicate_fds_and_shared_clients_are_not_double_counted(self) -> None:
        observed = snapshot(
            1, fdinfo(9, 100), fdinfo(9, 99, fd=4), fdinfo(9, 100, pid=13)
        )
        observed["fdinfo"][1]["contents"] = observed["fdinfo"][1]["contents"].replace(
            "drm-client-id: 9", "drm-client-id: 09"
        )
        self.assertEqual(
            client_counters(observed, TARGET["pciDevice"]), {"9": {"compute": 100}}
        )
        reject_activity([observed, self.after], TARGET["pciDevice"])

    def test_new_and_existing_foreign_work_is_rejected(self) -> None:
        for after in [
            snapshot(2, fdinfo(9, 101)),
            snapshot(2, fdinfo(9, 100), fdinfo(10, 1)),
        ]:
            with (
                self.subTest(after=after),
                self.assertRaisesRegex(ValueError, "Unrelated GPU activity"),
            ):
                reject_activity([self.before, after], TARGET["pciDevice"])

    def test_lost_clients_and_regressing_counters_are_not_idle_evidence(self) -> None:
        missing = fdinfo(9, 100)
        missing["contents"] = missing["contents"].replace(
            "drm-engine-compute: 100 ns\n", ""
        )
        for after, reason in [
            (snapshot(2), "coverage lost"),
            (snapshot(2, missing), "counters disappeared"),
            (snapshot(2, fdinfo(9, 99)), "regressed"),
            (snapshot(1, fdinfo(9, 100)), "not ordered"),
        ]:
            with (
                self.subTest(reason=reason),
                self.assertRaisesRegex(ValueError, reason),
            ):
                reject_activity([self.before, after], TARGET["pciDevice"])

    def test_wrong_identity_and_counter_units_fail_closed(self) -> None:
        for old, new, reason in [
            ("0000:c2:00.0", "0000:c3:00.0", "different PCI"),
            ("100 ns", "100 ms", "nanoseconds"),
            ("drm-client-id: 9", "drm-client-id: missing", "client identity"),
            (
                "drm-driver: amdgpu",
                "drm-driver: amdgpu\ndrm-driver: other",
                "Duplicate",
            ),
        ]:
            bad = copy.deepcopy(self.before)
            bad["fdinfo"][0]["contents"] = bad["fdinfo"][0]["contents"].replace(
                old, new
            )
            with (
                self.subTest(reason=reason),
                self.assertRaisesRegex(ValueError, reason),
            ):
                client_counters(bad, TARGET["pciDevice"])

    def test_sidecar_is_bound_to_run_policy_and_adapter(self) -> None:
        sidecar = self.capture()
        original = sidecar.read_text(encoding="utf-8")
        validate_activity(self.output, ROOT, self.policy, self.report)
        for field, value, reason in [
            ("evaluationHash", "0" * 64, "different evaluation"),
            ("policyHash", "0" * 64, "policy or backend"),
        ]:
            data = json.loads(original)
            data[field] = value
            sidecar.write_text(json.dumps(data), encoding="utf-8")
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, reason):
                validate_activity(self.output, ROOT, self.policy, self.report)
        sidecar.write_text(original, encoding="utf-8")
        changed = self.report | {"adapter": {"vendorID": 4098, "deviceID": 1}}
        with self.assertRaisesRegex(ValueError, "different adapter"):
            validate_activity(self.output, ROOT, self.policy, changed)
        sidecar.unlink()
        with self.assertRaises(FileNotFoundError):
            validate_activity(self.output, ROOT, self.policy, self.report)

    def test_admission_recomputes_raw_activity(self) -> None:
        self.after = snapshot(2, fdinfo(9, 101))
        self.capture()
        with self.assertRaisesRegex(ValueError, "Unrelated GPU activity"):
            validate_activity(self.output, ROOT, self.policy, self.report)

    def test_failure_keeps_observations_without_manufacturing_an_evaluation(
        self,
    ) -> None:
        with (
            patch(f"{MODULE}.detect_target", return_value=TARGET),
            patch(f"{MODULE}.read_snapshot", side_effect=[self.before, self.after]),
            self.assertRaisesRegex(RuntimeError, "child failed"),
            capture_activity(self.output, self.policy, "a" * 64, "vulkan", "measure"),
        ):
            raise RuntimeError("child failed")
        record = json.loads(
            Path(f"{self.output}.gpu-activity.json").read_text(encoding="utf-8")
        )
        self.assertIsNone(record["evaluationHash"])
        self.assertEqual(record["snapshots"], [self.before, self.after])
        schema = json.loads(
            (ROOT / "config/compute-program-gpu-activity.schema.json").read_text(
                encoding="utf-8"
            )
        )
        jsonschema.Draft202012Validator(schema).validate(record)

    def test_disabled_and_audit_modes_do_not_probe_or_change_execution(self) -> None:
        with patch(
            f"{MODULE}.detect_target", side_effect=AssertionError("unexpected probe")
        ):
            for policy, phase in [
                ({"gpuActivity": "off"}, "measure"),
                (self.policy, "audit"),
            ]:
                with capture_activity(self.output, policy, "a" * 64, "metal", phase):
                    pass
        with (
            self.assertRaisesRegex(ValueError, "requires the Vulkan"),
            capture_activity(self.output, self.policy, "a" * 64, "metal", "measure"),
        ):
            self.fail("unsupported backend executed")

    def test_read_snapshot_retains_only_target_drm_records(self) -> None:
        proc = self.root / "proc"
        for fd, target in [(3, "/dev/dri/renderD128"), (4, "/tmp/ordinary-file")]:
            (proc / "12/fd").mkdir(parents=True, exist_ok=True)
            (proc / "12/fdinfo").mkdir(exist_ok=True)
            (proc / f"12/fd/{fd}").symlink_to(target)
            (proc / f"12/fdinfo/{fd}").write_text(
                fdinfo(9, 100, fd=fd)["contents"], encoding="utf-8"
            )
        observed = read_snapshot(TARGET, proc)
        self.assertEqual(observed["fdinfo"], [fdinfo(9, 100)])
        with patch(
            f"{MODULE}.os.readlink",
            side_effect=PermissionError("fixture visibility gap"),
        ):
            observed = read_snapshot(TARGET, proc)
        self.assertEqual(observed["fdinfo"], [])
        self.assertEqual(observed["unreadableProcesses"], [12])

    def test_target_requires_unique_pci_render_device(self) -> None:
        drm = self.root / "drm"
        drm.mkdir()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            detect_target(drm)
        device = self.root / TARGET["pciDevice"]
        device.mkdir()
        for field, value in [("vendor", "0x1002"), ("device", "0x1586")]:
            (device / field).write_text(value, encoding="utf-8")
        (drm / "renderD128").mkdir()
        (drm / "renderD128/device").symlink_to(device)
        self.assertEqual(detect_target(drm), TARGET)
        (drm / "renderD129").mkdir()
        with self.assertRaisesRegex(ValueError, "exactly one"):
            detect_target(drm)

    def test_policy_version_controls_observation_explicitly(self) -> None:
        policy = json.loads(
            (ROOT / "config/compute-program-evaluation.json").read_text(
                encoding="utf-8"
            )
        )
        schema = json.loads(
            (ROOT / "config/compute-program-evaluation.schema.json").read_text(
                encoding="utf-8"
            )
        )
        validator = jsonschema.Draft202012Validator(schema)
        validator.validate(policy)
        with self.assertRaises(jsonschema.ValidationError):
            validator.validate(policy | {"schemaVersion": 3})
        del policy["gpuActivity"]
        with self.assertRaises(jsonschema.ValidationError):
            validator.validate(policy)
        validator.validate(policy | {"schemaVersion": 3})


if __name__ == "__main__":
    unittest.main()
