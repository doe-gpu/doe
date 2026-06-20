#!/usr/bin/env python3
"""Run repeated strict single-workload compare sweeps."""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if path_entry not in sys.path:
        sys.path.insert(0, path_entry)

from bench.lib import compare_claim_artifacts as artifacts_mod
from bench.native_compare_modules.reporting import safe_float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--config",
        default="bench/native-compare/compare.config.apple.metal.compare.json",
    )
    parser.add_argument("--workload", required=True)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument(
        "--out-dir",
        default="bench/out/scratch",
        help="Base output directory for per-run reports and sweep summary.",
    )
    return parser.parse_args()


def timestamp_id() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def median(values: list[float]) -> float | None:
    if not values:
        return None
    return float(statistics.median(values))


def run_once(
    *,
    config: Path,
    workload: str,
    out_path: Path,
    workspace_path: Path,
) -> tuple[int, str]:
    cmd = [
        sys.executable,
        "bench/cli.py",
        "compare",
        "--config",
        str(config),
        "--workload-filter",
        workload,
        "--no-timestamp-output",
        "--out",
        str(out_path),
        "--workspace",
        str(workspace_path),
    ]
    proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
    combined = "\n".join(
        part for part in (proc.stdout.strip(), proc.stderr.strip()) if part
    )
    return proc.returncode, combined


def main() -> int:
    args = parse_args()
    if args.repeats < 1:
        raise ValueError("--repeats must be >= 1")

    config_path = Path(args.config).resolve()
    out_root = Path(args.out_dir).resolve() / f"single-sweep.{args.workload}.{timestamp_id()}"
    out_root.mkdir(parents=True, exist_ok=True)

    run_rows: list[dict[str, Any]] = []
    p50_values: list[float] = []
    p95_values: list[float] = []
    baseline_p50_values: list[float] = []
    comparison_p50_values: list[float] = []

    for index in range(1, args.repeats + 1):
        out_path = out_root / f"run{index}.json"
        workspace_path = out_root / f"run{index}.workspace"
        rc, output = run_once(
            config=config_path,
            workload=args.workload,
            out_path=out_path,
            workspace_path=workspace_path,
        )
        row: dict[str, Any] = {
            "run": index,
            "returnCode": rc,
            "reportPath": str(out_path),
            "workspacePath": str(workspace_path),
            "claimStatus": "",
            "comparisonStatus": "",
            "deltaP50Percent": None,
            "deltaP95Percent": None,
            "baselineP50Ms": None,
            "comparisonP50Ms": None,
            "stderr": output,
        }

        if out_path.exists():
            payload = json.loads(out_path.read_text(encoding="utf-8"))
            claim_payload, _claim_path = artifacts_mod.load_optional_claim_report(out_path)
            workloads = payload.get("workloads", [])
            if isinstance(workloads, list) and workloads:
                workload_row = workloads[0]
                if isinstance(workload_row, dict):
                    delta = workload_row.get("deltaPercent", {})
                    baseline_stats = workload_row.get("baselineStatsMs", {})
                    comparison_stats = workload_row.get("comparisonStatsMs", {})
                    row["claimStatus"] = artifacts_mod.claim_status(payload, claim_payload)
                    row["comparisonStatus"] = str(payload.get("comparisonStatus", ""))
                    row["deltaP50Percent"] = safe_float(delta.get("p50Percent"))
                    row["deltaP95Percent"] = safe_float(delta.get("p95Percent"))
                    row["baselineP50Ms"] = safe_float(baseline_stats.get("p50Ms"))
                    row["comparisonP50Ms"] = safe_float(comparison_stats.get("p50Ms"))

                    if row["deltaP50Percent"] is not None:
                        p50_values.append(float(row["deltaP50Percent"]))
                    if row["deltaP95Percent"] is not None:
                        p95_values.append(float(row["deltaP95Percent"]))
                    if row["baselineP50Ms"] is not None:
                        baseline_p50_values.append(float(row["baselineP50Ms"]))
                    if row["comparisonP50Ms"] is not None:
                        comparison_p50_values.append(float(row["comparisonP50Ms"]))

        print(
            f"run {index}/{args.repeats}: rc={row['returnCode']} "
            f"comparison={row['comparisonStatus'] or '<none>'} "
            f"claim={row['claimStatus'] or '<none>'} "
            f"p50%={row['deltaP50Percent']!r} p95%={row['deltaP95Percent']!r}"
        )
        run_rows.append(row)

    summary = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "configPath": str(config_path),
        "workload": args.workload,
        "repeats": args.repeats,
        "outRoot": str(out_root),
        "runs": run_rows,
        "aggregate": {
            "successfulReportCount": len(p50_values),
            "medianDeltaP50Percent": median(p50_values),
            "medianDeltaP95Percent": median(p95_values),
            "medianBaselineP50Ms": median(baseline_p50_values),
            "medianComparisonP50Ms": median(comparison_p50_values),
            "minDeltaP50Percent": min(p50_values) if p50_values else None,
            "maxDeltaP50Percent": max(p50_values) if p50_values else None,
            "minDeltaP95Percent": min(p95_values) if p95_values else None,
            "maxDeltaP95Percent": max(p95_values) if p95_values else None,
        },
    }

    summary_path = out_root / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"summary: {summary_path}")

    if not p50_values:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
