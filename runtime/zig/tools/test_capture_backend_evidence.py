"""Focused tests for recomposition backend-output evidence."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from capture_backend_evidence import _representative_output_evidence


WORKLOAD_ID = "compute_workgroup_atomic_1024"


def _write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _sample(backend: str, *, matched: int = 1) -> dict[str, object]:
    return {
        "success": True,
        "traceMeta": {
            "executionBackend": backend,
            "executionDispatchCount": 100,
            "executionSuccessCount": 1,
            "outputOracleCount": 1,
            "outputOracleMatchedCount": matched,
            "outputOracleFailedCount": 1 - matched,
        },
    }


def _fixture(root: Path, *, matched: int = 1) -> Path:
    left_path = root / "bench/out/native/left.run.json"
    right_path = root / "bench/out/native/right.run.json"
    _write_json(
        left_path,
        {
            "product": "doe",
            "workload": {"id": WORKLOAD_ID},
            "samples": [_sample("doe_vulkan", matched=matched)],
        },
    )
    _write_json(
        right_path,
        {
            "product": "dawn_delegate",
            "workload": {"id": WORKLOAD_ID},
            "samples": [_sample("dawn_delegate")],
        },
    )
    report_path = root / "bench/out/native/report.json"
    _write_json(
        report_path,
        {
            "comparisonStatus": "comparable",
            "workloads": [
                {
                    "id": WORKLOAD_ID,
                    "baselineStatsMs": {"count": 1},
                    "comparisonStatsMs": {"count": 1},
                    "comparability": {
                        "comparable": True,
                        "blockingFailedObligations": [],
                    },
                    "receipts": {
                        "left": {
                            "path": left_path.relative_to(root).as_posix(),
                            "product": "doe",
                            "sha256": _sha256(left_path),
                        },
                        "right": {
                            "path": right_path.relative_to(root).as_posix(),
                            "product": "dawn_delegate",
                            "sha256": _sha256(right_path),
                        },
                    },
                }
            ],
        },
    )
    return report_path


class RepresentativeOutputEvidenceTests(unittest.TestCase):
    def test_accepts_hash_bound_comparable_output_oracles(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            report_path = _fixture(root)
            evidence = _representative_output_evidence(
                report_path,
                root,
                WORKLOAD_ID,
            )
            self.assertEqual(evidence["reportPath"], "bench/out/native/report.json")
            self.assertEqual(evidence["baseline"]["executionBackend"], "doe_vulkan")
            self.assertEqual(evidence["comparison"]["executionBackend"], "dawn_delegate")
            self.assertEqual(evidence["baseline"]["dispatchCount"], 100)
            self.assertEqual(evidence["baseline"]["outputOracleMatchedCount"], 1)

    def test_rejects_failed_output_oracle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            report_path = _fixture(root, matched=0)
            with self.assertRaisesRegex(ValueError, "output oracle failed"):
                _representative_output_evidence(report_path, root, WORKLOAD_ID)

    def test_rejects_tampered_run_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            report_path = _fixture(root)
            receipt_path = root / "bench/out/native/left.run.json"
            receipt_path.write_text(
                receipt_path.read_text(encoding="utf-8") + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                _representative_output_evidence(report_path, root, WORKLOAD_ID)


if __name__ == "__main__":
    unittest.main()
