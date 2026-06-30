#!/usr/bin/env python3
"""Validate runtime invariants for workloads marked comparable in compare reports."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)


import argparse
import json
from typing import Any

from bench.lib.bench_utils import canonical_source, load_json_object as load_json


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", default="bench/out/dawn-vs-doe.json")
    return parser.parse_args()


def parse_int(value: Any, fallback: int = 0) -> int:
    if isinstance(value, bool):
        return fallback
    if isinstance(value, int):
        return value
    return fallback


def main() -> int:
    args = parse_args()
    try:
        report = load_json(Path(args.report))
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: comparable runtime invariants gate input error: {exc}")
        return 1
    workloads = report.get("workloads")
    if not isinstance(workloads, list):
        print("FAIL: invalid report workloads")
        return 1

    failures: list[str] = []
    checked_workloads = 0

    for workload in workloads:
        if not isinstance(workload, dict):
            continue
        if workload.get("workloadComparable") is not True:
            continue
        comparability = workload.get("comparability")
        if not isinstance(comparability, dict):
            failures.append(f"{workload.get('id', 'unknown')}: missing comparability object")
            continue
        if comparability.get("comparable") is not True:
            failures.append(
                f"{workload.get('id', 'unknown')}: workloadComparable=true but comparability.comparable!=true"
            )
            continue

        checked_workloads += 1
        workload_id = str(workload.get("id", "unknown"))
        workload_domain = str(workload.get("domain", ""))

        for side_name in ("baseline", "comparison"):
            side = workload.get(side_name)
            if not isinstance(side, dict):
                continue
            samples = side.get("commandSamples")
            if not isinstance(samples, list):
                continue

            for sample in samples:
                if not isinstance(sample, dict):
                    continue
                if sample.get("returnCode") != 0:
                    continue
                trace_meta = sample.get("traceMeta")
                if not isinstance(trace_meta, dict):
                    continue

                exec_error_count = parse_int(trace_meta.get("executionErrorCount"))
                if exec_error_count > 0:
                    failures.append(
                        f"{workload_id}: {side_name} executionErrorCount={exec_error_count} on comparable workload"
                    )

                exec_unsupported_count = parse_int(trace_meta.get("executionUnsupportedCount"))
                if exec_unsupported_count > 0:
                    failures.append(
                        f"{workload_id}: {side_name} executionUnsupportedCount={exec_unsupported_count} on comparable workload"
                    )

                exec_success_count = parse_int(trace_meta.get("executionSuccessCount"))
                encode_total_ns = parse_int(trace_meta.get("executionEncodeTotalNs"))
                submit_wait_total_ns = parse_int(trace_meta.get("executionSubmitWaitTotalNs"))

                # Encode/submit telemetry checks apply only to the baseline
                # Doe side. The comparison Dawn adapter does not emit them.
                if side_name == "baseline":
                    if exec_success_count > 0 and encode_total_ns == 0 and submit_wait_total_ns == 0:
                        failures.append(
                            f"{workload_id}: {side_name} both encode and submit/wait totals are zero with successful execution"
                        )

                    timing_source = canonical_source(sample.get("timingSource"))
                    if timing_source == "doe-execution-encode-ns" and encode_total_ns == 0:
                        failures.append(
                            f"{workload_id}: {side_name} encode-only timing source has zero encode total"
                        )

                queue_sync_mode = trace_meta.get("queueSyncMode")
                upload_submit_every = parse_int(
                    sample.get("uploadSubmitEvery", trace_meta.get("uploadSubmitEvery", 1)),
                    fallback=1,
                )
                if (
                    workload_domain == "upload"
                    and queue_sync_mode == "per-command"
                    and upload_submit_every > 1
                    and exec_success_count > 0
                    and submit_wait_total_ns == 0
                ):
                    failures.append(
                        f"{workload_id}: {side_name} upload cadence tail not submitted (submit_wait_total_ns=0 with uploadSubmitEvery={upload_submit_every})"
                    )

    if checked_workloads == 0:
        print("FAIL: comparable runtime invariants gate found no comparable workloads to validate")
        return 1

    if failures:
        print("FAIL: comparable runtime invariants gate")
        for item in failures:
            print(f"  {item}")
        return 1

    print(
        "PASS: comparable runtime invariants gate "
        f"(checked comparable workloads={checked_workloads})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
