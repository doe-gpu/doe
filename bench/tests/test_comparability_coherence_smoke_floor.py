"""Coherence gate coverage for the two-tier sample-floor policy.

Claim-eligible workloads must clear ``comparabilityDefaults.minTimedSamples``.
Non-claim-eligible (smoke, directional, diagnostic) workloads must clear the
lower ``comparabilityDefaults.smokeMinTimedSamples``. A ``count: 2`` smoke
artifact must not be able to land ``comparability.comparable=true`` even though
it is never claim-eligible.
"""

from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _entry not in sys.path:
        sys.path.insert(0, _entry)

from bench.lib import comparability_coherence


def _workload(
    *,
    claim_eligible: bool,
    baseline_count: int,
    comparison_count: int,
) -> dict:
    return {
        "id": f"wl_{claim_eligible}_{baseline_count}_{comparison_count}",
        "workloadComparable": True,
        "claimEligible": claim_eligible,
        "workloadMatching": {"matched": True, "reasons": []},
        "baselineStatsMs": {"count": baseline_count},
        "comparisonStatsMs": {"count": comparison_count},
        "comparability": {
            "comparable": True,
            "reasons": [],
            "blockingFailedObligations": [],
            "obligations": [
                {
                    "id": "workload_marked_comparable",
                    "applicable": True,
                    "blocking": True,
                    "passes": True,
                },
                {
                    "id": "left_samples_present",
                    "applicable": True,
                    "blocking": True,
                    "passes": True,
                    "details": {"baselineSampleCount": baseline_count},
                },
                {
                    "id": "right_samples_present",
                    "applicable": True,
                    "blocking": True,
                    "passes": True,
                    "details": {"comparisonSampleCount": comparison_count},
                },
                {
                    "id": "baseline_comparison_timing_phase_match",
                    "applicable": True,
                    "blocking": True,
                    "passes": True,
                    "details": {},
                },
                {
                    "id": "baseline_comparison_execution_shape_match",
                    "applicable": True,
                    "blocking": True,
                    "passes": True,
                    "details": {
                        "baselineNormalizedExecutionShapes": [{"dispatch": 1}],
                        "comparisonNormalizedExecutionShapes": [{"dispatch": 1}],
                    },
                },
                {
                    "id": "baseline_comparison_hardware_path_match",
                    "applicable": True,
                    "blocking": True,
                    "passes": True,
                    "details": {},
                },
            ],
        },
    }


class SmokeFloorCoherenceTests(unittest.TestCase):
    def test_claim_eligible_below_floor_fails(self) -> None:
        workload = _workload(
            claim_eligible=True,
            baseline_count=5,
            comparison_count=5,
        )
        result = comparability_coherence.assess_workload(
            workload,
            min_timed_samples=7,
            smoke_min_timed_samples=3,
        )
        self.assertEqual(result["status"], "fail")
        reasons = result["reasons"]
        self.assertTrue(any("comparability floor 7" in reason for reason in reasons))
        self.assertFalse(
            any("smoke-comparability" in reason for reason in reasons),
            "claim-eligible workloads must not apply the smoke floor",
        )

    def test_claim_eligible_meeting_floor_passes(self) -> None:
        workload = _workload(
            claim_eligible=True,
            baseline_count=7,
            comparison_count=15,
        )
        result = comparability_coherence.assess_workload(
            workload,
            min_timed_samples=7,
            smoke_min_timed_samples=3,
        )
        self.assertEqual(result["status"], "pass", result["reasons"])

    def test_smoke_count_two_fails_smoke_floor(self) -> None:
        workload = _workload(
            claim_eligible=False,
            baseline_count=2,
            comparison_count=2,
        )
        result = comparability_coherence.assess_workload(
            workload,
            min_timed_samples=7,
            smoke_min_timed_samples=3,
        )
        self.assertEqual(result["status"], "fail")
        reasons = result["reasons"]
        self.assertTrue(
            any("smoke-comparability floor 3" in reason for reason in reasons),
            reasons,
        )
        self.assertFalse(
            any("< comparability floor 7" in reason for reason in reasons),
            "non-claim-eligible workloads must not apply the claim floor",
        )

    def test_smoke_count_three_passes_smoke_floor(self) -> None:
        workload = _workload(
            claim_eligible=False,
            baseline_count=3,
            comparison_count=3,
        )
        result = comparability_coherence.assess_workload(
            workload,
            min_timed_samples=7,
            smoke_min_timed_samples=3,
        )
        self.assertEqual(result["status"], "pass", result["reasons"])

    def test_inapplicable_phase_obligation_does_not_require_phase_samples(self) -> None:
        workload = _workload(
            claim_eligible=False,
            baseline_count=3,
            comparison_count=3,
        )
        workload = copy.deepcopy(workload)
        for obligation in workload["comparability"]["obligations"]:
            if obligation["id"] == "baseline_comparison_timing_phase_match":
                obligation["applicable"] = False
                obligation["details"] = {
                    "phaseSampleCounts": {
                        "encode": {"baseline": 0, "comparison": 0},
                        "setup": {"baseline": 0, "comparison": 0},
                        "submitWait": {"baseline": 0, "comparison": 0},
                    }
                }
                break

        result = comparability_coherence.assess_workload(
            workload,
            min_timed_samples=7,
            smoke_min_timed_samples=3,
        )

        self.assertEqual(result["status"], "pass", result["reasons"])

    def test_asymmetric_counts_only_failing_side_is_reported(self) -> None:
        workload = _workload(
            claim_eligible=False,
            baseline_count=10,
            comparison_count=2,
        )
        result = comparability_coherence.assess_workload(
            workload,
            min_timed_samples=7,
            smoke_min_timed_samples=3,
        )
        self.assertEqual(result["status"], "fail")
        reasons = result["reasons"]
        self.assertFalse(
            any("baselineStatsMs.count 10" in reason for reason in reasons),
            "baseline above floor must not be flagged",
        )
        self.assertTrue(
            any(
                "comparisonStatsMs.count 2 < smoke-comparability floor 3" in reason
                for reason in reasons
            ),
            reasons,
        )

    def test_report_level_demotes_smoke_count_two(self) -> None:
        workload = _workload(
            claim_eligible=False,
            baseline_count=2,
            comparison_count=2,
        )
        report = {
            "comparisonStatus": "comparable",
            "workloads": [workload],
            "comparabilitySummary": {"workloadCount": 1, "nonComparableCount": 0},
        }
        result = comparability_coherence.assess_report(
            report,
            min_timed_samples=7,
            smoke_min_timed_samples=3,
        )
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["minTimedSamples"], 7)
        self.assertEqual(result["smokeMinTimedSamples"], 3)

    def test_report_level_accepts_smoke_count_three(self) -> None:
        workload = _workload(
            claim_eligible=False,
            baseline_count=3,
            comparison_count=3,
        )
        report = {
            "comparisonStatus": "comparable",
            "workloads": [workload],
            "comparabilitySummary": {"workloadCount": 1, "nonComparableCount": 0},
        }
        result = comparability_coherence.assess_report(
            report,
            min_timed_samples=7,
            smoke_min_timed_samples=3,
        )
        self.assertEqual(result["status"], "pass", result.get("failures"))


class PolicyLoadingTests(unittest.TestCase):
    def test_smoke_floor_loaded_from_config(self) -> None:
        from native_compare_modules.config_support import (
            load_benchmark_methodology_policy,
        )

        policy = load_benchmark_methodology_policy(
            str(REPO_ROOT / "config/benchmark-methodology-thresholds.json")
        )
        self.assertEqual(policy.comparability_min_timed_samples, 7)
        self.assertEqual(policy.smoke_comparability_min_timed_samples, 3)
        self.assertEqual(policy.suspicious_speedup_ratio, 10.0)

    def test_smoke_floor_above_main_floor_rejected(self) -> None:
        import json
        import tempfile

        from native_compare_modules.config_support import (
            load_benchmark_methodology_policy,
        )

        payload = {
            "schemaVersion": 3,
            "timingSelection": {
                "minDispatchWindowNsWithoutEncode": 500000,
                "minDispatchWindowCoveragePercentWithoutEncode": 1.0,
            },
            "claimabilityDefaults": {
                "localMinTimedSamples": 7,
                "releaseMinTimedSamples": 15,
            },
            "comparabilityDefaults": {
                "minTimedSamples": 3,
                "smokeMinTimedSamples": 7,
            },
            "timingScopeSanity": {
                "minOperationWallCoverageRatio": 0.05,
                "maxOperationWallCoverageAsymmetryRatio": 128.0,
                "minRowTimingFloorNs": 0,
            },
            "reliability": {
                "suspiciousSpeedupRatio": 10.0,
                "localRequiredPositivePercentiles": ["p50Percent"],
                "releaseRequiredPositivePercentiles": ["p50Percent"],
                "flakeBudgetPercent": 5.0,
                "retryPolicy": {"maxRetries": 0, "retryOn": []},
            },
        }
        with tempfile.NamedTemporaryFile(
            suffix=".json", mode="w", delete=False
        ) as tmp:
            json.dump(payload, tmp)
            tmp_path = tmp.name
        try:
            with self.assertRaises(ValueError) as cm:
                load_benchmark_methodology_policy(tmp_path)
            self.assertIn("smokeMinTimedSamples", str(cm.exception))
        finally:
            Path(tmp_path).unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
