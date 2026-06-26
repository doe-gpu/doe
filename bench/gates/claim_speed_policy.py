"""Speed-claim checks used by the release claim gate."""

from __future__ import annotations

from typing import Any

from native_compare_modules.claimability import (
    SUSPICIOUS_SPEEDUP_AUDIT_NOTE,
    assess_suspicious_speedup,
    suspicious_speedup_audit_passes,
)


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


def _claimability_object(workload: dict[str, Any]) -> dict[str, Any]:
    claimability = workload.get("claimability")
    return claimability if isinstance(claimability, dict) else {}


def _string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str) and item]


def _claimability_reasons_empty(claimability: dict[str, Any]) -> bool:
    reasons = claimability.get("reasons")
    return isinstance(reasons, list) and not reasons


def claimability_skip_failures(
    *,
    workload_id: str,
    workload: dict[str, Any],
) -> tuple[list[str], bool]:
    """Return validation failures and whether speed checks should run."""
    claimability = _claimability_object(workload)
    if claimability.get("evaluated") is not False:
        return [], True

    failures: list[str] = []
    skip_reason = claimability.get("skipReason")
    if skip_reason != "claimEligible=false":
        failures.append(
            f"{workload_id}: unevaluated claimability requires skipReason=claimEligible=false"
        )
    if workload.get("claimEligible") is not False:
        failures.append(
            f"{workload_id}: unevaluated claimability requires report claimEligible=false"
        )
    if claimability.get("claimable") is not True:
        failures.append(
            f"{workload_id}: claim-ineligible skipped row must remain claimable"
        )
    if claimability.get("claimMetricField") not in ("", None):
        failures.append(
            f"{workload_id}: unevaluated claimability requires empty claimMetricField"
        )
    if claimability.get("claimMetricScope") != "notEvaluated":
        failures.append(
            f"{workload_id}: unevaluated claimability requires claimMetricScope=notEvaluated"
        )
    if _string_list(claimability.get("requiredPositivePercentiles")):
        failures.append(
            f"{workload_id}: unevaluated claimability requires no requiredPositivePercentiles"
        )
    if not _claimability_reasons_empty(claimability):
        failures.append(f"{workload_id}: unevaluated claimability requires no reasons")
    return failures, False


def _claim_metric_payload(
    *,
    workload_id: str,
    workload: dict[str, Any],
    claimability: dict[str, Any],
) -> tuple[list[str], dict[str, Any], dict[str, Any], dict[str, Any]]:
    scope = str(claimability.get("claimMetricScope", ""))
    field = str(claimability.get("claimMetricField", ""))
    if field == "deltaPercent" or scope == "selectedTiming":
        baseline_stats = workload.get("baselineStatsMs", {})
        comparison_stats = workload.get("comparisonStatsMs", {})
        delta = workload.get("deltaPercent", {})
    elif (
        field == "timingInterpretation.workloadUnitWall.deltaPercent"
        or scope == "workloadUnitWall"
    ):
        timing_interpretation = workload.get("timingInterpretation")
        if not isinstance(timing_interpretation, dict):
            timing_interpretation = {}
        workload_unit_wall = timing_interpretation.get("workloadUnitWall")
        if not isinstance(workload_unit_wall, dict):
            workload_unit_wall = {}
        baseline_stats = workload_unit_wall.get("baselineStatsMs", {})
        comparison_stats = workload_unit_wall.get("comparisonStatsMs", {})
        delta = workload_unit_wall.get("deltaPercent", {})
    else:
        return [
            f"{workload_id}: unsupported claim metric "
            f"field={field!r} scope={scope!r}"
        ], {}, {}, {}

    failures: list[str] = []
    if not isinstance(baseline_stats, dict):
        failures.append(f"{workload_id}: claim metric baselineStatsMs missing/invalid")
        baseline_stats = {}
    if not isinstance(comparison_stats, dict):
        failures.append(f"{workload_id}: claim metric comparisonStatsMs missing/invalid")
        comparison_stats = {}
    if not isinstance(delta, dict):
        failures.append(f"{workload_id}: claim metric deltaPercent missing/invalid")
        delta = {}
    return failures, baseline_stats, comparison_stats, delta


def _suspicious_speedup_is_audited(
    *,
    workload: dict[str, Any],
    claimability: dict[str, Any],
) -> bool:
    if claimability.get("claimable") is not True:
        return False
    if not _claimability_reasons_empty(claimability):
        return False
    if SUSPICIOUS_SPEEDUP_AUDIT_NOTE not in _string_list(claimability.get("auditNotes")):
        return False
    if workload.get("pathAsymmetry") is True:
        return False
    comparability = workload.get("comparability")
    if not isinstance(comparability, dict):
        return False
    return suspicious_speedup_audit_passes(comparability)


def claimable_speed_failures(
    *,
    workload_id: str,
    workload: dict[str, Any],
    expected_required_percentiles: list[str],
    min_timed_samples: int,
    suspicious_speedup_ratio: float,
) -> list[str]:
    failures: list[str] = []
    skip_failures, should_check_speed = claimability_skip_failures(
        workload_id=workload_id,
        workload=workload,
    )
    failures.extend(skip_failures)
    if not should_check_speed:
        return failures

    claimability = _claimability_object(workload)
    metric_failures, baseline_stats, comparison_stats, delta = _claim_metric_payload(
        workload_id=workload_id,
        workload=workload,
        claimability=claimability,
    )
    failures.extend(metric_failures)
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

    speedup_failures = suspicious_speedup_failures(
        workload_id=workload_id,
        baseline_stats=baseline_stats,
        comparison_stats=comparison_stats,
        suspicious_speedup_ratio=suspicious_speedup_ratio,
    )
    if speedup_failures and not _suspicious_speedup_is_audited(
        workload=workload,
        claimability=claimability,
    ):
        failures.extend(speedup_failures)
    if not speedup_failures and SUSPICIOUS_SPEEDUP_AUDIT_NOTE in _string_list(
        claimability.get("auditNotes")
    ):
        failures.append(
            f"{workload_id}: suspicious-speedup audit note present without "
            "a matching speedup trigger"
        )
    return failures
