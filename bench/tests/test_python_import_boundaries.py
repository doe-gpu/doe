"""Tests for package-safe Python import boundaries."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bench.lib.python_import_boundaries import (
    _mutation_lines,
    validate_python_import_boundaries,
)


REPO_ROOT = Path(__file__).resolve().parents[2]


class TestPythonImportBoundaries(unittest.TestCase):
    def test_repository_policy_passes(self) -> None:
        self.assertEqual(validate_python_import_boundaries(REPO_ROOT), [])

    def test_ast_check_detects_path_insert(self) -> None:
        source = "import sys\nsys.path.insert(0, 'legacy')\n"
        self.assertEqual(_mutation_lines(source, Path("example.py")), [2])

    def test_policy_rejects_protected_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "config").mkdir()
            (root / "package").mkdir()
            (root / "package" / "entry.py").write_text(
                "import sys\nsys.path.append('legacy')\n",
                encoding="utf-8",
            )
            (root / "config" / "python-import-boundaries.json").write_text(
                '{"schemaVersion":1,"protectedPaths":["package"],"legacyDirectScriptRoots":[]}',
                encoding="utf-8",
            )
            failures = validate_python_import_boundaries(root)
            self.assertEqual(len(failures), 1)
            self.assertIn("sys.path mutation is forbidden", failures[0])


if __name__ == "__main__":
    unittest.main()
