"""Unit tests verifying the 4-Lane Fawn-Doe Benchmark Matrix and Decision Rules."""

import os
import tempfile
import pytest

from bench.fawn_matrix.harness.types import (
    Lane,
    TimingBreakdown,
    WorkloadMetric,
    LaneExecutionResult,
)
from bench.fawn_matrix.harness.evaluator import evaluate_decision_rules
from bench.fawn_matrix.harness.lanes import MatrixLaneRunner
from bench.fawn_matrix.cli import run_matrix


def _make_dummy_result(lane: Lane, lat: float, tokens: int = 1000, mem: float = 300.0) -> LaneExecutionResult:
    return LaneExecutionResult(
        lane=lane,
        workload_id="test_workload",
        metrics=WorkloadMetric(
            latency_ms_p50=lat,
            latency_ms_p95=lat * 1.2,
            latency_ms_p99=lat * 1.4,
            memory_peak_mb=mem,
            context_tokens=tokens,
            success_rate=1.0,
            breakdown_p50=TimingBreakdown(
                setup_ms=lat * 0.2,
                snapshot_diff_ms=lat * 0.3,
                compute_ms=lat * 0.3,
                action_ms=lat * 0.2,
                total_wall_ms=lat,
            ),
        ),
    )


def test_rule_5_vertical_integration_validated():
    """Verifies Rule 5 triggers when Lane D beats Lane A in latency and tokens."""
    results = {
        Lane.LANE_A.value: _make_dummy_result(Lane.LANE_A, lat=100.0, tokens=4500, mem=400.0),
        Lane.LANE_B.value: _make_dummy_result(Lane.LANE_B, lat=75.0, tokens=4500, mem=360.0),
        Lane.LANE_C.value: _make_dummy_result(Lane.LANE_C, lat=55.0, tokens=1200, mem=330.0),
        Lane.LANE_D.value: _make_dummy_result(Lane.LANE_D, lat=35.0, tokens=1200, mem=290.0),
    }

    report = evaluate_decision_rules("test_workload", results)
    assert report.overall_thesis_status == "VERTICAL_THESIS_VALIDATED"
    assert report.speedup_d_over_a > 2.5
    assert report.token_reduction_ratio_d_vs_a >= 3.5

    r5 = next(v for v in report.verdicts if v.rule_id == "RULE_5_VERTICAL_INTEGRATION_VALIDATED")
    assert r5.satisfied


def test_rule_1_fawn_shell_only():
    """Verifies Rule 1 triggers when Fawn shell improves over A, but Doe does not beat Dawn."""
    results = {
        Lane.LANE_A.value: _make_dummy_result(Lane.LANE_A, lat=100.0, tokens=4500),
        Lane.LANE_B.value: _make_dummy_result(Lane.LANE_B, lat=70.0, tokens=4500),
        Lane.LANE_C.value: _make_dummy_result(Lane.LANE_C, lat=70.0, tokens=4500),
        Lane.LANE_D.value: _make_dummy_result(Lane.LANE_D, lat=70.0, tokens=4500),
    }

    report = evaluate_decision_rules("test_workload", results)
    r1 = next(v for v in report.verdicts if v.rule_id == "RULE_1_FAWN_SHELL_ONLY")
    assert r1.satisfied


def test_rule_3_token_tradeoff():
    """Verifies Rule 3 triggers when Lane D reduces tokens but increases wall time."""
    results = {
        Lane.LANE_A.value: _make_dummy_result(Lane.LANE_A, lat=50.0, tokens=4000),
        Lane.LANE_B.value: _make_dummy_result(Lane.LANE_B, lat=50.0, tokens=4000),
        Lane.LANE_C.value: _make_dummy_result(Lane.LANE_C, lat=50.0, tokens=4000),
        Lane.LANE_D.value: _make_dummy_result(Lane.LANE_D, lat=70.0, tokens=1000),
    }

    report = evaluate_decision_rules("test_workload", results)
    r3 = next(v for v in report.verdicts if v.rule_id == "RULE_3_TOKEN_SAVINGS_LATENCY_TRADEOFF")
    assert r3.satisfied


def test_lane_runner_execution():
    """Verifies that MatrixLaneRunner runs iterations and computes accurate statistics."""
    runner = MatrixLaneRunner(Lane.LANE_D, simulated_mode=True)
    res = runner.run_workload("webgpu_model_preprocessing", warmup_iterations=1, timed_iterations=5)

    assert res.lane == Lane.LANE_D
    assert res.workload_id == "webgpu_model_preprocessing"
    assert len(res.sample_latencies_ms) == 5
    assert res.metrics.latency_ms_p50 > 0
    assert res.metrics.latency_ms_p95 >= res.metrics.latency_ms_p50
    assert res.metrics.breakdown_p50.total_wall_ms == res.metrics.latency_ms_p50


def test_matrix_cli_run_to_artifact():
    """Verifies end-to-end matrix run saving JSON artifact to disk."""
    with tempfile.TemporaryDirectory() as tmpdir:
        report = run_matrix("multi_step_agent_interaction", output_dir=tmpdir, simulated=True)
        assert report.overall_thesis_status == "VERTICAL_THESIS_VALIDATED"
        out_file = os.path.join(tmpdir, "fawn-matrix.multi_step_agent_interaction.json")
        assert os.path.exists(out_file)
