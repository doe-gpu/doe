"""Tests for release claim-gate checks."""

from __future__ import annotations

import unittest

from bench.gates import claim_gate
from bench.gates.claim_backend_telemetry import backend_telemetry_failures
from bench.gates.claim_comparability import workload_comparability_failures
from bench.gates.claim_package_telemetry import (
    PACKAGE_EFFECTIVE_READBACK_OBLIGATION_ID,
    doe_package_telemetry_failures,
    required_comparability_obligation_ids_for_workload,
)
from bench.gates.claim_speed_policy import suspicious_speedup_failures
from bench.gates.claim_speed_policy import claimable_speed_failures
from native_compare_modules.claimability import SUSPICIOUS_SPEEDUP_AUDIT_NOTE


def _doe_package_meta() -> dict:
    return {
        "executionBackend": "doe_node_webgpu",
        "packagePreparedSession": True,
        "packageSetupIncludedInSelectedTiming": False,
        "packageReadbackMode": "native-map-read-copy-unmap",
        "packageEffectiveReadbackPaths": ["native-map-read-copy-unmap"],
        "packageFastPathStats": {
            "commandBufferBuild": 0,
            "dispatchFlush": 1,
            "flushAndMap": 1,
        },
        "packageNativeFastPaths": {
            "computeDispatchFlush": True,
            "bufferMapReadCopyUnmap": True,
        },
        "packageStepBreakdownNs": {
            "dispatchEncodeApiTotalNs": 10,
            "submitQueueSubmitTotalNs": 20,
        },
        "packageWriteBreakdown": {
            "batchCallCount": 0,
            "batchMethod": "none",
            "batchedWriteCount": 0,
            "byDataKind": {
                "u32": {
                    "bytes": 4,
                    "count": 1,
                },
            },
            "bySemanticPhase": {
                "dynamic_write": {
                    "bytes": 4,
                    "count": 1,
                },
            },
            "dynamicWriteBytes": 4,
            "dynamicWriteCount": 1,
            "staticBufferLoadBytes": 0,
            "staticBufferLoadCount": 0,
            "totalCount": 1,
            "totalBytes": 4,
            "unbatchedWriteCount": 1,
        },
    }


def _side(meta: dict, *, name: str = "doe_gpu_node_package_prepared") -> dict:
    return {
        "name": name,
        "commandSamples": [
            {
                "returnCode": 0,
                "traceMeta": meta,
            }
        ],
    }


def _comparability(
    *,
    comparable: bool,
    blocking_failed: list[str] | None = None,
    obligation_id: str = "baseline_comparison_effective_readback_path_match",
) -> dict:
    return {
        "comparability": {
            "blockingFailedObligations": blocking_failed or [],
            "comparable": comparable,
            "obligationSchemaVersion": 1,
            "obligations": [
                {
                    "applicable": True,
                    "blocking": True,
                    "id": obligation_id,
                    "passes": not blocking_failed,
                }
            ],
        }
    }


def _strict_audited_comparability() -> dict:
    obligation_ids = [
        "baseline_comparison_trace_meta_source_match",
        "baseline_comparison_timing_selection_policy_match",
        "baseline_comparison_queue_sync_mode_match",
        "baseline_comparison_execution_shape_match",
        "baseline_comparison_hardware_path_match",
        "baseline_execution_evidence_present",
        "baseline_successful_execution_present",
        "baseline_execution_errors_absent",
        "comparison_execution_errors_absent",
    ]
    return {
        "comparable": True,
        "blockingFailedObligations": [],
        "advisoryFailedObligations": [],
        "obligations": [
            {
                "id": obligation_id,
                "blocking": True,
                "applicable": True,
                "passes": True,
            }
            for obligation_id in obligation_ids
        ],
    }


def _backend_workload(trace_meta: dict) -> dict:
    return {
        "baseline": {
            "commandSamples": [
                {
                    "returnCode": 0,
                    "traceMeta": trace_meta,
                }
            ]
        }
    }


class ClaimGateTests(unittest.TestCase):
    def test_backend_telemetry_accepts_complete_trace_meta(self) -> None:
        self.assertEqual(
            backend_telemetry_failures(
                workload_id="atomic",
                workload=_backend_workload(
                    {
                        "backendId": "doe_vulkan",
                        "backendSelectionReason": "policy",
                        "selectionPolicyHash": "abc123",
                        "fallbackUsed": False,
                    }
                ),
                expected_backend_id="doe_vulkan",
            ),
            [],
        )

    def test_backend_telemetry_rejects_missing_fields(self) -> None:
        failures = backend_telemetry_failures(
            workload_id="atomic",
            workload=_backend_workload({}),
            expected_backend_id="doe_vulkan",
        )

        self.assertIn("atomic: sample 0 missing backendId", failures)
        self.assertIn("atomic: sample 0 missing backendSelectionReason", failures)
        self.assertIn("atomic: sample 0 missing selectionPolicyHash", failures)
        self.assertIn("atomic: sample 0 missing fallbackUsed bool", failures)

    def test_comparability_helper_rejects_missing_object(self) -> None:
        failures, has_comparability = workload_comparability_failures(
            workload_id="gemma_decode",
            workload={},
            require_comparison_status="comparable",
            expected_obligation_ids={
                "baseline_comparison_effective_readback_path_match"
            },
            expected_obligation_schema_version=1,
        )

        self.assertFalse(has_comparability)
        self.assertEqual(failures, ["gemma_decode: missing comparability object"])

    def test_comparability_helper_rejects_readback_blocker(self) -> None:
        blocker_id = "baseline_comparison_effective_readback_path_match"

        failures, has_comparability = workload_comparability_failures(
            workload_id="gemma_decode",
            workload=_comparability(
                comparable=False,
                blocking_failed=[blocker_id],
            ),
            require_comparison_status="comparable",
            expected_obligation_ids={blocker_id},
            expected_obligation_schema_version=1,
        )

        self.assertTrue(has_comparability)
        self.assertIn(
            "gemma_decode: comparability.comparable must be true",
            failures,
        )
        self.assertFalse(
            any(
                "not in canonical obligation contract" in failure
                for failure in failures
            ),
            f"unexpected canonical-id failure: {failures}",
        )

    def test_comparability_helper_rejects_stale_blocking_list(self) -> None:
        blocker_id = "baseline_comparison_effective_readback_path_match"

        failures, has_comparability = workload_comparability_failures(
            workload_id="gemma_decode",
            workload=_comparability(
                comparable=True,
                blocking_failed=[blocker_id],
            ),
            require_comparison_status="comparable",
            expected_obligation_ids={blocker_id},
            expected_obligation_schema_version=1,
        )

        self.assertTrue(has_comparability)
        self.assertIn(
            "gemma_decode: comparable workload must not have "
            "blockingFailedObligations",
            failures,
        )

    def test_comparability_helper_rejects_missing_required_obligation(self) -> None:
        required_id = "baseline_comparison_effective_readback_path_match"

        failures, has_comparability = workload_comparability_failures(
            workload_id="gemma_decode",
            workload=_comparability(
                comparable=True,
                obligation_id="baseline_comparison_timing_phase_match",
            ),
            require_comparison_status="comparable",
            expected_obligation_ids={
                required_id,
                "baseline_comparison_timing_phase_match",
            },
            expected_obligation_schema_version=1,
            required_obligation_ids={required_id},
        )

        self.assertTrue(has_comparability)
        self.assertIn(
            "gemma_decode: comparability missing required obligation "
            "baseline_comparison_effective_readback_path_match",
            failures,
        )

    def test_package_claim_requires_effective_readback_obligation(self) -> None:
        self.assertEqual(
            required_comparability_obligation_ids_for_workload(
                require_claim_status="claimable",
                workload={"baseline": _side(_doe_package_meta())},
            ),
            {PACKAGE_EFFECTIVE_READBACK_OBLIGATION_ID},
        )

    def test_diagnostic_package_does_not_require_readback_obligation(self) -> None:
        self.assertEqual(
            required_comparability_obligation_ids_for_workload(
                require_claim_status="diagnostic",
                workload={"baseline": _side(_doe_package_meta())},
            ),
            set(),
        )

    def test_doe_package_telemetry_accepts_complete_trace_meta(self) -> None:
        self.assertEqual(
            doe_package_telemetry_failures(
                workload_id="gemma64",
                side_name="baseline",
                side_payload=_side(_doe_package_meta()),
            ),
            [],
        )

    def test_doe_package_telemetry_rejects_missing_fast_path_maps(self) -> None:
        meta = _doe_package_meta()
        del meta["packageFastPathStats"]
        del meta["packageNativeFastPaths"]

        failures = doe_package_telemetry_failures(
            workload_id="gemma64",
            side_name="baseline",
            side_payload=_side(meta),
        )

        self.assertIn(
            "gemma64: baseline sample 0 missing packageFastPathStats "
            "non-negative numeric map",
            failures,
        )
        self.assertIn(
            "gemma64: baseline sample 0 missing packageNativeFastPaths boolean map",
            failures,
        )

    def test_doe_package_telemetry_rejects_missing_effective_readback_path(
        self,
    ) -> None:
        meta = _doe_package_meta()
        del meta["packageEffectiveReadbackPaths"]

        failures = doe_package_telemetry_failures(
            workload_id="gemma64",
            side_name="baseline",
            side_payload=_side(meta),
        )

        self.assertIn(
            "gemma64: baseline sample 0 missing packageEffectiveReadbackPaths "
            "non-empty string list",
            failures,
        )

    def test_doe_package_telemetry_rejects_invalid_effective_readback_path(
        self,
    ) -> None:
        meta = _doe_package_meta()
        meta["packageEffectiveReadbackPaths"] = ["requested-mode-only"]

        failures = doe_package_telemetry_failures(
            workload_id="gemma64",
            side_name="baseline",
            side_payload=_side(meta),
        )

        self.assertIn(
            "gemma64: baseline sample 0 packageEffectiveReadbackPaths contains "
            "invalid readback path",
            failures,
        )

    def test_non_doe_package_side_does_not_require_package_telemetry(self) -> None:
        self.assertEqual(
            doe_package_telemetry_failures(
                workload_id="gemma64",
                side_name="comparison",
                side_payload=_side(
                    {"executionBackend": "node_webgpu_package"},
                    name="node_webgpu_package_prepared",
                ),
            ),
            [],
        )

    def test_doe_package_telemetry_rejects_inconsistent_write_breakdown(self) -> None:
        meta = _doe_package_meta()
        meta["packageWriteBreakdown"]["batchedWriteCount"] = 1

        failures = doe_package_telemetry_failures(
            workload_id="gemma64",
            side_name="baseline",
            side_payload=_side(meta),
        )

        self.assertIn(
            "gemma64: baseline sample 0 packageWriteBreakdown "
            "batched+unbatched count must equal totalCount",
            failures,
        )
        self.assertIn(
            "gemma64: baseline sample 0 packageWriteBreakdown "
            "batchMethod=none requires zero batchedWriteCount and batchCallCount",
            failures,
        )

    def test_suspicious_speedup_rejected_even_with_claimable_sidecar(self) -> None:
        failures = suspicious_speedup_failures(
            workload_id="gemma_decode",
            baseline_stats={
                "p50Ms": 0.1,
                "p95Ms": 0.11,
                "p99Ms": 0.11,
                "meanMs": 0.1,
            },
            comparison_stats={
                "p50Ms": 20.0,
                "p95Ms": 21.0,
                "p99Ms": 21.0,
                "meanMs": 20.0,
            },
            suspicious_speedup_ratio=10.0,
        )

        self.assertTrue(
            any("fairness-audit threshold" in failure for failure in failures),
            f"expected suspicious-speedup failure, got: {failures}",
        )

    def test_claimable_speed_skips_claim_ineligible_row(self) -> None:
        failures = claimable_speed_failures(
            workload_id="compute_dispatch_fallback",
            workload={
                "claimEligible": False,
                "claimability": {
                    "evaluated": False,
                    "claimable": True,
                    "claimMetricField": "",
                    "claimMetricScope": "notEvaluated",
                    "requiredPositivePercentiles": [],
                    "skipReason": "claimEligible=false",
                    "reasons": [],
                },
            },
            expected_required_percentiles=["p50Percent", "p95Percent"],
            min_timed_samples=15,
            suspicious_speedup_ratio=10.0,
        )

        self.assertEqual(failures, [])

    def test_claimable_speed_rejects_invalid_claim_ineligible_skip(self) -> None:
        failures = claimable_speed_failures(
            workload_id="compute_dispatch_fallback",
            workload={
                "claimEligible": True,
                "claimability": {
                    "evaluated": False,
                    "claimable": True,
                    "claimMetricField": "",
                    "claimMetricScope": "notEvaluated",
                    "requiredPositivePercentiles": [],
                    "skipReason": "claimEligible=false",
                    "reasons": [],
                },
            },
            expected_required_percentiles=["p50Percent", "p95Percent"],
            min_timed_samples=15,
            suspicious_speedup_ratio=10.0,
        )

        self.assertIn(
            "compute_dispatch_fallback: unevaluated claimability requires report claimEligible=false",
            failures,
        )

    def test_claimable_speed_uses_workload_unit_wall_claim_metric(self) -> None:
        failures = claimable_speed_failures(
            workload_id="upload_write_buffer_1mb_staged",
            workload={
                "baselineStatsMs": {"count": 16, "p50Ms": 0.01, "p95Ms": 0.01},
                "comparisonStatsMs": {"count": 16, "p50Ms": 0.01, "p95Ms": 0.01},
                "deltaPercent": {"p50Percent": -5.0, "p95Percent": -1.0},
                "timingInterpretation": {
                    "workloadUnitWall": {
                        "baselineStatsMs": {"count": 16, "p50Ms": 1.0, "p95Ms": 1.1},
                        "comparisonStatsMs": {"count": 16, "p50Ms": 2.0, "p95Ms": 2.1},
                        "deltaPercent": {"p50Percent": 50.0, "p95Percent": 47.0},
                    },
                },
                "claimability": {
                    "evaluated": True,
                    "claimable": True,
                    "claimMetricField": "timingInterpretation.workloadUnitWall.deltaPercent",
                    "claimMetricScope": "workloadUnitWall",
                    "requiredPositivePercentiles": ["p50Percent", "p95Percent"],
                    "reasons": [],
                },
            },
            expected_required_percentiles=["p50Percent", "p95Percent"],
            min_timed_samples=15,
            suspicious_speedup_ratio=10.0,
        )

        self.assertEqual(failures, [])

    def test_claimable_speed_accepts_audited_suspicious_speedup(self) -> None:
        failures = claimable_speed_failures(
            workload_id="upload_write_buffer_1kb_staged",
            workload={
                "pathAsymmetry": False,
                "baselineStatsMs": {
                    "count": 16,
                    "p50Ms": 0.1,
                    "p95Ms": 0.11,
                    "p99Ms": 0.11,
                    "meanMs": 0.1,
                },
                "comparisonStatsMs": {
                    "count": 16,
                    "p50Ms": 20.0,
                    "p95Ms": 21.0,
                    "p99Ms": 21.0,
                    "meanMs": 20.0,
                },
                "deltaPercent": {"p50Percent": 99.0, "p95Percent": 99.0},
                "comparability": _strict_audited_comparability(),
                "claimability": {
                    "evaluated": True,
                    "claimable": True,
                    "claimMetricField": "deltaPercent",
                    "claimMetricScope": "selectedTiming",
                    "requiredPositivePercentiles": ["p50Percent", "p95Percent"],
                    "auditNotes": [SUSPICIOUS_SPEEDUP_AUDIT_NOTE],
                    "reasons": [],
                },
            },
            expected_required_percentiles=["p50Percent", "p95Percent"],
            min_timed_samples=15,
            suspicious_speedup_ratio=10.0,
        )

        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
