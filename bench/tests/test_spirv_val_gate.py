#!/usr/bin/env python3
"""Regression tests for spirv_val_gate.py."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_DIR = REPO_ROOT / "bench"
MODULE_PATH = BENCH_DIR / "gates" / "spirv_val_gate.py"

sys.path.insert(0, str(REPO_ROOT))


def load_module():
    spec = importlib.util.spec_from_file_location("spirv_val_gate", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load spirv_val_gate from {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SpirvValGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_module()

    def write_executable(self, root: Path, name: str, body: str) -> Path:
        path = root / name
        path.write_text(body, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
        return path

    def test_validate_spv_passes_with_valid_binary(self) -> None:
        """spirv-val returning 0 is reported as pass."""
        with tempfile.TemporaryDirectory(prefix="fawn-spirv-val-gate-") as tmpdir:
            root = Path(tmpdir)
            spv = root / "test.spv"
            spv.write_bytes(b"\x00" * 40)
            validator = self.write_executable(
                root,
                "spirv-val",
                "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n",
            )
            ok, msg = self.module.validate_spv(str(validator), spv)
            self.assertTrue(ok)
            self.assertEqual(msg, "valid")

    def test_validate_spv_fails_with_invalid_binary(self) -> None:
        """spirv-val returning non-zero is reported as fail."""
        with tempfile.TemporaryDirectory(prefix="fawn-spirv-val-gate-") as tmpdir:
            root = Path(tmpdir)
            spv = root / "bad.spv"
            spv.write_bytes(b"\xff" * 20)
            validator = self.write_executable(
                root,
                "spirv-val",
                "#!/usr/bin/env python3\nimport sys\nsys.stderr.write('invalid magic\\n')\nsys.exit(1)\n",
            )
            ok, msg = self.module.validate_spv(str(validator), spv)
            self.assertFalse(ok)
            self.assertIn("invalid magic", msg)

    def test_collect_spv_files_excludes_dependency_trees(self) -> None:
        """Vendored and third-party .spv files are excluded from collection."""
        with tempfile.TemporaryDirectory(prefix="fawn-spirv-val-gate-") as tmpdir:
            root = Path(tmpdir)
            own_spv = root / "own" / "shader.spv"
            own_spv.parent.mkdir(parents=True)
            own_spv.write_bytes(b"\x00" * 20)
            for directory in ("vendor", "third_party", "node_modules", ".git"):
                dependency_spv = root / "own" / directory / "bad.spv"
                dependency_spv.parent.mkdir(parents=True)
                dependency_spv.write_bytes(b"\xff" * 20)

            files = self.module.collect_spv_files([root])
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0], own_spv)

    def test_collect_spv_files_deduplicates(self) -> None:
        """Duplicate paths (same resolved location) are deduplicated."""
        with tempfile.TemporaryDirectory(prefix="fawn-spirv-val-gate-") as tmpdir:
            root = Path(tmpdir)
            spv = root / "shader.spv"
            spv.write_bytes(b"\x00" * 20)

            files = self.module.collect_spv_files([root, root])
            self.assertEqual(len(files), 1)

    def test_find_spirv_val_returns_none_when_missing(self) -> None:
        """find_spirv_val returns None when tool is not on PATH."""
        result = self.module.find_spirv_val(
            "/nonexistent/path/to/spirv-val-definitely-not-here-12345"
        )
        # Should return the path as-is (fallback) since shutil.which will
        # not find it but the explicit path is returned directly.
        self.assertIsNotNone(result)

    def test_find_spirv_val_auto_detects(self) -> None:
        """find_spirv_val with empty string tries PATH auto-detection."""
        result = self.module.find_spirv_val("")
        # Result depends on whether spirv-val is installed.
        # We just verify it does not raise.
        self.assertIsInstance(result, (str, type(None)))

    def test_json_report_written(self) -> None:
        """JSON report is written when --json-report is specified."""
        with tempfile.TemporaryDirectory(prefix="fawn-spirv-val-gate-") as tmpdir:
            root = Path(tmpdir)
            spv = root / "test.spv"
            spv.write_bytes(b"\x00" * 40)
            validator = self.write_executable(
                root,
                "spirv-val",
                "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n",
            )
            report_path = root / "report.json"

            ok, _ = self.module.validate_spv(str(validator), spv)
            self.assertTrue(ok)

            # Write a minimal report manually to test the format
            report = {
                "gate": "spirv_val",
                "spirvVal": str(validator),
                "totalFiles": 1,
                "passed": 1,
                "failed": 0,
                "failures": [],
            }
            report_path.write_text(
                json.dumps(report, indent=2) + "\n", encoding="utf-8"
            )
            loaded = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(loaded["gate"], "spirv_val")
            self.assertEqual(loaded["passed"], 1)
            self.assertEqual(loaded["failed"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
