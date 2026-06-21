#!/usr/bin/env python3
"""One-command evidence bundle: release report + claim scope + footprint + CTS + model capacity."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
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
    parser.add_argument(
        "--config",
        default="bench/native-compare/compare.config.apple.metal.release.json",
        help="Compare-lane config path used when release pipeline runs.",
    )
    parser.add_argument(
        "--report",
        default="",
        help="Compare report path. Defaults to run.out from --config.",
    )
    parser.add_argument(
        "--claim-report",
        default="",
        help="Optional explicit claim report path passed to build_claim_scope_report.py.",
    )
    parser.add_argument(
        "--skip-release-pipeline",
        action="store_true",
        help="Skip running run_release_pipeline.py.",
    )
    parser.add_argument(
        "--skip-claim-scope",
        action="store_true",
        help="Skip build_claim_scope_report.py.",
    )
    parser.add_argument(
        "--skip-footprint",
        action="store_true",
        help="Skip measure_runtime_footprint.py.",
    )
    parser.add_argument(
        "--skip-cts",
        action="store_true",
        help="Skip run_cts_subset.py.",
    )
    parser.add_argument(
        "--skip-model-capacity",
        action="store_true",
        help="Skip build_model_capacity_matrix.py.",
    )
    parser.add_argument(
        "--cts-config",
        default="bench/fixtures/cts_subset.fawn-node.json",
        help="CTS subset config passed to run_cts_subset.py.",
    )
    parser.add_argument(
        "--cts-max-queries",
        type=int,
        default=0,
        help="Optional query limit passed to run_cts_subset.py.",
    )
    parser.add_argument(
        "--cts-dry-run",
        action="store_true",
        help="Pass --dry-run to run_cts_subset.py.",
    )
    parser.add_argument(
        "--doe-build-cmd",
        default="",
        help="Optional Doe build command passed to measure_runtime_footprint.py.",
    )
    parser.add_argument(
        "--dawn-build-cmd",
        default="",
        help="Optional Dawn build command passed to measure_runtime_footprint.py.",
    )
    parser.add_argument(
        "--model-capacity-config",
        default="",
        help="Optional model-capacity input JSON for build_model_capacity_matrix.py.",
    )
    parser.add_argument(
        "--claim-scope-required-comparison-status",
        default="comparable",
        help="Required comparisonStatus passed to build_claim_scope_report.py.",
    )
    parser.add_argument(
        "--claim-scope-required-claim-status",
        default="claimable",
        help="Required claimStatus passed to build_claim_scope_report.py.",
    )
    parser.add_argument(
        "--claim-scope-required-claimability-mode",
        default="release",
        help="Required claimPolicy.mode passed to build_claim_scope_report.py.",
    )
    parser.add_argument(
        "--out-prefix",
        default="",
        help="Output prefix for generated artifacts (default: <report-without-suffix>.market-readiness).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print commands without executing them.",
    )
    return parser.parse_args()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def resolve_report_path(config_path: Path, explicit_report: str) -> Path:
    if explicit_report.strip():
        return Path(explicit_report)
    payload = load_json(config_path)
    run = payload.get("run")
    if not isinstance(run, dict):
        raise ValueError(f"invalid config {config_path}: missing run object")
    out = run.get("out")
    if not isinstance(out, str) or not out.strip():
        raise ValueError(f"invalid config {config_path}: missing run.out")
    return Path(out)


def default_prefix(report_path: Path) -> Path:
    if report_path.suffix:
        return Path(f"{report_path.with_suffix('')}.market-readiness")
    return Path(f"{report_path}.market-readiness")


def run_command(label: str, command: list[str], *, dry_run: bool) -> dict[str, Any]:
    print(f"[bundle] {label}: {' '.join(command)}", flush=True)
    if dry_run:
        return {
            "label": label,
            "command": command,
            "ran": False,
            "exitCode": 0,
        }
    proc = subprocess.run(command, check=False)
    return {
        "label": label,
        "command": command,
        "ran": True,
        "exitCode": proc.returncode,
    }


def main() -> int:
    args = parse_args()
    config_path = Path(args.config)
    if not args.skip_release_pipeline and not config_path.exists():
        print(f"FAIL: missing config: {config_path}")
        return 1

    try:
        report_path = resolve_report_path(config_path, args.report)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: {exc}")
        return 1

    prefix = Path(args.out_prefix) if args.out_prefix.strip() else default_prefix(report_path)
    prefix.parent.mkdir(parents=True, exist_ok=True)

    steps: list[dict[str, Any]] = []

    if not args.skip_release_pipeline:
        release_cmd = [
            sys.executable,
            "bench/runners/run_release_pipeline.py",
            "--config",
            str(config_path),
            "--report",
            str(report_path),
            "--no-timestamp-output",
            "--with-claim-gate",
        ]
        step = run_command("release-pipeline", release_cmd, dry_run=args.dry_run)
        steps.append(step)
        if step["exitCode"] != 0:
            print("FAIL: release pipeline failed")
            return 1

    if not args.skip_claim_scope:
        claim_json = Path(f"{prefix}.claim-scope.json")
        claim_md = Path(f"{prefix}.claim-scope.md")
        claim_cmd = [
            sys.executable,
            "bench/tools/build_claim_scope_report.py",
            "--report",
            str(report_path),
            "--out-json",
            str(claim_json),
            "--out-md",
            str(claim_md),
            "--require-comparison-status",
            args.claim_scope_required_comparison_status,
            "--require-claim-status",
            args.claim_scope_required_claim_status,
            "--require-claimability-mode",
            args.claim_scope_required_claimability_mode,
        ]
        if args.claim_report.strip():
            claim_cmd.extend(["--claim-report", args.claim_report])
        step = run_command("claim-scope", claim_cmd, dry_run=args.dry_run)
        steps.append(step)
        if step["exitCode"] != 0:
            print("FAIL: claim scope report failed")
            return 1

    if not args.skip_footprint:
        footprint_json = Path(f"{prefix}.footprint.json")
        footprint_md = Path(f"{prefix}.footprint.md")
        footprint_cmd = [
            sys.executable,
            "bench/tools/measure_runtime_footprint.py",
            "--out-json",
            str(footprint_json),
            "--out-md",
            str(footprint_md),
        ]
        if args.doe_build_cmd.strip():
            footprint_cmd.extend(["--doe-build-cmd", args.doe_build_cmd])
        if args.dawn_build_cmd.strip():
            footprint_cmd.extend(["--dawn-build-cmd", args.dawn_build_cmd])
        step = run_command("runtime-footprint", footprint_cmd, dry_run=args.dry_run)
        steps.append(step)
        if step["exitCode"] != 0:
            print("FAIL: runtime footprint report failed")
            return 1

    if not args.skip_cts:
        cts_json = Path(f"{prefix}.cts.json")
        cts_md = Path(f"{prefix}.cts.md")
        cts_cmd = [
            sys.executable,
            "bench/runners/run_cts_subset.py",
            "--config",
            args.cts_config,
            "--out-json",
            str(cts_json),
            "--out-md",
            str(cts_md),
        ]
        if args.cts_max_queries > 0:
            cts_cmd.extend(["--max-queries", str(args.cts_max_queries)])
        if args.cts_dry_run:
            cts_cmd.append("--dry-run")
        step = run_command("cts-subset", cts_cmd, dry_run=args.dry_run)
        steps.append(step)
        if step["exitCode"] != 0:
            print("FAIL: cts subset report failed")
            return 1

    if not args.skip_model_capacity and args.model_capacity_config.strip():
        model_json = Path(f"{prefix}.model-capacity.json")
        model_md = Path(f"{prefix}.model-capacity.md")
        model_cmd = [
            sys.executable,
            "bench/tools/build_model_capacity_matrix.py",
            "--input",
            args.model_capacity_config,
            "--out-json",
            str(model_json),
            "--out-md",
            str(model_md),
        ]
        step = run_command("model-capacity", model_cmd, dry_run=args.dry_run)
        steps.append(step)
        if step["exitCode"] != 0:
            print("FAIL: model capacity report failed")
            return 1

    manifest = {
        "schemaVersion": 1,
        "generatedAtUtc": utc_now(),
        "configPath": str(config_path),
        "reportPath": str(report_path),
        "outputPrefix": str(prefix),
        "steps": steps,
    }
    manifest_path = Path(f"{prefix}.manifest.json")
    if args.dry_run:
        print(json.dumps(manifest, indent=2))
        return 0

    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "manifest": str(manifest_path),
                "steps": len(steps),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
