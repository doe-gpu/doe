"""Claimability helpers for the compare lane."""

from __future__ import annotations

from typing import Any

from native_compare_modules import timing_sanity
from native_compare_modules.reporting import safe_float, safe_int
from native_compare_modules.timing_interpretation import workload_unit_wall_view
from native_compare_modules.timing_selection import (
    canonical_timing_source,
    effective_execution_total_ns_for_sample,
    effective_setup_total_ns_for_sample,
)

END_TO_END_CLAIM_UNDERCOVERAGE_RATIO = 0.5
SPEEDUP_STAT_KEYS = (
    ("p50Ms", "p50"),
    ("p95Ms", "p95"),
    ("p99Ms", "p99"),
    ("meanMs", "mean"),
)


def coverage_ratio(measured_ms: float | None, wall_ms: float | None) -> float | None:
    if measured_ms is None or wall_ms is None or wall_ms <= 0.0:
        return None
    if measured_ms < 0.0:
        return None
    return measured_ms / wall_ms


def default_claim_min_timed_samples(
    mode: str,
    benchmark_policy: Any,
) -> int:
    if mode == "local":
        return benchmark_policy.local_claim_min_timed_samples
    if mode == "release":
        return benchmark_policy.release_claim_min_timed_samples
    return 0


def required_positive_percentiles(mode: str) -> list[str]:
    if mode == "release":
        return ["p50Percent", "p95Percent", "p99Percent"]
    if mode == "local":
        return ["p50Percent", "p95Percent"]
    return []


def assess_upload_timing_scope_consistency(
    *,
    side_name: str,
    command_samples: list[dict[str, Any]],
) -> list[str]:
    reasons: list[str] = []
    canonical_sources = {
        canonical_timing_source(str(sample.get("timingSource", "")))
        for sample in command_samples
        if isinstance(sample.get("timingSource"), str) and str(sample.get("timingSource", ""))
    }
    if len(canonical_sources) > 1:
        reasons.append(
            f"{side_name} upload timings use mixed canonical sources: {sorted(canonical_sources)}"
        )

    for sample in command_samples:
        timing = sample.get("timing", {})
        if not isinstance(timing, dict):
            continue
        ignore_applied = timing.get("uploadIgnoreFirstApplied") is True
        timing_source_raw = sample.get("timingSource")
        timing_source = str(timing_source_raw) if isinstance(timing_source_raw, str) else ""
        canonical = canonical_timing_source(timing_source)
        run_index = safe_int(sample.get("runIndex"), default=-1)
        run_label = f"run {run_index}" if run_index >= 0 else "sample"

        if ignore_applied and canonical != "doe-execution-workload-total-ns":
            reasons.append(
                f"{side_name} {run_label} uses ignore-first with non-row timing source "
                f"({canonical}); require doe-execution-workload-total-ns"
            )
        if ignore_applied:
            base_source_raw = timing.get("uploadIgnoreFirstBaseTimingSource")
            adjusted_source_raw = timing.get("uploadIgnoreFirstAdjustedTimingSource")
            base_source = (
                str(base_source_raw) if isinstance(base_source_raw, str) else ""
            )
            adjusted_source = (
                str(adjusted_source_raw) if isinstance(adjusted_source_raw, str) else ""
            )
            canonical_base = canonical_timing_source(base_source)
            canonical_adjusted = canonical_timing_source(adjusted_source)
            if not canonical_base:
                reasons.append(
                    f"{side_name} {run_label} missing uploadIgnoreFirstBaseTimingSource while ignore-first is applied"
                )
            if canonical_adjusted != "doe-execution-workload-total-ns":
                reasons.append(
                    f"{side_name} {run_label} uses ignore-first adjusted source "
                    f"({canonical_adjusted}); require doe-execution-workload-total-ns"
                )
            if canonical_base and canonical_adjusted and canonical_base != canonical_adjusted:
                reasons.append(
                    f"{side_name} {run_label} uses mixed-scope ignore-first sources "
                    f"(base={canonical_base}, adjusted={canonical_adjusted})"
                )
        if "ignore-first-ops" in timing_source and not ignore_applied:
            reasons.append(
                f"{side_name} {run_label} timing source marks ignore-first but uploadIgnoreFirstApplied=false"
            )
    return reasons


def _median_phase_fractions(
    command_samples: list[dict[str, Any]],
) -> dict[str, list[float]]:
    """Return per-sample phase fractions (setup, encode, submitWait) relative to executionTotal."""
    fractions: dict[str, list[float]] = {"setup": [], "encode": [], "submitWait": []}
    for sample in command_samples:
        if not isinstance(sample, dict):
            continue
        tm = sample.get("traceMeta", {})
        if not isinstance(tm, dict):
            continue
        total = effective_execution_total_ns_for_sample(sample)
        if total <= 0:
            continue
        setup = effective_setup_total_ns_for_sample(sample)
        encode = safe_int(tm.get("executionEncodeTotalNs"), default=0)
        submit_wait = safe_int(tm.get("executionSubmitWaitTotalNs"), default=0)
        fractions["setup"].append(setup / total)
        fractions["encode"].append(encode / total)
        fractions["submitWait"].append(submit_wait / total)
    return fractions



def assess_phase_equivalence(
    *,
    left_command_samples: list[dict[str, Any]],
    right_command_samples: list[dict[str, Any]],
) -> list[str]:
    """Reject claims where one side reports zero-on-every-sample for a phase the other
    side reports material cost on.

    CLAUDE.md #11 formulation: if every sample on one side has phase fraction
    below _PHASE_ZERO_EPSILON AND the other side has at least _PHASE_MATERIAL
    _MIN_SAMPLES samples at or above _PHASE_MATERIAL_FLOOR_FRACTION of
    executionTotal, the two sides are measuring different scopes and the
    result is not claimable.
    """
    from native_compare_modules.comparability import (  # local to avoid cycle
        _PHASE_MATERIAL_FLOOR_FRACTION,
        _PHASE_MATERIAL_MIN_SAMPLES,
        _all_samples_zero,
        _material_sample_count,
    )

    reasons: list[str] = []
    left_fracs = _median_phase_fractions(left_command_samples)
    right_fracs = _median_phase_fractions(right_command_samples)

    phase_labels = {"setup": "executionSetupTotalNs", "encode": "executionEncodeTotalNs", "submitWait": "executionSubmitWaitTotalNs"}
    for phase_key, field_name in phase_labels.items():
        left_vals = left_fracs.get(phase_key, [])
        right_vals = right_fracs.get(phase_key, [])
        if not left_vals or not right_vals:
            continue
        left_all_zero = _all_samples_zero(left_vals)
        right_all_zero = _all_samples_zero(right_vals)
        left_material = _material_sample_count(left_vals)
        right_material = _material_sample_count(right_vals)

        if left_all_zero and right_material >= _PHASE_MATERIAL_MIN_SAMPLES:
            reasons.append(
                f"phase asymmetry: baseline reports zero {field_name} on every sample "
                f"while comparison has {right_material} sample(s) "
                f">= {_PHASE_MATERIAL_FLOOR_FRACTION:.1%} of executionTotalNs; "
                f"treat as non-claimable until phase equivalence is confirmed"
            )
        elif right_all_zero and left_material >= _PHASE_MATERIAL_MIN_SAMPLES:
            reasons.append(
                f"phase asymmetry: comparison reports zero {field_name} on every sample "
                f"while baseline has {left_material} sample(s) "
                f">= {_PHASE_MATERIAL_FLOOR_FRACTION:.1%} of executionTotalNs; "
                f"treat as non-claimable until phase equivalence is confirmed"
            )
    return reasons


def _median_elapsed_ns(command_samples: list[dict[str, Any]]) -> float | None:
    """Return the median raw elapsedMs (converted to ns) across successful samples."""
    elapsed_values: list[float] = []
    for sample in command_samples:
        if not isinstance(sample, dict):
            continue
        val = safe_float(sample.get("elapsedMs"))
        if val is not None and val > 0.0:
            elapsed_values.append(val * 1e6)
    if not elapsed_values:
        return None
    elapsed_values.sort()
    return elapsed_values[len(elapsed_values) // 2]


def assess_row_timing_floor(
    *,
    left_command_samples: list[dict[str, Any]],
    right_command_samples: list[dict[str, Any]],
    min_row_timing_floor_ns: int,
) -> list[str]:
    """Demote claims where per-row wall time is below the scheduler-noise floor."""
    if min_row_timing_floor_ns <= 0:
        return []
    reasons: list[str] = []
    left_median_ns = _median_elapsed_ns(left_command_samples)
    right_median_ns = _median_elapsed_ns(right_command_samples)
    for side_name, median_ns in [("baseline", left_median_ns), ("comparison", right_median_ns)]:
        if median_ns is not None and median_ns < min_row_timing_floor_ns:
            reasons.append(
                f"{side_name} median row wall time ({median_ns / 1e6:.3f}ms) is below "
                f"the {min_row_timing_floor_ns / 1e6:.1f}ms scheduler-noise floor; "
                f"increase commandRepeat to push row timing above the floor"
            )
    return reasons


_UPLOAD_SIZE_SUFFIXES = {
    "1kb": 1024,
    "4kb": 4096,
    "16kb": 16384,
    "64kb": 65536,
    "256kb": 262144,
    "1mb": 1048576,
    "4mb": 4194304,
    "16mb": 16777216,
    "64mb": 67108864,
    "256mb": 268435456,
    "1gb": 1073741824,
    "4gb": 4294967296,
    "16gb": 17179869184,
}

# 500 GB/s — above PCIe 5.0 x16 (64 GB/s) and Apple M-series memory
# bandwidth (~400 GB/s peak). Anything above this is not real.
_MAX_PLAUSIBLE_THROUGHPUT_BYTES_PER_SEC = 500_000_000_000


def _parse_upload_bytes_from_id(workload_id: str) -> int | None:
    for suffix, size in _UPLOAD_SIZE_SUFFIXES.items():
        if workload_id.endswith(suffix):
            return size
    return None


def assess_throughput_plausibility(
    *,
    workload_id: str,
    workload_domain: str,
    left_p50_ms: float | None,
    right_p50_ms: float | None,
) -> list[str]:
    """Reject claims where implied throughput exceeds hardware limits."""
    if workload_domain != "upload":
        return []
    upload_bytes = _parse_upload_bytes_from_id(workload_id)
    if upload_bytes is None or upload_bytes == 0:
        return []
    reasons: list[str] = []
    for side_name, p50_ms in [("baseline", left_p50_ms), ("comparison", right_p50_ms)]:
        if p50_ms is None or p50_ms <= 0.0:
            continue
        throughput = upload_bytes / (p50_ms / 1000.0)
        if throughput > _MAX_PLAUSIBLE_THROUGHPUT_BYTES_PER_SEC:
            reasons.append(
                f"{side_name} implies {throughput / 1e9:.0f} GB/s throughput for "
                f"{upload_bytes / (1024**2):.0f} MB upload at p50={p50_ms:.4f}ms; "
                f"exceeds plausibility ceiling of "
                f"{_MAX_PLAUSIBLE_THROUGHPUT_BYTES_PER_SEC / 1e9:.0f} GB/s"
            )
    return reasons


def assess_suspicious_speedup(
    *,
    left_stats: dict[str, Any],
    right_stats: dict[str, Any],
    claim_metric_scope: str,
    suspicious_speedup_ratio: float,
) -> list[str]:
    if suspicious_speedup_ratio < 1.0:
        return []
    reasons: list[str] = []
    for stat_key, label in SPEEDUP_STAT_KEYS:
        left_ms = safe_float(left_stats.get(stat_key))
        right_ms = safe_float(right_stats.get(stat_key))
        if left_ms is None or right_ms is None or left_ms <= 0.0:
            continue
        speedup_ratio = right_ms / left_ms
        if speedup_ratio >= suspicious_speedup_ratio:
            reasons.append(
                f"{claim_metric_scope} {label} speedup {speedup_ratio:.2f}x "
                f"exceeds fairness-audit threshold "
                f"{suspicious_speedup_ratio:.2f}x; treat as non-claimable "
                "until same work, timing scope, cache/preparation state, "
                "fallback state, dispatch work, and readback/output work are audited"
            )
    return reasons


_SUSPICIOUS_SPEEDUP_AUDIT_OBLIGATIONS = {
    "baseline_comparison_trace_meta_source_match",
    "baseline_comparison_timing_selection_policy_match",
    "baseline_comparison_queue_sync_mode_match",
    "baseline_comparison_execution_shape_match",
    "baseline_comparison_hardware_path_match",
    "baseline_execution_evidence_present",
    "baseline_successful_execution_present",
    "baseline_execution_errors_absent",
    "comparison_execution_errors_absent",
}
SUSPICIOUS_SPEEDUP_AUDIT_NOTE = (
    "suspicious speedup trigger accepted after strict comparability audit"
)


def suspicious_speedup_audit_passes(comparability: dict[str, Any]) -> bool:
    if not comparability.get("comparable", False):
        return False
    if comparability.get("blockingFailedObligations") or comparability.get("advisoryFailedObligations"):
        return False
    obligations = comparability.get("obligations")
    if not isinstance(obligations, list) or not obligations:
        return False
    required_seen: set[str] = set()
    for obligation in obligations:
        if not isinstance(obligation, dict):
            return False
        obligation_id = str(obligation.get("id", ""))
        applicable = obligation.get("applicable") is True
        blocking = obligation.get("blocking") is True
        passes = obligation.get("passes") is True
        if applicable and blocking and not passes:
            return False
        if obligation_id in _SUSPICIOUS_SPEEDUP_AUDIT_OBLIGATIONS:
            if not applicable or not passes:
                return False
            required_seen.add(obligation_id)
    return _SUSPICIOUS_SPEEDUP_AUDIT_OBLIGATIONS.issubset(required_seen)


def should_prefer_workload_unit_wall_for_upload_claim(
    *,
    workload_id: str,
    workload_domain: str,
    left_p50_ms: float | None,
    right_p50_ms: float | None,
) -> bool:
    return bool(
        assess_throughput_plausibility(
            workload_id=workload_id,
            workload_domain=workload_domain,
            left_p50_ms=left_p50_ms,
            right_p50_ms=right_p50_ms,
        )
    )


def _workload_unit_wall_percentiles_positive(
    workload_unit_wall_delta: dict[str, Any] | None,
    required_percentiles: list[str],
) -> bool:
    if not isinstance(workload_unit_wall_delta, dict):
        return False
    for percentile in required_percentiles:
        value = safe_float(workload_unit_wall_delta.get(percentile))
        if value is None or value <= 0.0:
            return False
    return True


def should_prefer_workload_unit_wall_for_end_to_end_claim(
    *,
    workload_domain: str,
    selected_scope_class: str,
    workload_unit_wall_delta: dict[str, Any] | None,
    left_selected_wall_coverage: float | None,
    right_selected_wall_coverage: float | None,
    required_percentiles: list[str],
) -> bool:
    if workload_domain not in {"copy", "surface"}:
        return False
    if selected_scope_class != "operation-total":
        return False
    if left_selected_wall_coverage is None or right_selected_wall_coverage is None:
        return False
    if max(left_selected_wall_coverage, right_selected_wall_coverage) >= END_TO_END_CLAIM_UNDERCOVERAGE_RATIO:
        return False
    return _workload_unit_wall_percentiles_positive(
        workload_unit_wall_delta,
        required_percentiles,
    )


def assess_claimability(
    *,
    mode: str,
    min_timed_samples: int,
    workload: Any,
    baseline: dict[str, Any],
    comparison: dict[str, Any],
    delta: dict[str, Any],
    timing_interpretation: dict[str, Any],
    comparability: dict[str, Any],
    benchmark_policy: Any,
) -> dict[str, Any]:
    if mode == "off":
        return {
            "mode": "off",
            "evaluated": False,
            "claimable": None,
            "minTimedSamples": 0,
            "requiredPositivePercentiles": [],
            "reasons": [],
        }
    if getattr(workload, "claim_eligible", True) is False:
        return {
            "mode": mode,
            "evaluated": False,
            "claimable": True,
            "minTimedSamples": 0,
            "requiredPositivePercentiles": [],
            "claimMetricField": "",
            "claimMetricScope": "notEvaluated",
            "baselineTimedSamples": 0,
            "comparisonTimedSamples": 0,
            "skipReason": "claimEligible=false",
            "reasons": [],
        }

    reasons: list[str] = []
    audit_notes: list[str] = []
    effective_min_samples = (
        min_timed_samples
        if min_timed_samples > 0
        else default_claim_min_timed_samples(mode, benchmark_policy)
    )
    required_percentiles = required_positive_percentiles(mode)
    claim_metric_field = "deltaPercent"
    claim_metric_scope = "selectedTiming"
    claim_delta = delta
    claim_left_stats = baseline.get("stats", {}) if isinstance(baseline.get("stats"), dict) else {}
    claim_right_stats = comparison.get("stats", {}) if isinstance(comparison.get("stats"), dict) else {}

    if not comparability.get("comparable", False):
        reasons.append("workload is non-comparable; reliability claimability requires comparability")

    if getattr(workload, "path_asymmetry", False):
        note = getattr(workload, "path_asymmetry_note", "")
        reason = "workload has pathAsymmetry: baseline/comparison use structurally different execution paths"
        if note:
            reason += f" ({note})"
        reasons.append(reason)

    selected_timing = timing_interpretation.get("selectedTiming", {})
    if not isinstance(selected_timing, dict):
        selected_timing = {}
    workload_unit_wall = workload_unit_wall_view(timing_interpretation)
    workload_unit_wall_available = workload_unit_wall.get("available") is True
    if selected_timing.get("scopeClass") == "narrow-hot-path":
        if workload_unit_wall_available:
            workload_unit_wall_delta = workload_unit_wall.get("deltaPercent")
            workload_unit_wall_left = workload_unit_wall.get("baselineStatsMs")
            workload_unit_wall_right = workload_unit_wall.get("comparisonStatsMs")
            if (
                isinstance(workload_unit_wall_delta, dict)
                and isinstance(workload_unit_wall_left, dict)
                and isinstance(workload_unit_wall_right, dict)
            ):
                claim_metric_field = "timingInterpretation.workloadUnitWall.deltaPercent"
                claim_metric_scope = "workloadUnitWall"
                claim_delta = workload_unit_wall_delta
                claim_left_stats = workload_unit_wall_left
                claim_right_stats = workload_unit_wall_right
            else:
                reasons.append(
                    "selected timing scope is narrow-hot-path but workloadUnitWall is incomplete for claim evaluation"
                )
        else:
            reasons.append(
                "selected timing scope is narrow-hot-path and workloadUnitWall is unavailable for full workload-unit claim evaluation"
            )

    left_p50_ms = safe_float(claim_left_stats.get("p50Ms"))
    right_p50_ms = safe_float(claim_right_stats.get("p50Ms"))
    workload_unit_wall_delta = (
        workload_unit_wall.get("deltaPercent") if isinstance(workload_unit_wall, dict) else None
    )
    workload_unit_wall_left = (
        workload_unit_wall.get("baselineStatsMs") if isinstance(workload_unit_wall, dict) else None
    )
    workload_unit_wall_right = (
        workload_unit_wall.get("comparisonStatsMs") if isinstance(workload_unit_wall, dict) else None
    )
    workload_unit_wall_left_p50_ms = (
        safe_float(workload_unit_wall_left.get("p50Ms"))
        if isinstance(workload_unit_wall_left, dict)
        else None
    )
    workload_unit_wall_right_p50_ms = (
        safe_float(workload_unit_wall_right.get("p50Ms"))
        if isinstance(workload_unit_wall_right, dict)
        else None
    )
    left_selected_wall_coverage = coverage_ratio(left_p50_ms, workload_unit_wall_left_p50_ms)
    right_selected_wall_coverage = coverage_ratio(right_p50_ms, workload_unit_wall_right_p50_ms)
    if (
        workload.domain in {"copy", "upload", "p0-resource"}
        and claim_metric_scope == "selectedTiming"
        and selected_timing.get("scopeClass") == "operation-total"
        and isinstance(workload_unit_wall_delta, dict)
        and isinstance(workload_unit_wall_left, dict)
        and isinstance(workload_unit_wall_right, dict)
        and left_selected_wall_coverage is not None
        and right_selected_wall_coverage is not None
    ):
        smaller_coverage = min(left_selected_wall_coverage, right_selected_wall_coverage)
        larger_coverage = max(left_selected_wall_coverage, right_selected_wall_coverage)
        coverage_asymmetry = float("inf") if smaller_coverage <= 0.0 else larger_coverage / smaller_coverage
        if smaller_coverage < 0.05 and coverage_asymmetry >= 5.0:
            claim_metric_field = "timingInterpretation.workloadUnitWall.deltaPercent"
            claim_metric_scope = "workloadUnitWall"
            claim_delta = workload_unit_wall_delta
            claim_left_stats = workload_unit_wall_left
            claim_right_stats = workload_unit_wall_right
            left_p50_ms = workload_unit_wall_left_p50_ms
            right_p50_ms = workload_unit_wall_right_p50_ms
    if (
        claim_metric_scope == "selectedTiming"
        and isinstance(workload_unit_wall_delta, dict)
        and isinstance(workload_unit_wall_left, dict)
        and isinstance(workload_unit_wall_right, dict)
        and should_prefer_workload_unit_wall_for_end_to_end_claim(
            workload_domain=workload.domain,
            selected_scope_class=str(selected_timing.get("scopeClass", "")),
            workload_unit_wall_delta=workload_unit_wall_delta,
            left_selected_wall_coverage=left_selected_wall_coverage,
            right_selected_wall_coverage=right_selected_wall_coverage,
            required_percentiles=required_percentiles,
        )
    ):
        claim_metric_field = "timingInterpretation.workloadUnitWall.deltaPercent"
        claim_metric_scope = "workloadUnitWall"
        claim_delta = workload_unit_wall_delta
        claim_left_stats = workload_unit_wall_left
        claim_right_stats = workload_unit_wall_right
        left_p50_ms = workload_unit_wall_left_p50_ms
        right_p50_ms = workload_unit_wall_right_p50_ms
    if (
        workload.domain == "upload"
        and claim_metric_scope == "selectedTiming"
        and isinstance(workload_unit_wall_delta, dict)
        and isinstance(workload_unit_wall_left, dict)
        and isinstance(workload_unit_wall_right, dict)
        and should_prefer_workload_unit_wall_for_upload_claim(
            workload_id=workload.id,
            workload_domain=workload.domain,
            left_p50_ms=left_p50_ms,
            right_p50_ms=right_p50_ms,
        )
    ):
        claim_metric_field = "timingInterpretation.workloadUnitWall.deltaPercent"
        claim_metric_scope = "workloadUnitWall"
        claim_delta = workload_unit_wall_delta
        claim_left_stats = workload_unit_wall_left
        claim_right_stats = workload_unit_wall_right
        left_p50_ms = workload_unit_wall_left_p50_ms
        right_p50_ms = workload_unit_wall_right_p50_ms
    if (
        workload.domain == "upload"
        and claim_metric_scope == "selectedTiming"
        and selected_timing.get("scopeClass") == "operation-total"
        and _workload_unit_wall_percentiles_positive(
            workload_unit_wall_delta,
            required_percentiles,
        )
        and left_selected_wall_coverage is not None
        and right_selected_wall_coverage is not None
        and max(left_selected_wall_coverage, right_selected_wall_coverage) < 0.5
    ):
        claim_metric_field = "timingInterpretation.workloadUnitWall.deltaPercent"
        claim_metric_scope = "workloadUnitWall"
        claim_delta = workload_unit_wall_delta
        claim_left_stats = workload_unit_wall_left
        claim_right_stats = workload_unit_wall_right
        left_p50_ms = workload_unit_wall_left_p50_ms
        right_p50_ms = workload_unit_wall_right_p50_ms
    if (
        workload.domain == "copy"
        and claim_metric_scope == "selectedTiming"
        and selected_timing.get("scopeClass") == "operation-total"
        and workload_unit_wall_available
        and ((left_p50_ms is not None and left_p50_ms < 0.0001) or (right_p50_ms is not None and right_p50_ms < 0.0001))
    ):
        if (
            isinstance(workload_unit_wall_delta, dict)
            and isinstance(workload_unit_wall_left, dict)
            and isinstance(workload_unit_wall_right, dict)
        ):
            claim_metric_field = "timingInterpretation.workloadUnitWall.deltaPercent"
            claim_metric_scope = "workloadUnitWall"
            claim_delta = workload_unit_wall_delta
            claim_left_stats = workload_unit_wall_left
            claim_right_stats = workload_unit_wall_right
            left_p50_ms = safe_float(claim_left_stats.get("p50Ms"))
            right_p50_ms = safe_float(claim_right_stats.get("p50Ms"))
        else:
            reasons.append(
                "copy workload selected timing is below the measurement noise floor but workloadUnitWall is incomplete"
            )

    left_count = safe_int(claim_left_stats.get("count"), default=0)
    right_count = safe_int(claim_right_stats.get("count"), default=0)
    if left_count < effective_min_samples:
        reasons.append(
            f"baseline timed sample count {left_count} is below claim floor {effective_min_samples}"
        )
    if right_count < effective_min_samples:
        reasons.append(
            f"comparison timed sample count {right_count} is below claim floor {effective_min_samples}"
        )

    left_stdev_ms = safe_float(claim_left_stats.get("stdevMs"))
    left_samples = baseline.get("commandSamples", [])
    left_canonical_sources = {
        canonical_timing_source(str(sample.get("timingSource", "")))
        for sample in left_samples
        if isinstance(sample, dict) and isinstance(sample.get("timingSource"), str)
    } if isinstance(left_samples, list) else set()
    if (
        left_count >= effective_min_samples
        and left_stdev_ms is not None
        and left_stdev_ms == 0.0
        and left_canonical_sources
        and left_canonical_sources.issubset(
            {
                "doe-execution-workload-total-ns",
                "doe-execution-total-ns",
                "doe-execution-dispatch-window-ns",
                "doe-execution-encode-ns",
            }
        )
    ):
        reasons.append(
            "baseline timed samples have zero variance across the full claim window; "
            "treat as non-claimable until timing path is proven non-synthetic"
        )

    if left_p50_ms is not None and left_p50_ms < 0.0001:
        reasons.append(f"baseline p50 timing ({left_p50_ms * 1e6:.1f}ns) is below the 100ns measurement noise floor")
    if right_p50_ms is not None and right_p50_ms < 0.0001:
        reasons.append(f"comparison p50 timing ({right_p50_ms * 1e6:.1f}ns) is below the 100ns measurement noise floor")

    min_row_timing_floor_ns = getattr(benchmark_policy, "min_row_timing_floor_ns", 0)
    if min_row_timing_floor_ns > 0:
        left_samples_for_floor = baseline.get("commandSamples", [])
        right_samples_for_floor = comparison.get("commandSamples", [])
        if isinstance(left_samples_for_floor, list) and isinstance(right_samples_for_floor, list):
            reasons.extend(
                assess_row_timing_floor(
                    left_command_samples=left_samples_for_floor,
                    right_command_samples=right_samples_for_floor,
                    min_row_timing_floor_ns=min_row_timing_floor_ns,
                )
            )

    reasons.extend(
        assess_throughput_plausibility(
            workload_id=workload.id,
            workload_domain=workload.domain,
            left_p50_ms=left_p50_ms,
            right_p50_ms=right_p50_ms,
        )
    )
    suspicious_speedup_reasons = assess_suspicious_speedup(
        left_stats=claim_left_stats,
        right_stats=claim_right_stats,
        claim_metric_scope=claim_metric_scope,
        suspicious_speedup_ratio=benchmark_policy.suspicious_speedup_ratio,
    )
    if suspicious_speedup_reasons:
        if (
            not getattr(workload, "path_asymmetry", False)
            and suspicious_speedup_audit_passes(comparability)
        ):
            audit_notes.append(SUSPICIOUS_SPEEDUP_AUDIT_NOTE)
        else:
            reasons.extend(suspicious_speedup_reasons)

    for percentile_key in required_percentiles:
        value = safe_float(claim_delta.get(percentile_key))
        if value is None:
            reasons.append(f"missing delta percentile {percentile_key}")
            continue
        if value <= 0.0:
            reasons.append(
                f"{percentile_key}={value:.6f} is not positive (positive means baseline faster)"
            )

    if workload.domain == "upload":
        left_samples = baseline.get("commandSamples", [])
        right_samples = comparison.get("commandSamples", [])
        if isinstance(left_samples, list):
            reasons.extend(
                assess_upload_timing_scope_consistency(
                    side_name="baseline",
                    command_samples=left_samples,
                )
            )
        if isinstance(right_samples, list):
            reasons.extend(
                assess_upload_timing_scope_consistency(
                    side_name="comparison",
                    command_samples=right_samples,
                )
            )

    left_samples = baseline.get("commandSamples", [])
    right_samples = comparison.get("commandSamples", [])
    if isinstance(left_samples, list) and isinstance(right_samples, list):
        # Operation-scope sanity only applies when the claim metric is still
        # based on operation timing.  When the claim has already been promoted
        # to workloadUnitWall (e.g. because of a known coverage asymmetry
        # such as upload deferred-queue-sync), the operation-timing coverage
        # ratio is expected to be asymmetric and is no longer claim-relevant.
        if claim_metric_scope != "workloadUnitWall":
            reasons.extend(
                timing_sanity.assess_operation_scope_claim_sanity(
                    left_command_samples=left_samples,
                    right_command_samples=right_samples,
                    min_operation_wall_coverage_ratio=benchmark_policy.min_operation_wall_coverage_ratio,
                    max_operation_wall_coverage_asymmetry_ratio=benchmark_policy.max_operation_wall_coverage_asymmetry_ratio,
                )
            )
        reasons.extend(
            assess_phase_equivalence(
                left_command_samples=left_samples,
                right_command_samples=right_samples,
            )
        )

    return {
        "mode": mode,
        "evaluated": True,
        "claimable": len(reasons) == 0,
        "minTimedSamples": effective_min_samples,
        "requiredPositivePercentiles": required_percentiles,
        "claimMetricField": claim_metric_field,
        "claimMetricScope": claim_metric_scope,
        "baselineTimedSamples": left_count,
        "comparisonTimedSamples": right_count,
        "auditNotes": audit_notes,
        "reasons": reasons,
    }
