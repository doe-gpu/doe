"""Focused tests for recomposition backend-output evidence."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from capture_backend_evidence import (
    _d3d12_device_from_payload,
    _metal_device_from_payload,
    _preserve_captured_backends,
    _representative_output_evidence,
)


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
            "fallbackUsed": False,
        },
    }


def _fixture(
    root: Path,
    *,
    matched: int = 1,
    backend: str = "doe_vulkan",
    api: str = "vulkan",
) -> Path:
    left_path = root / "bench/out/native/left.run.json"
    right_path = root / "bench/out/native/right.run.json"
    _write_json(
        left_path,
        {
            "hostIdentity": {"api": api},
            "product": "doe",
            "workload": {"id": WORKLOAD_ID},
            "samples": [_sample(backend, matched=matched)],
        },
    )
    _write_json(
        right_path,
        {
            "hostIdentity": {"api": api},
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
            self.assertEqual(
                evidence["comparison"]["executionBackend"],
                "dawn_delegate",
            )
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

    def test_accepts_metal_backend_and_api_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            report_path = _fixture(root, backend="doe_metal", api="metal")
            evidence = _representative_output_evidence(
                report_path,
                root,
                WORKLOAD_ID,
                "Metal",
                "doe_metal",
            )
            self.assertEqual(evidence["baseline"]["executionBackend"], "doe_metal")

    def test_parses_physical_metal_device(self) -> None:
        device = _metal_device_from_payload(
            {
                "SPDisplaysDataType": [
                    {
                        "sppci_model": "Apple M4 Max",
                        "spdisplays_metal": "Metal Support",
                    }
                ]
            }
        )
        self.assertEqual(device["deviceName"], "Apple M4 Max")

    def test_rejects_windows_software_adapter(self) -> None:
        device = _d3d12_device_from_payload(
            {
                "Name": "Microsoft Basic Render Driver",
                "DriverVersion": "1.0",
                "AdapterCompatibility": "Microsoft",
            }
        )
        self.assertIsNone(device)

    def test_preserves_captured_evidence_from_another_host(self) -> None:
        backends = {
            "d3d12": {"representativeOutput": "not-captured"},
            "metal": {"representativeOutput": "not-captured"},
            "vulkan": {"representativeOutput": "not-captured"},
        }
        prior_vulkan = {
            "representativeOutput": "captured",
            "representativeOutputEvidence": {"workloadId": WORKLOAD_ID},
        }
        _preserve_captured_backends(
            backends,
            {
                "backends": {"vulkan": prior_vulkan},
                "host": {
                    "machine": "x86_64",
                    "operatingSystem": "Linux",
                    "release": "test",
                },
            },
        )
        self.assertEqual(backends["vulkan"]["representativeOutput"], "captured")
        self.assertEqual(
            backends["vulkan"]["evidenceHost"]["operatingSystem"],
            "Linux",
        )


if __name__ == "__main__":
    unittest.main()
