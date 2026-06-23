"""Tests for release claim-gate checks."""

from __future__ import annotations

import unittest

from bench.gates import claim_gate
from bench.gates.claim_comparability import workload_comparability_failures
from bench.gates.claim_package_telemetry import (
    PACKAGE_EFFECTIVE_READBACK_OBLIGATION_ID,
    doe_package_telemetry_failures,
    required_comparability_obligation_ids_for_workload,
)
from bench.gates.claim_speed_policy import suspicious_speedup_failures


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


class ClaimGateTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
