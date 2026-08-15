"""Pure collectors used by compare_assessment."""

from __future__ import annotations

import statistics
from typing import Any
from typing import Callable

from native_compare_modules.reporting import safe_float, safe_int
from native_compare_modules.timing_selection import canonical_timing_source


_NATIVE_READBACK_FIELDS = (
    "readbackMapReadCopyUnmapTotalNs",
    "readbackMapReadCopyUnmapMapTotalNs",
    "readbackMapReadCopyUnmapCopyTotalNs",
    "readbackMapReadCopyUnmapDeferredCopyTotalNs",
    "readbackMapReadCopyUnmapDeferredResolveTotalNs",
    "readbackMapReadCopyUnmapQueueWaitCompletedTotalNs",
    "readbackMapReadCopyUnmapUnmapTotalNs",
    "readbackNativeReadCopyTotalNs",
)
_MAP_ASYNC_READBACK_FIELDS = (
    "readbackMapAsyncTotalNs",
    "readbackGetMappedRangeTotalNs",
    "readbackHostCopyTotalNs",
    "readbackUnmapTotalNs",
)
_PACKAGE_EFFECTIVE_READBACK_PATHS = frozenset({
    "native-map-read-copy-unmap",
    "mapAsync",
})
_INVALID_EFFECTIVE_READBACK_PATH = "invalid-readback-path"
_PACKAGE_EXECUTION_BACKENDS = frozenset({
    "node_webgpu_package",
    "doe_node_webgpu",
    "doe_node_native_direct",
    "bun_webgpu_package",
    "doe_bun_package",
    "deno_webgpu_package",
    "doe_deno_package",
})
_DOE_EXECUTION_BACKENDS = frozenset({
    "doe_metal",
    "doe_vulkan",
    "doe_d3d12",
    "doe_node_webgpu",
    "doe_node_native_direct",
    "doe_bun_package",
    "doe_deno_package",
    "doppler_node_webgpu_doe",
    "webgpu-ffi",
    "native",
})


def collect_result_output_signatures(
    samples: list[dict[str, Any]],
) -> set[tuple[str, int]]:
    signatures: set[tuple[str, int]] = set()
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        result_summary = trace_meta.get("resultSummary", {})
        if not isinstance(result_summary, dict):
            continue
        digest = str(result_summary.get("generatedTextSha256", "")).strip().lower()
        length = safe_int(result_summary.get("generatedTextLength"), default=-1)
        if len(digest) == 64 and length >= 0:
            signatures.add((digest, length))
    return signatures


def _has_positive_field(payload: dict[str, Any], fields: tuple[str, ...]) -> bool:
    return any(safe_int(payload.get(field), default=0) > 0 for field in fields)


def _effective_readback_path(trace_meta: dict[str, Any]) -> str:
    breakdown = trace_meta.get("packageStepBreakdownNs")
    if not isinstance(breakdown, dict):
        return ""
    native_readback = _has_positive_field(breakdown, _NATIVE_READBACK_FIELDS)
    map_async_readback = _has_positive_field(breakdown, _MAP_ASYNC_READBACK_FIELDS)
    if native_readback and map_async_readback:
        return "mixed-native-mapAsync"
    if native_readback:
        return "native-map-read-copy-unmap"
    if map_async_readback:
        return "mapAsync"
    if safe_int(breakdown.get("readbackTotalNs"), default=0) > 0:
        return "unknown-readback"
    return ""


def _explicit_effective_readback_paths(trace_meta: dict[str, Any]) -> set[str] | None:
    raw_paths = trace_meta.get("packageEffectiveReadbackPaths")
    if not isinstance(raw_paths, list):
        return None
    paths: set[str] = set()
    for path in raw_paths:
        if isinstance(path, str) and path in _PACKAGE_EFFECTIVE_READBACK_PATHS:
            paths.add(path)
        else:
            paths.add(_INVALID_EFFECTIVE_READBACK_PATH)
    if not paths and _effective_readback_path(trace_meta):
        paths.add("unknown-readback")
    return paths


def collect_effective_readback_paths(samples: list[dict[str, Any]]) -> set[str]:
    paths: set[str] = set()
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        explicit_paths = _explicit_effective_readback_paths(trace_meta)
        if explicit_paths is not None:
            if explicit_paths:
                paths.update(explicit_paths)
            continue
        path = _effective_readback_path(trace_meta)
        if path:
            paths.add(path)
    return paths


def assess_effective_readback_path_equivalence(
    left_paths: set[str],
    right_paths: set[str],
    *,
    left_readback_counts: set[int] | None = None,
    right_readback_counts: set[int] | None = None,
) -> tuple[bool, bool, dict[str, Any], str]:
    left_counts = left_readback_counts or set()
    right_counts = right_readback_counts or set()
    left_required = any(count > 0 for count in left_counts)
    right_required = any(count > 0 for count in right_counts)
    applies = (
        left_required
        or right_required
        or bool(left_paths)
        or bool(right_paths)
    )
    passes = (
        len(left_paths) == 1
        and len(right_paths) == 1
        and left_paths == right_paths
        and left_paths <= _PACKAGE_EFFECTIVE_READBACK_PATHS
        and right_paths <= _PACKAGE_EFFECTIVE_READBACK_PATHS
    )
    details = {
        "baselineEffectiveReadbackPaths": sorted(left_paths),
        "comparisonEffectiveReadbackPaths": sorted(right_paths),
        "baselineReadBufferCounts": sorted(left_counts),
        "comparisonReadBufferCounts": sorted(right_counts),
        "baselineEffectiveReadbackPathRequired": left_required,
        "comparisonEffectiveReadbackPathRequired": right_required,
    }
    if (left_required and not left_paths) or (right_required and not right_paths):
        failure_reason = (
            "baseline/comparison effective readback path evidence missing for "
            f"readBufferCount evidence: {left_counts} vs {right_counts}"
        )
    else:
        failure_reason = (
            "baseline/comparison effective readback path mismatch: "
            f"{left_paths} vs {right_paths}"
        )
    return applies, passes, details, failure_reason


def uses_package_execution(backends: set[str]) -> bool:
    return bool(backends & _PACKAGE_EXECUTION_BACKENDS)


def uses_doe_execution(backends: set[str]) -> bool:
    return bool(backends & _DOE_EXECUTION_BACKENDS)


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


def collect_readback_counts(samples: list[dict[str, Any]]) -> set[int]:
    counts: set[int] = set()
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        execution_shape = trace_meta.get("executionShape", {})
        if not isinstance(execution_shape, dict):
            continue
        readback_count = safe_int(execution_shape.get("readBufferCount"), default=-1)
        if readback_count >= 0:
            counts.add(readback_count)
    return counts


def assess_readback_capture_equivalence(
    left_samples: list[dict[str, Any]],
    right_samples: list[dict[str, Any]],
) -> tuple[bool, bool, dict[str, Any], str]:
    left_captures = collect_readback_capture_signatures(left_samples)
    right_captures = collect_readback_capture_signatures(right_samples)
    left_readback_counts = collect_readback_counts(left_samples)
    right_readback_counts = collect_readback_counts(right_samples)
    capture_required = (
        any(count > 0 for count in left_readback_counts)
        or any(count > 0 for count in right_readback_counts)
    )
    applies = capture_required or bool(left_captures) or bool(right_captures)
    required_captures_present = (
        not capture_required
        or (bool(left_captures) and bool(right_captures))
    )
    passes = required_captures_present and left_captures == right_captures
    details = {
        "baselineReadBufferCounts": sorted(left_readback_counts),
        "comparisonReadBufferCounts": sorted(right_readback_counts),
        "baselineReadbackCaptureRequired": any(
            count > 0 for count in left_readback_counts
        ),
        "comparisonReadbackCaptureRequired": any(
            count > 0 for count in right_readback_counts
        ),
        "baselineReadbackCaptures": left_captures,
        "comparisonReadbackCaptures": right_captures,
    }
    if not required_captures_present:
        failure_reason = (
            "baseline/comparison readback capture evidence missing for "
            f"readBufferCount evidence: {left_readback_counts} vs {right_readback_counts}"
        )
    else:
        failure_reason = (
            "baseline/comparison readback capture mismatch: "
            f"{left_captures} vs {right_captures}"
        )
    return applies, passes, details, failure_reason


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
