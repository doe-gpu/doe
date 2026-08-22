"""Convert validated physical samples into lane statistics."""

from __future__ import annotations

import math
import statistics
from typing import Any

from bench.fawn_matrix.harness.types import (
    Lane,
    LaneExecutionResult,
    TimingBreakdown,
    WorkloadMetric,
)


def compute_percentile(values: list[float], percentile: float) -> float:
    """Return a linearly interpolated percentile."""
    if not values:
        raise ValueError("percentile requires at least one value")
    sorted_values = sorted(values)
    position = (len(sorted_values) - 1) * percentile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return sorted_values[lower]
    lower_weight = upper - position
    upper_weight = position - lower
    return (
        sorted_values[lower] * lower_weight
        + sorted_values[upper] * upper_weight
    )


def _median(samples: list[dict[str, Any]], path: tuple[str, ...]) -> float:
    values: list[float] = []
    for sample in samples:
        value: Any = sample
        for key in path:
            value = value[key]
        values.append(float(value))
    return statistics.median(values)


def build_lane_results(
    payload: dict[str, Any],
    evidence: dict[str, Any],
) -> dict[str, LaneExecutionResult]:
    """Build statistics only after raw evidence passes validation."""
    if evidence.get("status") != "pass":
        raise ValueError("lane statistics require passing physical evidence")

    results: dict[str, LaneExecutionResult] = {}
    for lane in Lane:
        lane_payload = payload["lanes"][lane.value]
        samples = [
            sample
            for sample in lane_payload["samples"]
            if sample["phase"] == "timed"
        ]
        latencies = [
            float(sample["timing"]["totalWallMs"]) for sample in samples
        ]
        context_tokens = int(
            round(
                statistics.median(
                    sample["contextTokens"] for sample in samples
                )
            )
        )
        serialized_bytes = int(
            round(
                statistics.median(
                    sample["serializedBytes"] for sample in samples
                )
            )
        )
        memory_peak_mb = max(
            float(sample["rendererJsHeapMb"]) for sample in samples
        )
        success_rate = (
            sum(bool(sample["success"]) for sample in samples) / len(samples)
        )
        metrics = WorkloadMetric(
            latency_ms_p50=compute_percentile(latencies, 0.50),
            latency_ms_p95=compute_percentile(latencies, 0.95),
            latency_ms_p99=compute_percentile(latencies, 0.99),
            memory_peak_mb=memory_peak_mb,
            context_tokens=context_tokens,
            serialized_bytes=serialized_bytes,
            renderer_cpu_ms_p50=_median(samples, ("rendererCpuMs",)),
            success_rate=success_rate,
            breakdown_p50=TimingBreakdown(
                setup_ms=_median(samples, ("timing", "setupMs")),
                snapshot_diff_ms=_median(
                    samples, ("timing", "snapshotDiffMs")
                ),
                action_ms=_median(samples, ("timing", "actionMs")),
                total_wall_ms=compute_percentile(latencies, 0.50),
            ),
        )
        results[lane.value] = LaneExecutionResult(
            lane=lane,
            workload_id=payload["workload"]["workloadId"],
            metrics=metrics,
            sample_latencies_ms=latencies,
            metadata={
                "adapterInfo": lane_payload["adapterInfo"],
                "browserIdentity": lane_payload["browserIdentity"],
                "evidenceValid": True,
                "hardwareIdentity": payload["platform"]["hardwareIdentity"],
                "runtimeIdentity": lane_payload["runtimeIdentity"],
                "sampleCount": len(samples),
                "transport": lane_payload["transport"],
            },
            timestamp_utc=payload["run"]["startedAtUtc"],
        )
    return results
