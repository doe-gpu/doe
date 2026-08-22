"""CLI front door for the Fawn-Doe 4-Lane Benchmark Matrix."""

import argparse
import dataclasses
import json
import os
import sys
from pathlib import Path
from typing import Dict, List

from .harness.evaluator import evaluate_decision_rules
from .harness.lanes import MatrixLaneRunner
from .harness.types import Lane, LaneExecutionResult, MatrixComparisonReport


def load_config() -> dict:
    config_path = Path(__file__).parent / "config" / "matrix-workloads.json"
    with open(config_path, "r", encoding="utf-8") as f:
        return json.load(f)


def run_matrix(
    workload_id: str,
    output_dir: str = "reports/fawn-matrix",
    simulated: bool = True,
) -> MatrixComparisonReport:
    """Executes all 4 lanes for a workload and evaluates the decision rules."""
    os.makedirs(output_dir, exist_ok=True)

    results: Dict[str, LaneExecutionResult] = {}
    for lane in Lane:
        runner = MatrixLaneRunner(lane, simulated_mode=simulated)
        res = runner.run_workload(workload_id)
        results[lane.value] = res

    report = evaluate_decision_rules(workload_id, results)

    # Save artifact
    out_file = Path(output_dir) / f"fawn-matrix.{workload_id}.json"
    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(dataclasses.asdict(report), f, indent=2)

    return report


def print_report_summary(report: MatrixComparisonReport) -> None:
    print("\n" + "=" * 80)
    print(f" FAWN-DOE 4-LANE MATRIX REPORT: {report.workload_id.upper()}")
    print("=" * 80)

    print(f"\n  Overall Thesis Status: \033[1;32m{report.overall_thesis_status}\033[0m")
    print(f"  Speedup Lane D vs Lane A: {report.speedup_d_over_a:.2f}x")
    print(f"  Token Reduction Ratio (D vs A): {report.token_reduction_ratio_d_vs_a:.2f}x")
    print(f"  Memory Delta (D vs A): {report.memory_delta_mb_d_vs_a:.1f} MB\n")

    print("Lane Comparison Breakdown (p50):")
    print("-" * 80)
    for lane_id, res in report.results_by_lane.items():
        m = res.metrics
        b = m.breakdown_p50
        print(
            f"  {lane_id:<36} | Total: {m.latency_ms_p50:>5.1f}ms | "
            f"Diff: {b.snapshot_diff_ms:>4.1f}ms | Comp: {b.compute_ms:>4.1f}ms | "
            f"Tokens: {m.context_tokens:>4d}"
        )

    print("\nFalsifiable Decision Rule Verdicts:")
    print("-" * 80)
    for v in report.verdicts:
        status_icon = "✅ SATISFIED" if v.satisfied else "❌ NOT TRIGGERED"
        print(f"  [{status_icon}] {v.rule_id} ({v.rule_name})")
        if v.satisfied:
            print(f"     Statement: {v.statement}")
            print(f"     Action:    {v.recommended_action}")
    print("=" * 80 + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Fawn-Doe 4-Lane Benchmark Matrix CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="Run benchmark across all 4 operational lanes")
    run_parser.add_argument(
        "--workload",
        default="all",
        choices=[
            "all",
            "persistent_session_startup",
            "context_snapshot_diff",
            "webgpu_model_preprocessing",
            "multi_step_agent_interaction",
        ],
        help="Target workload ID to benchmark",
    )
    run_parser.add_argument(
        "--output-dir",
        default="reports/fawn-matrix",
        help="Directory to save JSON comparison reports",
    )
    run_parser.add_argument(
        "--live",
        action="store_true",
        help="Run against live browsers rather than deterministic simulated mode",
    )

    args = parser.parse_args()

    if args.command == "run":
        cfg = load_config()
        workloads = [w["id"] for w in cfg["workloads"]] if args.workload == "all" else [args.workload]

        for w_id in workloads:
            report = run_matrix(w_id, output_dir=args.output_dir, simulated=not args.live)
            print_report_summary(report)

        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
