"""Evidence-scoped decisions for the Fawn-Doe context matrix."""

from __future__ import annotations

import datetime
from typing import Any

from bench.fawn_matrix.harness.types import (
    DecisionRuleVerdict,
    Lane,
    LaneExecutionResult,
    MatrixComparisonReport,
)


def _ratio(numerator: float, denominator: float) -> float:
    if denominator <= 0:
        raise ValueError("matrix ratios require positive measurements")
    return numerator / denominator


def evaluate_decision_rules(
    workload_id: str,
    results: dict[str, LaneExecutionResult],
    thresholds: dict[str, float],
    platform: dict[str, Any],
    evidence: dict[str, Any],
    raw_artifact: dict[str, str],
) -> MatrixComparisonReport:
    """Evaluate only claims that the context workload can support."""
    if evidence.get("status") != "pass":
        raise ValueError("decision evaluation requires passing evidence")
    if set(results) != {lane.value for lane in Lane}:
        raise ValueError("matrix evaluation requires all four lanes")

    a = results[Lane.LANE_A.value].metrics
    b = results[Lane.LANE_B.value].metrics
    c = results[Lane.LANE_C.value].metrics
    d = results[Lane.LANE_D.value].metrics
    speedup_b_over_a = _ratio(a.latency_ms_p50, b.latency_ms_p50)
    speedup_c_over_b = _ratio(b.latency_ms_p50, c.latency_ms_p50)
    speedup_d_over_c = _ratio(c.latency_ms_p50, d.latency_ms_p50)
    speedup_d_over_a = _ratio(a.latency_ms_p50, d.latency_ms_p50)
    token_reduction = _ratio(
        float(a.context_tokens), float(d.context_tokens)
    )
    byte_reduction = _ratio(
        float(a.serialized_bytes), float(d.serialized_bytes)
    )
    memory_delta = d.memory_peak_mb - a.memory_peak_mb

    material_speedup = thresholds["materialSpeedupRatio"]
    material_context = thresholds["materialContextReductionRatio"]
    max_memory_regression = thresholds["maxMemoryRegressionMb"]
    shell_value = speedup_b_over_a >= material_speedup
    direct_context_value = (
        speedup_d_over_a >= material_speedup
        and token_reduction >= material_context
        and byte_reduction >= material_context
        and memory_delta <= max_memory_regression
        and d.success_rate >= a.success_rate
    )
    context_tradeoff = (
        token_reduction >= material_context
        and byte_reduction >= material_context
        and speedup_d_over_a < material_speedup
    )
    no_context_advantage = (
        not shell_value
        and not direct_context_value
        and not context_tradeoff
    )

    verdicts = [
        DecisionRuleVerdict(
            rule_id="RULE_1_FAWN_SHELL_CONTEXT_VALUE",
            rule_name="Fawn shell context value",
            satisfied=shell_value,
            statement=(
                "Fawn materially improves full accessibility-context "
                "capture over stock Chromium."
            ),
            recommended_action=(
                "Retain Fawn for agent context capture on this physical tuple."
                if shell_value
                else "Do not attribute a material context-capture win to "
                "the Fawn shell on this physical tuple."
            ),
            evidence_deltas={"speedupBOverA": speedup_b_over_a},
        ),
        DecisionRuleVerdict(
            rule_id="RULE_2_DIRECT_CONTEXT_PATH_VALUE",
            rule_name="Direct incremental context value",
            satisfied=direct_context_value,
            statement=(
                "The direct incremental protocol reduces context bytes and "
                "tokens without losing task equivalence."
            ),
            recommended_action=(
                "Promote the direct context path only after the second "
                "physical platform agrees."
                if direct_context_value
                else "Do not promote the direct context path from this "
                "physical tuple."
            ),
            evidence_deltas={
                "byteReduction": byte_reduction,
                "speedupDOverA": speedup_d_over_a,
                "tokenReduction": token_reduction,
            },
        ),
        DecisionRuleVerdict(
            rule_id="RULE_3_CONTEXT_SAVINGS_LATENCY_TRADEOFF",
            rule_name="Context savings latency tradeoff",
            satisfied=context_tradeoff,
            statement=(
                "The direct protocol compresses context but does not "
                "materially improve latency."
            ),
            recommended_action=(
                "Use the direct path only for context-budget-bound agents."
                if context_tradeoff
                else "Do not cite a context-for-latency tradeoff on this "
                "physical tuple."
            ),
            evidence_deltas={
                "byteReduction": byte_reduction,
                "speedupDOverA": speedup_d_over_a,
                "tokenReduction": token_reduction,
            },
        ),
        DecisionRuleVerdict(
            rule_id="RULE_4_NO_CONTEXT_ADVANTAGE",
            rule_name="No context-stack advantage",
            satisfied=no_context_advantage,
            statement=(
                "Neither Fawn nor the direct context path earns product "
                "status on this tuple."
            ),
            recommended_action=(
                "Keep stock Chromium for this workload."
                if no_context_advantage
                else "Do not default to stock Chromium based on this rule."
            ),
            evidence_deltas={
                "speedupBOverA": speedup_b_over_a,
                "speedupDOverA": speedup_d_over_a,
            },
        ),
        DecisionRuleVerdict(
            rule_id="RULE_5_DOERUNTIME_PERFORMANCE_NOT_EVALUATED",
            rule_name="DoeRuntime performance scope",
            satisfied=False,
            statement=(
                "This workload probes Doe identity but performs no timed GPU "
                "work, so it cannot award DoeRuntime performance credit."
            ),
            recommended_action=(
                "Use webgpu_model_preprocessing to evaluate DoeRuntime "
                "beneath Fawn."
            ),
            evidence_deltas={"timedWebgpuWork": False},
        ),
    ]

    if direct_context_value:
        status = "FAWN_DIRECT_CONTEXT_PATH_EVIDENCED"
    elif shell_value:
        status = "FAWN_SHELL_CONTEXT_VALUE_ONLY"
    elif context_tradeoff:
        status = "DIRECT_CONTEXT_BUDGET_NICHE"
    elif no_context_advantage:
        status = "NO_CONTEXT_STACK_ADVANTAGE"
    else:
        status = "INCONCLUSIVE"

    return MatrixComparisonReport(
        schema_version=1,
        report_kind=(
            "fawn-doe-context-snapshot-diff-platform-report"
        ),
        workload_id=workload_id,
        platform=platform,
        raw_artifact=raw_artifact,
        evidence_status="physical_diagnostic",
        comparability={
            **evidence,
            "claimScope": "context_capture_only",
            "doeRuntimePerformanceCredit": False,
        },
        results_by_lane=results,
        speedup_b_over_a=speedup_b_over_a,
        speedup_c_over_b=speedup_c_over_b,
        speedup_d_over_c=speedup_d_over_c,
        speedup_d_over_a=speedup_d_over_a,
        token_reduction_ratio_d_vs_a=token_reduction,
        serialized_byte_reduction_ratio_d_vs_a=byte_reduction,
        memory_delta_mb_d_vs_a=memory_delta,
        verdicts=verdicts,
        overall_thesis_status=status,
        generated_at_utc=datetime.datetime.now(
            datetime.timezone.utc
        ).isoformat(),
    )
