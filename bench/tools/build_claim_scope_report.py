#!/usr/bin/env python3
"""Emit claim-scope artifacts that external copy can cite without overgeneralizing."""

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

from bench.lib import compare_claim_artifacts as artifacts_mod


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report",
        default="bench/out/dawn-vs-doe.compare.json",
        help="Compare report produced by the compare lane.",
    )
    parser.add_argument(
        "--claim-report",
        default="",
        help="Optional explicit claim report path. Defaults to sibling .claim.json.",
    )
    parser.add_argument(
        "--out-json",
        default="bench/out/claim_scope_report.json",
        help="JSON output path.",
    )
    parser.add_argument(
        "--out-md",
        default="bench/out/claim_scope_report.md",
        help="Markdown output path.",
    )
    parser.add_argument(
        "--require-comparison-status",
        default="comparable",
        help="Required top-level comparisonStatus.",
    )
    parser.add_argument(
        "--require-claim-status",
        default="claimable",
        help="Required top-level claimStatus.",
    )
    parser.add_argument(
        "--require-claimability-mode",
        default="release",
        help="Required claimPolicy.mode.",
    )
    return parser.parse_args()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def parse_string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    out: list[str] = []
    for item in value:
        if isinstance(item, str) and item:
            out.append(item)
    return out


def unique_paths(paths: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        out.append(path)
    return out


def trace_meta_paths(side: dict[str, Any]) -> list[str]:
    raw_samples = side.get("commandSamples")
    if not isinstance(raw_samples, list):
        return []
    paths: list[str] = []
    for sample in raw_samples:
        if not isinstance(sample, dict):
            continue
        raw_path = sample.get("traceMetaPath")
        if isinstance(raw_path, str) and raw_path.strip():
            paths.append(raw_path.strip())
    return unique_paths(paths)


def side_profile(side: dict[str, Any]) -> dict[str, str]:
    last_meta = side.get("lastMeta")
    if not isinstance(last_meta, dict):
        return {}
    profile = last_meta.get("profile")
    if not isinstance(profile, dict):
        return {}
    out: dict[str, str] = {}
    for key in ("vendor", "api", "deviceFamily", "driver"):
        value = profile.get(key)
        if isinstance(value, str) and value:
            out[key] = value
    return out


def side_backend_id(side: dict[str, Any]) -> str:
    last_meta = side.get("lastMeta")
    if not isinstance(last_meta, dict):
        return ""
    value = last_meta.get("backendId")
    return value if isinstance(value, str) else ""


def side_stats(side: dict[str, Any]) -> dict[str, float | None]:
    stats = side.get("stats")
    if not isinstance(stats, dict):
        return {"p50Ms": None, "p95Ms": None, "p99Ms": None}
    return {
        "p50Ms": parse_float(stats.get("p50Ms")),
        "p95Ms": parse_float(stats.get("p95Ms")),
        "p99Ms": parse_float(stats.get("p99Ms")),
    }


def claim_scope_rows(report: dict[str, Any]) -> list[dict[str, Any]]:
    workloads = report.get("workloads")
    if not isinstance(workloads, list):
        return []

    report_out_path = report.get("outPath")
    report_path_value = report_out_path if isinstance(report_out_path, str) else ""
    top_comparison_status = report.get("comparisonStatus")
    top_claim_status = report.get("claimStatus")

    rows: list[dict[str, Any]] = []
    for workload in workloads:
        if not isinstance(workload, dict):
            continue
        workload_id = workload.get("id")
        if not isinstance(workload_id, str) or not workload_id:
            continue
        baseline = workload.get("baseline")
        comparison = workload.get("comparison")
        if not isinstance(baseline, dict):
            baseline = {}
        if not isinstance(comparison, dict):
            comparison = {}

        comparability = workload.get("comparability")
        if not isinstance(comparability, dict):
            comparability = {}
        claimability = workload.get("claimability")
        if not isinstance(claimability, dict):
            claimability = {}
        timing_interpretation = workload.get("timingInterpretation")
        if not isinstance(timing_interpretation, dict):
            timing_interpretation = {}
        selected_timing = timing_interpretation.get("selectedTiming")
        if not isinstance(selected_timing, dict):
            selected_timing = {}
        workload_unit_wall = workload.get("workloadUnitWall")
        if not isinstance(workload_unit_wall, dict):
            workload_unit_wall = {}
        delta = workload.get("deltaPercent")
        if not isinstance(delta, dict):
            delta = {}

        baseline_timing_sources = parse_string_list(baseline.get("timingSources"))
        comparison_timing_sources = parse_string_list(comparison.get("timingSources"))
        baseline_timing_classes = parse_string_list(baseline.get("timingClasses"))
        comparison_timing_classes = parse_string_list(comparison.get("timingClasses"))
        baseline_stats = side_stats(baseline)
        comparison_stats = side_stats(comparison)
        baseline_backend = side_backend_id(baseline)
        comparison_backend = side_backend_id(comparison)
        baseline_profile = side_profile(baseline)
        comparison_profile = side_profile(comparison)
        baseline_meta_paths = trace_meta_paths(baseline)
        comparison_meta_paths = trace_meta_paths(comparison)

        delta_p50 = parse_float(delta.get("p50Percent"))
        delta_p95 = parse_float(delta.get("p95Percent"))
        delta_p99 = parse_float(delta.get("p99Percent"))
        workload_unit_delta = workload_unit_wall.get("deltaPercent")
        if not isinstance(workload_unit_delta, dict):
            workload_unit_delta = {}
        workload_unit_delta_p50 = parse_float(workload_unit_delta.get("p50Percent"))
        workload_unit_delta_p95 = parse_float(workload_unit_delta.get("p95Percent"))
        workload_unit_delta_p99 = parse_float(workload_unit_delta.get("p99Percent"))

        citation = (
            f"{workload_id}: comparisonStatus={top_comparison_status}, claimStatus={top_claim_status}, "
            f"workloadComparableContract={bool(workload.get('workloadComparable'))}, "
            f"workloadComparableNow={comparability.get('comparable')}, "
            f"workloadClaimableNow={claimability.get('claimable')}, "
            f"delta(p50/p95/p99)={delta_p50}/{delta_p95}/{delta_p99}, "
            f"workloadUnitWallDelta(p50/p95/p99)={workload_unit_delta_p50}/{workload_unit_delta_p95}/{workload_unit_delta_p99}, "
            f"selectedScope={selected_timing.get('scope')}/{selected_timing.get('scopeClass')}, "
            f"timingSources(baseline/comparison)={baseline_timing_sources}/{comparison_timing_sources}, "
            f"backend(baseline/comparison)={baseline_backend}/{comparison_backend}, report={report_path_value}"
        )

        rows.append(
            {
                "workloadId": workload_id,
                "name": workload.get("name", workload_id),
                "domain": workload.get("domain", ""),
                "reportStatus": {
                    "comparisonStatus": top_comparison_status,
                    "claimStatus": top_claim_status,
                },
                "workloadStatus": {
                    "workloadComparableContract": bool(workload.get("workloadComparable")),
                    "workloadComparableNow": comparability.get("comparable"),
                    "workloadClaimableNow": claimability.get("claimable"),
                },
                "timing": {
                    "baselineSources": baseline_timing_sources,
                    "comparisonSources": comparison_timing_sources,
                    "baselineClasses": baseline_timing_classes,
                    "comparisonClasses": comparison_timing_classes,
                    "selectedScope": selected_timing.get("scope"),
                    "selectedScopeClass": selected_timing.get("scopeClass"),
                    "selectedIsNarrowHotPath": selected_timing.get("isNarrowHotPath"),
                    "selectedScopeNote": selected_timing.get("note"),
                },
                "performance": {
                    "deltaPercent": {
                        "p50Percent": delta_p50,
                        "p95Percent": delta_p95,
                        "p99Percent": delta_p99,
                    },
                    "workloadUnitWallDeltaPercent": {
                        "p50Percent": workload_unit_delta_p50,
                        "p95Percent": workload_unit_delta_p95,
                        "p99Percent": workload_unit_delta_p99,
                    },
                    "baselineStatsMs": baseline_stats,
                    "comparisonStatsMs": comparison_stats,
                    "workloadUnitWallBaselineStatsMs": workload_unit_wall.get("baselineStatsMs", {}),
                    "workloadUnitWallComparisonStatsMs": workload_unit_wall.get("comparisonStatsMs", {}),
                },
                "runtime": {
                    "baselineBackendId": baseline_backend,
                    "comparisonBackendId": comparison_backend,
                    "baselineProfile": baseline_profile,
                    "comparisonProfile": comparison_profile,
                },
                "artifacts": {
                    "reportPath": report_path_value,
                    "baselineTraceMetaPaths": baseline_meta_paths,
                    "comparisonTraceMetaPaths": comparison_meta_paths,
                },
                "externalCitation": citation,
            }
        )
    return rows


def markdown(payload: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append("# Claim Scope Report")
    lines.append("")
    lines.append(f"- Generated: `{payload.get('generatedAtUtc', '')}`")
    lines.append(f"- Report: `{payload.get('reportPath', '')}`")
    lines.append(f"- Claim report: `{payload.get('claimReportPath', '')}`")
    lines.append(f"- Comparison status: `{payload.get('comparisonStatus', '')}`")
    lines.append(f"- Claim status: `{payload.get('claimStatus', '')}`")
    lines.append(f"- Claimability mode: `{payload.get('claimabilityMode', '')}`")
    lines.append(f"- Workloads: `{payload.get('workloadCount', 0)}`")
    lines.append("")
    lines.append("| Workload | Domain | Selected p50% | Workload-unit wall p50% | Scope | Timing (L/R) | Backend (L/R) |")
    lines.append("|---|---|---:|---:|---|---|---|")
    for row in payload.get("rows", []):
        if not isinstance(row, dict):
            continue
        performance = row.get("performance", {})
        if not isinstance(performance, dict):
            performance = {}
        delta = performance.get("deltaPercent", {})
        if not isinstance(delta, dict):
            delta = {}
        workload_unit_delta = performance.get("workloadUnitWallDeltaPercent", {})
        if not isinstance(workload_unit_delta, dict):
            workload_unit_delta = {}
        timing = row.get("timing", {})
        if not isinstance(timing, dict):
            timing = {}
        runtime = row.get("runtime", {})
        if not isinstance(runtime, dict):
            runtime = {}
        baseline_sources = ",".join(parse_string_list(timing.get("baselineSources")))
        comparison_sources = ",".join(parse_string_list(timing.get("comparisonSources")))
        baseline_backend = runtime.get("baselineBackendId", "")
        comparison_backend = runtime.get("comparisonBackendId", "")
        selected_scope = timing.get("selectedScopeClass") or timing.get("selectedScope") or ""
        lines.append(
            "| "
            f"{row.get('workloadId', '')} | {row.get('domain', '')} | "
            f"{delta.get('p50Percent', '')} | {workload_unit_delta.get('p50Percent', '')} | {selected_scope} | "
            f"{baseline_sources} / {comparison_sources} | {baseline_backend} / {comparison_backend} |"
        )
    lines.append("")
    lines.append("## Citation-ready lines")
    lines.append("")
    for row in payload.get("rows", []):
        if not isinstance(row, dict):
            continue
        citation = row.get("externalCitation", "")
        if isinstance(citation, str) and citation:
            lines.append(f"- {citation}")
    lines.append("")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    report_path = Path(args.report)
    if not report_path.exists():
        print(f"FAIL: missing report: {report_path}")
        return 1

    try:
        compare_report, claim_report, claim_report_path = artifacts_mod.load_compare_bundle(
            report_path,
            explicit_claim_path=args.claim_report,
            require_claim=True,
        )
    except (OSError, json.JSONDecodeError, ValueError, FileNotFoundError) as exc:
        print(f"FAIL: {exc}")
        return 1
    assert claim_report is not None
    assert claim_report_path is not None

    projected = artifacts_mod.projected_compare_report(
        compare_report,
        report_path,
        claim_report=claim_report,
    )
    comparison_status = projected.get("comparisonStatus")
    claim_status = projected.get("claimStatus")
    claimability_mode = projected.get("claimabilityPolicy", {}).get("mode")

    failures: list[str] = []
    if comparison_status != args.require_comparison_status:
        failures.append(
            f"comparisonStatus mismatch: expected {args.require_comparison_status}, got {comparison_status!r}"
        )
    if claim_status != args.require_claim_status:
        failures.append(
            f"claimStatus mismatch: expected {args.require_claim_status}, got {claim_status!r}"
        )
    if claimability_mode != args.require_claimability_mode:
        failures.append(
            f"claimability mode mismatch: expected {args.require_claimability_mode}, got {claimability_mode!r}"
        )
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1

    rows = claim_scope_rows(projected)
    payload = {
        "schemaVersion": 1,
        "generatedAtUtc": utc_now(),
        "reportPath": str(report_path),
        "claimReportPath": str(claim_report_path),
        "comparisonStatus": comparison_status,
        "claimStatus": claim_status,
        "claimabilityMode": claimability_mode,
        "workloadCount": len(rows),
        "rows": rows,
    }

    out_json = Path(args.out_json)
    out_md = Path(args.out_md)
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    out_md.write_text(markdown(payload), encoding="utf-8")
    print(
        json.dumps(
            {
                "outJson": str(out_json),
                "outMd": str(out_md),
                "workloadCount": len(rows),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
