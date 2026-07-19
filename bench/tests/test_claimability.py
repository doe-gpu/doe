#!/usr/bin/env python3
"""Regression tests for claimability metric-scope selection."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
if str(BENCH_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCH_ROOT))

from native_compare_modules.claimability import assess_claimability
from native_compare_modules.config_support import BenchmarkMethodologyPolicy


BENCHMARK_POLICY = BenchmarkMethodologyPolicy(
    source_path="config/benchmark-methodology-thresholds.json",
    min_dispatch_window_ns_without_encode=500000,
    min_dispatch_window_coverage_percent_without_encode=1.0,
    local_claim_min_timed_samples=19,
    release_claim_min_timed_samples=15,
    comparability_min_timed_samples=7,
    min_operation_wall_coverage_ratio=0.05,
    max_operation_wall_coverage_asymmetry_ratio=128.0,
    suspicious_speedup_ratio=10.0,
    min_row_timing_floor_ns=5000000,
    smoke_comparability_min_timed_samples=3,
)


def make_stats(p50: float, p95: float) -> dict[str, float]:
    return {
        "count": 19,
        "minMs": p50,
        "maxMs": p95,
        "p10Ms": p50,
        "p50Ms": p50,
        "p95Ms": p95,
        "p99Ms": p95,
        "meanMs": p50,
        "stdevMs": 0.00001,
    }


def make_timing_interpretation(
    *,
    headline_p50: float,
    headline_p95: float,
    headline_delta_p50: float,
    headline_delta_p95: float,
) -> dict[str, object]:
    return {
        "selectedTiming": {
            "scope": "operation-total",
            "scopeClass": "operation-total",
        },
        "workloadUnitWall": {
            "available": True,
            "baselineStatsMs": make_stats(headline_p50, headline_p95),
            "comparisonStatsMs": make_stats(headline_p50 * 1.1, headline_p95 * 1.1),
            "deltaPercent": {
                "p50Percent": headline_delta_p50,
                "p95Percent": headline_delta_p95,
                "p99Percent": headline_delta_p95,
            },
        },
    }


def strict_audited_comparability() -> dict[str, object]:
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
                "applicable": True,
                "blocking": True,
                "passes": True,
            }
            for obligation_id in obligation_ids
        ],
    }


class ClaimabilityMetricScopeTests(unittest.TestCase):
    def test_operation_total_selected_and_wall_sign_disagreement_blocks_claim(self) -> None:
        workload = SimpleNamespace(
            id="package_buffer_upload_readback_exact_1mb",
            domain="upload-readback",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline={"stats": make_stats(2.8, 3.2), "commandSamples": []},
            comparison={"stats": make_stats(4.0, 4.8), "commandSamples": []},
            delta={
                "p50Percent": 30.0,
                "p95Percent": 25.0,
                "p99Percent": 25.0,
            },
            timing_interpretation=make_timing_interpretation(
                headline_p50=45.0,
                headline_p95=49.0,
                headline_delta_p50=-8.0,
                headline_delta_p95=-5.0,
            ),
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["claimable"])
        self.assertEqual(claimability["claimMetricScope"], "selectedTiming")
        self.assertTrue(
            any("disagree on claim sign" in reason for reason in claimability["reasons"]),
            claimability["reasons"],
        )

    def test_claim_ineligible_workload_is_not_evaluated(self) -> None:
        workload = SimpleNamespace(
            id="compute_dispatch_grid",
            domain="compute",
            claim_eligible=False,
            path_asymmetry=False,
            path_asymmetry_note="",
        )

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline={"stats": make_stats(0.1, 0.11), "commandSamples": []},
            comparison={"stats": make_stats(20.0, 21.0), "commandSamples": []},
            delta={
                "p50Percent": 99.5,
                "p95Percent": 99.47,
                "p99Percent": 99.47,
            },
            timing_interpretation={
                "selectedTiming": {
                    "scope": "operation-total",
                    "scopeClass": "operation-total",
                },
                "workloadUnitWall": {"available": False},
            },
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["evaluated"])
        self.assertTrue(claimability["claimable"])
        self.assertEqual(claimability["reasons"], [])
        self.assertEqual(claimability["skipReason"], "claimEligible=false")

    def _compute_prewarm_samples(self, *, elapsed_ms: float, measured_ms: float) -> list[dict[str, object]]:
        return [
            {
                "runIndex": i,
                "elapsedMs": elapsed_ms,
                "measuredRawMs": measured_ms,
                "measuredMs": measured_ms,
                "timingSource": "doe-execution-total-ns+host-kernel-prewarm",
                "timing": {
                    "traceMetaSource": "doe-execution-total-ns+host-kernel-prewarm",
                    "timingRawMs": measured_ms,
                    "timingNormalizationDivisor": 1.0,
                    "commandRepeat": 1,
                },
                "traceMeta": {
                    "executionTotalNs": int((measured_ms - 1.0) * 1_000_000),
                    "executionSetupTotalNs": 0,
                    "executionEncodeTotalNs": 100_000,
                    "executionSubmitWaitTotalNs": int((measured_ms - 1.1) * 1_000_000),
                    "hostKernelPrewarmTotalNs": 1_000_000,
                },
                "commandRepeat": 1,
                "timingNormalizationDivisor": 1.0,
            }
            for i in range(19)
        ]

    def test_copy_wall_metric_does_not_hide_selected_tail_sign_disagreement(self) -> None:
        workload = SimpleNamespace(
            id="copy_texture_to_texture",
            domain="copy",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        left = {"stats": make_stats(0.00047, 0.00050), "commandSamples": []}
        right = {"stats": make_stats(0.00048, 0.00049), "commandSamples": []}
        timing_interpretation = make_timing_interpretation(
            headline_p50=0.00173,
            headline_p95=0.00178,
            headline_delta_p50=24.5,
            headline_delta_p95=22.4,
        )

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": 2.1, "p95Percent": -0.7, "p99Percent": -0.7},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["claimable"])
        self.assertEqual(claimability["claimMetricScope"], "workloadUnitWall")
        self.assertTrue(
            any("p95Percent" in reason and "disagree on claim sign" in reason for reason in claimability["reasons"]),
            claimability["reasons"],
        )

    def test_surface_wall_metric_does_not_hide_selected_sign_disagreement(self) -> None:
        workload = SimpleNamespace(
            id="surface_full_presentation",
            domain="surface",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        left = {"stats": make_stats(0.0202, 0.0246), "commandSamples": []}
        right = {"stats": make_stats(0.0191, 0.0240), "commandSamples": []}
        timing_interpretation = make_timing_interpretation(
            headline_p50=0.0507,
            headline_p95=0.0526,
            headline_delta_p50=7.8,
            headline_delta_p95=16.7,
        )

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": -5.3, "p95Percent": -2.5, "p99Percent": -2.5},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["claimable"])
        self.assertEqual(claimability["claimMetricScope"], "workloadUnitWall")
        self.assertTrue(
            any("disagree on claim sign" in reason for reason in claimability["reasons"]),
            claimability["reasons"],
        )

    def test_compute_prewarm_stays_on_selected_timing_when_selected_operation_loses(self) -> None:
        workload = SimpleNamespace(
            id="compute_workgroup_non_atomic_1024",
            domain="compute",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        left = {
            "stats": make_stats(25.0, 26.0),
            "commandSamples": self._compute_prewarm_samples(elapsed_ms=31.0, measured_ms=25.0),
        }
        right = {
            "stats": make_stats(13.0, 14.0),
            "commandSamples": self._compute_prewarm_samples(elapsed_ms=164.0, measured_ms=13.0),
        }
        timing_interpretation = make_timing_interpretation(
            headline_p50=0.31,
            headline_p95=0.32,
            headline_delta_p50=400.0,
            headline_delta_p95=390.0,
        )

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": -48.0, "p95Percent": -46.0, "p99Percent": -46.0},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["claimable"])
        self.assertEqual(claimability["claimMetricScope"], "selectedTiming")

    def test_compute_without_prewarm_provenance_stays_on_selected_timing(self) -> None:
        workload = SimpleNamespace(
            id="compute_workgroup_non_atomic_1024",
            domain="compute",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        left_samples = self._compute_prewarm_samples(elapsed_ms=31.0, measured_ms=25.0)
        right_samples = self._compute_prewarm_samples(elapsed_ms=164.0, measured_ms=13.0)
        for sample in [*left_samples, *right_samples]:
            sample["timingSource"] = "doe-execution-total-ns"
            sample["timing"]["traceMetaSource"] = "doe-execution-total-ns"
        left = {"stats": make_stats(25.0, 26.0), "commandSamples": left_samples}
        right = {"stats": make_stats(13.0, 14.0), "commandSamples": right_samples}
        timing_interpretation = make_timing_interpretation(
            headline_p50=0.31,
            headline_p95=0.32,
            headline_delta_p50=400.0,
            headline_delta_p95=390.0,
        )

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": -48.0, "p95Percent": -46.0, "p99Percent": -46.0},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["claimable"])
        self.assertEqual(claimability["claimMetricScope"], "selectedTiming")

    def test_pipeline_prewarm_stays_on_selected_timing_when_selected_operation_loses(self) -> None:
        workload = SimpleNamespace(
            id="pipeline_compile_stress",
            domain="pipeline",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        left = {
            "stats": make_stats(24.0, 25.0),
            "commandSamples": self._compute_prewarm_samples(elapsed_ms=31.5, measured_ms=24.0),
        }
        right = {
            "stats": make_stats(14.0, 15.0),
            "commandSamples": self._compute_prewarm_samples(elapsed_ms=164.0, measured_ms=14.0),
        }
        timing_interpretation = make_timing_interpretation(
            headline_p50=0.63,
            headline_p95=0.64,
            headline_delta_p50=400.0,
            headline_delta_p95=390.0,
        )

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": -41.0, "p95Percent": -40.0, "p99Percent": -40.0},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["claimable"])
        self.assertEqual(claimability["claimMetricScope"], "selectedTiming")

    def test_upload_workload_unit_claim_not_blocked_by_operation_scope_asymmetry(self) -> None:
        """When an upload workload's claim has been promoted to workloadUnitWall
        due to operation-timing coverage asymmetry (e.g. Doe deferred-queue-sync
        memcpy vs Dawn callback-loop timing), the operation-scope sanity check
        must not re-reject the already-promoted claim."""
        workload = SimpleNamespace(
            id="upload_write_buffer_1kb",
            domain="upload",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        # Left (Doe): operation timing ~0.00017ms, wall ~100ms/500 = 0.2ms
        # coverage = 0.00085 (far below 0.05 threshold)
        left_samples = [
            {
                "runIndex": i,
                "elapsedMs": 100.0,
                "measuredRawMs": 0.00017,
                "measuredMs": 0.00017,
                "timingSource": "doe-execution-workload-total-ns+ignore-first-ops",
                "timing": {
                    "timingRawMs": 0.00017,
                    "timingNormalizationDivisor": 1.0,
                    "commandRepeat": 500,
                    "uploadIgnoreFirstApplied": True,
                    "uploadIgnoreFirstBaseTimingSource": "doe-execution-workload-total-ns",
                    "uploadIgnoreFirstAdjustedTimingSource": "doe-execution-workload-total-ns",
                    "uploadTimingRawMsAfterIgnore": 0.00017,
                },
                "commandRepeat": 500,
                "timingNormalizationDivisor": 1.0,
            }
            for i in range(19)
        ]
        # Right (Dawn): operation timing ~0.076ms, wall ~116ms/500 = 0.232ms
        # coverage = 0.328 (above 0.05)
        right_samples = [
            {
                "runIndex": i,
                "elapsedMs": 116.0,
                "measuredRawMs": 0.076,
                "measuredMs": 0.076,
                "timingSource": "doe-execution-workload-total-ns+ignore-first-ops",
                "timing": {
                    "timingRawMs": 0.076,
                    "timingNormalizationDivisor": 1.0,
                    "commandRepeat": 500,
                    "uploadIgnoreFirstApplied": True,
                    "uploadIgnoreFirstBaseTimingSource": "doe-execution-workload-total-ns",
                    "uploadIgnoreFirstAdjustedTimingSource": "doe-execution-workload-total-ns",
                    "uploadTimingRawMsAfterIgnore": 0.076,
                },
                "commandRepeat": 500,
                "timingNormalizationDivisor": 1.0,
            }
            for i in range(19)
        ]
        left = {"stats": make_stats(0.00017, 0.00019), "commandSamples": left_samples}
        right = {"stats": make_stats(0.076, 0.080), "commandSamples": right_samples}
        timing_interpretation = make_timing_interpretation(
            headline_p50=0.200,
            headline_p95=0.210,
            headline_delta_p50=15.0,
            headline_delta_p95=12.0,
        )

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": 44600.0, "p95Percent": 42000.0, "p99Percent": 42000.0},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertTrue(claimability["claimable"], f"reasons: {claimability['reasons']}")
        self.assertEqual(claimability["claimMetricScope"], "workloadUnitWall")

    def test_operation_scope_asymmetry_blocks_when_claim_is_selected_timing(self) -> None:
        """When the claim metric is still selectedTiming (headline not available),
        operation-scope asymmetry must still block claimability."""
        workload = SimpleNamespace(
            id="upload_write_buffer_1kb",
            domain="upload",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        left_samples = [
            {
                "runIndex": i,
                "elapsedMs": 100.0,
                "measuredRawMs": 0.00017,
                "measuredMs": 0.00017,
                "timingSource": "doe-execution-workload-total-ns+ignore-first-ops",
                "timing": {
                    "timingRawMs": 0.00017,
                    "timingNormalizationDivisor": 1.0,
                    "commandRepeat": 500,
                    "uploadIgnoreFirstApplied": True,
                    "uploadIgnoreFirstBaseTimingSource": "doe-execution-workload-total-ns",
                    "uploadIgnoreFirstAdjustedTimingSource": "doe-execution-workload-total-ns",
                    "uploadTimingRawMsAfterIgnore": 0.00017,
                },
                "commandRepeat": 500,
                "timingNormalizationDivisor": 1.0,
            }
            for i in range(19)
        ]
        right_samples = [
            {
                "runIndex": i,
                "elapsedMs": 116.0,
                "measuredRawMs": 0.076,
                "measuredMs": 0.076,
                "timingSource": "doe-execution-workload-total-ns+ignore-first-ops",
                "timing": {
                    "timingRawMs": 0.076,
                    "timingNormalizationDivisor": 1.0,
                    "commandRepeat": 500,
                    "uploadIgnoreFirstApplied": True,
                    "uploadIgnoreFirstBaseTimingSource": "doe-execution-workload-total-ns",
                    "uploadIgnoreFirstAdjustedTimingSource": "doe-execution-workload-total-ns",
                    "uploadTimingRawMsAfterIgnore": 0.076,
                },
                "commandRepeat": 500,
                "timingNormalizationDivisor": 1.0,
            }
            for i in range(19)
        ]
        left = {"stats": make_stats(0.00017, 0.00019), "commandSamples": left_samples}
        right = {"stats": make_stats(0.076, 0.080), "commandSamples": right_samples}
        # No workload-unit wall available -- claim stays on selectedTiming
        timing_interpretation = {
            "selectedTiming": {
                "scope": "operation-total",
                "scopeClass": "operation-total",
            },
            "workloadUnitWall": {"available": False},
        }

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": 44600.0, "p95Percent": 42000.0, "p99Percent": 42000.0},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["claimable"])
        self.assertEqual(claimability["claimMetricScope"], "selectedTiming")
        self.assertTrue(
            any("asymmetric versus process wall" in r for r in claimability["reasons"]),
            f"expected operation-scope asymmetry reason, got: {claimability['reasons']}",
        )

    def test_legacy_headline_alias_still_promotes_to_workload_unit_wall(self) -> None:
        workload = SimpleNamespace(
            id="surface_full_presentation",
            domain="surface",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        left = {"stats": make_stats(0.0202, 0.0246), "commandSamples": []}
        right = {"stats": make_stats(0.0191, 0.0240), "commandSamples": []}
        timing_interpretation = {
            "selectedTiming": {
                "scope": "operation-total",
                "scopeClass": "narrow-hot-path",
            },
            "headlineProcessWall": {
                "available": True,
                "baselineStatsMs": make_stats(0.0507, 0.0526),
                "comparisonStatsMs": make_stats(0.0558, 0.0578),
                "deltaPercent": {
                    "p50Percent": 7.8,
                    "p95Percent": 16.7,
                    "p99Percent": 16.7,
                },
            },
        }

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": -5.3, "p95Percent": -2.5, "p99Percent": -2.5},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertTrue(claimability["claimable"])
        self.assertEqual(claimability["claimMetricScope"], "workloadUnitWall")

    def test_row_timing_floor_blocks_short_upload_rows(self) -> None:
        """When the median row wall time is below minRowTimingFloorNs (5ms),
        the workload should be non-claimable due to scheduler-noise risk."""
        workload = SimpleNamespace(
            id="upload_write_buffer_1kb",
            domain="upload",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        # Simulate 1KB upload with 1000 repeats: ~0.170ms total row time
        left_samples = [
            {
                "runIndex": i,
                "elapsedMs": 0.170,
                "measuredRawMs": 0.170,
                "measuredMs": 0.170,
                "timingSource": "doe-execution-workload-total-ns",
                "timing": {
                    "timingRawMs": 0.170,
                    "timingNormalizationDivisor": 1.0,
                    "commandRepeat": 1000,
                },
                "commandRepeat": 1000,
                "timingNormalizationDivisor": 1.0,
            }
            for i in range(19)
        ]
        right_samples = [
            {
                "runIndex": i,
                "elapsedMs": 0.200,
                "measuredRawMs": 0.200,
                "measuredMs": 0.200,
                "timingSource": "doe-execution-workload-total-ns",
                "timing": {
                    "timingRawMs": 0.200,
                    "timingNormalizationDivisor": 1.0,
                    "commandRepeat": 1000,
                },
                "commandRepeat": 1000,
                "timingNormalizationDivisor": 1.0,
            }
            for i in range(19)
        ]
        left = {"stats": make_stats(0.170, 0.180), "commandSamples": left_samples}
        right = {"stats": make_stats(0.200, 0.210), "commandSamples": right_samples}
        timing_interpretation = make_timing_interpretation(
            headline_p50=0.170,
            headline_p95=0.180,
            headline_delta_p50=15.0,
            headline_delta_p95=14.0,
        )

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": 15.0, "p95Percent": 14.0, "p99Percent": 14.0},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["claimable"])
        self.assertTrue(
            any("scheduler-noise floor" in r for r in claimability["reasons"]),
            f"expected scheduler-noise floor reason, got: {claimability['reasons']}",
        )

    def test_row_timing_floor_allows_long_upload_rows(self) -> None:
        """When the median row wall time is above minRowTimingFloorNs (5ms),
        the row timing floor check should not block claimability."""
        workload = SimpleNamespace(
            id="upload_write_buffer_1kb",
            domain="upload",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        # Simulate 1KB upload with 50000 repeats: ~8.5ms total row time
        left_samples = [
            {
                "runIndex": i,
                "elapsedMs": 8.5,
                "measuredRawMs": 8.5,
                "measuredMs": 8.5,
                "timingSource": "doe-execution-workload-total-ns",
                "timing": {
                    "timingRawMs": 8.5,
                    "timingNormalizationDivisor": 1.0,
                    "commandRepeat": 50000,
                },
                "commandRepeat": 50000,
                "timingNormalizationDivisor": 1.0,
            }
            for i in range(19)
        ]
        right_samples = [
            {
                "runIndex": i,
                "elapsedMs": 10.0,
                "measuredRawMs": 10.0,
                "measuredMs": 10.0,
                "timingSource": "doe-execution-workload-total-ns",
                "timing": {
                    "timingRawMs": 10.0,
                    "timingNormalizationDivisor": 1.0,
                    "commandRepeat": 50000,
                },
                "commandRepeat": 50000,
                "timingNormalizationDivisor": 1.0,
            }
            for i in range(19)
        ]
        left = {"stats": make_stats(8.5, 9.0), "commandSamples": left_samples}
        right = {"stats": make_stats(10.0, 10.5), "commandSamples": right_samples}
        timing_interpretation = make_timing_interpretation(
            headline_p50=8.5,
            headline_p95=9.0,
            headline_delta_p50=15.0,
            headline_delta_p95=14.0,
        )

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": 15.0, "p95Percent": 14.0, "p99Percent": 14.0},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        floor_reasons = [r for r in claimability["reasons"] if "scheduler-noise floor" in r]
        self.assertEqual(floor_reasons, [], f"unexpected floor reasons: {floor_reasons}")

    def test_suspicious_speedup_blocks_claimability(self) -> None:
        workload = SimpleNamespace(
            id="inference_decode",
            domain="inference",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        left = {"stats": make_stats(0.1, 0.11), "commandSamples": []}
        right = {"stats": make_stats(20.0, 21.0), "commandSamples": []}
        timing_interpretation = {
            "selectedTiming": {
                "scope": "operation-total",
                "scopeClass": "operation-total",
            },
            "workloadUnitWall": {"available": False},
        }

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={
                "p50Percent": 99.5,
                "p95Percent": 99.47,
                "p99Percent": 99.47,
            },
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["claimable"])
        self.assertTrue(
            any("fairness-audit threshold" in r for r in claimability["reasons"]),
            f"expected suspicious-speedup reason, got: {claimability['reasons']}",
        )

    def test_suspicious_speedup_passes_with_strict_comparability_audit(self) -> None:
        workload = SimpleNamespace(
            id="upload_write_buffer_64kb_staged",
            domain="upload",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        left = {"stats": make_stats(0.1, 0.11), "commandSamples": []}
        right = {"stats": make_stats(20.0, 21.0), "commandSamples": []}
        timing_interpretation = {
            "selectedTiming": {
                "scope": "operation-total",
                "scopeClass": "operation-total",
            },
            "workloadUnitWall": {"available": False},
        }

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={
                "p50Percent": 99.5,
                "p95Percent": 99.47,
                "p99Percent": 99.47,
            },
            timing_interpretation=timing_interpretation,
            comparability=strict_audited_comparability(),
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertTrue(claimability["claimable"], f"reasons: {claimability['reasons']}")
        self.assertTrue(claimability["auditNotes"])

    def test_does_not_switch_when_headline_tail_is_not_positive(self) -> None:
        workload = SimpleNamespace(
            id="copy_texture_to_texture",
            domain="copy",
            path_asymmetry=False,
            path_asymmetry_note="",
        )
        left = {"stats": make_stats(0.00047, 0.00050), "commandSamples": []}
        right = {"stats": make_stats(0.00048, 0.00049), "commandSamples": []}
        timing_interpretation = make_timing_interpretation(
            headline_p50=0.00173,
            headline_p95=0.00178,
            headline_delta_p50=24.5,
            headline_delta_p95=-1.0,
        )

        claimability = assess_claimability(
            mode="local",
            min_timed_samples=19,
            workload=workload,
            baseline=left,
            comparison=right,
            delta={"p50Percent": 2.1, "p95Percent": -0.7, "p99Percent": -0.7},
            timing_interpretation=timing_interpretation,
            comparability={"comparable": True},
            benchmark_policy=BENCHMARK_POLICY,
        )

        self.assertFalse(claimability["claimable"])
        self.assertEqual(claimability["claimMetricScope"], "selectedTiming")


if __name__ == "__main__":
    unittest.main()
