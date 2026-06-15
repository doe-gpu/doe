"""Pure collectors used by compare_assessment."""

from __future__ import annotations

import statistics
from typing import Any
from typing import Callable

from native_compare_modules.reporting import safe_float, safe_int
from native_compare_modules.timing_selection import canonical_timing_source


def collect_execution_shapes(samples: list[dict[str, Any]]) -> list[dict[str, int]]:
    shape_set: set[tuple[int, int, int, int]] = set()
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        dispatch_count = safe_int(trace_meta.get("executionDispatchCount"), default=-1)
        submit_count = safe_int(trace_meta.get("executionSubmitCount"), default=-1)
        row_count = safe_int(trace_meta.get("executionRowCount"), default=-1)
        success_count = safe_int(trace_meta.get("executionSuccessCount"), default=-1)
        if (
            dispatch_count < 0
            and submit_count < 0
            and row_count < 0
            and success_count < 0
        ):
            continue
        shape_set.add((dispatch_count, submit_count, row_count, success_count))
    return [
        {
            "executionDispatchCount": shape[0],
            "executionSubmitCount": shape[1],
            "executionRowCount": shape[2],
            "executionSuccessCount": shape[3],
        }
        for shape in sorted(shape_set)
    ]


def collect_execution_backends(samples: list[dict[str, Any]]) -> set[str]:
    return {
        str(trace_meta.get("executionBackend", ""))
        for sample in samples
        if isinstance(sample, dict)
        for trace_meta in [sample.get("traceMeta", {})]
        if isinstance(trace_meta, dict) and trace_meta.get("executionBackend")
    }


def collect_trace_meta_values(samples: list[dict[str, Any]], key: str) -> set[Any]:
    return {
        sample.get("traceMeta", {}).get(key)
        for sample in samples
        if isinstance(sample, dict)
        and isinstance(sample.get("traceMeta"), dict)
        and key in sample.get("traceMeta", {})
    }


def collect_trace_meta_optional_values(samples: list[dict[str, Any]], key: str) -> set[Any]:
    return {
        sample.get("traceMeta", {}).get(key)
        for sample in samples
        if isinstance(sample, dict) and isinstance(sample.get("traceMeta"), dict)
    }


def collect_resident_buffer_load_shapes(samples: list[dict[str, Any]]) -> set[tuple[int, int]]:
    shapes: set[tuple[int, int]] = set()
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        if trace_meta.get("packageResidentBufferLoads") is not True:
            continue
        breakdown = trace_meta.get("packageResidentBufferLoadBreakdown", {})
        if not isinstance(breakdown, dict):
            shapes.add((-1, -1))
            continue
        shapes.add((
            safe_int(breakdown.get("count"), default=-1),
            safe_int(breakdown.get("bytes"), default=-1),
        ))
    return shapes


def collect_shader_source_receipt_hashes(samples: list[dict[str, Any]]) -> set[str]:
    hashes: set[str] = set()
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        value = trace_meta.get("shaderSourceReceiptsHash")
        if isinstance(value, str) and value.strip():
            hashes.add(value.strip())
    return hashes


def collect_readback_capture_signatures(samples: list[dict[str, Any]]) -> list[dict[str, Any]]:
    signatures: set[tuple[Any, ...]] = set()
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        captures = trace_meta.get("readbackCaptures", [])
        if not isinstance(captures, list):
            continue
        for capture in captures:
            if not isinstance(capture, dict):
                continue
            sha256 = str(capture.get("sha256", "")).strip()
            if not sha256:
                continue
            signatures.add((
                safe_int(capture.get("repeatIndex"), default=-1),
                safe_int(capture.get("stepIndex"), default=-1),
                str(capture.get("stepId", "")),
                str(capture.get("bufferId", "")),
                safe_int(capture.get("byteLength"), default=-1),
                sha256,
                safe_int(capture.get("decodedU32Le"), default=-1),
                str(capture.get("semanticOpId", "")),
                str(capture.get("semanticStage", "")),
                str(capture.get("semanticPhase", "")),
                safe_int(capture.get("semanticTokenIndex"), default=-1),
                str(capture.get("captureSourceBufferId", "")),
                safe_int(capture.get("captureOffset"), default=-1),
                safe_int(capture.get("captureSize"), default=-1),
            ))
    return [
        {
            "repeatIndex": item[0],
            "stepIndex": item[1],
            "stepId": item[2],
            "bufferId": item[3],
            "byteLength": item[4],
            "sha256": item[5],
            "decodedU32Le": item[6],
            "semanticOpId": item[7],
            "semanticStage": item[8],
            "semanticPhase": item[9],
            "semanticTokenIndex": item[10],
            "captureSourceBufferId": item[11],
            "captureOffset": item[12],
            "captureSize": item[13],
        }
        for item in sorted(signatures)
    ]


def normalize_execution_shapes(
    shapes: list[dict[str, int]],
    *,
    side_name: str,
    command_repeat: int,
) -> tuple[list[dict[str, int]], str]:
    repeat = command_repeat if command_repeat > 0 else 1
    normalized: list[dict[str, int]] = []
    for shape in shapes:
        normalized_shape = dict(shape)
        for field in (
            "executionDispatchCount",
            "executionSubmitCount",
            "executionRowCount",
            "executionSuccessCount",
        ):
            value = safe_int(shape.get(field), default=-1)
            if value < 0:
                continue
            if repeat > 1:
                if value % repeat != 0:
                    return [], (
                        f"{side_name} {field}={value} is not divisible by commandRepeat={repeat}"
                    )
                value //= repeat
            normalized_shape[field] = value
        normalized.append(normalized_shape)
    return normalized, ""


def compare_execution_shapes(
    left_shapes: list[dict[str, int]],
    right_shapes: list[dict[str, int]],
) -> tuple[bool, str]:
    def to_shape_map(
        shapes: list[dict[str, int]],
    ) -> dict[tuple[int, int], tuple[set[int], set[int]]]:
        mapped: dict[tuple[int, int], tuple[set[int], set[int]]] = {}
        for shape in shapes:
            row_count = safe_int(shape.get("executionRowCount"), default=-1)
            success_count = safe_int(shape.get("executionSuccessCount"), default=-1)
            dispatch_count = safe_int(shape.get("executionDispatchCount"), default=-1)
            submit_count = safe_int(shape.get("executionSubmitCount"), default=-1)
            key = (row_count, success_count)
            if key not in mapped:
                mapped[key] = (set(), set())
            mapped[key][0].add(dispatch_count)
            mapped[key][1].add(submit_count)
        return mapped

    left_map = to_shape_map(left_shapes)
    right_map = to_shape_map(right_shapes)
    if set(left_map.keys()) != set(right_map.keys()):
        return False, "row/success shape sets differ"

    for key in sorted(left_map.keys()):
        left_dispatches, left_submits = left_map[key]
        right_dispatches, right_submits = right_map[key]
        left_known = {value for value in left_dispatches if value >= 0}
        right_known = {value for value in right_dispatches if value >= 0}
        if not left_known or not right_known:
            return (
                False,
                (
                    f"dispatch counts unknown for row/success={key}: "
                    f"baseline_known={sorted(left_known)} "
                    f"comparison_known={sorted(right_known)}"
                ),
            )
        if left_known != right_known:
            return (
                False,
                (
                    f"dispatch counts differ for row/success={key}: "
                    f"{sorted(left_known)} vs {sorted(right_known)}"
                ),
            )
        left_submit_known = {value for value in left_submits if value >= 0}
        right_submit_known = {value for value in right_submits if value >= 0}
        if left_submit_known and right_submit_known and left_submit_known != right_submit_known:
            return (
                False,
                (
                    f"submit counts differ for row/success={key}: "
                    f"{sorted(left_submit_known)} vs {sorted(right_submit_known)}"
                ),
            )
    return True, ""


def collect_upload_ignore_first_violations(
    *,
    side_name: str,
    samples: list[dict[str, Any]],
) -> list[str]:
    side_reasons: list[str] = []
    for sample in samples:
        timing = sample.get("timing", {})
        if not isinstance(timing, dict):
            continue
        if timing.get("uploadIgnoreFirstApplied") is not True:
            continue
        run_index = safe_int(sample.get("runIndex"), default=-1)
        run_label = f"run {run_index}" if run_index >= 0 else "sample"
        base_raw = timing.get("uploadIgnoreFirstBaseTimingSource")
        adjusted_raw = timing.get("uploadIgnoreFirstAdjustedTimingSource")
        base_source = str(base_raw) if isinstance(base_raw, str) else ""
        adjusted_source = str(adjusted_raw) if isinstance(adjusted_raw, str) else ""
        canonical_base = canonical_timing_source(base_source)
        canonical_adjusted = canonical_timing_source(adjusted_source)
        canonical_selected = canonical_timing_source(str(sample.get("timingSource", "")))
        if canonical_adjusted != "doe-execution-workload-total-ns":
            side_reasons.append(
                f"{side_name} {run_label} ignore-first adjusted source is "
                f"{canonical_adjusted}; require doe-execution-workload-total-ns"
            )
        if canonical_base and canonical_adjusted and canonical_base != canonical_adjusted:
            side_reasons.append(
                f"{side_name} {run_label} uses mixed-scope ignore-first sources "
                f"(base={canonical_base}, adjusted={canonical_adjusted})"
            )
        if canonical_adjusted and canonical_selected != canonical_adjusted:
            side_reasons.append(
                f"{side_name} {run_label} selected timing source {canonical_selected} "
                f"does not match ignore-first adjusted source {canonical_adjusted}"
            )
    return side_reasons


def median_timing_wall_ratio(
    samples: list[dict[str, Any]],
    sample_normalized_wall_ms: Callable[[dict[str, Any]], float | None],
) -> tuple[float | None, float | None, float | None, float | None]:
    """Return median traced ms, normalized wall ms, traced/wall ratio, and process wall ms."""
    ratios: list[float] = []
    traced_values: list[float] = []
    wall_values: list[float] = []
    process_wall_values: list[float] = []
    for sample in samples:
        traced = safe_float(sample.get("measuredMs"))
        wall = sample_normalized_wall_ms(sample)
        process_wall = safe_float(sample.get("elapsedMs"))
        if traced is not None and wall is not None and wall > 0:
            traced_values.append(traced)
            wall_values.append(wall)
            ratios.append(traced / wall)
            if process_wall is not None and process_wall > 0.0:
                process_wall_values.append(process_wall)
    if not ratios:
        return None, None, None, None
    return (
        statistics.median(traced_values),
        statistics.median(wall_values),
        statistics.median(ratios),
        statistics.median(process_wall_values) if process_wall_values else None,
    )


def ratio_asymmetry(left_ratio: float | None, right_ratio: float | None) -> float | None:
    if left_ratio is None or right_ratio is None:
        return None
    smaller = min(left_ratio, right_ratio)
    larger = max(left_ratio, right_ratio)
    if smaller <= 0.0:
        return float("inf")
    return larger / smaller
