#!/usr/bin/env python3
"""Tests for the drop-in cutover rehearsal receipt builder."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import jsonschema

from bench.tools import build_dropin_cutover_rehearsal_receipt as builder


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "config" / "dropin-cutover-rehearsal-receipt.schema.json"


def _write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _stats(value: float) -> dict:
    return {
        "count": 1,
        "minMs": value,
        "maxMs": value,
        "p10Ms": value,
        "p50Ms": value,
        "p95Ms": value,
        "p99Ms": value,
        "meanMs": value,
        "stdevMs": 0.0,
    }


def _dropin_report(artifact: str) -> dict:
    symbol_report = {
        "pass": True,
        "requiredSymbolCount": 199,
        "exportedSymbolCount": 240,
        "missingSymbolCount": 0,
        "extraSymbolCount": 41,
    }
    child_pass = {"pass": True}
    return {
        "schemaVersion": 1,
        "artifact": artifact,
        "benchmarkHtml": "tmp-dropin/dropin-benchmark.html",
        "outputTimestamp": "20260702T000000Z",
        "pass": True,
        "steps": [
            {
                "label": "symbol_gate",
                "pass": True,
                "returnCode": 0,
                "report": symbol_report,
            },
            {
                "label": "behavior_suite",
                "pass": True,
                "returnCode": 0,
                "report": child_pass,
            },
            {
                "label": "proc_resolution",
                "pass": True,
                "returnCode": 0,
            },
            {
                "label": "benchmark_suite",
                "pass": True,
                "returnCode": 0,
                "report": child_pass,
            },
            {
                "label": "benchmark_visualization",
                "pass": True,
                "returnCode": 0,
            },
        ],
    }


def _compare_report() -> dict:
    return {
        "schemaVersion": 1,
        "artifactKind": "compare-report",
        "generatedAt": "2026-07-02T00:00:00Z",
        "outPath": "tmp-dropin/rollback.compare.json",
        "comparisonStatus": "comparable",
        "primaryMetric": "measured_ms",
        "deltaPercentConvention": "positive_means_baseline_faster_percent_of_comparison_time_saved",
        "deltaPercentFormula": "((comparisonMs - baselineMs) / comparisonMs) * 100",
        "comparabilityPolicy": {"mode": "strict", "requireTimingClass": "operation"},
        "participants": {
            "left": {
                "product": "doe",
                "executorId": "doe_vulkan",
                "runtimeIdentity": {},
                "hostIdentity": {},
            },
            "right": {
                "product": "dawn",
                "executorId": "dawn_delegate",
                "runtimeIdentity": {},
                "hostIdentity": {},
            },
        },
        "workloadManifest": {
            "path": "bench/workloads/workloads.amd.vulkan.json",
            "sha256": "a" * 64,
            "ownership": "generated",
            "inputFreshness": "fresh",
            "freshnessReason": "test",
        },
        "runReceiptPaths": [],
        "comparabilitySummary": {"workloadCount": 1, "nonComparableCount": 0},
        "comparabilityFailures": [],
        "overall": {
            "baselineStatsMs": _stats(1.0),
            "comparisonStatsMs": _stats(1.2),
            "deltaPercent": {
                "meanPercent": 1.0,
                "p10Percent": 1.0,
                "p50Percent": 1.0,
                "p95Percent": 1.0,
                "p99Percent": 1.0,
            },
        },
        "overallWorkloadUnitWall": {
            "baselineStatsMs": _stats(1.0),
            "comparisonStatsMs": _stats(1.2),
            "deltaPercent": {
                "meanPercent": 1.0,
                "p10Percent": 1.0,
                "p50Percent": 1.0,
                "p95Percent": 1.0,
                "p99Percent": 1.0,
            },
        },
        "workloads": [
            {
                "id": "dropin_test",
                "comparability": {
                    "baselineExecutionBackends": ["doe_vulkan"],
                    "comparisonExecutionBackends": ["dawn_delegate"],
                },
            }
        ],
    }


def _claim_report(compare_path: str) -> dict:
    return {
        "schemaVersion": 1,
        "artifactKind": "claim-report",
        "generatedAt": "2026-07-02T00:00:00Z",
        "compareReport": {"path": compare_path, "sha256": "b" * 64},
        "comparisonStatus": "comparable",
        "claimStatus": "claimable",
        "pass": True,
        "claimPolicy": {
            "mode": "release",
            "minTimedSamples": 0,
            "benchmarkPolicy": {
                "path": "config/benchmark-methodology-thresholds.json",
                "sha256": "c" * 64,
            },
            "policyHash": "c" * 64,
        },
        "workloads": [
            {
                "workloadId": "dropin_test",
                "claimable": True,
                "reasons": [],
                "claimMetricField": "status",
                "claimMetricScope": "dropin",
                "requiredPositivePercentiles": [],
            }
        ],
        "reasons": [],
    }


class DropinCutoverRehearsalReceiptTest(unittest.TestCase):
    def test_build_receipt_binds_dropin_gate_and_rollback_evidence(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
            root = Path(tmpdir)
            (root / "config").mkdir()
            (root / "tmp-dropin").mkdir()
            artifact = root / "tmp-dropin" / "libwebgpu_doe.so"
            artifact.write_bytes(b"dropin")
            cutover_policy = {
                "schemaVersion": 1,
                "cutover": {
                    "targetLane": "metal_doe_app",
                    "defaultBackend": "doe_vulkan",
                    "requiredComparablePasses": 1,
                    "requiredClaimablePasses": 1,
                    "requireRollbackRehearsal": True,
                },
                "rollback": {
                    "switchName": "strict_no_runtime_fallback",
                    "switchBackend": "dawn_delegate",
                    "requiredCiValidation": False,
                },
            }
            _write_json(root / "config" / "backend-cutover-policy.json", cutover_policy)
            _write_json(
                root / "tmp-dropin" / "dropin-report.json",
                _dropin_report("tmp-dropin/libwebgpu_doe.so"),
            )
            _write_json(root / "tmp-dropin" / "rollback.compare.json", _compare_report())
            _write_json(
                root / "tmp-dropin" / "rollback.claim.json",
                _claim_report("tmp-dropin/rollback.compare.json"),
            )

            receipt = builder.build_receipt(
                root=root,
                cutover_policy_path=Path("config/backend-cutover-policy.json"),
                dropin_report_path=Path("tmp-dropin/dropin-report.json"),
                rollback_report_path=Path("tmp-dropin/rollback.compare.json"),
                rollback_claim_path=Path("tmp-dropin/rollback.claim.json"),
                receipt_id="test-dropin-cutover",
            )

        jsonschema.validate(receipt, json.loads(SCHEMA_PATH.read_text(encoding="utf-8")))
        self.assertEqual(receipt["artifactKind"], "dropin-cutover-rehearsal-receipt")
        self.assertEqual(receipt["comparisonStatus"], "comparable")
        self.assertEqual(receipt["claimStatus"], "claimable")
        self.assertEqual(receipt["abiValidation"]["missingSymbolCount"], 0)
        self.assertIs(receipt["rehearsal"]["rollbackRehearsed"], True)
        self.assertIn(
            "dawn_delegate",
            receipt["rollbackBackendEvidence"]["observedExecutionBackends"],
        )

    def test_build_receipt_rejects_missing_proc_resolution_step(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
            root = Path(tmpdir)
            (root / "config").mkdir()
            (root / "tmp-dropin").mkdir()
            artifact = root / "tmp-dropin" / "libwebgpu_doe.so"
            artifact.write_bytes(b"dropin")
            cutover_policy = {
                "schemaVersion": 1,
                "cutover": {
                    "targetLane": "metal_doe_app",
                    "defaultBackend": "doe_vulkan",
                    "requiredComparablePasses": 1,
                    "requiredClaimablePasses": 1,
                    "requireRollbackRehearsal": True,
                },
                "rollback": {
                    "switchName": "strict_no_runtime_fallback",
                    "switchBackend": "dawn_delegate",
                    "requiredCiValidation": False,
                },
            }
            report = _dropin_report("tmp-dropin/libwebgpu_doe.so")
            report["steps"] = [
                step for step in report["steps"] if step["label"] != "proc_resolution"
            ]
            _write_json(root / "config" / "backend-cutover-policy.json", cutover_policy)
            _write_json(root / "tmp-dropin" / "dropin-report.json", report)
            _write_json(root / "tmp-dropin" / "rollback.compare.json", _compare_report())
            _write_json(
                root / "tmp-dropin" / "rollback.claim.json",
                _claim_report("tmp-dropin/rollback.compare.json"),
            )

            with self.assertRaisesRegex(ValueError, "proc_resolution"):
                builder.build_receipt(
                    root=root,
                    cutover_policy_path=Path("config/backend-cutover-policy.json"),
                    dropin_report_path=Path("tmp-dropin/dropin-report.json"),
                    rollback_report_path=Path("tmp-dropin/rollback.compare.json"),
                    rollback_claim_path=Path("tmp-dropin/rollback.claim.json"),
                )


if __name__ == "__main__":
    unittest.main()
