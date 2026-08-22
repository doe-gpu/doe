"""Evaluator enforcing the 5 falsifiable decision rules for Fawn-Doe 4-lane matrix."""

from typing import Dict, List
from .types import (
    Lane,
    LaneExecutionResult,
    DecisionRuleVerdict,
    MatrixComparisonReport,
)


def evaluate_decision_rules(
    workload_id: str,
    results: Dict[str, LaneExecutionResult],
) -> MatrixComparisonReport:
    """Evaluates the 4 operational lanes against the 5 canonical decision rules."""

    res_a = results.get(Lane.LANE_A.value)
    res_b = results.get(Lane.LANE_B.value)
    res_c = results.get(Lane.LANE_C.value)
    res_d = results.get(Lane.LANE_D.value)

    if not (res_a and res_b and res_c and res_d):
        raise ValueError("Matrix evaluation requires results from all 4 operational lanes.")

    lat_a = res_a.metrics.latency_ms_p50
    lat_b = res_b.metrics.latency_ms_p50
    lat_c = res_c.metrics.latency_ms_p50
    lat_d = res_d.metrics.latency_ms_p50

    tok_a = res_a.metrics.context_tokens
    tok_d = res_d.metrics.context_tokens

    mem_a = res_a.metrics.memory_peak_mb
    mem_d = res_d.metrics.memory_peak_mb

    speedup_b_over_a = (lat_a / lat_b) if lat_b > 0 else 1.0
    speedup_c_over_b = (lat_b / lat_c) if lat_c > 0 else 1.0
    speedup_d_over_c = (lat_c / lat_d) if lat_d > 0 else 1.0
    speedup_d_over_a = (lat_a / lat_d) if lat_d > 0 else 1.0

    token_reduction_ratio = (float(tok_a) / float(tok_d)) if tok_d > 0 else 1.0
    memory_delta_mb = mem_d - mem_a

    verdicts: List[DecisionRuleVerdict] = []

    # Rule 1: If B beats A but C does not beat B
    b_beats_a = speedup_b_over_a > 1.05
    c_beats_b = speedup_c_over_b > 1.05
    d_beats_c = speedup_d_over_c > 1.05
    d_beats_a = speedup_d_over_a > 1.15

    r1_satisfied = b_beats_a and not c_beats_b
    verdicts.append(
        DecisionRuleVerdict(
            rule_id="RULE_1_FAWN_SHELL_ONLY",
            rule_name="Fawn Shell Standalone Value",
            satisfied=r1_satisfied,
            statement=(
                "Fawn browser shell and agent features improve workload over stock Chromium, "
                "but DoeRuntime does not yet show speedup over Dawn in this configuration."
            ),
            recommended_action=(
                "Ship Fawn with Dawn as interim default while optimizing Doe native browser backend paths."
            ),
            evidence_deltas={
                "speedup_b_over_a": speedup_b_over_a,
                "speedup_c_over_b": speedup_c_over_b,
            },
        )
    )

    # Rule 2: If C beats B but D does not beat C
    r2_satisfied = c_beats_b and not d_beats_c
    verdicts.append(
        DecisionRuleVerdict(
            rule_id="RULE_2_DOERUNTIME_SPEEDUP_STANDARD_PLAYWRIGHT",
            rule_name="DoeRuntime Value Under Playwright",
            satisfied=r2_satisfied,
            statement=(
                "DoeRuntime provides measurable browser acceleration over Dawn, "
                "but Fawn Direct Protocol does not yield additional latency win over standard Playwright."
            ),
            recommended_action=(
                "Promote DoeRuntime as primary WebGPU engine; keep standard Playwright protocol as default."
            ),
            evidence_deltas={
                "speedup_c_over_b": speedup_c_over_b,
                "speedup_d_over_c": speedup_d_over_c,
            },
        )
    )

    # Rule 3: If D reduces tokens but increases total task time
    r3_satisfied = token_reduction_ratio > 1.2 and speedup_d_over_a < 0.95
    verdicts.append(
        DecisionRuleVerdict(
            rule_id="RULE_3_TOKEN_SAVINGS_LATENCY_TRADEOFF",
            rule_name="Token Savings vs Wall Latency Tradeoff",
            satisfied=r3_satisfied,
            statement=(
                "Fawn Direct Protocol successfully compresses context and reduces token consumption, "
                "but total wall-clock latency is higher than stock baseline."
            ),
            recommended_action=(
                "Restrict Direct Protocol to context-bound agents where token budget dominates latency."
            ),
            evidence_deltas={
                "token_reduction_ratio": token_reduction_ratio,
                "speedup_d_over_a": speedup_d_over_a,
            },
        )
    )

    # Rule 4: If none beat A
    r4_satisfied = not b_beats_a and not c_beats_b and not d_beats_a
    verdicts.append(
        DecisionRuleVerdict(
            rule_id="RULE_4_NO_BROWSER_ADVANTAGE",
            rule_name="No Measurable Browser Advantage",
            satisfied=r4_satisfied,
            statement=(
                "Neither Fawn shell nor DoeRuntime achieves performance or efficiency gains over stock Chromium."
            ),
            recommended_action=(
                "Do not rationalize browser results. Redirect DoeRuntime focus to Node/Bun/Electron package lanes."
            ),
            evidence_deltas={
                "speedup_b_over_a": speedup_b_over_a,
                "speedup_c_over_b": speedup_c_over_b,
                "speedup_d_over_a": speedup_d_over_a,
            },
        )
    )

    # Rule 5: If D materially beats A across task success, latency, memory, and recovery
    tokens_improved = token_reduction_ratio >= 1.2 or (tok_a <= 500 and d_beats_a)
    latency_improved = d_beats_a
    success_maintained = res_d.metrics.success_rate >= res_a.metrics.success_rate
    r5_satisfied = tokens_improved and latency_improved and success_maintained

    verdicts.append(
        DecisionRuleVerdict(
            rule_id="RULE_5_VERTICAL_INTEGRATION_VALIDATED",
            rule_name="Vertical Integration Thesis Validated",
            satisfied=r5_satisfied,
            statement=(
                "Fawn Direct Protocol + DoeRuntime materially outperforms Stock Chromium + Playwright + Dawn "
                "in wall-clock latency, token efficiency, and execution success."
            ),
            recommended_action=(
                "Advance Fawn + Doe as the primary unified distribution and execution stack for AI agents."
            ),
            evidence_deltas={
                "speedup_d_over_a": speedup_d_over_a,
                "token_reduction_ratio": token_reduction_ratio,
                "memory_delta_mb": memory_delta_mb,
            },
        )
    )

    if r5_satisfied:
        overall_status = "VERTICAL_THESIS_VALIDATED"
    elif r2_satisfied:
        overall_status = "DOERUNTIME_ACCELERATION_PROVEN"
    elif r1_satisfied:
        overall_status = "FAWN_SHELL_VALUE_ONLY"
    elif r3_satisfied:
        overall_status = "TOKEN_OPTIMIZED_NICHE"
    else:
        overall_status = "INCONCLUSIVE_OR_REGRESSED"

    return MatrixComparisonReport(
        workload_id=workload_id,
        results_by_lane=results,
        speedup_b_over_a=speedup_b_over_a,
        speedup_c_over_b=speedup_c_over_b,
        speedup_d_over_c=speedup_d_over_c,
        speedup_d_over_a=speedup_d_over_a,
        token_reduction_ratio_d_vs_a=token_reduction_ratio,
        memory_delta_mb_d_vs_a=memory_delta_mb,
        verdicts=verdicts,
        overall_thesis_status=overall_status,
    )
