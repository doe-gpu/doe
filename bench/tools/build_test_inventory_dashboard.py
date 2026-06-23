#!/usr/bin/env python3
"""Build a canonical tested-profile inventory and a simple matrix dashboard."""

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
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from glob import glob
from typing import Any

from bench.lib import compare_claim_artifacts as artifacts_mod
from bench.lib import inventory_dashboard_html
from bench.lib import output_paths
from bench.lib import report_conformance


TIMESTAMP_SUFFIX_RE = re.compile(r"\d{8}T\d{6}Z$")


@dataclass(frozen=True)
class SideProfile:
    profile_id: str
    vendor: str
    api: str
    device_family: str
    driver: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--report-glob",
        action="append",
        default=[],
        help=(
            "Glob for compare reports. "
            "May be repeated. Default: bench/out/**/dawn-vs-doe*.json"
        ),
    )
    parser.add_argument(
        "--report",
        action="append",
        default=[],
        help="Explicit compare report path. May be repeated.",
    )
    parser.add_argument(
        "--inventory-out",
        default="bench/out/test-inventory.json",
        help="Output JSON inventory path.",
    )
    parser.add_argument(
        "--dashboard-out",
        default="",
        help="Optional HTML dashboard path. Leave empty to emit JSON only.",
    )
    parser.add_argument(
        "--latest-inventory",
        default="bench/out/test-inventory.latest.json",
        help="Stable latest inventory JSON path (always overwritten).",
    )
    parser.add_argument(
        "--latest-dashboard",
        default="",
        help="Optional stable latest dashboard HTML path. Leave empty to skip HTML output.",
    )
    parser.add_argument(
        "--max-recent-reports",
        type=int,
        default=30,
        help="Maximum number of recent reports shown in dashboard.",
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
        help="Stamp inventory/dashboard output paths with a UTC timestamp suffix.",
    )
    parser.add_argument(
        "--comparability-obligations",
        default="config/comparability-obligations.json",
        help="Canonical comparability-obligation contract used for report conformance checks.",
    )
    return parser.parse_args()


def safe_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    if parsed != parsed:
        return None
    return parsed


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


def parse_report_timestamp(payload: dict[str, Any], source_path: Path) -> datetime | None:
    generated = parse_utc_iso(payload.get("generatedAt"))
    if generated is not None:
        return generated

    output_timestamp = payload.get("outputTimestamp")
    if isinstance(output_timestamp, str):
        try:
            return datetime.strptime(output_timestamp, output_paths.TIMESTAMP_FORMAT).replace(tzinfo=timezone.utc)
        except ValueError:
            pass

    stem = source_path.stem
    parts = stem.split(".")
    if parts and TIMESTAMP_SUFFIX_RE.fullmatch(parts[-1]):
        try:
            return datetime.strptime(parts[-1], output_paths.TIMESTAMP_FORMAT).replace(tzinfo=timezone.utc)
        except ValueError:
            return None
    return None


def iso_utc(dt: datetime | None) -> str:
    if dt is None:
        return ""
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


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


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"invalid JSON object: {path}")
    return payload


def should_include_report(
    *,
    payload: dict[str, Any],
    source_path: Path,
    repo_root: Path,
    obligation_schema_version: int,
    obligation_ids: set[str],
) -> tuple[bool, str]:
    return report_conformance.validate_report_conformance(
        payload=payload,
        report_path=source_path,
        repo_root=repo_root,
        expected_obligation_schema_version=obligation_schema_version,
        expected_obligation_ids=obligation_ids,
    )


def side_name(payload: dict[str, Any], side: str) -> str:
    participants = payload.get("participants")
    if not isinstance(participants, dict):
        return side
    participant_key = "left" if side == "baseline" else "right"
    side_payload = participants.get(participant_key)
    if isinstance(side_payload, dict):
        name = side_payload.get("product")
        if isinstance(name, str) and name.strip():
            return name.strip()
    return side


def read_trace_meta(sample: dict[str, Any], cache: dict[str, dict[str, Any] | None]) -> dict[str, Any] | None:
    inline = sample.get("traceMeta")
    if isinstance(inline, dict):
        return inline

    trace_meta_path = sample.get("traceMetaPath")
    if not isinstance(trace_meta_path, str) or not trace_meta_path.strip():
        return None
    if trace_meta_path in cache:
        return cache[trace_meta_path]
    path = Path(trace_meta_path)
    if not path.exists():
        cache[trace_meta_path] = None
        return None
    try:
        parsed = load_json(path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        cache[trace_meta_path] = None
        return None
    cache[trace_meta_path] = parsed
    return parsed


def extract_side_profiles(
    payload: dict[str, Any],
    side: str,
    report_path: Path,
    receipt_cache: dict[str, dict[str, Any]],
) -> tuple[list[SideProfile], int]:
    workloads = payload.get("workloads")
    if not isinstance(workloads, list):
        return [], 0

    profiles: dict[str, SideProfile] = {}
    sample_count = 0
    for workload in workloads:
        if not isinstance(workload, dict):
            continue
        try:
            left_receipt, right_receipt = artifacts_mod.load_workload_receipts(
                workload,
                report_path,
                cache=receipt_cache,
            )
        except (FileNotFoundError, ValueError):
            continue
        receipt = left_receipt if side == "baseline" else right_receipt
        samples = receipt.get("samples")
        if not isinstance(samples, list):
            continue
        for sample in samples:
            if not isinstance(sample, dict):
                continue
            return_code = sample.get("returnCode")
            if not isinstance(return_code, int) or return_code != 0:
                continue
            trace_meta = sample.get("traceMeta")
            if not isinstance(trace_meta, dict):
                continue
            profile = trace_meta.get("profile")
            if not isinstance(profile, dict):
                continue
            vendor = profile.get("vendor")
            api = profile.get("api")
            driver = profile.get("driver")
            if not isinstance(vendor, str) or not vendor.strip():
                continue
            if not isinstance(api, str) or not api.strip():
                continue
            if not isinstance(driver, str) or not driver.strip():
                continue
            family_raw = profile.get("deviceFamily")
            family = family_raw.strip() if isinstance(family_raw, str) else ""
            profile_id = f"{vendor.strip()}|{api.strip()}|{family}|{driver.strip()}"
            profiles[profile_id] = SideProfile(
                profile_id=profile_id,
                vendor=vendor.strip(),
                api=api.strip(),
                device_family=family,
                driver=driver.strip(),
            )
            sample_count += 1
    return sorted(profiles.values(), key=lambda item: item.profile_id), sample_count


def derive_overall_delta_p50(payload: dict[str, Any]) -> float | None:
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
    comparability_summary = payload.get("comparabilitySummary")
    from_summary = get_count(comparability_summary, "nonComparableCount")
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
    return 0


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


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


def main() -> int:
    args = parse_args()
    if args.max_recent_reports < 0:
        print(f"FAIL: --max-recent-reports must be >= 0 (received {args.max_recent_reports})")
        return 1

    report_patterns = args.report_glob if args.report_glob else ["bench/out/**/dawn-vs-doe*.json"]
    sources = collect_paths(report_patterns, args.report)
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

    meta_cache: dict[str, dict[str, Any] | None] = {}
    receipt_cache: dict[str, dict[str, Any]] = {}
    skipped_files: list[dict[str, str]] = []
    report_entries: list[dict[str, Any]] = []

    profile_agg: dict[str, dict[str, Any]] = {}
    matrix_agg: dict[str, list[dict[str, Any]]] = {}

    for source_path in sources:
        if is_scratch_namespace_path(source_path):
            skipped_files.append(
                {
                    "path": str(source_path),
                    "reason": "scratch namespace (excluded from canonical inventory)",
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

        include, reason = should_include_report(
            payload=payload,
            source_path=source_path,
            repo_root=repo_root,
            obligation_schema_version=obligation_schema_version,
            obligation_ids=obligation_ids,
        )
        if not include:
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

        generated_at = parse_report_timestamp(payload, source_path)
        generated_at_utc = iso_utc(generated_at)
        matrix_id = normalize_matrix_id(payload, source_path)
        workloads = payload.get("workloads")
        workload_count = len(workloads) if isinstance(workloads, list) else 0
        comparison_status = str(payload.get("comparisonStatus", "unknown"))
        claim_status = artifacts_mod.claim_status(payload, claim_report)
        overall_p50_delta = derive_overall_delta_p50(payload)
        non_comparable_count = count_non_comparable(payload)
        non_claimable_count = artifacts_mod.non_claimable_count(payload, claim_report)
        baseline_name = side_name(payload, "baseline")
        comparison_name = side_name(payload, "comparison")

        baseline_profiles, baseline_samples = extract_side_profiles(
            payload,
            "baseline",
            source_path,
            receipt_cache,
        )
        comparison_profiles, comparison_samples = extract_side_profiles(
            payload,
            "comparison",
            source_path,
            receipt_cache,
        )

        if baseline_profiles and comparison_profiles:
            baseline_apis = {profile.api for profile in baseline_profiles}
            comparison_apis = {profile.api for profile in comparison_profiles}
            if baseline_apis != comparison_apis:
                skipped_files.append(
                    {
                        "path": str(source_path),
                        "reason": f"API mismatch: baseline={baseline_apis}, comparison={comparison_apis}",
                    }
                )
                continue

        entry = {
            "sourcePath": str(source_path),
            "outPath": payload.get("outPath", ""),
            "matrixId": matrix_id,
            "lane": inventory_dashboard_html.infer_matrix_lane(matrix_id),
            "generatedAtUtc": generated_at_utc,
            "comparisonStatus": comparison_status,
            "claimStatus": claim_status,
            "workloadCount": workload_count,
            "nonComparableCount": non_comparable_count,
            "nonClaimableCount": non_claimable_count,
            "overallP50DeltaPercent": overall_p50_delta,
            "baselineName": baseline_name,
            "comparisonName": comparison_name,
            "baselineProfiles": [profile.profile_id for profile in baseline_profiles],
            "comparisonProfiles": [profile.profile_id for profile in comparison_profiles],
            "baselineProfileSampleCount": baseline_samples,
            "comparisonProfileSampleCount": comparison_samples,
        }
        report_entries.append(entry)
        matrix_agg.setdefault(matrix_id, []).append(entry)

        for side_label, runtime_name, side_profiles, sample_count in (
            ("baseline", baseline_name, baseline_profiles, baseline_samples),
            ("comparison", comparison_name, comparison_profiles, comparison_samples),
        ):
            per_profile_samples = sample_count // max(len(side_profiles), 1) if side_profiles else 0
            for profile in side_profiles:
                agg = profile_agg.get(profile.profile_id)
                if agg is None:
                    agg = {
                        "profileId": profile.profile_id,
                        "vendor": profile.vendor,
                        "api": profile.api,
                        "deviceFamily": profile.device_family,
                        "driver": profile.driver,
                        "reportPaths": set(),
                        "matrixIds": set(),
                        "sides": set(),
                        "runtimes": set(),
                        "sampleCount": 0,
                        "firstSeen": generated_at,
                        "lastSeen": generated_at,
                    }
                    profile_agg[profile.profile_id] = agg
                agg["reportPaths"].add(str(source_path))
                agg["matrixIds"].add(matrix_id)
                agg["sides"].add(side_label)
                agg["runtimes"].add(runtime_name)
                agg["sampleCount"] += max(per_profile_samples, 1)
                first_seen = agg.get("firstSeen")
                last_seen = agg.get("lastSeen")
                if isinstance(generated_at, datetime):
                    if not isinstance(first_seen, datetime) or generated_at < first_seen:
                        agg["firstSeen"] = generated_at
                    if not isinstance(last_seen, datetime) or generated_at > last_seen:
                        agg["lastSeen"] = generated_at

    if not report_entries:
        print("FAIL: no comparable-report artifacts found after filtering")
        return 1

    report_entries.sort(key=lambda item: item.get("generatedAtUtc", ""), reverse=True)

    matrix_entries: list[dict[str, Any]] = []
    for matrix_id, entries in matrix_agg.items():
        entries_sorted = sorted(entries, key=lambda item: str(item.get("generatedAtUtc", "")), reverse=True)
        latest = entries_sorted[0]
        comparison_counts = Counter(str(item.get("comparisonStatus", "unknown")) for item in entries_sorted)
        claim_counts = Counter(str(item.get("claimStatus", "unknown")) for item in entries_sorted)
        matrix_entries.append(
            {
                "matrixId": matrix_id,
                "lane": inventory_dashboard_html.infer_matrix_lane(matrix_id),
                "reportCount": len(entries_sorted),
                "comparisonStatusCounts": dict(sorted(comparison_counts.items())),
                "claimStatusCounts": dict(sorted(claim_counts.items())),
                "latest": latest,
            }
        )
    matrix_entries.sort(key=lambda item: str(item.get("matrixId", "")))

    profile_entries: list[dict[str, Any]] = []
    for agg in profile_agg.values():
        report_paths = agg["reportPaths"]
        matrix_ids = agg["matrixIds"]
        sides = agg["sides"]
        runtimes = agg["runtimes"]
        profile_entries.append(
            {
                "profileId": agg["profileId"],
                "vendor": agg["vendor"],
                "api": agg["api"],
                "deviceFamily": agg["deviceFamily"],
                "driver": agg["driver"],
                "reportCount": len(report_paths),
                "matrixCount": len(matrix_ids),
                "sampleCount": agg["sampleCount"],
                "sides": sorted(sides),
                "runtimes": sorted(runtimes),
                "firstSeenUtc": iso_utc(agg.get("firstSeen")),
                "lastSeenUtc": iso_utc(agg.get("lastSeen")),
                "reportPaths": sorted(report_paths),
                "matrixIds": sorted(matrix_ids),
            }
        )
    profile_entries.sort(key=lambda item: str(item.get("profileId", "")))

    comparison_counter = Counter(str(item.get("comparisonStatus", "unknown")) for item in report_entries)
    claim_counter = Counter(str(item.get("claimStatus", "unknown")) for item in report_entries)
    claimable_comparable_report_count = sum(
        1
        for item in report_entries
        if str(item.get("comparisonStatus", "")) == "comparable"
        and str(item.get("claimStatus", "")) == "claimable"
    )
    latest_comparable_matrix_count = sum(
        1
        for matrix in matrix_entries
        if isinstance(matrix, dict)
        and isinstance(matrix.get("latest"), dict)
        and str(matrix["latest"].get("comparisonStatus", "")) == "comparable"
    )
    latest_claimable_matrix_count = sum(
        1
        for matrix in matrix_entries
        if isinstance(matrix, dict)
        and isinstance(matrix.get("latest"), dict)
        and str(matrix["latest"].get("claimStatus", "")) == "claimable"
    )
    summary = {
        "totalMatchedFiles": len(sources),
        "includedReports": len(report_entries),
        "skippedFiles": len(skipped_files),
        "matrixCount": len(matrix_entries),
        "uniqueProfileCount": len(profile_entries),
        "comparableReportCount": comparison_counter.get("comparable", 0),
        "claimableReportCount": claim_counter.get("claimable", 0),
        "claimableComparableReportCount": claimable_comparable_report_count,
        "latestComparableMatrixCount": latest_comparable_matrix_count,
        "latestClaimableMatrixCount": latest_claimable_matrix_count,
        "comparisonStatusCounts": dict(sorted(comparison_counter.items())),
        "claimStatusCounts": dict(sorted(claim_counter.items())),
    }

    generated_at_utc = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    output_timestamp = (
        output_paths.resolve_timestamp(args.timestamp)
        if args.timestamp_output
        else ""
    )
    inventory_out = output_paths.with_timestamp(
        args.inventory_out,
        output_timestamp,
        enabled=args.timestamp_output,
    )
    dashboard_out = (
        output_paths.with_timestamp(
            args.dashboard_out,
            output_timestamp,
            enabled=args.timestamp_output,
        )
        if args.dashboard_out.strip()
        else None
    )
    latest_inventory = Path(args.latest_inventory)
    latest_dashboard = Path(args.latest_dashboard) if args.latest_dashboard.strip() else None

    inventory_payload = {
        "schemaVersion": 1,
        "generatedAtUtc": generated_at_utc,
        "outputTimestamp": output_timestamp,
        "inventoryPath": str(inventory_out),
        "source": {
            "reportGlobs": report_patterns,
            "explicitReports": args.report,
        },
        "summary": summary,
        "matrices": matrix_entries,
        "profiles": profile_entries,
        "reports": report_entries,
        "skippedFiles": skipped_files,
    }
    write_json(inventory_out, inventory_payload)
    write_json(latest_inventory, inventory_payload)
    if dashboard_out is not None or latest_dashboard is not None:
        dashboard_html = inventory_dashboard_html.build_dashboard_html(
            inventory_payload,
            max_recent_reports=args.max_recent_reports,
            dashboard_path=dashboard_out or latest_dashboard or inventory_out,
        )
        if dashboard_out is not None:
            write_text(dashboard_out, dashboard_html)
        if latest_dashboard is not None:
            write_text(latest_dashboard, dashboard_html)
    emitted_outputs = [inventory_out]
    if dashboard_out is not None:
        emitted_outputs.append(dashboard_out)
    output_paths.write_run_manifest_for_outputs(
        emitted_outputs,
        {
            "runType": "inventory_dashboard",
            "config": {
                "reportGlobs": report_patterns,
                "explicitReports": args.report,
            },
            "fullRun": True,
            "claimGateRan": False,
            "dropinGateRan": False,
            "inventoryPath": str(inventory_out),
            "dashboardPath": str(dashboard_out) if dashboard_out is not None else "",
            "status": "passed",
        },
    )

    print("PASS: built test inventory")
    print(f"inventory: {inventory_out}")
    print(f"latest inventory: {latest_inventory}")
    if dashboard_out is not None:
        print(f"dashboard: {dashboard_out}")
    if latest_dashboard is not None:
        print(f"latest dashboard: {latest_dashboard}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
