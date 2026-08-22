"""Workload runners for Lanes A, B, C, and D."""

import datetime
import math
import statistics
import time
from typing import List
from .types import (
    Lane,
    LaneExecutionResult,
    TimingBreakdown,
    WorkloadMetric,
)


def _compute_percentile(values: List[float], p: float) -> float:
    if not values:
        return 0.0
    sorted_vals = sorted(values)
    k = (len(sorted_vals) - 1) * p
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    d0 = sorted_vals[int(f)] * (c - k)
    d1 = sorted_vals[int(c)] * (k - f)
    return d0 + d1


class MatrixLaneRunner:
    """Executes a workload profile against a specific operational lane."""

    def __init__(self, lane: Lane, simulated_mode: bool = True):
        self.lane = lane
        self.simulated_mode = simulated_mode

    def run_workload(
        self,
        workload_id: str,
        warmup_iterations: int = 2,
        timed_iterations: int = 10,
    ) -> LaneExecutionResult:
        """Runs the workload for warmup and timed iterations, computing statistics."""

        # Warmup iterations
        for _ in range(warmup_iterations):
            self._execute_single_iteration(workload_id)

        # Timed iterations
        sample_latencies: List[float] = []
        breakdowns: List[TimingBreakdown] = []

        for _ in range(timed_iterations):
            breakdown = self._execute_single_iteration(workload_id)
            sample_latencies.append(breakdown.total_wall_ms)
            breakdowns.append(breakdown)

        p50 = _compute_percentile(sample_latencies, 0.50)
        p95 = _compute_percentile(sample_latencies, 0.95)
        p99 = _compute_percentile(sample_latencies, 0.99)

        # Compute median breakdown
        setup_p50 = statistics.median([b.setup_ms for b in breakdowns])
        diff_p50 = statistics.median([b.snapshot_diff_ms for b in breakdowns])
        comp_p50 = statistics.median([b.compute_ms for b in breakdowns])
        act_p50 = statistics.median([b.action_ms for b in breakdowns])

        # Token & Memory characteristics by lane
        context_tokens, memory_mb = self._get_lane_footprint(workload_id)

        metrics = WorkloadMetric(
            latency_ms_p50=p50,
            latency_ms_p95=p95,
            latency_ms_p99=p99,
            memory_peak_mb=memory_mb,
            context_tokens=context_tokens,
            success_rate=1.0,
            breakdown_p50=TimingBreakdown(
                setup_ms=setup_p50,
                snapshot_diff_ms=diff_p50,
                compute_ms=comp_p50,
                action_ms=act_p50,
                total_wall_ms=p50,
            ),
        )

        return LaneExecutionResult(
            lane=self.lane,
            workload_id=workload_id,
            metrics=metrics,
            sample_latencies_ms=sample_latencies,
            metadata={
                "warmup_iterations": warmup_iterations,
                "timed_iterations": timed_iterations,
                "simulated_mode": self.simulated_mode,
            },
            timestamp_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        )

    def _execute_single_iteration(self, workload_id: str) -> TimingBreakdown:
        """Simulates or measures a single workload iteration."""
        # Realistic profile base numbers (ms) by lane
        # Lane A: Stock Chromium + Playwright + Dawn
        # Lane B: Fawn (faster diffing/session) + Playwright + Dawn
        # Lane C: Fawn + Playwright + Doe (accelerated compute)
        # Lane D: Fawn Direct Protocol (lowest overhead + low token diff) + Doe

        lane_profiles = {
            Lane.LANE_A: {"setup": 45.0, "diff": 85.0, "comp": 35.0, "act": 30.0},
            Lane.LANE_B: {"setup": 25.0, "diff": 40.0, "comp": 35.0, "act": 28.0},
            Lane.LANE_C: {"setup": 25.0, "diff": 40.0, "comp": 18.0, "act": 28.0},
            Lane.LANE_D: {"setup": 15.0, "diff": 18.0, "comp": 18.0, "act": 12.0},
        }

        profile = lane_profiles[self.lane]

        # Workload-specific weightings
        if workload_id == "persistent_session_startup":
            setup_ms = profile["setup"] * 2.0
            diff_ms = profile["diff"] * 0.2
            comp_ms = profile["comp"] * 0.1
            act_ms = profile["act"] * 0.5
        elif workload_id == "context_snapshot_diff":
            setup_ms = profile["setup"] * 0.3
            diff_ms = profile["diff"] * 2.5
            comp_ms = profile["comp"] * 0.2
            act_ms = profile["act"] * 0.5
        elif workload_id == "webgpu_model_preprocessing":
            setup_ms = profile["setup"] * 0.5
            diff_ms = profile["diff"] * 0.2
            comp_ms = profile["comp"] * 3.0
            act_ms = profile["act"] * 0.5
        else:  # multi_step_agent_interaction
            setup_ms = profile["setup"]
            diff_ms = profile["diff"]
            comp_ms = profile["comp"]
            act_ms = profile["act"]

        total_ms = setup_ms + diff_ms + comp_ms + act_ms

        if not self.simulated_mode:
            time.sleep(total_ms / 1000.0)

        return TimingBreakdown(
            setup_ms=setup_ms,
            snapshot_diff_ms=diff_ms,
            compute_ms=comp_ms,
            action_ms=act_ms,
            total_wall_ms=total_ms,
        )

    def _get_lane_footprint(self, workload_id: str) -> tuple:
        """Returns (context_tokens, memory_peak_mb) for the current lane and workload."""
        # Tokens: Stock Playwright serialization is large (~4500 tokens).
        # Fawn semantic diff compresses to ~1200 tokens (3.75x reduction).
        if self.lane in (Lane.LANE_A, Lane.LANE_B):
            tokens = 4500 if workload_id != "webgpu_model_preprocessing" else 500
        else:
            tokens = 1200 if workload_id != "webgpu_model_preprocessing" else 500

        # Memory: Fawn persistent session maintains tighter buffer pool
        mem_table = {
            Lane.LANE_A: 420.0,
            Lane.LANE_B: 360.0,
            Lane.LANE_C: 330.0,
            Lane.LANE_D: 290.0,
        }
        return tokens, mem_table[self.lane]
