#!/usr/bin/env python3
"""Build baseline trend dataset from historical compare artifacts."""

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
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from glob import glob
from typing import Any

from bench.lib import compare_claim_artifacts as artifacts_mod
from bench.lib import output_paths
from bench.lib import report_conformance


TIMESTAMP_SUFFIX_RE = re.compile(r"\d{8}T\d{6}Z$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report-glob",
        action="append",
        default=[],
        help=(
            "Glob for compare reports. May be repeated. "
            "Default: bench/out/**/dawn-vs-doe*.json"
        ),
    )
    parser.add_argument(
        "--report",
        action="append",
        default=[],
        help="Explicit compare report path. May be repeated.",
    )
    parser.add_argument(
        "--out",
        default="bench/out/baseline-dataset.json",
        help="Output JSON dataset path.",
    )
    parser.add_argument(
        "--summary-md-out",
        default="bench/out/baseline-dataset.md",
        help="Output markdown summary path.",
    )
    parser.add_argument(
        "--latest-out",
        default="bench/out/baseline-dataset.latest.json",
        help="Stable latest output path for JSON dataset.",
    )
    parser.add_argument(
        "--latest-summary-md-out",
        default="bench/out/baseline-dataset.latest.md",
        help="Stable latest output path for markdown summary.",
    )
    parser.add_argument(
        "--timestamp",
        default="",
        help=(
            "UTC suffix for output artifact paths (YYYYMMDDTHHMMSSZ). "
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
        "--comparability-obligations",
        default="config/comparability-obligations.json",
        help="Canonical comparability-obligation contract used for report conformance checks.",
    )
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"invalid JSON object: {path}")
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


def iso_utc(dt: datetime | None) -> str:
    if dt is None:
        return ""
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_report_timestamp(payload: dict[str, Any], source_path: Path) -> datetime | None:
    generated = parse_utc_iso(payload.get("generatedAt"))
    if generated is not None:
        return generated
    output_timestamp = payload.get("outputTimestamp")
    if isinstance(output_timestamp, str):
        try:
            return datetime.strptime(output_timestamp, output_paths.TIMESTAMP_FORMAT).replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            pass
    stem = source_path.stem
    parts = stem.split(".")
    if parts and TIMESTAMP_SUFFIX_RE.fullmatch(parts[-1]):
        try:
            return datetime.strptime(parts[-1], output_paths.TIMESTAMP_FORMAT).replace(
                tzinfo=timezone.utc
            )
        except ValueError:
            return None
    return None


def normalize_matrix_id(payload: dict[str, Any], source_path: Path) -> str:
    path_hint = payload.get("outPath")
    if isinstance(path_hint, str) and path_hint.strip():
        stem = Path(path_hint).stem
    else:
        stem = source_path.stem
    parts = stem.split(".")
    if parts and TIMESTAMP_SUFFIX_RE.fullmatch(parts[-1]):
        parts = parts[:-1]
    normalized = ".".join(parts).strip()
    return normalized or stem


def safe_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    if parsed != parsed:
        return None
    return parsed


def derive_overall_p50_delta(payload: dict[str, Any]) -> float | None:
    overall = payload.get("overall")
    if not isinstance(overall, dict):
        return None
    delta = overall.get("deltaPercent")
    if isinstance(delta, dict):
        parsed = safe_float(delta.get("p50Percent"))
        if parsed is not None:
            return parsed
    return None


def get_count(summary: Any, key: str) -> int:
    if not isinstance(summary, dict):
        return 0
    value = summary.get(key)
    return value if isinstance(value, int) and value >= 0 else 0


def count_non_comparable(payload: dict[str, Any]) -> int:
    from_summary = get_count(payload.get("comparabilitySummary"), "nonComparableCount")
    if from_summary > 0:
        return from_summary
    workloads = payload.get("workloads")
    if not isinstance(workloads, list):
        return 0
    count = 0
    for workload in workloads:
        if not isinstance(workload, dict):
            continue
        comparability = workload.get("comparability")
        if isinstance(comparability, dict) and comparability.get("comparable") is False:
            count += 1
    return count


def count_non_claimable(payload: dict[str, Any]) -> int:
    from_summary = get_count(payload.get("claimabilitySummary"), "nonClaimableCount")
    if from_summary > 0:
        return from_summary
    workloads = payload.get("workloads")
    if not isinstance(workloads, list):
        return 0
    count = 0
    for workload in workloads:
        if not isinstance(workload, dict):
            continue
        claimability = workload.get("claimability")
        if isinstance(claimability, dict) and claimability.get("claimable") is False:
            count += 1
    return count


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


def is_scratch_namespace_path(path: Path) -> bool:
    parts = path.parts
    for idx in range(len(parts) - 2):
        if parts[idx] == "bench" and parts[idx + 1] == "out" and parts[idx + 2] == "scratch":
            return True
    return False


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def build_markdown_summary(payload: dict[str, Any]) -> str:
    summary = payload.get("summary", {})
    matrix_trends = payload.get("matrixTrends", [])
    lines: list[str] = []
    lines.append("# Baseline Dataset Summary")
    lines.append("")
    lines.append(f"- generated: `{payload.get('generatedAtUtc', '')}`")
    lines.append(f"- included reports: `{summary.get('includedReports', 0)}`")
    lines.append(f"- matrix count: `{summary.get('matrixCount', 0)}`")
    lines.append(f"- runtime pair count: `{summary.get('runtimePairCount', 0)}`")
    lines.append(f"- comparable reports: `{summary.get('comparableReportCount', 0)}`")
    lines.append(f"- claimable reports: `{summary.get('claimableReportCount', 0)}`")
    lines.append("")
    lines.append("## Matrix Trends")
    lines.append("")
    lines.append("| Matrix | Pair | Reports | Latest UTC | Latest p50 delta | Latest comparison | Latest claim |")
    lines.append("|---|---:|---:|---|---:|---|---|")
    for matrix in matrix_trends:
        if not isinstance(matrix, dict):
            continue
        latest = matrix.get("latest", {})
        if not isinstance(latest, dict):
            latest = {}
        delta = safe_float(latest.get("overallP50DeltaPercent"))
        delta_text = "n/a" if delta is None else f"{delta:+.2f}%"
        lines.append(
            "| "
            + f"`{matrix.get('matrixId', '')}` | "
            + f"`{matrix.get('runtimePair', '')}` | "
            + f"{matrix.get('reportCount', 0)} | "
            + f"{latest.get('generatedAtUtc', '')} | "
            + f"{delta_text} | "
            + f"{latest.get('comparisonStatus', '')} | "
            + f"{latest.get('claimStatus', '')} |"
        )
    lines.append("")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    patterns = args.report_glob if args.report_glob else ["bench/out/**/dawn-vs-doe*.json"]
    sources = collect_paths(patterns, args.report)
    if not sources:
        print("FAIL: no report files matched")
        return 1
    bench_dir = BENCH_ROOT
    repo_root = bench_dir.parent
    obligations_path = Path(args.comparability_obligations)
    if not obligations_path.is_absolute():
        obligations_path = repo_root / obligations_path
    try:
        (
            obligation_schema_version,
            obligation_ids,
        ) = report_conformance.load_obligation_contract(obligations_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: invalid comparability obligations contract: {exc}")
        return 1

    report_entries: list[dict[str, Any]] = []
    skipped_files: list[dict[str, str]] = []
    matrix_buckets: dict[str, list[dict[str, Any]]] = defaultdict(list)
    runtime_pair_counts: Counter[str] = Counter()
    comparison_status_counts: Counter[str] = Counter()
    claim_status_counts: Counter[str] = Counter()

    for source_path in sources:
        if is_scratch_namespace_path(source_path):
            skipped_files.append(
                {
                    "path": str(source_path),
                    "reason": "scratch namespace (excluded from baseline dataset)",
                }
            )
            continue
        if not source_path.exists():
            skipped_files.append({"path": str(source_path), "reason": "missing"})
            continue
        try:
            payload = load_json(source_path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            skipped_files.append({"path": str(source_path), "reason": f"parse failed: {exc}"})
            continue

        conformant, reason = report_conformance.validate_report_conformance(
            payload=payload,
            report_path=source_path,
            repo_root=repo_root,
            expected_obligation_schema_version=obligation_schema_version,
            expected_obligation_ids=obligation_ids,
        )
        if not conformant:
            skipped_files.append(
                {
                    "path": str(source_path),
                    "reason": f"non-conformant compare report: {reason}",
                }
            )
            continue
        claim_report, _claim_report_path = artifacts_mod.load_optional_claim_report(
            source_path
        )
        workloads = payload.get("workloads")
        comparison_status = payload.get("comparisonStatus")
        claim_status = artifacts_mod.claim_status(payload, claim_report)
        if not isinstance(workloads, list):
            skipped_files.append({"path": str(source_path), "reason": "missing workloads list"})
            continue
        if not isinstance(comparison_status, str) or not comparison_status:
            skipped_files.append({"path": str(source_path), "reason": "missing comparisonStatus"})
            continue
        if not isinstance(claim_status, str) or not claim_status:
            skipped_files.append({"path": str(source_path), "reason": "missing claimStatus"})
            continue

        generated_at = parse_report_timestamp(payload, source_path)
        generated_at_utc = iso_utc(generated_at)
        matrix_id = normalize_matrix_id(payload, source_path)
        participants = payload.get("participants")
        if not isinstance(participants, dict):
            participants = {}
        left = participants.get("left")
        right = participants.get("right")
        if not isinstance(left, dict):
            left = {}
        if not isinstance(right, dict):
            right = {}
        baseline_name = str(left.get("product", "baseline"))
        comparison_name = str(right.get("product", "comparison"))
        runtime_pair = f"{baseline_name}→{comparison_name}"
        entry = {
            "sourcePath": str(source_path),
            "matrixId": matrix_id,
            "runtimePair": runtime_pair,
            "baselineName": baseline_name,
            "comparisonName": comparison_name,
            "generatedAtUtc": generated_at_utc,
            "comparisonStatus": comparison_status,
            "claimStatus": claim_status,
            "workloadCount": len(workloads),
            "nonComparableCount": count_non_comparable(payload),
            "nonClaimableCount": artifacts_mod.non_claimable_count(payload, claim_report),
            "overallP50DeltaPercent": derive_overall_p50_delta(payload),
            "outputTimestamp": payload.get("outputTimestamp", ""),
        }
        report_entries.append(entry)
        matrix_buckets[matrix_id].append(entry)
        runtime_pair_counts[runtime_pair] += 1
        comparison_status_counts[comparison_status] += 1
        claim_status_counts[claim_status] += 1

    if not report_entries:
        print("FAIL: no baseline-eligible reports after filtering")
        return 1

    report_entries.sort(key=lambda item: str(item.get("generatedAtUtc", "")), reverse=True)
    matrix_trends: list[dict[str, Any]] = []
    for matrix_id, entries in matrix_buckets.items():
        ordered = sorted(entries, key=lambda item: str(item.get("generatedAtUtc", "")))
        latest = ordered[-1]
        deltas = [safe_float(item.get("overallP50DeltaPercent")) for item in ordered]
        numeric_deltas = [value for value in deltas if value is not None]
        matrix_trends.append(
            {
                "matrixId": matrix_id,
                "runtimePair": str(latest.get("runtimePair", "")),
                "reportCount": len(ordered),
                "latest": latest,
                "firstSeenUtc": str(ordered[0].get("generatedAtUtc", "")),
                "lastSeenUtc": str(latest.get("generatedAtUtc", "")),
                "bestP50DeltaPercent": max(numeric_deltas) if numeric_deltas else None,
                "worstP50DeltaPercent": min(numeric_deltas) if numeric_deltas else None,
                "series": ordered,
            }
        )
    matrix_trends.sort(key=lambda item: str(item.get("matrixId", "")))

    summary = {
        "totalMatchedFiles": len(sources),
        "includedReports": len(report_entries),
        "skippedFiles": len(skipped_files),
        "matrixCount": len(matrix_trends),
        "runtimePairCount": len(runtime_pair_counts),
        "comparableReportCount": comparison_status_counts.get("comparable", 0),
        "claimableReportCount": claim_status_counts.get("claimable", 0),
        "comparisonStatusCounts": dict(sorted(comparison_status_counts.items())),
        "claimStatusCounts": dict(sorted(claim_status_counts.items())),
        "runtimePairCounts": dict(sorted(runtime_pair_counts.items())),
    }

    output_timestamp = (
        output_paths.resolve_timestamp(args.timestamp)
        if args.timestamp_output
        else ""
    )
    out_path = output_paths.with_timestamp(
        args.out,
        output_timestamp,
        enabled=args.timestamp_output,
    )
    summary_md_path = output_paths.with_timestamp(
        args.summary_md_out,
        output_timestamp,
        enabled=args.timestamp_output,
    )
    latest_out = Path(args.latest_out)
    latest_summary_md = Path(args.latest_summary_md_out)

    payload = {
        "schemaVersion": 1,
        "generatedAtUtc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "outputTimestamp": output_timestamp,
        "datasetPath": str(out_path),
        "source": {
            "reportGlobs": patterns,
            "explicitReports": args.report,
        },
        "summary": summary,
        "matrixTrends": matrix_trends,
        "reports": report_entries,
        "skippedFiles": skipped_files,
    }
    md = build_markdown_summary(payload)

    write_json(out_path, payload)
    write_text(summary_md_path, md)
    write_json(latest_out, payload)
    write_text(latest_summary_md, md)
    output_paths.write_run_manifest_for_outputs(
        [out_path, summary_md_path],
        {
            "runType": "baseline_dataset",
            "config": {
                "reportGlobs": patterns,
                "explicitReports": args.report,
            },
            "fullRun": True,
            "claimGateRan": False,
            "dropinGateRan": False,
            "datasetPath": str(out_path),
            "summaryPath": str(summary_md_path),
            "status": "passed",
        },
    )

    print("PASS: built baseline dataset")
    print(f"dataset: {out_path}")
    print(f"summary: {summary_md_path}")
    print(f"latest dataset: {latest_out}")
    print(f"latest summary: {latest_summary_md}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
