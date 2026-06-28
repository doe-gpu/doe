"""Timing-source selection helpers for the compare lane."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from native_compare_modules.reporting import NS_PER_MS, safe_float, safe_int


RENDER_ENCODE_TIMING_DOMAINS = {"render", "p0-render"}
HOST_KERNEL_PREWARM_TIMING_SUFFIX = "host-kernel-prewarm"

def _is_render_encode_plausible(
    *,
    execution_total_ns: int,
    execution_encode_total_ns: int,
) -> bool:
    _ = execution_total_ns
    return execution_encode_total_ns > 0


def parse_trace_rows(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []

    rows: list[dict[str, Any]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            rows.append(json.loads(raw))
        except json.JSONDecodeError as exc:
            print(f"WARN: invalid trace jsonl row in {path}: {exc}")
            return []
    return rows


def parse_execution_row_total_ns_rows(path: Path) -> list[int]:
    rows = parse_trace_rows(path)
    if len(rows) == 1 and rows[0].get("traceFormat") == "compact-upload-repeat-v1":
        raw_duration_rows_path = rows[0].get("executionDurationRowsPath")
        if isinstance(raw_duration_rows_path, str) and raw_duration_rows_path.strip():
            raw_path = raw_duration_rows_path.strip()
            duration_rows_path = Path(raw_path)
            if not duration_rows_path.is_absolute() and not duration_rows_path.exists():
                duration_rows_path = path.parent / raw_path
            try:
                payload = json.loads(duration_rows_path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError) as exc:
                print(f"WARN: invalid compact upload duration rows in {duration_rows_path}: {exc}")
                return []
            if not isinstance(payload, list):
                return []
            durations: list[int] = []
            for entry in payload:
                if isinstance(entry, int) and entry >= 0:
                    durations.append(entry)
            return durations
    durations: list[int] = []
    for row in rows:
        duration_ns = safe_int(row.get("executionDurationNs"), default=-1)
        setup_ns = safe_int(row.get("executionSetupNs"), default=-1)
        encode_ns = safe_int(row.get("executionEncodeNs"), default=-1)
        submit_wait_ns = safe_int(row.get("executionSubmitWaitNs"), default=-1)

        component_total_ns = 0
        has_component_timing = False
        for component_ns in (setup_ns, encode_ns, submit_wait_ns):
            if component_ns >= 0:
                component_total_ns += component_ns
                has_component_timing = True

        if has_component_timing and component_total_ns > 0:
            if duration_ns > 0:
                durations.append(max(duration_ns, component_total_ns))
            else:
                durations.append(component_total_ns)
            continue

        if duration_ns >= 0:
            durations.append(duration_ns)
    return durations


def trace_has_kernel_dispatch(path: Path) -> bool:
    return any(row.get("command") == "kernel_dispatch" for row in parse_trace_rows(path))


def maybe_adjust_timing_for_ignored_first_ops(
    *,
    measured_ms: float,
    measured_source: str,
    trace_jsonl: Path,
    ignore_first_ops: int,
) -> tuple[float, str, dict[str, Any]]:
    if ignore_first_ops <= 0:
        return measured_ms, measured_source, {
            "uploadIgnoreFirstOps": 0,
            "uploadIgnoreFirstApplied": False,
        }

    durations_ns = parse_execution_row_total_ns_rows(trace_jsonl)
    if not durations_ns:
        return measured_ms, measured_source, {
            "uploadIgnoreFirstOps": ignore_first_ops,
            "uploadIgnoreFirstApplied": False,
            "uploadIgnoreFirstReason": "trace has no execution workload-total timing rows",
        }

    if len(durations_ns) <= ignore_first_ops:
        return measured_ms, measured_source, {
            "uploadIgnoreFirstOps": ignore_first_ops,
            "uploadIgnoreFirstApplied": False,
            "uploadIgnoreFirstReason": (
                "trace row count is not greater than ignore count "
                f"({len(durations_ns)} <= {ignore_first_ops})"
            ),
        }

    # Upload ignore-first must stay in a single operation scope. Derive both the
    # pre/post values from per-row operation totals to avoid mixed-scope
    # adjustments when primary timing selection used a different source.
    base_row_total_ns = sum(durations_ns)
    base_row_count = len(durations_ns)
    base_row_avg_ms = (float(base_row_total_ns) / float(base_row_count)) / NS_PER_MS
    adjusted_ns = sum(durations_ns[ignore_first_ops:])
    adjusted_count = len(durations_ns) - ignore_first_ops
    adjusted_ms = (float(adjusted_ns) / float(adjusted_count)) / NS_PER_MS
    adjusted_source = "doe-execution-workload-total-ns+ignore-first-ops"
    return adjusted_ms, adjusted_source, {
        "uploadIgnoreFirstOps": ignore_first_ops,
        "uploadIgnoreFirstApplied": True,
        "uploadIgnoreFirstBaseTimingSource": "doe-execution-workload-total-ns",
        "uploadIgnoreFirstAdjustedTimingSource": "doe-execution-workload-total-ns",
        "uploadRowsTotal": base_row_count,
        "uploadRowsIncluded": adjusted_count,
        "uploadTimingRawMsBeforeIgnore": base_row_avg_ms,
        "uploadTimingMeasuredMsBeforeIgnore": measured_ms,
        "uploadTimingMeasuredSourceBeforeIgnore": measured_source,
        "uploadTimingRawMsAfterIgnore": adjusted_ms,
        "uploadTimingTotalNsBeforeIgnore": base_row_total_ns,
        "uploadTimingTotalNsAfterIgnore": adjusted_ns,
    }


def canonical_timing_source(source: str) -> str:
    if not source:
        return ""
    return source.split("+", 1)[0]


def host_kernel_prewarm_ns(trace_meta: dict[str, Any]) -> int:
    return max(0, safe_int(trace_meta.get("hostKernelPrewarmTotalNs"), default=0))


def timing_source_includes_host_kernel_prewarm(source: str) -> bool:
    return HOST_KERNEL_PREWARM_TIMING_SUFFIX in {
        part.strip() for part in str(source or "").split("+")[1:]
    }


def operation_total_with_host_kernel_prewarm_ns(
    trace_meta: dict[str, Any],
    *,
    include_host_kernel_prewarm: bool,
) -> int:
    execution_total_ns = safe_int(trace_meta.get("executionTotalNs"), default=-1)
    if execution_total_ns <= 0:
        return execution_total_ns
    if not include_host_kernel_prewarm:
        return execution_total_ns
    return execution_total_ns + host_kernel_prewarm_ns(trace_meta)


def effective_setup_total_ns_for_sample(sample: dict[str, Any]) -> int:
    trace_meta = sample.get("traceMeta", {})
    if not isinstance(trace_meta, dict):
        return 0
    setup_ns = max(0, safe_int(trace_meta.get("executionSetupTotalNs"), default=0))
    source = str(sample.get("timingSource", "")).strip()
    timing = sample.get("timing", {})
    if isinstance(timing, dict):
        source = str(timing.get("traceMetaSource", source)).strip() or source
    if (
        canonical_timing_source(source) == "doe-execution-total-ns"
        and timing_source_includes_host_kernel_prewarm(source)
    ):
        setup_ns += host_kernel_prewarm_ns(trace_meta)
    return setup_ns


def effective_execution_total_ns_for_sample(sample: dict[str, Any]) -> int:
    trace_meta = sample.get("traceMeta", {})
    if not isinstance(trace_meta, dict):
        return 0
    total_ns = max(0, safe_int(trace_meta.get("executionTotalNs"), default=0))
    source = str(sample.get("timingSource", "")).strip()
    timing = sample.get("timing", {})
    if isinstance(timing, dict):
        source = str(timing.get("traceMetaSource", source)).strip() or source
    if (
        total_ns > 0
        and canonical_timing_source(source) == "doe-execution-total-ns"
        and timing_source_includes_host_kernel_prewarm(source)
    ):
        total_ns += host_kernel_prewarm_ns(trace_meta)
    return total_ns


def classify_timing_source(source: str) -> str:
    canonical = canonical_timing_source(source)
    if canonical in (
        "doe-execution-total-ns",
        "doe-execution-workload-total-ns",
        "doe-execution-row-average-ns",
        "doe-execution-dispatch-window-ns",
        "doe-execution-encode-ns",
        "doe-execution-gpu-timestamp-ns",
        "dawn-perf-wall-time",
        "dawn-perf-cpu-time",
        "dawn-perf-gpu-time",
        "dawn-perf-wall-ns",
        "doe-trace-window",
        "browser-ort-timed-mean-ms",
        "tjs-ort-generation-ms",
    ):
        return "operation"
    if canonical in ("wall-time", "tjs-ort-process-wall-ms"):
        return "process-wall"
    return "unknown"


def pick_measured_timing_ms(
    wall_ms: float,
    trace_meta: dict[str, Any],
    trace_jsonl: Path,
    required_timing_class: str,
    benchmark_policy: Any,
    workload_domain: str = "",
    command_repeat: int = 1,
) -> tuple[float, str, dict[str, Any]]:
    if required_timing_class == "process-wall":
        timing_meta = {
            "source": "wall-time",
            "wallTimeMs": wall_ms,
            "timingSelectionPolicy": "forced-process-wall",
        }
        return wall_ms, "wall-time", timing_meta

    normalized_domain = workload_domain.strip().lower()
    execution_total_ns = safe_int(trace_meta.get("executionTotalNs"), default=-1)
    execution_encode_total_ns = safe_int(trace_meta.get("executionEncodeTotalNs"), default=-1)
    execution_submit_wait_total_ns = safe_int(
        trace_meta.get("executionSubmitWaitTotalNs"), default=-1
    )
    execution_dispatch_count = safe_int(trace_meta.get("executionDispatchCount"), default=0)
    execution_row_count = safe_int(trace_meta.get("executionRowCount"), default=0)
    execution_success_count = safe_int(trace_meta.get("executionSuccessCount"), default=0)
    has_kernel_dispatch = trace_has_kernel_dispatch(trace_jsonl)

    has_execution_evidence = (
        execution_dispatch_count > 0
        or execution_row_count > 0
        or execution_success_count > 0
    )

    prefer_upload_row_total = normalized_domain == "upload" and has_execution_evidence
    prefer_render_encode = (
        normalized_domain in RENDER_ENCODE_TIMING_DOMAINS and has_execution_evidence
    )
    render_encode_plausible = _is_render_encode_plausible(
        execution_total_ns=execution_total_ns,
        execution_encode_total_ns=execution_encode_total_ns,
    )
    effective_repeat = command_repeat if command_repeat > 0 else 1

    def maybe_normalize_by_repeat(
        measured_ms: float,
        timing_meta: dict[str, Any],
        *,
        canonical_source: str,
    ) -> float:
        if effective_repeat <= 1:
            timing_meta["commandRepeat"] = effective_repeat
            timing_meta["repeatNormalized"] = False
            return measured_ms
        if canonical_source in {
            "doe-execution-total-ns",
            "doe-execution-encode-ns",
            "doe-execution-dispatch-window-ns",
            "doe-execution-gpu-timestamp-ns",
        }:
            timing_meta["commandRepeat"] = effective_repeat
            timing_meta["repeatNormalized"] = True
            return measured_ms / float(effective_repeat)
        timing_meta["commandRepeat"] = effective_repeat
        timing_meta["repeatNormalized"] = False
        return measured_ms

    meta_timing_ms = safe_float(trace_meta.get("timingMs"))
    meta_source = trace_meta.get("timingSource")
    if meta_timing_ms is not None and meta_timing_ms >= 0.0:
        source = meta_source if isinstance(meta_source, str) and meta_source else "trace-meta"
        canonical_source = canonical_timing_source(source)
        if source == "wall-time":
            timing_meta = {
                "source": "wall-time",
                "traceMetaSource": "wall-time",
                "traceMetaTimingMs": meta_timing_ms,
                "wallTimeMs": wall_ms,
                "timingSelectionPolicy": "outer-process-wall-time",
            }
            return wall_ms, "wall-time", timing_meta
        if prefer_upload_row_total and canonical_source != "doe-execution-workload-total-ns":
            pass
        elif (
            prefer_render_encode
            and (
                canonical_source != "doe-execution-encode-ns"
                or not render_encode_plausible
            )
        ):
            pass
        else:
            if canonical_source == "doe-execution-total-ns":
                source_host_prewarm_ns = (
                    host_kernel_prewarm_ns(trace_meta) if has_kernel_dispatch else 0
                )
                if source_host_prewarm_ns > 0:
                    timing_meta = {
                        "source": "trace-meta",
                        "traceMetaSource": source,
                        "traceMetaTimingMs": meta_timing_ms,
                        "executionTotalNs": execution_total_ns,
                        "hostKernelPrewarmTotalNs": source_host_prewarm_ns,
                        "hostKernelPrewarmScope": "outside-selected-execution-timing",
                        "wallTimeMs": wall_ms,
                    }
                    measured_ms = maybe_normalize_by_repeat(
                        meta_timing_ms,
                        timing_meta,
                        canonical_source=canonical_source,
                    )
                    return measured_ms, source, timing_meta
            timing_meta = {
                "source": "trace-meta",
                "traceMetaSource": source,
                "traceMetaTimingMs": meta_timing_ms,
                "wallTimeMs": wall_ms,
            }
            measured_ms = maybe_normalize_by_repeat(
                meta_timing_ms,
                timing_meta,
                canonical_source=canonical_source,
            )
            if prefer_upload_row_total and canonical_source == "doe-execution-workload-total-ns":
                timing_meta["timingSelectionPolicy"] = "upload-workload-total-preferred"
            if prefer_render_encode and canonical_source == "doe-execution-encode-ns":
                timing_meta["timingSelectionPolicy"] = "render-encode-preferred"
            return measured_ms, source, timing_meta

    if prefer_upload_row_total:
        row_durations_ns = parse_execution_row_total_ns_rows(trace_jsonl)
        if row_durations_ns:
            row_total_ns = sum(row_durations_ns)
            row_count = len(row_durations_ns)
            if row_total_ns > 0 and row_count > 0:
                row_average_ns = float(row_total_ns) / float(row_count)
                measured_ms = row_average_ns / NS_PER_MS
                timing_meta = {
                    "source": "trace-meta",
                    "traceMetaSource": "doe-execution-workload-total-ns",
                    "traceMetaTimingMs": measured_ms,
                    "executionRowTotalNs": row_total_ns,
                    "executionRowDurationCount": row_count,
                    "executionRowOperationTotalAverageNs": row_average_ns,
                    "executionDispatchCount": execution_dispatch_count,
                    "executionRowCount": execution_row_count,
                    "executionSuccessCount": execution_success_count,
                    "wallTimeMs": wall_ms,
                    "timingSelectionPolicy": "upload-workload-total-preferred",
                    "commandRepeat": effective_repeat,
                    "repeatNormalized": False,
                }
                return measured_ms, "doe-execution-workload-total-ns", timing_meta

    if prefer_render_encode and render_encode_plausible:
        measured_ms = float(execution_encode_total_ns) / NS_PER_MS
        timing_meta = {
            "source": "trace-meta",
            "traceMetaSource": "doe-execution-encode-ns",
            "traceMetaTimingMs": measured_ms,
            "executionEncodeTotalNs": execution_encode_total_ns,
            "executionDispatchCount": execution_dispatch_count,
            "executionRowCount": execution_row_count,
            "executionSuccessCount": execution_success_count,
            "wallTimeMs": wall_ms,
            "timingSelectionPolicy": "render-encode-preferred",
        }
        measured_ms = maybe_normalize_by_repeat(
            measured_ms,
            timing_meta,
            canonical_source="doe-execution-encode-ns",
        )
        return measured_ms, "doe-execution-encode-ns", timing_meta

    if execution_total_ns > 0 and has_execution_evidence:
        source = "doe-execution-total-ns"
        measured_ms = float(execution_total_ns) / NS_PER_MS
        timing_meta = {
            "source": "trace-meta",
            "traceMetaSource": source,
            "traceMetaTimingMs": measured_ms,
            "executionTotalNs": execution_total_ns,
            "hostKernelPrewarmTotalNs": host_kernel_prewarm_ns(trace_meta),
            "hostKernelPrewarmScope": "outside-selected-execution-timing",
            "executionDispatchCount": execution_dispatch_count,
            "executionRowCount": execution_row_count,
            "executionSuccessCount": execution_success_count,
            "wallTimeMs": wall_ms,
        }
        measured_ms = maybe_normalize_by_repeat(
            measured_ms,
            timing_meta,
            canonical_source="doe-execution-total-ns",
        )
        return measured_ms, source, timing_meta

    gpu_timestamp_total_ns = safe_int(
        trace_meta.get("executionGpuTimestampTotalNs"), default=-1
    )
    gpu_timestamp_valid_count = safe_int(
        trace_meta.get("executionGpuTimestampValidCount"), default=0
    )
    if gpu_timestamp_total_ns > 0 and gpu_timestamp_valid_count > 0:
        measured_ms = float(gpu_timestamp_total_ns) / NS_PER_MS
        timing_meta = {
            "source": "trace-meta",
            "traceMetaSource": "doe-execution-gpu-timestamp-ns",
            "traceMetaTimingMs": measured_ms,
            "executionGpuTimestampTotalNs": gpu_timestamp_total_ns,
            "executionGpuTimestampValidCount": gpu_timestamp_valid_count,
            "executionDispatchCount": execution_dispatch_count,
            "executionRowCount": execution_row_count,
            "executionSuccessCount": execution_success_count,
            "wallTimeMs": wall_ms,
            "timingSelectionPolicy": "gpu-timestamp-fallback",
        }
        measured_ms = maybe_normalize_by_repeat(
            measured_ms,
            timing_meta,
            canonical_source="doe-execution-gpu-timestamp-ns",
        )
        return measured_ms, "doe-execution-gpu-timestamp-ns", timing_meta

    dispatch_window_ns = -1
    if execution_encode_total_ns >= 0 and execution_submit_wait_total_ns >= 0:
        dispatch_window_ns = execution_encode_total_ns + execution_submit_wait_total_ns
        if dispatch_window_ns > 0 and has_execution_evidence:
            measured_ms = float(dispatch_window_ns) / NS_PER_MS
            timing_meta = {
                "source": "trace-meta",
                "traceMetaSource": "doe-execution-dispatch-window-ns",
                "traceMetaTimingMs": measured_ms,
                "executionEncodeTotalNs": execution_encode_total_ns,
                "executionSubmitWaitTotalNs": execution_submit_wait_total_ns,
                "executionDispatchCount": execution_dispatch_count,
                "executionRowCount": execution_row_count,
                "executionSuccessCount": execution_success_count,
                "wallTimeMs": wall_ms,
            }
            measured_ms = maybe_normalize_by_repeat(
                measured_ms,
                timing_meta,
                canonical_source="doe-execution-dispatch-window-ns",
            )
            return measured_ms, "doe-execution-dispatch-window-ns", timing_meta

    trace_rows = parse_trace_rows(trace_jsonl)
    timing_meta: dict[str, Any] = {
        "source": "wall-time",
        "wallTimeMs": wall_ms,
        "traceRows": len(trace_rows),
    }
    if not trace_rows:
        return wall_ms, "wall-time", timing_meta

    timestamps: list[int] = []
    for row in trace_rows:
        ts = row.get("timestampMonoNs")
        if isinstance(ts, int):
            timestamps.append(ts)
    if len(timestamps) < 2:
        timing_meta["traceRows"] = len(timestamps)
        return wall_ms, "wall-time", timing_meta

    first = min(timestamps)
    last = max(timestamps)
    measured_ms = float(last - first) / NS_PER_MS
    if measured_ms < 0:
        timing_meta["traceRows"] = len(timestamps)
        return wall_ms, "wall-time", timing_meta

    timing_meta.update(
        {
            "source": "doe-trace-window",
            "traceWindowStartMonoNs": first,
            "traceWindowEndMonoNs": last,
            "traceRows": len(timestamps),
            "rowCount": safe_int(trace_meta.get("rowCount"), default=0),
        }
    )
    return measured_ms, "doe-trace-window", timing_meta
