"""Tests for receipt-bound GPU smoke verification."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from bench.gates.verify_smoke_gpu_usage import _resource_ok


class VerifySmokeGpuUsageTests(unittest.TestCase):
    def _fixture(
        self,
        root: Path,
    ) -> tuple[dict[str, object], Path]:
        receipt_path = root / "bench/out/smoke/doe.run.json"
        receipt_path.parent.mkdir(parents=True)
        receipt = {
            "product": "doe",
            "workload": {"id": "upload"},
            "samples": [
                {
                    "success": True,
                    "resource": {
                        "gpuMemoryProbeAvailable": True,
                        "resourceSampleCount": 3,
                        "gpuVramUsedPeakBytes": 4096,
                    },
                }
            ],
        }
        receipt_path.write_text(
            json.dumps(receipt, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        workload: dict[str, object] = {
            "id": "upload",
            "baselineStatsMs": {"count": 1},
            "receipts": {
                "left": {
                    "path": receipt_path.relative_to(root).as_posix(),
                    "product": "doe",
                    "sha256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
                }
            },
        }
        return workload, receipt_path

    def test_receipt_bound_samples_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workload, _ = self._fixture(root)

            self.assertEqual(_resource_ok(workload, "baseline", root), (True, "ok"))

    def test_tampered_receipt_fails_hash_check(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workload, receipt_path = self._fixture(root)
            receipt_path.write_text("{}\n", encoding="utf-8")

            ok, message = _resource_ok(workload, "baseline", root)

            self.assertFalse(ok)
            self.assertIn("SHA-256", message)

    def test_missing_gpu_sample_evidence_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workload, receipt_path = self._fixture(root)
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["samples"][0]["resource"]["gpuVramUsedPeakBytes"] = 0
            receipt_path.write_text(
                json.dumps(receipt, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            workload["receipts"]["left"]["sha256"] = hashlib.sha256(
                receipt_path.read_bytes()
            ).hexdigest()

            ok, message = _resource_ok(workload, "baseline", root)

            self.assertFalse(ok)
            self.assertIn("gpuVramUsedPeakBytes", message)


if __name__ == "__main__":
    unittest.main()
