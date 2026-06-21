#!/usr/bin/env python3
"""Build a timestamped Doe benchmark JSON bundle."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from datetime import datetime, timezone
from glob import glob
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib import output_paths
from bench.lib.bench_utils import load_json_object as load_json
from bench.lib.bench_utils import write_json_object as write_json

NO_MATCH_GLOB = "bench/out/__visualization_pipeline_no_match__/*.json"
TIMESTAMP_SUFFIX_RE = re.compile(r"\d{8}T\d{6}Z$")
STATIC_VIEWER = (BENCH_ROOT / "viewers" / "bench_out_viewer.html").resolve()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--backend-report-glob",
        action="append",
        default=[],
        help="Glob for native/backend compare reports.",
    )
    parser.add_argument(
        "--backend-report",
        action="append",
        default=[],
        help="Explicit native/backend compare report path. May be repeated.",
    )
    parser.add_argument(
        "--node-report-glob",
        action="append",
        default=[],
        help="Glob for Node package compare reports.",
    )
    parser.add_argument(
        "--node-report",
        action="append",
        default=[],
        help="Explicit Node package compare report path. May be repeated.",
    )
    parser.add_argument(
        "--bun-report-glob",
        action="append",
        default=[],
        help="Glob for Bun package compare reports.",
    )
    parser.add_argument(
        "--bun-report",
        action="append",
        default=[],
        help="Explicit Bun package compare report path. May be repeated.",
    )
    parser.add_argument(
        "--summary-out",
        default="bench/out/visualization/pipeline.summary.json",
        help="Summary JSON path for the timestamped bundle.",
    )
    parser.add_argument(
        "--latest-summary",
        default="bench/out/visualization/latest/pipeline.summary.json",
        help="Stable latest summary JSON path.",
    )
    parser.add_argument(
        "--title",
        default="Doe benchmark JSON bundle",
        help="Summary title.",
    )
    parser.add_argument(
        "--timestamp",
        default="",
        help="UTC timestamp suffix for the visualization bundle.",
    )
    parser.add_argument(
        "--timestamp-output",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Stamp the primary outputs into a timestamped run folder.",
    )
    parser.add_argument(
        "--inventory-max-recent-reports",
        type=int,
        default=30,
        help="Max recent reports retained in the generated inventory JSON.",
    )
    return parser.parse_args()


def collect_paths(patterns: list[str], explicit_paths: list[str]) -> list[Path]:
    candidates: list[Path] = []
    seen: set[str] = set()
    for raw in explicit_paths:
        path = Path(raw).resolve()
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        candidates.append(path)
    for pattern in patterns:
        for raw in sorted(glob(pattern, recursive=True)):
            path = Path(raw).resolve()
            key = str(path)
            if key in seen:
                continue
            seen.add(key)
            candidates.append(path)
    return candidates


def run_command(argv: list[str]) -> None:
    subprocess.run(
        argv,
        check=True,
        cwd=REPO_ROOT,
    )


def slugify(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9]+", "-", value.strip().lower())
    cleaned = re.sub(r"-{2,}", "-", cleaned).strip("-")
    return cleaned or "artifact"


def surface_label(path: Path) -> str:
    path_text = str(path).lower()
    name_text = path.name.lower()
    if "apple-metal" in path_text or ".metal" in name_text:
        return "Apple Metal"
    if "amd-vulkan" in path_text or ".vulkan" in name_text:
        return "AMD Vulkan"
    if "d3d12" in path_text or ".d3d12" in name_text:
        return "Windows D3D12"
    return "Benchmark"


def lane_label(kind: str, path: Path) -> str:
    surface = surface_label(path)
    if kind == "backend":
        return f"{surface} native"
    if kind == "node":
        return f"{surface} Node package"
    return f"{surface} Bun package"


def default_claim_report_path(report_path: Path) -> Path | None:
    name = report_path.name
    if name.endswith(".compare.json"):
        candidate = report_path.with_name(name.replace(".compare.json", ".claim.json"))
        if candidate.exists():
            return candidate
    return None


def load_optional_claim_report(report_path: Path) -> dict[str, Any]:
    candidate = default_claim_report_path(report_path)
    if candidate is None:
        return {}
    payload = load_json(candidate)
    if payload.get("artifactKind") != "claim-report":
        raise ValueError(f"expected claim-report at {candidate}")
    return payload


def parse_utc_iso(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    candidate = value.strip()
    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def parse_report_timestamp(payload: dict[str, Any], source_path: Path) -> str:
    generated = parse_utc_iso(payload.get("generatedAt"))
    if generated is not None:
        return generated.isoformat().replace("+00:00", "Z")
    output_timestamp = payload.get("outputTimestamp")
    if isinstance(output_timestamp, str) and output_timestamp:
        return output_timestamp
    stem = source_path.stem
    parts = stem.split(".")
    if parts and TIMESTAMP_SUFFIX_RE.fullmatch(parts[-1]):
        return parts[-1]
    return ""


def as_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def nested_delta(payload: dict[str, Any], *path: str) -> float | None:
    current: Any = payload
    for part in path:
        if not isinstance(current, dict):
            return None
        current = current.get(part)
    return as_float(current)


def summarize_report(*, label: str, report_path: Path) -> dict[str, Any]:
    payload = load_json(report_path)
    claim_payload = load_optional_claim_report(report_path)
    comparability = payload.get("comparabilitySummary", {})
    comparable_count = 0
    if isinstance(comparability, dict):
        comparable_count = max(
            int(comparability.get("workloadCount", 0))
            - int(comparability.get("nonComparableCount", 0)),
            0,
        )
    claim_policy = claim_payload.get("claimPolicy", {})
    if not isinstance(claim_policy, dict):
        claim_policy = {}
    claim_report_path = default_claim_report_path(report_path)
    return {
        "label": label,
        "reportPath": str(report_path),
        "claimReportPath": str(claim_report_path) if claim_report_path is not None else "",
        "reportTimestamp": parse_report_timestamp(payload, report_path),
        "comparisonStatus": payload.get("comparisonStatus", "unknown"),
        "claimStatus": claim_payload.get(
            "claimStatus",
            payload.get("claimStatus", "not-evaluated"),
        ),
        "claimabilityMode": claim_policy.get(
            "mode",
            payload.get("claimabilityPolicy", {}).get("mode", "not-evaluated"),
            ),
        "workloadCount": len(payload.get("workloads", []))
        if isinstance(payload.get("workloads"), list)
        else 0,
        "comparableCount": comparable_count,
        "selectedP50DeltaPercent": nested_delta(
            payload,
            "overall",
            "deltaPercent",
            "p50Percent",
        ),
        "selectedP95DeltaPercent": nested_delta(
            payload,
            "overall",
            "deltaPercent",
            "p95Percent",
        ),
        "wallP50DeltaPercent": nested_delta(
            payload,
            "overallWorkloadUnitWall",
            "deltaPercent",
            "p50Percent",
        ),
        "wallP95DeltaPercent": nested_delta(
            payload,
            "overallWorkloadUnitWall",
            "deltaPercent",
            "p95Percent",
        ),
    }


def main() -> int:
    args = parse_args()
    backend_reports = collect_paths(args.backend_report_glob, args.backend_report)
    node_reports = collect_paths(args.node_report_glob, args.node_report)
    bun_reports = collect_paths(args.bun_report_glob, args.bun_report)
    all_reports = backend_reports + node_reports + bun_reports
    if not all_reports:
        raise ValueError("no compare reports provided to visualization pipeline")

    timestamp = (
        output_paths.resolve_timestamp(args.timestamp)
        if args.timestamp_output
        else ""
    )
    summary_out = output_paths.with_timestamp(
        args.summary_out,
        timestamp,
        enabled=args.timestamp_output,
        group="visualization",
    ).resolve()
    latest_summary = Path(args.latest_summary).resolve()
    run_dir = summary_out.parent
    latest_dir = latest_summary.parent
    run_dir.mkdir(parents=True, exist_ok=True)
    latest_dir.mkdir(parents=True, exist_ok=True)

    report_entries: list[dict[str, Any]] = []
    for kind, reports in (
        ("backend", backend_reports),
        ("node", node_reports),
        ("bun", bun_reports),
    ):
        for report_path in reports:
            report_entries.append(
                summarize_report(
                    label=lane_label(kind, report_path),
                    report_path=report_path,
                )
            )
    report_entries.sort(key=lambda item: (item.get("label", ""), item.get("reportTimestamp", "")))

    inventory_json = run_dir / "inventory.json"
    latest_inventory_json = latest_dir / "inventory.json"
    inventory_args = [
        sys.executable,
        "bench/tools/build_test_inventory_dashboard.py",
        "--no-timestamp-output",
        "--report-glob",
        NO_MATCH_GLOB,
        "--inventory-out",
        str(inventory_json),
        "--latest-inventory",
        str(latest_inventory_json),
        "--max-recent-reports",
        str(max(args.inventory_max_recent_reports, 0)),
    ]
    for report_path in all_reports:
        inventory_args.extend(["--report", str(report_path)])
    run_command(inventory_args)

    cube_summary = run_dir / "cube.summary.json"
    cube_rows = run_dir / "cube.rows.json"
    latest_cube_summary = latest_dir / "cube.summary.json"
    latest_cube_rows = latest_dir / "cube.rows.json"
    cube_args = [
        sys.executable,
        "bench/tools/build_benchmark_cube.py",
        "--no-timestamp-output",
        "--backend-report-glob",
        NO_MATCH_GLOB,
        "--node-report-glob",
        NO_MATCH_GLOB,
        "--bun-report-glob",
        NO_MATCH_GLOB,
        "--summary-out",
        str(cube_summary),
        "--rows-out",
        str(cube_rows),
        "--latest-summary",
        str(latest_cube_summary),
        "--latest-rows",
        str(latest_cube_rows),
        "--no-preserve-latest",
    ]
    for report_path in backend_reports:
        cube_args.extend(["--backend-report", str(report_path)])
    for report_path in node_reports:
        cube_args.extend(["--node-report", str(report_path)])
    for report_path in bun_reports:
        cube_args.extend(["--bun-report", str(report_path)])
    run_command(cube_args)

    summary_payload = {
        "schemaVersion": 1,
        "generatedAtUtc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "outputTimestamp": timestamp,
        "title": args.title,
        "viewerPath": str(STATIC_VIEWER),
        "reports": report_entries,
        "artifacts": {
            "cube": {
                "summaryPath": str(cube_summary),
                "rowsPath": str(cube_rows),
            },
            "inventory": {
                "inventoryPath": str(inventory_json),
            },
        },
    }
    write_json(summary_out, summary_payload)
    write_json(latest_summary, summary_payload)

    output_paths.write_run_manifest_for_outputs(
        [
            summary_out,
            inventory_json,
            cube_summary,
            cube_rows,
        ],
        {
            "runType": "visualization-pipeline",
            "title": args.title,
            "status": "passed",
            "summaryPath": str(summary_out),
            "compareReportCount": len(report_entries),
            "viewerPath": str(STATIC_VIEWER),
        },
    )

    print("PASS: built visualization JSON bundle")
    print(f"summary: {summary_out}")
    print(f"latest summary: {latest_summary}")
    print(f"viewer: {STATIC_VIEWER}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
