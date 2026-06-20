from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from bench.lib import report_conformance


class TestReportConformance(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.contract_path = self.root / "workloads.json"
        self.benchmark_policy_path = self.root / "benchmark-policy.json"
        self.compare_path = self.root / "sample.compare.json"
        self.claim_path = self.root / "sample.claim.json"
        self.obligations_path = self.root / "comparability-obligations.json"

        self.contract_path.write_text(
            json.dumps(
                {
                    "workloads": [
                        {
                            "id": "w0",
                            "pathAsymmetry": False,
                            "pathAsymmetryNote": "",
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        self.benchmark_policy_path.write_text(
            json.dumps({"schemaVersion": 1}),
            encoding="utf-8",
        )
        self.obligations_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 2,
                    "obligations": [
                        {
                            "id": "matching_workload_id",
                            "blocking": True,
                            "applicableWhen": {"const": True},
                            "passesWhen": {"const": True},
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _write_archive_registry(self, archive_path: Path, archive_hash: str) -> None:
        config_dir = self.root / "config"
        config_dir.mkdir()
        registry_path = config_dir / "workload-manifest-archives.json"
        registry_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "archives": [
                        {
                            "originalPath": "workloads.json",
                            "sha256": archive_hash,
                            "archivePath": archive_path.name,
                            "reason": "fixture historical manifest",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

    def _compare_payload(self) -> dict[str, object]:
        return {
            "schemaVersion": 1,
            "artifactKind": "compare-report",
            "generatedAt": "2026-04-09T12:00:00+00:00",
            "outPath": str(self.compare_path),
            "comparisonStatus": "comparable",
            "primaryMetric": "measured_ms",
            "deltaPercentConvention": (
                "positive_means_baseline_faster_percent_of_comparison_time_saved"
            ),
            "deltaPercentFormula": "((comparisonMs - baselineMs) / comparisonMs) * 100",
            "comparabilityPolicy": {
                "mode": "strict",
                "requireTimingClass": "operation",
            },
            "participants": {
                "left": {
                    "product": "doe",
                    "executorId": "doe_direct_vulkan",
                    "runtimeIdentity": {},
                    "hostIdentity": {},
                },
                "right": {
                    "product": "dawn",
                    "executorId": "dawn_delegate_vulkan",
                    "runtimeIdentity": {},
                    "hostIdentity": {},
                },
            },
            "workloadManifest": {
                "path": str(self.contract_path),
                "sha256": report_conformance.file_sha256(self.contract_path),
                "ownership": "generated",
                "inputFreshness": "fresh",
                "freshnessReason": "test fixture",
            },
            "runReceiptPaths": [],
            "comparabilitySummary": {
                "workloadCount": 1,
                "nonComparableCount": 0,
            },
            "comparabilityFailures": [],
            "overall": {},
            "overallWorkloadUnitWall": {},
            "workloads": [
                {
                    "id": "w0",
                    "name": "workload 0",
                    "description": "fixture workload",
                    "domain": "compute",
                    "workloadComparable": True,
                    "benchmarkClass": "comparable",
                    "claimEligible": True,
                    "pathAsymmetry": False,
                    "pathAsymmetryNote": "",
                    "receipts": {
                        "left": {"path": "", "product": "doe", "sha256": ""},
                        "right": {"path": "", "product": "dawn", "sha256": ""},
                    },
                    "workloadMatching": {"matched": True, "reasons": []},
                    "comparability": {
                        "comparable": True,
                        "reasons": [],
                        "obligationSchemaVersion": 2,
                        "obligations": [
                            {
                                "id": "matching_workload_id",
                                "blocking": True,
                                "applicable": True,
                                "passes": True,
                            }
                        ],
                        "blockingFailedObligations": [],
                    },
                    "primaryMetric": "measured_ms",
                    "normalization": "none",
                    "baselineStatsMs": {"count": 1},
                    "comparisonStatsMs": {"count": 1},
                    "deltaPercent": {"p50Percent": 1.0},
                    "workloadUnitWall": {},
                    "timingInterpretation": {},
                }
            ],
        }

    def _claim_payload(self) -> dict[str, object]:
        return {
            "schemaVersion": 1,
            "artifactKind": "claim-report",
            "generatedAt": "2026-04-09T12:10:00+00:00",
            "compareReport": {
                "path": str(self.compare_path),
                "sha256": report_conformance.file_sha256(self.compare_path),
            },
            "comparisonStatus": "comparable",
            "claimStatus": "claimable",
            "pass": True,
            "claimPolicy": {
                "mode": "local",
                "minTimedSamples": 15,
                "benchmarkPolicy": {
                    "path": str(self.benchmark_policy_path),
                    "sha256": report_conformance.file_sha256(self.benchmark_policy_path),
                },
                "policyHash": "a" * 64,
            },
            "workloads": [
                {
                    "workloadId": "w0",
                    "claimable": True,
                    "reasons": [],
                    "claimMetricField": "deltaPercent",
                    "claimMetricScope": "selectedTiming",
                    "requiredPositivePercentiles": ["p50Percent", "p95Percent"],
                }
            ],
            "reasons": [],
        }

    def test_validate_report_conformance_accepts_matching_compare_report(self) -> None:
        payload = self._compare_payload()
        self.compare_path.write_text(json.dumps(payload), encoding="utf-8")
        schema_version, obligation_ids = report_conformance.load_obligation_contract(
            self.obligations_path
        )
        ok, reason = report_conformance.validate_report_conformance(
            payload=payload,
            report_path=self.compare_path,
            repo_root=self.root,
            expected_obligation_schema_version=schema_version,
            expected_obligation_ids=obligation_ids,
        )
        self.assertTrue(ok, reason)
        self.assertEqual(reason, "")

    def test_validate_report_conformance_accepts_registered_archive_manifest(self) -> None:
        archive_path = self.root / "workloads.archive.json"
        archive_path.write_text(self.contract_path.read_text(encoding="utf-8"), encoding="utf-8")
        archive_hash = report_conformance.file_sha256(archive_path)
        self.contract_path.write_text(
            json.dumps(
                {
                    "workloads": [
                        {
                            "id": "w0",
                            "pathAsymmetry": True,
                            "pathAsymmetryNote": "current manifest changed",
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
        self._write_archive_registry(archive_path, archive_hash)

        payload = self._compare_payload()
        payload["workloadManifest"]["sha256"] = archive_hash
        self.compare_path.write_text(json.dumps(payload), encoding="utf-8")
        schema_version, obligation_ids = report_conformance.load_obligation_contract(
            self.obligations_path
        )
        ok, reason = report_conformance.validate_report_conformance(
            payload=payload,
            report_path=self.compare_path,
            repo_root=self.root,
            expected_obligation_schema_version=schema_version,
            expected_obligation_ids=obligation_ids,
        )
        self.assertTrue(ok, reason)
        self.assertEqual(reason, "")

        resolved_live_path = report_conformance.resolve_contract_path(
            report_path=self.compare_path,
            repo_root=self.root,
            raw_contract_path=str(self.contract_path),
        )
        self.assertEqual(resolved_live_path, self.contract_path)

    def test_validate_report_conformance_rejects_unregistered_manifest_hash(self) -> None:
        payload = self._compare_payload()
        payload["workloadManifest"]["sha256"] = "b" * 64
        self.compare_path.write_text(json.dumps(payload), encoding="utf-8")
        schema_version, obligation_ids = report_conformance.load_obligation_contract(
            self.obligations_path
        )
        ok, reason = report_conformance.validate_report_conformance(
            payload=payload,
            report_path=self.compare_path,
            repo_root=self.root,
            expected_obligation_schema_version=schema_version,
            expected_obligation_ids=obligation_ids,
        )
        self.assertFalse(ok)
        self.assertIn("workloadManifest.sha256 mismatch", reason)

    def test_validate_claim_report_conformance_accepts_matching_sidecar(self) -> None:
        compare_payload = self._compare_payload()
        self.compare_path.write_text(json.dumps(compare_payload), encoding="utf-8")
        claim_payload = self._claim_payload()
        self.claim_path.write_text(json.dumps(claim_payload), encoding="utf-8")

        ok, reason = report_conformance.validate_claim_report_conformance(
            compare_payload=compare_payload,
            compare_report_path=self.compare_path,
            claim_payload=claim_payload,
            claim_report_path=self.claim_path,
        )
        self.assertTrue(ok, reason)
        self.assertEqual(reason, "")

    def test_validate_claim_report_conformance_rejects_compare_sha_mismatch(self) -> None:
        compare_payload = self._compare_payload()
        self.compare_path.write_text(json.dumps(compare_payload), encoding="utf-8")
        claim_payload = self._claim_payload()
        claim_payload["compareReport"]["sha256"] = "f" * 64
        self.claim_path.write_text(json.dumps(claim_payload), encoding="utf-8")

        ok, reason = report_conformance.validate_claim_report_conformance(
            compare_payload=compare_payload,
            compare_report_path=self.compare_path,
            claim_payload=claim_payload,
            claim_report_path=self.claim_path,
        )
        self.assertFalse(ok)
        self.assertIn("compareReport.sha256 mismatch", reason)


if __name__ == "__main__":
    unittest.main()
