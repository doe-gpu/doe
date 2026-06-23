#!/usr/bin/env python3
"""Build a normalized benchmark cube from backend and package compare reports."""

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
from collections import Counter, defaultdict
from datetime import datetime, timezone
from glob import glob
from statistics import median
from typing import Any

from bench.lib import compare_claim_artifacts as artifacts_mod
from bench.lib import benchmark_cube_reports as cube_reports_mod
from bench.lib import compare_axes as compare_axes_mod
from bench.lib import benchmark_cube_dashboard_html
from bench.lib import output_paths
from bench.lib import report_conformance
from native_compare_modules import timing_sanity

STATUS_ORDER = {
    "unsupported": 0,
    "unimplemented": 1,
    "diagnostic": 2,
    "comparable": 3,
    "claimable": 4,
}

load_json = cube_reports_mod.load_json
load_json_object = cube_reports_mod.load_json_object
parse_utc_iso = cube_reports_mod.parse_utc_iso
iso_utc = cube_reports_mod.iso_utc
parse_report_timestamp = cube_reports_mod.parse_report_timestamp
run_id_from_timestamp = cube_reports_mod.run_id_from_timestamp
safe_float = cube_reports_mod.safe_float
parse_int = cube_reports_mod.parse_int
validate_schema = cube_reports_mod.validate_schema
validate_backend_report_shape = cube_reports_mod.validate_backend_report_shape
load_policy = cube_reports_mod.load_policy
load_governed_lanes = cube_reports_mod.load_governed_lanes
load_workload_registry = cube_reports_mod.load_workload_registry
resolve_workload_identity = cube_reports_mod.resolve_workload_identity
canonical_lane_id = cube_reports_mod.canonical_lane_id
validate_governed_lane_binding = cube_reports_mod.validate_governed_lane_binding
load_timing_scope_sanity_policy = cube_reports_mod.load_timing_scope_sanity_policy
workload_set_for_row = cube_reports_mod.workload_set_for_row
detect_backend_host = cube_reports_mod.detect_backend_host
detect_package_host = cube_reports_mod.detect_package_host
normalize_backend_report = cube_reports_mod.normalize_backend_report
validate_package_report = cube_reports_mod.validate_package_report
normalize_package_report = cube_reports_mod.normalize_package_report

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--backend-report-glob",
        action="append",
        default=[],
        help=(
            "Glob for backend Dawn-vs-Doe compare reports. May be repeated. "
            "Default: bench/out/**/dawn-vs-doe*.json"
        ),
    )
    parser.add_argument(
        "--backend-report",
        action="append",
        default=[],
        help="Explicit backend compare report path. May be repeated.",
    )
    parser.add_argument(
        "--node-report-glob",
        action="append",
        default=[],
        help=(
            "Glob for Node package compare reports. May be repeated. "
            "Default: bench/out/node-doe-vs-dawn*/*.json"
        ),
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
        help=(
            "Glob for Bun package compare reports. May be repeated. "
            "Default: bench/out/bun-doe-vs-webgpu/*.json"
        ),
    )
    parser.add_argument(
        "--bun-report",
        action="append",
        default=[],
        help="Explicit Bun package compare report path. May be repeated.",
    )
    parser.add_argument(
        "--policy",
        default="config/benchmark-cube-policy.json",
        help="Benchmark cube policy contract.",
    )
    parser.add_argument(
        "--workload-registry",
        default="bench/workloads/metadata/workload-registry.json",
        help="Canonical workload registry used to normalize cross-surface workload IDs.",
    )
    parser.add_argument(
        "--comparability-obligations",
        default="config/comparability-obligations.json",
        help="Canonical comparability obligation contract for backend report conformance.",
    )
    parser.add_argument(
        "--summary-out",
        default="bench/out/cube/cube.summary.json",
        help="Output JSON summary path.",
    )
    parser.add_argument(
        "--rows-out",
        default="bench/out/cube/cube.rows.json",
        help="Output JSON rows path.",
    )
    parser.add_argument(
        "--matrix-md-out",
        default="",
        help="Optional markdown matrix path. Leave empty to emit JSON only.",
    )
    parser.add_argument(
        "--dashboard-html-out",
        default="",
        help="Optional HTML dashboard path. Leave empty to emit JSON only.",
    )
    parser.add_argument(
        "--latest-summary",
        default="bench/out/cube/latest/cube.summary.json",
        help="Stable latest summary path.",
    )
    parser.add_argument(
        "--latest-rows",
        default="bench/out/cube/latest/cube.rows.json",
        help="Stable latest rows path.",
    )
    parser.add_argument(
        "--latest-matrix-md",
        default="",
        help="Optional stable latest markdown matrix path.",
    )
    parser.add_argument(
        "--latest-dashboard-html",
        default="",
        help="Optional stable latest HTML dashboard path.",
    )
    parser.add_argument(
        "--timestamp",
        default="",
        help=(
            "UTC suffix for timestamped outputs (YYYYMMDDTHHMMSSZ). "
            "Defaults to current UTC time when --timestamp-output is enabled."
        ),
    )
    parser.add_argument(
        "--timestamp-output",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Stamp output artifact paths with a UTC timestamp suffix.",
    )
    parser.add_argument(
        "--preserve-latest",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "Seed the build with report paths referenced by the current latest cube summary so "
            "subset reruns cannot silently downgrade the latest mirror."
        ),
    )
    return parser.parse_args()


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def collect_paths(patterns: list[str], explicit_paths: list[str]) -> list[Path]:
    candidates: list[Path] = []
    seen: set[str] = set()
    for raw in explicit_paths:
        path = Path(raw)
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        candidates.append(path)
    for pattern in patterns:
        for raw in sorted(glob(pattern, recursive=True)):
            path = Path(raw)
            key = str(path)
            if key in seen:
                continue
            seen.add(key)
            candidates.append(path)
    return candidates


def collect_seed_report_paths(repo_root: Path, latest_summary_path: Path) -> dict[str, list[Path]]:
    if not latest_summary_path.exists():
        return {"backend": [], "node": [], "bun": []}
    try:
        payload = load_json_object(latest_summary_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        return {"backend": [], "node": [], "bun": []}
    cells = payload.get("cells")
    if not isinstance(cells, list):
        return {"backend": [], "node": [], "bun": []}
    seeded = {"backend": [], "node": [], "bun": []}
    seen: set[str] = set()
    for cell in cells:
        if not isinstance(cell, dict):
            continue
        raw = cell.get("latestReportPath")
        if not isinstance(raw, str) or not raw.strip():
            continue
        path = Path(raw)
        if not path.is_absolute():
            path = (repo_root / raw).resolve()
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        path_text = key.lower()
        if "bun-doe-vs-webgpu" in path_text:
            seeded["bun"].append(path)
        elif "node-doe-vs-dawn" in path_text:
            seeded["node"].append(path)
        else:
            seeded["backend"].append(path)
    return seeded


def is_scratch_namespace_path(path: Path) -> bool:
    parts = path.parts
    for idx in range(len(parts) - 2):
        if parts[idx] == "bench" and parts[idx + 1] == "out" and parts[idx + 2] == "scratch":
            return True
    return False


def median_non_null(values: list[float | None]) -> float | None:
    filtered = [value for value in values if value is not None]
    if not filtered:
        return None
    return float(median(filtered))


def status_rank(status: str) -> int:
    return STATUS_ORDER.get(status, -1)


def source_conformance_rank(source_conformance: str) -> int:
    return 1 if source_conformance == "canonical" else 0


def degrade_status_for_conformance(status: str, source_conformance: str) -> str:
    if source_conformance == "canonical":
        return status
    if status in {"claimable", "comparable"}:
        return "diagnostic"
    return status


def summarize_row_group(rows: list[dict[str, Any]]) -> tuple[str, str, float | None]:
    if not rows:
        return "unimplemented", "unimplemented", None
    source_conformance = rows[0].get("sourceConformance", "canonical")
    comparison_status = (
        "comparable"
        if all(row["comparisonStatus"] == "comparable" for row in rows)
        else "diagnostic"
    )
    claim_status = (
        "claimable"
        if rows and all(row["claimStatus"] == "claimable" for row in rows)
        else "diagnostic"
    )
    comparison_status = degrade_status_for_conformance(comparison_status, source_conformance)
    claim_status = degrade_status_for_conformance(claim_status, source_conformance)
    current_status = claim_status if claim_status == "claimable" else comparison_status
    return current_status, claim_status, median_non_null(
        [row["metrics"]["deltaP50Percent"] for row in rows]
    )


def render_matrix_markdown(summary: dict[str, Any], policy: dict[str, Any]) -> str:
    host_profiles = policy["hostProfiles"]
    workload_sets = policy["workloadSets"]
    cells = {
        (
            cell["surface"],
            cell["hostProfile"],
            cell["workloadSet"],
        ): cell
        for cell in summary["cells"]
    }
    lines = [
        "# Benchmark Cube",
        "",
        f"Generated: `{summary['generatedAt']}`",
        "",
        f"Rows: `{summary['rowCount']}`",
        "",
    ]

    for surface in policy["raw"]["surfaces"]:
        lines.append(f"## {surface['displayName']}")
        lines.append("")
        lines.append(
            f"Maturity: `{surface['maturity']}`. Primary support: `{surface['primarySupport']}`."
        )
        lines.append("")
        header = ["Workload Set", *[host_profiles[item]["displayName"] for item in surface["expectedHostProfiles"]]]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("| " + " | ".join("---" for _ in header) + " |")
        for workload_set_id in surface["workloadSets"]:
            row = [workload_sets[workload_set_id]["displayName"]]
            for host_profile_id in surface["expectedHostProfiles"]:
                cell = cells[(surface["id"], host_profile_id, workload_set_id)]
                if cell["reportCount"] == 0:
                    detail = str(cell.get("statusDetail") or "").strip()
                    row.append(f"{cell['status']} ({detail})" if detail else cell["status"])
                else:
                    row.append(f"{cell['status']} ({cell['rowCount']} rows)")
            lines.append("| " + " | ".join(row) + " |")
        lines.append("")
        for note in surface["notes"]:
            lines.append(f"- {note}")
        lines.append("")

    return "\n".join(lines)


def eligible_governed_lane_ids(
    governed_lanes: dict[str, Any],
    *,
    surface_id: str,
    host_profile: str,
    provider_pair: str,
) -> list[str]:
    lane_ids: list[str] = []
    for lane in governed_lanes["raw"]["lanes"]:
        if lane.get("cubeEligible") is not True:
            continue
        if lane.get("surface") != surface_id:
            continue
        if host_profile not in lane.get("hostProfiles", []):
            continue
        comparison_views = lane.get("comparisonViews", lane.get("providerPairs"))
        if (
            isinstance(comparison_views, list)
            and comparison_views
            and provider_pair not in comparison_views
        ):
            continue
        lane_ids.append(lane["id"])
    return lane_ids


def make_placeholder_cell(
    surface: dict[str, Any],
    host_profile: str,
    provider_pair: str,
    workload_set: str,
    *,
    governed_lanes: dict[str, Any],
) -> dict[str, Any]:
    lane_ids = eligible_governed_lane_ids(
        governed_lanes,
        surface_id=surface["id"],
        host_profile=host_profile,
        provider_pair=provider_pair,
    )
    status_detail = (
        "contract exists, evidence missing"
        if lane_ids
        else "no governed lane contract"
    )
    return {
        "surface": surface["id"],
        "comparisonView": provider_pair,
        "providerPair": provider_pair,
        "providerSet": compare_axes_mod.derive_provider_set(
            boundary=(
                "backend_native"
                if surface["id"] == "backend_native"
                else "package_surface"
            ),
            runtime_host=(
                "bun"
                if surface["id"] == "bun_package"
                else ("deno" if surface["id"] == "deno_package" else "node")
            ) if surface["id"].endswith("_package") else "none",
            comparison_view=provider_pair,
        ),
        "providers": list(compare_axes_mod.providers_for_comparison_view(provider_pair)),
        "governedLaneIds": lane_ids,
        "hostProfile": host_profile,
        "workloadSet": workload_set,
        "scopeType": "full_matrix" if workload_set == "full_comparable" else "workload_set",
        "maturity": surface["maturity"],
        "primarySupport": surface["primarySupport"],
        "status": surface["defaultMissingStatus"],
        "statusDetail": status_detail,
        "reportCount": 0,
        "rowCount": 0,
        "notes": surface["notes"],
    }


def surface_comparison_views(
    policy: dict[str, Any],
    surface: dict[str, Any],
) -> list[str]:
    comparison_views = surface.get("comparisonViews")
    if isinstance(comparison_views, list) and comparison_views:
        return [str(item) for item in comparison_views]
    provider_pairs = surface.get("providerPairs")
    if isinstance(provider_pairs, list) and provider_pairs:
        return [str(item) for item in provider_pairs]
    product_views = [
        str(product.get("id"))
        for product in policy["raw"].get("products", [])
        if product.get("surface") == surface["id"] and isinstance(product.get("id"), str)
    ]
    if product_views:
        return product_views
    raise ValueError(f"surface {surface['id']} declares no comparison views")


def build_cells(
    *,
    policy: dict[str, Any],
    governed_lanes: dict[str, Any],
    rows: list[dict[str, Any]],
    reports: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    rows_by_report: dict[tuple[str, str, str, str, str], list[dict[str, Any]]] = defaultdict(list)
    report_counts: Counter[tuple[str, str, str, str]] = Counter()
    latest_report_for_tuple: dict[tuple[str, str, str, str], dict[str, Any]] = {}

    for row in rows:
        key = (
            row["surface"],
            row["providerPair"],
            row["host"]["profileId"],
            row["workloadSet"],
            row["sourceReportPath"],
        )
        rows_by_report[key].append(row)

    for key in rows_by_report:
        short_key = key[:4]
        report_counts[short_key] += 1

    def report_sort_key(report: dict[str, Any]) -> tuple[int, int, int, int, str]:
        return (
            source_conformance_rank(report.get("sourceConformance", "canonical")),
            int(report.get("rowCount", 0)),
            status_rank(report.get("claimStatus", "diagnostic")),
            status_rank(report.get("comparisonStatus", "diagnostic")),
            report["generatedAt"],
        )

    for report in reports:
        full_key = (
            report["surface"],
            report["providerPair"],
            report["hostProfile"],
            "full_comparable",
        )
        existing = latest_report_for_tuple.get(full_key)
        if existing is None or report_sort_key(existing) < report_sort_key(report):
            latest_report_for_tuple[full_key] = report

    latest_row_report: dict[tuple[str, str, str, str], tuple[str, list[dict[str, Any]], str]] = {}
    def row_group_sort_key(grouped_rows: list[dict[str, Any]], generated_at: str) -> tuple[int, int, int, int, str]:
        status, claim_status, _delta_percent = summarize_row_group(grouped_rows)
        comparison_status = (
            "comparable"
            if all(row["comparisonStatus"] == "comparable" for row in grouped_rows)
            else "diagnostic"
        )
        return (
            source_conformance_rank(grouped_rows[0].get("sourceConformance", "canonical")),
            len(grouped_rows),
            status_rank(claim_status),
            status_rank(status),
            generated_at,
        )

    for key, grouped_rows in rows_by_report.items():
        short_key = key[:4]
        generated_at = grouped_rows[0]["generatedAt"]
        existing = latest_row_report.get(short_key)
        if existing is None or row_group_sort_key(existing[1], existing[2]) < row_group_sort_key(grouped_rows, generated_at):
            latest_row_report[short_key] = (key[4], grouped_rows, generated_at)

    cells: list[dict[str, Any]] = []
    for surface in policy["raw"]["surfaces"]:
        for provider_pair in surface_comparison_views(policy, surface):
            for host_profile in surface["expectedHostProfiles"]:
                for workload_set in surface["workloadSets"]:
                    tuple_key = (surface["id"], provider_pair, host_profile, workload_set)
                    if workload_set == "full_comparable":
                        latest = latest_report_for_tuple.get(tuple_key)
                        if latest is None:
                            cells.append(
                                make_placeholder_cell(
                                    surface,
                                    host_profile,
                                    provider_pair,
                                    workload_set,
                                    governed_lanes=governed_lanes,
                                )
                            )
                            continue
                        status = latest["claimStatus"]
                        if status != "claimable":
                            status = latest["comparisonStatus"]
                        comparison_status = degrade_status_for_conformance(
                            latest["comparisonStatus"],
                            latest.get("sourceConformance", "canonical"),
                        )
                        claim_status = degrade_status_for_conformance(
                            latest["claimStatus"],
                            latest.get("sourceConformance", "canonical"),
                        )
                        status = claim_status if claim_status == "claimable" else comparison_status
                        cells.append(
                            {
                                "surface": surface["id"],
                                "comparisonView": provider_pair,
                                "providerPair": provider_pair,
                                "providerSet": compare_axes_mod.derive_provider_set(
                                    boundary=(
                                        "backend_native"
                                        if surface["id"] == "backend_native"
                                        else "package_surface"
                                    ),
                                    runtime_host=(
                                        "bun"
                                        if surface["id"] == "bun_package"
                                        else ("deno" if surface["id"] == "deno_package" else "node")
                                    ) if surface["id"].endswith("_package") else "none",
                                    comparison_view=provider_pair,
                                ),
                                "providers": list(compare_axes_mod.providers_for_comparison_view(provider_pair)),
                                "governedLaneIds": latest.get("governedLaneIds", []),
                                "hostProfile": host_profile,
                                "workloadSet": workload_set,
                                "scopeType": "full_matrix",
                                "maturity": surface["maturity"],
                                "primarySupport": surface["primarySupport"],
                                "status": status,
                                "reportCount": sum(
                                    1
                                    for report in reports
                                    if report["surface"] == surface["id"]
                                    and report["providerPair"] == provider_pair
                                    and report["hostProfile"] == host_profile
                                ),
                                "rowCount": latest["rowCount"],
                                "latestRunId": latest["runId"],
                                "latestGeneratedAt": latest["generatedAt"],
                                "latestReportPath": latest["sourceReportPath"],
                                "sourceConformance": latest.get("sourceConformance", "canonical"),
                                "sourceConformanceReason": latest.get("sourceConformanceReason", ""),
                                "comparisonStatus": comparison_status,
                                "claimStatus": claim_status,
                                "deltaP50MedianPercent": latest["deltaP50MedianPercent"],
                                "notes": surface["notes"],
                            }
                        )
                        continue

                    latest_rows_info = latest_row_report.get(tuple_key)
                    if latest_rows_info is None:
                        cells.append(
                            make_placeholder_cell(
                                surface,
                                host_profile,
                                provider_pair,
                                workload_set,
                                governed_lanes=governed_lanes,
                            )
                        )
                        continue
                    latest_report_path, latest_rows, latest_generated_at = latest_rows_info
                    status, claim_status, delta_percent = summarize_row_group(latest_rows)
                    comparison_status = (
                        "comparable"
                        if all(row["comparisonStatus"] == "comparable" for row in latest_rows)
                        else "diagnostic"
                    )
                    comparison_status = degrade_status_for_conformance(
                        comparison_status,
                        latest_rows[0].get("sourceConformance", "canonical"),
                    )
                    cells.append(
                        {
                            "surface": surface["id"],
                            "comparisonView": provider_pair,
                            "providerPair": provider_pair,
                            "providerSet": compare_axes_mod.derive_provider_set(
                                boundary=(
                                    "backend_native"
                                    if surface["id"] == "backend_native"
                                    else "package_surface"
                                ),
                                runtime_host=(
                                    "bun"
                                    if surface["id"] == "bun_package"
                                    else ("deno" if surface["id"] == "deno_package" else "node")
                                ) if surface["id"].endswith("_package") else "none",
                                comparison_view=provider_pair,
                            ),
                            "providers": list(compare_axes_mod.providers_for_comparison_view(provider_pair)),
                            "governedLaneIds": latest_rows[0].get("governedLaneIds", []),
                            "hostProfile": host_profile,
                            "workloadSet": workload_set,
                            "scopeType": "workload_set",
                            "maturity": surface["maturity"],
                            "primarySupport": surface["primarySupport"],
                            "status": status,
                            "reportCount": report_counts[tuple_key],
                            "rowCount": len(latest_rows),
                            "latestRunId": latest_rows[0]["runId"],
                            "latestGeneratedAt": latest_generated_at,
                            "latestReportPath": latest_report_path,
                            "sourceConformance": latest_rows[0].get("sourceConformance", "canonical"),
                            "sourceConformanceReason": latest_rows[0].get("sourceConformanceReason", ""),
                            "comparisonStatus": comparison_status,
                            "claimStatus": claim_status,
                            "deltaP50MedianPercent": delta_percent,
                            "notes": surface["notes"],
                        }
                    )

    cells.sort(
        key=lambda cell: (
            cell["surface"],
            cell["hostProfile"],
            cell["workloadSet"],
            cell["providerPair"],
        )
    )
    return cells


def main() -> None:
    args = parse_args()
    repo_root = REPO_ROOT
    timestamp = output_paths.resolve_timestamp(args.timestamp)

    policy_path = (repo_root / args.policy).resolve()
    workload_registry_path = (repo_root / args.workload_registry).resolve()
    obligation_path = (repo_root / args.comparability_obligations).resolve()
    policy = load_policy(repo_root, policy_path)
    workload_registry = load_workload_registry(repo_root, workload_registry_path)
    governed_lanes = load_governed_lanes(repo_root, repo_root / "config" / "governed-lanes.json")
    timing_scope_sanity_policy = load_timing_scope_sanity_policy(repo_root)
    obligation_schema_version, obligation_ids = report_conformance.load_obligation_contract(
        obligation_path
    )

    backend_patterns = args.backend_report_glob or ["bench/out/**/dawn-vs-doe*.json"]
    node_patterns = args.node_report_glob or ["bench/out/node-doe-vs-dawn*/*.json"]
    bun_patterns = args.bun_report_glob or ["bench/out/bun-doe-vs-webgpu/*.json"]

    backend_paths = collect_paths(backend_patterns, args.backend_report)
    node_paths = collect_paths(node_patterns, args.node_report)
    bun_paths = collect_paths(bun_patterns, args.bun_report)
    if args.preserve_latest:
        seeded = collect_seed_report_paths(repo_root, (repo_root / args.latest_summary).resolve())
        backend_paths = collect_paths([], [str(path) for path in [*backend_paths, *seeded["backend"]]])
        node_paths = collect_paths([], [str(path) for path in [*node_paths, *seeded["node"]]])
        bun_paths = collect_paths([], [str(path) for path in [*bun_paths, *seeded["bun"]]])

    rows: list[dict[str, Any]] = []
    reports: list[dict[str, Any]] = []
    receipt_cache: dict[str, dict[str, Any]] = {}
    source_counts = {
        "backendReports": {
            "discovered": len(backend_paths),
            "included": 0,
            "canonicalIncluded": 0,
            "legacyIncluded": 0,
            "skipped": 0,
        },
        "nodeReports": {
            "discovered": len(node_paths),
            "included": 0,
            "canonicalIncluded": 0,
            "legacyIncluded": 0,
            "skipped": 0,
        },
        "bunReports": {
            "discovered": len(bun_paths),
            "included": 0,
            "canonicalIncluded": 0,
            "legacyIncluded": 0,
            "skipped": 0,
        },
    }

    for path in backend_paths:
        if is_scratch_namespace_path(path):
            source_counts["backendReports"]["skipped"] += 1
            continue
        try:
            payload = load_json_object(path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
            source_counts["backendReports"]["skipped"] += 1
            continue
        normalize_payload = payload
        if payload.get("artifactKind") == "compare-report":
            try:
                claim_report, _claim_report_path = artifacts_mod.load_optional_claim_report(path)
                normalize_payload = artifacts_mod.projected_compare_report(
                    payload,
                    path,
                    claim_report=claim_report,
                    cache=receipt_cache,
                )
            except (FileNotFoundError, ValueError):
                source_counts["backendReports"]["skipped"] += 1
                continue
        include, reason = validate_backend_report_shape(normalize_payload, report_label=str(path))
        if not include:
            source_counts["backendReports"]["skipped"] += 1
            continue
        if payload.get("artifactKind") == "compare-report":
            is_canonical, canonical_reason = report_conformance.validate_report_conformance(
                payload=payload,
                report_path=path,
                repo_root=repo_root,
                expected_obligation_schema_version=obligation_schema_version,
                expected_obligation_ids=obligation_ids,
            )
        else:
            is_canonical, canonical_reason = False, "legacy compare payload"
        generated_at = parse_report_timestamp(payload, path)
        surface_policy = policy["surfaces"]["backend_native"]
        try:
            normalized_rows, report_info = normalize_backend_report(
                payload=normalize_payload,
                source_path=path,
                generated_at=generated_at,
                policy=policy,
                workload_registry=workload_registry,
                governed_lanes=governed_lanes,
                maturity=surface_policy["maturity"],
                source_conformance="canonical" if is_canonical else "legacy_nonconformant",
                source_conformance_reason="" if is_canonical else canonical_reason,
                timing_scope_sanity_policy=timing_scope_sanity_policy,
            )
        except ValueError:
            source_counts["backendReports"]["skipped"] += 1
            continue
        rows.extend(normalized_rows)
        reports.append(report_info)
        source_counts["backendReports"]["included"] += 1
        if is_canonical:
            source_counts["backendReports"]["canonicalIncluded"] += 1
        else:
            source_counts["backendReports"]["legacyIncluded"] += 1

    for path in node_paths:
        if is_scratch_namespace_path(path):
            source_counts["nodeReports"]["skipped"] += 1
            continue
        try:
            payload = load_json_object(path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
            source_counts["nodeReports"]["skipped"] += 1
            continue
        normalize_payload = payload
        if payload.get("artifactKind") == "compare-report":
            try:
                claim_report, _claim_report_path = artifacts_mod.load_optional_claim_report(path)
                normalize_payload = artifacts_mod.projected_compare_report(
                    payload,
                    path,
                    claim_report=claim_report,
                    cache=receipt_cache,
                )
            except (FileNotFoundError, ValueError):
                source_counts["nodeReports"]["skipped"] += 1
                continue
        include, _reason = validate_package_report(normalize_payload, report_label=str(path))
        if not include:
            source_counts["nodeReports"]["skipped"] += 1
            continue
        generated_at = parse_report_timestamp(payload, path)
        surface_policy = policy["surfaces"]["node_package"]
        try:
            normalized_rows, report_info = normalize_package_report(
                payload=normalize_payload,
                source_path=path,
                generated_at=generated_at,
                policy=policy,
                workload_registry=workload_registry,
                governed_lanes=governed_lanes,
                maturity=surface_policy["maturity"],
                surface="node_package",
                provider_pair="doe_vs_dawn_node_webgpu_package",
                source_report_type="node_package_compare_report",
            )
        except ValueError:
            source_counts["nodeReports"]["skipped"] += 1
            continue
        rows.extend(normalized_rows)
        reports.append(report_info)
        source_counts["nodeReports"]["included"] += 1
        source_counts["nodeReports"]["canonicalIncluded"] += 1

    for path in bun_paths:
        if is_scratch_namespace_path(path):
            source_counts["bunReports"]["skipped"] += 1
            continue
        try:
            payload = load_json_object(path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
            source_counts["bunReports"]["skipped"] += 1
            continue
        normalize_payload = payload
        if payload.get("artifactKind") == "compare-report":
            try:
                claim_report, _claim_report_path = artifacts_mod.load_optional_claim_report(path)
                normalize_payload = artifacts_mod.projected_compare_report(
                    payload,
                    path,
                    claim_report=claim_report,
                    cache=receipt_cache,
                )
            except (FileNotFoundError, ValueError):
                source_counts["bunReports"]["skipped"] += 1
                continue
        include, _reason = validate_package_report(normalize_payload, report_label=str(path))
        if not include:
            source_counts["bunReports"]["skipped"] += 1
            continue
        generated_at = parse_report_timestamp(payload, path)
        surface_policy = policy["surfaces"]["bun_package"]
        try:
            normalized_rows, report_info = normalize_package_report(
                payload=normalize_payload,
                source_path=path,
                generated_at=generated_at,
                policy=policy,
                workload_registry=workload_registry,
                governed_lanes=governed_lanes,
                maturity=surface_policy["maturity"],
                surface="bun_package",
                provider_pair="doe_vs_dawn_bun_webgpu_package",
                source_report_type="bun_package_compare_report",
            )
        except ValueError:
            source_counts["bunReports"]["skipped"] += 1
            continue
        rows.extend(normalized_rows)
        reports.append(report_info)
        source_counts["bunReports"]["included"] += 1
        source_counts["bunReports"]["canonicalIncluded"] += 1

    row_schema_path = repo_root / "config" / "benchmark-cube-row.schema.json"
    for row in rows:
        validate_schema(row_schema_path, row)

    summary_out = output_paths.with_timestamp(
        args.summary_out,
        timestamp,
        enabled=args.timestamp_output,
        group="cube",
    )
    rows_out = output_paths.with_timestamp(
        args.rows_out,
        timestamp,
        enabled=args.timestamp_output,
        group="cube",
    )
    matrix_md_out = (
        output_paths.with_timestamp(
            args.matrix_md_out,
            timestamp,
            enabled=args.timestamp_output,
            group="cube",
        )
        if args.matrix_md_out.strip()
        else None
    )
    dashboard_html_out = (
        output_paths.with_timestamp(
            args.dashboard_html_out,
            timestamp,
            enabled=args.timestamp_output,
            group="cube",
        )
        if args.dashboard_html_out.strip()
        else None
    )
    latest_matrix_md = Path(args.latest_matrix_md) if args.latest_matrix_md.strip() else None
    latest_dashboard_html = (
        Path(args.latest_dashboard_html) if args.latest_dashboard_html.strip() else None
    )

    cells = build_cells(policy=policy, governed_lanes=governed_lanes, rows=rows, reports=reports)
    status_counts = Counter(cell["status"] for cell in cells)
    for status in STATUS_ORDER:
        status_counts.setdefault(status, 0)

    summary_payload = {
        "schemaVersion": 1,
        "generatedAt": iso_utc(datetime.now(timezone.utc)),
        "policy": {
            "path": str(policy_path.relative_to(repo_root)),
            "sha256": report_conformance.file_sha256(policy_path),
        },
        "artifacts": {
            "rowsPath": str(rows_out),
            "matrixMarkdownPath": str(matrix_md_out) if matrix_md_out is not None else "",
            "dashboardHtmlPath": (
                str(dashboard_html_out) if dashboard_html_out is not None else ""
            ),
        },
        "sourceCounts": source_counts,
        "rowCount": len(rows),
        "cells": cells,
        "statusCounts": {status: status_counts[status] for status in STATUS_ORDER},
    }
    validate_schema(repo_root / "config" / "benchmark-cube.schema.json", summary_payload)

    write_json(rows_out, rows)
    write_json(summary_out, summary_payload)
    write_json(Path(args.latest_rows), rows)
    write_json(Path(args.latest_summary), summary_payload)
    if matrix_md_out is not None or latest_matrix_md is not None:
        matrix_markdown = render_matrix_markdown(summary_payload, policy)
        if matrix_md_out is not None:
            write_text(matrix_md_out, matrix_markdown + "\n")
        if latest_matrix_md is not None:
            write_text(latest_matrix_md, matrix_markdown + "\n")
    if dashboard_html_out is not None or latest_dashboard_html is not None:
        dashboard_html = benchmark_cube_dashboard_html.build_dashboard_html(
            summary_payload,
            policy,
            dashboard_path=dashboard_html_out or latest_dashboard_html or summary_out,
        )
        if dashboard_html_out is not None:
            write_text(dashboard_html_out, dashboard_html + "\n")
        if latest_dashboard_html is not None:
            write_text(latest_dashboard_html, dashboard_html + "\n")

    emitted_outputs = [rows_out, summary_out]
    if matrix_md_out is not None:
        emitted_outputs.append(matrix_md_out)
    if dashboard_html_out is not None:
        emitted_outputs.append(dashboard_html_out)
    output_paths.write_run_manifest_for_outputs(
        emitted_outputs,
        {
            "runType": "benchmark-cube",
            "config": str(policy_path.relative_to(repo_root)),
            "status": "ok",
            "summaryPath": str(summary_out),
            "rowsPath": str(rows_out),
            "matrixMarkdownPath": str(matrix_md_out) if matrix_md_out is not None else "",
            "dashboardHtmlPath": (
                str(dashboard_html_out) if dashboard_html_out is not None else ""
            ),
        },
    )


if __name__ == "__main__":
    main()
