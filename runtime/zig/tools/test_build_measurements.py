"""Regressions for per-build accounting and private source-edit snapshots."""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import capture_build_measurements as measurement


class BuildMeasurementTests(unittest.TestCase):
    def test_snapshot_edits_never_touch_the_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repository = root / "source"
            repository.mkdir()
            subprocess.run(["git", "init", "-q", str(repository)], check=True)
            source = repository / "runtime/zig/leaf.zig"
            source.parent.mkdir(parents=True)
            source.write_text("pub const value: u32 = 4;\n", encoding="utf-8")
            snapshot = root / "snapshot"
            inputs = measurement._snapshot(repository, snapshot, ["runtime/zig"])
            self.assertEqual(inputs[0]["sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
            path, original, changed = measurement._apply_edit(snapshot / "runtime/zig", {
                "id": "constant", "path": "leaf.zig", "before": "= 4;", "after": "= 1 << 2;",
            })
            self.assertNotEqual(changed, inputs[0]["sha256"])
            self.assertEqual(source.read_bytes(), original)
            self.assertNotEqual(source.read_bytes(), path.read_bytes())
            with self.assertRaisesRegex(ValueError, "exactly one"):
                measurement._apply_edit(snapshot / "runtime/zig", {
                    "id": "stale", "path": "leaf.zig", "before": "= 4;", "after": "= 8;",
                })
            with self.assertRaisesRegex(ValueError, "within its root"):
                measurement._relative_path("../outside.zig")

    def test_each_build_has_its_own_memory_and_exit_status(self) -> None:
        if not hasattr(measurement.os, "wait4"):
            self.skipTest("POSIX resource accounting")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            large = measurement._run_build([sys.executable, "-c", "x = bytearray(64 * 1024 * 1024)"], root, root)
            small = measurement._run_build([sys.executable, "-c", "print('ok'); raise SystemExit(7)"], root, root)
            self.assertEqual(large["exitCode"], 0)
            self.assertEqual(small["exitCode"], 7)
            self.assertGreater(large["peakResidentBytes"], small["peakResidentBytes"])
            self.assertGreater(large["elapsedNs"], 0)
            self.assertEqual(small["stdout"], "ok\n")

    def test_declared_edits_change_one_real_source_fragment(self) -> None:
        profile = json.loads(measurement.PROFILE_PATH.read_text(encoding="utf-8"))
        for edit in profile["edits"]:
            source = (measurement.ROOT / edit["path"]).read_text(encoding="utf-8")
            self.assertEqual(source.count(edit["before"]), 1, edit["id"])
            self.assertNotEqual(edit["before"], edit["after"])


if __name__ == "__main__":
    unittest.main()
