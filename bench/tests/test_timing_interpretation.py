#!/usr/bin/env python3
"""Regression tests for timing-interpretation metric naming."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
if str(BENCH_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCH_ROOT))

from native_compare_modules.timing_interpretation import build_timing_interpretation
from native_compare_modules.normalization import (
    derive_workload_unit_normalization_divisor,
    sample_normalized_elapsed_ms,
)


def make_side(timing_source: str) -> dict[str, object]:
    return {
        "timingSources": [timing_source],
        "timingClasses": ["operation"],
        "commandSamples": [
            {
                "elapsedMs": 10.0,
                "measuredMs": 4.0,
                "commandRepeat": 2,
                "timingNormalizationDivisor": 1.0,
                "traceMeta": {
                    "hostInputReadTotalNs": 1_000_000,
                    "hostInputParseTotalNs": 2_000_000,
                    "hostCommandOrchestrationTotalNs": 500_000,
                },
            },
            {
                "elapsedMs": 12.0,
                "measuredMs": 5.0,
                "commandRepeat": 2,
                "timingNormalizationDivisor": 1.0,
                "traceMeta": {
                    "hostInputReadTotalNs": 1_000_000,
                    "hostInputParseTotalNs": 2_000_000,
                    "hostCommandOrchestrationTotalNs": 500_000,
                },
            },
        ],
    }


def make_prepared_session_side() -> dict[str, object]:
    return {
        "timingSources": ["doe-execution-total-ns"],
        "timingClasses": ["operation"],
        "commandSamples": [
            {
                "elapsedMs": 30.0,
                "measuredMs": 20.0,
                "commandRepeat": 1,
                "timingNormalizationDivisor": 1.0,
                "traceMeta": {
                    "workloadUnitWallSource": "trace-meta-process-wall",
                    "packagePreparedSession": True,
                    "hostInputReadTotalNs": 0,
                    "hostInputParseTotalNs": 0,
                    "hostWorkloadPrepareTotalNs": 0,
                    "hostExecutorInitTotalNs": 0,
                    "hostCommandOrchestrationTotalNs": 3_000_000,
                    "hostArtifactFinalizeTotalNs": 2_000_000,
                },
            },
            {
                "elapsedMs": 32.0,
                "measuredMs": 21.0,
                "commandRepeat": 1,
                "timingNormalizationDivisor": 1.0,
                "traceMeta": {
                    "workloadUnitWallSource": "trace-meta-process-wall",
                    "packagePreparedSession": True,
                    "hostInputReadTotalNs": 0,
                    "hostInputParseTotalNs": 0,
                    "hostWorkloadPrepareTotalNs": 0,
                    "hostExecutorInitTotalNs": 0,
                    "hostCommandOrchestrationTotalNs": 4_000_000,
                    "hostArtifactFinalizeTotalNs": 2_000_000,
                },
            },
        ],
    }


def make_single_divisor_side() -> dict[str, object]:
    return {
        "timingSources": ["doe-execution-total-ns"],
        "timingClasses": ["operation"],
        "commandSamples": [
            {
                "elapsedMs": 1000.0,
                "measuredMs": 8.0,
                "commandRepeat": 100,
                "timingNormalizationDivisor": 100.0,
                "workloadUnitNormalizationDivisor": 100.0,
                "traceMeta": {
                    "hostInputReadTotalNs": 100_000_000,
                },
            },
            {
                "elapsedMs": 1200.0,
                "measuredMs": 9.0,
                "commandRepeat": 100,
                "timingNormalizationDivisor": 100.0,
                "workloadUnitNormalizationDivisor": 100.0,
                "traceMeta": {
                    "hostInputReadTotalNs": 100_000_000,
                },
            },
        ],
    }


class TimingInterpretationNamingTests(unittest.TestCase):
    def test_compute_trace_rows_do_not_implicitly_divide_workload_wall(self) -> None:
        divisor, source = derive_workload_unit_normalization_divisor(
            workload_domain="compute",
            strict_normalization_unit="",
            trace_meta={
                "executionDispatchCount": 1170,
                "executionRowCount": 1585,
                "executionSuccessCount": 1585,
            },
            command_repeat=1,
            configured_timing_divisor=1.0,
            required_timing_class="operation",
        )

        self.assertEqual(divisor, 1.0)
        self.assertEqual(source, "identity")
        self.assertEqual(
            sample_normalized_elapsed_ms(
                {
                    "elapsedMs": 148.0,
                    "commandRepeat": 1,
                    "timingClass": "operation",
                    "timingNormalizationDivisor": 1.0,
                    "workloadDomain": "compute",
                    "traceMeta": {
                        "executionRowCount": 1585,
                        "executionSuccessCount": 1585,
                    },
                }
            ),
            148.0,
        )

    def test_declared_dispatch_unit_divides_workload_wall(self) -> None:
        divisor, source = derive_workload_unit_normalization_divisor(
            workload_domain="compute",
            strict_normalization_unit="dispatch",
            trace_meta={"executionDispatchCount": 100},
            command_repeat=1,
            configured_timing_divisor=100.0,
            required_timing_class="operation",
        )

        self.assertEqual(divisor, 100.0)
        self.assertEqual(source, "declared-dispatch-count")

    def test_emits_workload_unit_wall_with_legacy_alias(self) -> None:
        interpretation = build_timing_interpretation(
            baseline=make_side("doe-execution-total-ns"),
            comparison=make_side("doe-execution-total-ns"),
        )

        workload_unit_wall = interpretation.get("workloadUnitWall")
        legacy_alias = interpretation.get("headlineProcessWall")

        self.assertIsInstance(workload_unit_wall, dict)
        self.assertEqual(workload_unit_wall.get("scopeClass"), "workload-unit-wall")
        self.assertTrue(workload_unit_wall.get("available"))
        self.assertAlmostEqual(workload_unit_wall["baselineStatsMs"]["p50Ms"], 5.0)
        self.assertAlmostEqual(workload_unit_wall["comparisonStatsMs"]["p50Ms"], 5.0)

        self.assertIsInstance(legacy_alias, dict)
        self.assertEqual(legacy_alias.get("deprecatedAliasFor"), "workloadUnitWall")
        self.assertEqual(
            legacy_alias.get("deltaPercent"),
            workload_unit_wall.get("deltaPercent"),
        )

        host_overhead = interpretation.get("hostOverheadBreakdown")
        self.assertIsInstance(host_overhead, dict)
        self.assertTrue(host_overhead.get("available"))
        self.assertAlmostEqual(host_overhead["selectedGap"]["baselineStatsMs"]["p50Ms"], 1.0)
        self.assertAlmostEqual(host_overhead["attributedHostOverhead"]["baselineStatsMs"]["p50Ms"], 1.75)
        self.assertAlmostEqual(
            host_overhead["unattributedGapRemainder"]["baselineStatsMs"]["p50Ms"],
            -0.75,
        )
        self.assertIn("inputRead", host_overhead.get("buckets", {}))
        self.assertEqual(
            host_overhead["buckets"]["inputRead"].get("traceMetaField"),
            "hostInputReadTotalNs",
        )

    def test_prepared_session_host_overhead_stays_within_selected_gap(self) -> None:
        interpretation = build_timing_interpretation(
            baseline=make_prepared_session_side(),
            comparison=make_prepared_session_side(),
        )

        host_overhead = interpretation.get("hostOverheadBreakdown")
        self.assertIsInstance(host_overhead, dict)
        self.assertTrue(host_overhead.get("available"))
        self.assertLessEqual(
            host_overhead["attributedHostOverhead"]["baselineStatsMs"]["p50Ms"],
            host_overhead["selectedGap"]["baselineStatsMs"]["p50Ms"],
        )
        self.assertGreaterEqual(
            host_overhead["unattributedGapRemainder"]["baselineStatsMs"]["p50Ms"],
            0.0,
        )

    def test_workload_unit_wall_uses_single_explicit_divisor(self) -> None:
        interpretation = build_timing_interpretation(
            baseline=make_single_divisor_side(),
            comparison=make_single_divisor_side(),
        )

        workload_unit_wall = interpretation["workloadUnitWall"]
        self.assertAlmostEqual(workload_unit_wall["baselineStatsMs"]["p50Ms"], 10.0)
        self.assertAlmostEqual(
            interpretation["hostOverheadBreakdown"]["buckets"]["inputRead"]["baselineStatsMs"]["p50Ms"],
            1.0,
        )


if __name__ == "__main__":
    unittest.main()
