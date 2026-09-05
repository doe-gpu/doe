"""Reporting/statistics helpers for the compare lane."""

from __future__ import annotations

import math
import statistics
from typing import Any


NS_PER_MS: float = 1_000_000.0


def safe_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    if parsed != parsed:  # NaN
        return None
    return parsed


def safe_int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    return default


def parse_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        text = value.strip()
        if text.isdigit():
            try:
                return int(text)
            except ValueError:
                return None
    return None


def valid_sync_mode(value: Any) -> bool:
    return isinstance(value, str) and value in {"per-command", "deferred"}


def format_stats(values: list[float], *, percentile_method: str = "lower-index") -> dict[str, float]:
    if percentile_method not in ("lower-index", "nearest-rank"):
        raise ValueError(f"Unknown percentile method: {percentile_method}")
    if not values:
        return {
            "count": 0,
            "minMs": 0.0,
            "maxMs": 0.0,
            "p10Ms": 0.0,
            "p50Ms": 0.0,
            "p95Ms": 0.0,
            "p99Ms": 0.0,
            "meanMs": 0.0,
            "stdevMs": 0.0,
        }

    sorted_values = sorted(values)

    def percentile(p: float) -> float:
        if not sorted_values:
            return 0.0
        index = (max(0, math.ceil(len(sorted_values) * p) - 1) if percentile_method == "nearest-rank"
                 else int((len(sorted_values) - 1) * p))
        return sorted_values[index]

    return {
        "count": len(values),
        "minMs": min(values),
        "maxMs": max(values),
        "p10Ms": percentile(0.10),
        "p50Ms": percentile(0.5),
        "p95Ms": percentile(0.95),
        "p99Ms": percentile(0.99),
        "meanMs": statistics.fmean(values),
        "stdevMs": statistics.pstdev(values) if len(values) > 1 else 0.0,
    }


def format_distribution(values: list[float]) -> dict[str, float]:
    if not values:
        return {
            "count": 0,
            "min": 0.0,
            "max": 0.0,
            "p10": 0.0,
            "p50": 0.0,
            "p95": 0.0,
            "p99": 0.0,
            "mean": 0.0,
            "stdev": 0.0,
        }

    sorted_values = sorted(values)

    def percentile(p: float) -> float:
        if not sorted_values:
            return 0.0
        index = int((len(sorted_values) - 1) * p)
        return sorted_values[index]

    return {
        "count": len(values),
        "min": min(values),
        "max": max(values),
        "p10": percentile(0.10),
        "p50": percentile(0.5),
        "p95": percentile(0.95),
        "p99": percentile(0.99),
        "mean": statistics.fmean(values),
        "stdev": statistics.pstdev(values) if len(values) > 1 else 0.0,
    }


def median_sample(values: list[float]) -> float:
    if not values:
        return 0.0
    sorted_values = sorted(values)
    return sorted_values[len(sorted_values) // 2]


def subtract_baseline_ms(values: list[float], baseline_ms: float) -> list[float]:
    baseline = max(baseline_ms, 0.0)
    return [max(value - baseline, 0.0) for value in values]


def summarize_timing_metric_stats(
    run_records: list[dict[str, Any]],
    field: str,
) -> dict[str, dict[str, float]]:
    metric_values: dict[str, list[float]] = {
        "wall_time": [],
        "cpu_time": [],
        "gpu_time": [],
    }
    for sample in run_records:
        metrics = sample.get(field)
        if not isinstance(metrics, dict):
            continue
        for metric in metric_values:
            value = safe_float(metrics.get(metric))
            if value is None:
                continue
            metric_values[metric].append(value)
    return {metric: format_stats(values) for metric, values in metric_values.items()}


def summarize_resource_stats(samples: list[dict[str, Any]]) -> dict[str, Any]:
    process_peak_rss_kb_values: list[float] = []
    gpu_vram_delta_peak_bytes_values: list[float] = []
    gpu_vram_peak_bytes_values: list[float] = []
    gpu_vram_before_bytes_values: list[float] = []
    gpu_vram_after_bytes_values: list[float] = []
    probe_modes: set[str] = set()
    gpu_probe_available_count = 0
    sampling_truncated_count = 0

    for sample in samples:
        resource = sample.get("resource")
        if not isinstance(resource, dict):
            continue
        probe_mode = resource.get("gpuMemoryProbe")
        if isinstance(probe_mode, str) and probe_mode:
            probe_modes.add(probe_mode)

        rss_kb = parse_int(resource.get("processPeakRssKb"))
        if rss_kb is not None:
            process_peak_rss_kb_values.append(float(rss_kb))

        gpu_available = resource.get("gpuMemoryProbeAvailable")
        if gpu_available is True:
            gpu_probe_available_count += 1
        if resource.get("resourceSamplingTruncated") is True:
            sampling_truncated_count += 1

        peak_delta = parse_int(resource.get("gpuVramDeltaPeakFromBeforeBytes"))
        if peak_delta is not None:
            gpu_vram_delta_peak_bytes_values.append(float(peak_delta))

        peak_used = parse_int(resource.get("gpuVramUsedPeakBytes"))
        if peak_used is not None:
            gpu_vram_peak_bytes_values.append(float(peak_used))

        before_used = parse_int(resource.get("gpuVramUsedBeforeBytes"))
        if before_used is not None:
            gpu_vram_before_bytes_values.append(float(before_used))

        after_used = parse_int(resource.get("gpuVramUsedAfterBytes"))
        if after_used is not None:
            gpu_vram_after_bytes_values.append(float(after_used))

    return {
        "gpuProbeModes": sorted(probe_modes),
        "gpuProbeAvailableCount": gpu_probe_available_count,
        "samplingTruncatedCount": sampling_truncated_count,
        "processPeakRssKb": format_distribution(process_peak_rss_kb_values),
        "gpuVramDeltaPeakFromBeforeBytes": format_distribution(gpu_vram_delta_peak_bytes_values),
        "gpuVramUsedPeakBytes": format_distribution(gpu_vram_peak_bytes_values),
        "gpuVramUsedBeforeBytes": format_distribution(gpu_vram_before_bytes_values),
        "gpuVramUsedAfterBytes": format_distribution(gpu_vram_after_bytes_values),
    }
