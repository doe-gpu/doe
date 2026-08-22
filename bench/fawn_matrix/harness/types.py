"""Data schemas and types for the 4-Lane Fawn-Doe Benchmark Matrix."""

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, List, Optional


class Lane(str, Enum):
    LANE_A = "lane_a_chromium_playwright_dawn"
    LANE_B = "lane_b_fawn_playwright_dawn"
    LANE_C = "lane_c_fawn_playwright_doe"
    LANE_D = "lane_d_fawn_direct_doe"

    @property
    def label(self) -> str:
        labels = {
            Lane.LANE_A: "Chromium + Playwright + Dawn",
            Lane.LANE_B: "Fawn + Playwright + Dawn",
            Lane.LANE_C: "Fawn + Playwright + Doe",
            Lane.LANE_D: "Fawn Direct Protocol + Doe",
        }
        return labels.get(self, self.value)


@dataclass
class TimingBreakdown:
    setup_ms: float = 0.0
    snapshot_diff_ms: float = 0.0
    compute_ms: float = 0.0
    action_ms: float = 0.0
    total_wall_ms: float = 0.0


@dataclass
class WorkloadMetric:
    latency_ms_p50: float
    latency_ms_p95: float
    latency_ms_p99: float
    memory_peak_mb: float
    context_tokens: int
    success_rate: float
    breakdown_p50: TimingBreakdown = field(default_factory=TimingBreakdown)


@dataclass
class LaneExecutionResult:
    lane: Lane
    workload_id: str
    metrics: WorkloadMetric
    sample_latencies_ms: List[float] = field(default_factory=list)
    metadata: Dict[str, Any] = field(default_factory=dict)
    timestamp_utc: str = ""


@dataclass
class DecisionRuleVerdict:
    rule_id: str
    rule_name: str
    satisfied: bool
    statement: str
    recommended_action: str
    evidence_deltas: Dict[str, float] = field(default_factory=dict)


@dataclass
class MatrixComparisonReport:
    workload_id: str
    results_by_lane: Dict[str, LaneExecutionResult]
    speedup_b_over_a: float
    speedup_c_over_b: float
    speedup_d_over_c: float
    speedup_d_over_a: float
    token_reduction_ratio_d_vs_a: float
    memory_delta_mb_d_vs_a: float
    verdicts: List[DecisionRuleVerdict]
    overall_thesis_status: str
