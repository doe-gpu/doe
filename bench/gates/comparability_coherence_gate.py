#!/usr/bin/env python3
"""Gate top-level compare-report comparability against layer coherence."""

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

from bench.lib import comparability_coherence  # noqa: E402
from bench.lib.bench_utils import load_json_object as load_json  # noqa: E402
from native_compare_modules.config_support import (  # noqa: E402
    load_benchmark_methodology_policy,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, help="Compare report JSON path")
    parser.add_argument(
        "--benchmark-policy",
        default="config/benchmark-methodology-thresholds.json",
        help="Benchmark methodology threshold config path",
    )
    parser.add_argument(
        "--require-pass",
        action="store_true",
        help="Exit non-zero when coherence status is not pass.",
    )
    parser.add_argument("--out", default="", help="Optional JSON result path")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    report_path = Path(args.report)
    if not report_path.exists():
        print(f"FAIL: missing --report: {report_path}")
        return 1

    try:
        policy = load_benchmark_methodology_policy(args.benchmark_policy)
        report = load_json(report_path)
        result = comparability_coherence.assess_report(
            report,
            min_timed_samples=policy.comparability_min_timed_samples,
            smoke_min_timed_samples=policy.smoke_comparability_min_timed_samples,
            benchmark_policy_path=policy.source_path,
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FAIL: comparability coherence input error: {exc}")
        return 1

    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(
            json.dumps(result, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    print(
        "comparability coherence: "
        f"{result['status']} ({result['failureCount']} failure(s), "
        f"minTimedSamples={result['minTimedSamples']}, "
        f"smokeMinTimedSamples={result['smokeMinTimedSamples']})"
    )
    for failure in result.get("failures", []):
        workload_id = failure.get("workloadId", "?")
        reasons = failure.get("reasons", [])
        if not isinstance(reasons, list):
            reasons = [str(reasons)]
        print(f"- {workload_id}: {'; '.join(str(reason) for reason in reasons)}")

    if args.require_pass and result.get("status") != "pass":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
