"""Typed results for the physical Fawn-Doe context matrix."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class Lane(str, Enum):
    LANE_A = "lane_a_chromium_playwright_dawn"
    LANE_B = "lane_b_fawn_playwright_dawn"
    LANE_C = "lane_c_fawn_playwright_doe"
    LANE_D = "lane_d_fawn_direct_doe"

    @property
    def label(self) -> str:
        return {
            Lane.LANE_A: "Chromium + Playwright + Dawn",
            Lane.LANE_B: "Fawn + Playwright + Dawn",
            Lane.LANE_C: "Fawn + Playwright + Doe",
            Lane.LANE_D: "Fawn Direct Protocol + Doe",
        }[self]


@dataclass(frozen=True)
class TimingBreakdown:
    setup_ms: float
    snapshot_diff_ms: float
    action_ms: float
    total_wall_ms: float


@dataclass(frozen=True)
class WorkloadMetric:
    latency_ms_p50: float
    latency_ms_p95: float
    latency_ms_p99: float
    memory_peak_mb: float
    context_tokens: int
    serialized_bytes: int
    renderer_cpu_ms_p50: float
    success_rate: float
    breakdown_p50: TimingBreakdown


@dataclass(frozen=True)
class LaneExecutionResult:
    lane: Lane
    workload_id: str
    metrics: WorkloadMetric
    sample_latencies_ms: list[float] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)
    timestamp_utc: str = ""


@dataclass(frozen=True)
class DecisionRuleVerdict:
    rule_id: str
    rule_name: str
    satisfied: bool
    statement: str
    recommended_action: str
    evidence_deltas: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class MatrixComparisonReport:
    schema_version: int
    report_kind: str
    workload_id: str
    platform: dict[str, Any]
    raw_artifact: dict[str, str]
    evidence_status: str
    comparability: dict[str, Any]
    results_by_lane: dict[str, LaneExecutionResult]
    speedup_b_over_a: float
    speedup_c_over_b: float
    speedup_d_over_c: float
    speedup_d_over_a: float
    token_reduction_ratio_d_vs_a: float
    serialized_byte_reduction_ratio_d_vs_a: float
    memory_delta_mb_d_vs_a: float
    verdicts: list[DecisionRuleVerdict]
    overall_thesis_status: str
    generated_at_utc: str
