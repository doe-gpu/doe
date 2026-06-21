#!/usr/bin/env python3
"""Reject compare reports that mix diagnostic rows into claimable output."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import load_json_object as load_json


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, help="Compare report JSON path.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def evaluate_report(report: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if report.get("comparisonStatus") == "comparable" and report.get("comparabilityFailures"):
        failures.append(
            failure(
                "comparable_report_has_failures",
                "comparabilityFailures",
                "comparisonStatus=comparable cannot carry comparabilityFailures",
            )
        )

    workloads = report.get("workloads", [])
    if not isinstance(workloads, list) or not workloads:
        return failures + [failure("missing_workloads", "workloads", "compare report must carry workloads")]

    for index, workload in enumerate(workloads):
        if not isinstance(workload, dict):
            failures.append(failure("invalid_workload", f"workloads[{index}]", "workload row must be object"))
            continue
        row_path = f"workloads[{index}]"
        workload_id = str(workload.get("id", f"row-{index}"))
        claim_eligible = workload.get("claimEligible") is True
        benchmark_class = str(workload.get("benchmarkClass", ""))
        workload_comparable = workload.get("workloadComparable") is True
        comparability = workload.get("comparability")
        comparable = isinstance(comparability, dict) and comparability.get("comparable") is True
        reasons = comparability.get("reasons", []) if isinstance(comparability, dict) else []

        if claim_eligible and benchmark_class != "comparable":
            failures.append(
                failure(
                    "claimable_row_not_comparable_class",
                    f"{row_path}.benchmarkClass",
                    f"{workload_id}: claimEligible=true requires benchmarkClass=comparable",
                )
            )
        if claim_eligible and not workload_comparable:
            failures.append(
                failure(
                    "claimable_row_not_workload_comparable",
                    f"{row_path}.workloadComparable",
                    f"{workload_id}: claimEligible=true requires workloadComparable=true",
                )
            )
        if claim_eligible and not comparable:
            failures.append(
                failure(
                    "claimable_row_not_comparable",
                    f"{row_path}.comparability.comparable",
                    f"{workload_id}: claimEligible=true requires comparability.comparable=true",
                )
            )
        if claim_eligible and reasons:
            failures.append(
                failure(
                    "claimable_row_has_diagnostic_reasons",
                    f"{row_path}.comparability.reasons",
                    f"{workload_id}: claimEligible=true cannot carry diagnostic comparability reasons",
                )
            )
        if benchmark_class == "diagnostic" and claim_eligible:
            failures.append(
                failure(
                    "diagnostic_row_marked_claimable",
                    f"{row_path}.claimEligible",
                    f"{workload_id}: diagnostic benchmark row cannot be claim eligible",
                )
            )
    return failures


def main() -> int:
    args = parse_args()
    failures = evaluate_report(load_json(Path(args.report)))
    report = {
        "schemaVersion": 1,
        "artifactKind": "compare_output_partition_gate",
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: compare output partition gate")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: compare output partition gate")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
