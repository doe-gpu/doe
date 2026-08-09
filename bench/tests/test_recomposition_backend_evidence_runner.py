from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bench.runners.run_recomposition_backend_evidence import (
    REPO_ROOT,
    _backend_for_host,
    _receipt_from_output,
)
from bench.runners.run_local_d3d12_lane import receipt_paths


class RecompositionBackendEvidenceRunnerTests(unittest.TestCase):
    def test_extracts_one_existing_receipt(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPO_ROOT / "bench" / "out") as temporary:
            receipt = Path(temporary) / "metal.run.json"
            receipt.write_text("{}\n", encoding="utf-8")
            relative = receipt.relative_to(REPO_ROOT)
            output = f"  {relative.as_posix()}\n"
            self.assertEqual(_receipt_from_output(output, "baseline"), receipt)

    def test_rejects_ambiguous_receipt_output(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "expected exactly one"):
            _receipt_from_output("", "comparison")

    def test_explicit_backend_is_host_independent_for_dry_run(self) -> None:
        self.assertEqual(_backend_for_host("metal"), "metal")

    def test_d3d12_lane_extracts_multiple_receipts(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPO_ROOT / "bench" / "out") as temporary:
            root = Path(temporary)
            first = root / "first.run.json"
            second = root / "second.run.json"
            first.write_text("{}\n", encoding="utf-8")
            second.write_text("{}\n", encoding="utf-8")
            output = "\n".join(
                f"  {path.relative_to(REPO_ROOT).as_posix()}"
                for path in (first, second)
            )
            self.assertEqual(receipt_paths(output, "baseline"), [first, second])


if __name__ == "__main__":
    unittest.main()
