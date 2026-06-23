from __future__ import annotations

import sys
import unittest
from pathlib import Path

from bench.tools._repo_import import ensure_repo_root


REPO_ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = REPO_ROOT / "bench" / "tools" / "_repo_import.py"


class TestToolRepoImport(unittest.TestCase):
    def test_ensure_repo_root_adds_repo_and_bench_once(self) -> None:
        original_path = list(sys.path)
        repo_text = str(REPO_ROOT)
        bench_text = str(REPO_ROOT / "bench")
        try:
            sys.path[:] = [
                entry for entry in sys.path if entry not in {repo_text, bench_text}
            ]

            self.assertEqual(ensure_repo_root(HELPER_PATH), REPO_ROOT)
            ensure_repo_root(HELPER_PATH)

            self.assertIn(repo_text, sys.path)
            self.assertIn(bench_text, sys.path)
            self.assertEqual(sys.path.count(repo_text), 1)
            self.assertEqual(sys.path.count(bench_text), 1)
        finally:
            sys.path[:] = original_path


if __name__ == "__main__":
    unittest.main()
