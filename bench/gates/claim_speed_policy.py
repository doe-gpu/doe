"""Speed-claim checks used by the release claim gate."""

from __future__ import annotations

from typing import Any

from native_compare_modules.claimability import assess_suspicious_speedup


RELEASE_REQUIRED_POSITIVE_PERCENTILES = ["p50Percent", "p95Percent", "p99Percent"]
LOCAL_REQUIRED_POSITIVE_PERCENTILES = ["p50Percent", "p95Percent"]


def _parse_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    return None


def _parse_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def expected_positive_percentiles_for_mode(mode: str) -> list[str]:
    if mode == "release":
        return RELEASE_REQUIRED_POSITIVE_PERCENTILES
    if mode == "local":
        return LOCAL_REQUIRED_POSITIVE_PERCENTILES
    return []


def suspicious_speedup_failures(
    *,
    workload_id: str,
    baseline_stats: dict[str, Any],
    comparison_stats: dict[str, Any],
    suspicious_speedup_ratio: float,
) -> list[str]:
    return [
        f"{workload_id}: {reason}"
        for reason in assess_suspicious_speedup(
            left_stats=baseline_stats,
            right_stats=comparison_stats,
            claim_metric_scope="selectedTiming",
            suspicious_speedup_ratio=suspicious_speedup_ratio,
        )
    ]


def claimable_speed_failures(
    *,
    workload_id: str,
    workload: dict[str, Any],
    expected_required_percentiles: list[str],
    min_timed_samples: int,
    suspicious_speedup_ratio: float,
) -> list[str]:
    failures: list[str] = []
    baseline_stats = workload.get("baselineStatsMs", {})
    comparison_stats = workload.get("comparisonStatsMs", {})
    if not isinstance(baseline_stats, dict):
        baseline_stats = {}
    if not isinstance(comparison_stats, dict):
        comparison_stats = {}
    left_count = _parse_int(baseline_stats.get("count"))
    right_count = _parse_int(comparison_stats.get("count"))
    if left_count is None or left_count < min_timed_samples:
        failures.append(
            f"{workload_id}: baselineStatsMs.count must be >= {min_timed_samples}"
        )
    if right_count is None or right_count < min_timed_samples:
        failures.append(
            f"{workload_id}: comparisonStatsMs.count must be >= {min_timed_samples}"
        )
    delta = workload.get("deltaPercent")
    if not isinstance(delta, dict):
        failures.append(f"{workload_id}: missing deltaPercent object")
    else:
        for percentile in expected_required_percentiles:
            value = _parse_float(delta.get(percentile))
            if value is None:
                failures.append(
                    f"{workload_id}: deltaPercent.{percentile} missing or invalid"
                )
            elif value <= 0.0:
                failures.append(
                    f"{workload_id}: deltaPercent.{percentile} must be > 0 "
                    "(positive means baseline faster)"
                )
    failures.extend(
        suspicious_speedup_failures(
            workload_id=workload_id,
            baseline_stats=baseline_stats,
            comparison_stats=comparison_stats,
            suspicious_speedup_ratio=suspicious_speedup_ratio,
        )
    )
    return failures
