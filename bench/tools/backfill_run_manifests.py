#!/usr/bin/env python3
"""Backfill run_manifest.json for historical timestamped benchmark folders."""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

import argparse
import json
from datetime import datetime, timezone
from typing import Any

from bench.lib import output_paths


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--out-dir",
        default="bench/out",
        help="Benchmark output directory containing timestamp folders.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing run_manifest.json files.",
    )
    parser.add_argument(
        "--include-scratch",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Also backfill bench/out/scratch/<timestamp>/ folders.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned writes without changing files.",
    )
    return parser.parse_args()


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def infer_run_type(folder: Path) -> tuple[str, list[str]]:
    signals: list[str] = []
    files = [path.name for path in folder.glob("*") if path.is_file()]
    dirs = [path.name for path in folder.glob("*") if path.is_dir()]

    if any(name.startswith("dawn-vs-doe") and name.endswith(".json") for name in files):
        signals.append("dawn-vs-doe*.json")
        return "compare_dawn_vs_doe", signals
    if any(name.startswith("release-claim-windows") and name.endswith(".json") for name in files):
        signals.append("release-claim-windows*.json")
        return "release_claim_windows", signals
    if any(name.startswith("substantiation_report") and name.endswith(".json") for name in files):
        signals.append("substantiation_report*.json")
        return "substantiation_gate", signals
    if any(name.startswith("dropin_report") and name.endswith(".json") for name in files):
        signals.append("dropin_report*.json")
        return "dropin_gate", signals
    if any(name.startswith("dropin_symbol_report") and name.endswith(".json") for name in files):
        signals.append("dropin_symbol_report*.json")
        return "dropin_symbol_gate", signals
    if any(name.startswith("dropin_behavior_report") and name.endswith(".json") for name in files):
        signals.append("dropin_behavior_report*.json")
        return "dropin_behavior_suite", signals
    if any(name.startswith("dropin_benchmark_report") and name.endswith(".json") for name in files):
        signals.append("dropin_benchmark_report*.json")
        return "dropin_benchmark_suite", signals
    if any(name.startswith("perf_report") and name.endswith(".json") for name in files):
        signals.append("perf_report*.json")
        return "run_bench", signals
    if any(name.startswith("run_metadata") and name.endswith(".json") for name in files):
        signals.append("run_metadata*.json")
        return "run_bench", signals
    if any(name.startswith("test-inventory") and name.endswith(".json") for name in files):
        signals.append("test-inventory*.json")
        return "inventory_dashboard", signals
    if any(name.startswith("test-dashboard") and name.endswith(".html") for name in files):
        signals.append("test-dashboard*.html")
        return "inventory_dashboard", signals
    if any(name.startswith("runtime-comparisons") for name in dirs):
        signals.append("runtime-comparisons*/")
        return "runtime_workspace", signals

    return "legacy_unknown", signals


def manifest_payload(folder: Path, *, status: str = "unknown_historical") -> dict[str, Any]:
    run_type, signals = infer_run_type(folder)
    now = now_utc()
    return {
        "schemaVersion": 1,
        "runFolder": str(folder),
        "outputTimestamp": folder.name,
        "runType": run_type,
        "config": {
            "inferred": True,
            "inferenceSignals": signals,
        },
        "fullRun": False,
        "claimGateRan": False,
        "dropinGateRan": False,
        "status": status,
        "createdAtUtc": now,
        "updatedAtUtc": now,
    }


def collect_timestamp_folders(out_dir: Path, *, include_scratch: bool) -> list[Path]:
    return output_paths.collect_timestamp_folders(out_dir, include_scratch=include_scratch)


def main() -> int:
    args = parse_args()
    out_dir = Path(args.out_dir)
    if not out_dir.exists() or not out_dir.is_dir():
        print(f"FAIL: invalid --out-dir: {out_dir}")
        return 1

    folders = collect_timestamp_folders(out_dir, include_scratch=args.include_scratch)
    if not folders:
        print(f"FAIL: no timestamp folders under: {out_dir}")
        return 1

    written = 0
    skipped = 0
    for folder in folders:
        manifest_path = folder / "run_manifest.json"
        if manifest_path.exists() and not args.overwrite:
            skipped += 1
            continue

        payload = manifest_payload(folder)
        if args.dry_run:
            print(f"PLAN: {manifest_path} ({payload['runType']})")
            written += 1
            continue

        manifest_path.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        written += 1

    print(f"PASS: manifest backfill complete (written={written} skipped={skipped})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
