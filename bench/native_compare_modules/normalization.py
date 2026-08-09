"""Normalization helpers shared by benchmark receipt and compare code."""

from __future__ import annotations

from typing import Any

from native_compare_modules.reporting import parse_int, safe_float


def _positive_float(value: Any) -> float | None:
    parsed = safe_float(value)
    if parsed is None or parsed <= 0.0:
        return None
    return parsed


def _timing_meta(sample: dict[str, Any]) -> dict[str, Any]:
    timing = sample.get("timing", {})
    return timing if isinstance(timing, dict) else {}


def derive_counter_derived_divisor(
    *,
    workload_domain: str,
    strict_normalization_unit: str,
    trace_meta: dict[str, Any],
    command_repeat: int,
) -> tuple[float, int, int, int]:
    trace_row_count = parse_int(trace_meta.get("executionRowCount", 0)) or 0
    trace_dispatch_count = parse_int(trace_meta.get("executionDispatchCount", 0)) or 0
    trace_success_count = parse_int(trace_meta.get("executionSuccessCount", 0)) or 0
    trace_submit_every = parse_int(trace_meta.get("uploadSubmitEvery", 0)) or 0
    derived_divisor = 0.0

    if strict_normalization_unit == "cycle" and command_repeat > 0:
        derived_divisor = float(command_repeat)
    elif strict_normalization_unit == "dispatch" and trace_dispatch_count > 0:
        derived_divisor = float(trace_dispatch_count)
    elif workload_domain == "surface" and command_repeat > 0:
        derived_divisor = float(command_repeat)
    elif workload_domain == "upload" and trace_submit_every > 0:
        derived_divisor = float(trace_row_count)
    elif trace_success_count > 0 or trace_row_count > 0:
        derived_divisor = float(max(trace_success_count, trace_row_count))

    return derived_divisor, trace_success_count, trace_row_count, trace_dispatch_count


def sample_command_repeat(sample: dict[str, Any]) -> float:
    timing = _timing_meta(sample)
    command_repeat = _positive_float(timing.get("commandRepeat"))
    if command_repeat is None:
        command_repeat = _positive_float(sample.get("commandRepeat"))
    return command_repeat if command_repeat is not None else 1.0


def sample_selected_timing_divisor(sample: dict[str, Any]) -> float:
    timing = _timing_meta(sample)
    timing_divisor = _positive_float(timing.get("timingNormalizationDivisor"))
    if timing_divisor is None:
        timing_divisor = _positive_float(sample.get("timingNormalizationDivisor"))
    return timing_divisor if timing_divisor is not None else 1.0


def sample_configured_timing_divisor(sample: dict[str, Any]) -> float:
    timing = _timing_meta(sample)
    timing_divisor = _positive_float(timing.get("timingConfiguredDivisor"))
    if timing_divisor is None:
        timing_divisor = _positive_float(sample.get("timingNormalizationDivisor"))
    if timing_divisor is None:
        timing_divisor = _positive_float(timing.get("timingNormalizationDivisor"))
    return timing_divisor if timing_divisor is not None else 1.0


def derive_workload_unit_normalization_divisor(
    *,
    workload_domain: str,
    strict_normalization_unit: str,
    trace_meta: dict[str, Any],
    command_repeat: int,
    configured_timing_divisor: float,
    required_timing_class: str,
) -> tuple[float, str]:
    if required_timing_class == "process-wall":
        return 1.0, "selected-process-wall"

    normalized_unit = strict_normalization_unit.strip().lower()
    normalized_domain = workload_domain.strip().lower()
    if normalized_unit == "cycle" and command_repeat > 1:
        return float(command_repeat), "declared-cycle-count"
    if normalized_unit == "dispatch":
        dispatch_count = parse_int(trace_meta.get("executionDispatchCount", 0)) or 0
        if dispatch_count > 1:
            return float(dispatch_count), "declared-dispatch-count"
    if normalized_domain == "surface" and command_repeat > 1:
        return float(command_repeat), "declared-surface-repeat"
    if normalized_domain == "upload":
        submit_every = parse_int(trace_meta.get("uploadSubmitEvery", 0)) or 0
        row_count = parse_int(trace_meta.get("executionRowCount", 0)) or 0
        if submit_every > 0 and row_count > 1:
            return float(row_count), "declared-upload-row-count"

    if configured_timing_divisor > 1.0 and command_repeat > 1:
        return max(configured_timing_divisor, float(command_repeat)), "normalization-fallback-max"
    if configured_timing_divisor > 1.0:
        return configured_timing_divisor, "configured-timing-divisor"
    if command_repeat > 1:
        return float(command_repeat), "command-repeat"
    return 1.0, "identity"


def sample_workload_unit_normalization_divisor(sample: dict[str, Any]) -> float:
    timing = _timing_meta(sample)
    explicit_divisor = _positive_float(timing.get("workloadUnitNormalizationDivisor"))
    if explicit_divisor is None:
        explicit_divisor = _positive_float(sample.get("workloadUnitNormalizationDivisor"))
    if explicit_divisor is not None:
        return explicit_divisor

    trace_meta = sample.get("traceMeta", {})
    if not isinstance(trace_meta, dict):
        trace_meta = {}
    workload_domain = str(sample.get("workloadDomain", "")).strip().lower()
    strict_normalization_unit = str(sample.get("strictNormalizationUnit", "")).strip().lower()
    configured_timing_divisor = sample_configured_timing_divisor(sample)
    command_repeat = sample_command_repeat(sample)
    derived_divisor, _ = derive_workload_unit_normalization_divisor(
        workload_domain=workload_domain,
        strict_normalization_unit=strict_normalization_unit,
        trace_meta=trace_meta,
        command_repeat=int(command_repeat),
        configured_timing_divisor=configured_timing_divisor,
        required_timing_class=str(sample.get("timingClass", "")).strip(),
    )
    if derived_divisor > 1.0:
        return derived_divisor
    if configured_timing_divisor > 1.0 and command_repeat > 1.0:
        return max(configured_timing_divisor, command_repeat)
    if configured_timing_divisor > 1.0:
        return configured_timing_divisor
    if command_repeat > 1.0:
        return command_repeat
    return 1.0


def sample_normalized_elapsed_ms(sample: dict[str, Any]) -> float | None:
    elapsed_ms = safe_float(sample.get("elapsedMs"))
    if elapsed_ms is None or elapsed_ms < 0.0:
        return None
    return elapsed_ms / sample_workload_unit_normalization_divisor(sample)
