#!/usr/bin/env python3
"""Audit local Dawn/Tint-facing claim sidecars for promotion candidates."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

from bench.lib.bench_utils import (  # noqa: E402
    detect_repo_root,
    load_json_object,
    unsafe_repo_path_reason,
    write_json_object,
)


CLAIM_REPORT_KIND = "claim-report"
COMPARE_REPORT_KIND = "compare-report"
CLAIMABLE_STATUS = "claimable"
COMPARABLE_STATUS = "comparable"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        default="",
        help="Repository root. Auto-detected when omitted.",
    )
    parser.add_argument(
        "--scan-root",
        action="append",
        default=[],
        help=(
            "Directory to scan relative to the repository root. "
            "Can be passed more than once. Defaults to bench/out."
        ),
    )
    parser.add_argument(
        "--claim-index",
        default="reports/claim-index.json",
        help="Claim index path relative to the repository root.",
    )
    parser.add_argument(
        "--frontier",
        default="config/dawn-replacement-frontier.json",
        help="Dawn replacement frontier path relative to the repository root.",
    )
    parser.add_argument(
        "--out",
        default="",
        help="Optional JSON report output path relative to the repository root.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def repo_relative(root: Path, path: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def path_is_under(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(f"{prefix}/")


def iter_claim_json_paths(root: Path, scan_roots: list[str]) -> list[Path]:
    paths: list[Path] = []
    for scan_root in scan_roots or ["bench/out"]:
        reason = unsafe_repo_path_reason(scan_root, allow_empty=False)
        if reason:
            raise ValueError(f"invalid --scan-root {scan_root!r}: {reason}")
        base = root / scan_root
        if not base.exists():
            continue
        if not base.is_dir():
            raise ValueError(f"scan root is not a directory: {scan_root}")
        paths.extend(
            path
            for path in base.rglob("*.json")
            if "claim" in path.name.lower()
        )
    return sorted(set(paths), key=lambda path: repo_relative(root, path))


def claim_entries_by_path(
    claim_index: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    by_claim_path: dict[str, dict[str, Any]] = {}
    by_report_path: dict[str, dict[str, Any]] = {}
    for entry in claim_index.get("entries", []):
        if not isinstance(entry, dict):
            continue
        claim_path = entry.get("claimPath")
        report_path = entry.get("reportPath")
        if isinstance(claim_path, str) and claim_path:
            by_claim_path[claim_path] = entry
        if isinstance(report_path, str) and report_path:
            by_report_path[report_path] = entry
    return by_claim_path, by_report_path


def frontier_rows_by_id(frontier: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows = frontier.get("rows", [])
    if not isinstance(rows, list):
        return {}
    return {
        row["id"]: row
        for row in rows
        if isinstance(row, dict) and isinstance(row.get("id"), str)
    }


def infer_frontier_rows(
    claim_path: str,
    claim: dict[str, Any],
    known_rows: set[str],
) -> list[dict[str, str]]:
    haystack_values = [
        claim_path,
        str(claim.get("compareConfigPath", "")),
        str(claim.get("target", "")),
    ]
    compare_report = claim.get("compareReport")
    if isinstance(compare_report, dict):
        haystack_values.append(str(compare_report.get("path", "")))
    haystack = " ".join(haystack_values).lower()

    checks = [
        (
            "native-metal-runtime",
            ("apple.metal", "apple-metal", "metal"),
            "path-or-target mentions Apple Metal",
        ),
        (
            "native-vulkan-runtime",
            ("amd.vulkan", "amd-vulkan", "vulkan"),
            "path-or-target mentions Vulkan",
        ),
        (
            "native-d3d12-runtime",
            ("d3d12", "dxil"),
            "path-or-target mentions D3D12/DXIL",
        ),
        (
            "package-node-runtime",
            ("node-package", "node_webgpu", "node-webgpu", "node_ort"),
            "path-or-target mentions Node package/WebGPU",
        ),
        (
            "package-bun-runtime",
            ("bun-package", "bun_webgpu", "bun-webgpu", "bun_ort"),
            "path-or-target mentions Bun package/WebGPU",
        ),
        (
            "package-deno-runtime",
            ("deno",),
            "path-or-target mentions Deno",
        ),
        (
            "browser-chromium-runtime",
            ("browser", "chromium"),
            "path-or-target mentions browser/Chromium",
        ),
        (
            "wgsl-tint-compiler",
            ("tint", "doe-vs-tint", "msl", "spv", "spirv"),
            "path-or-target mentions Tint/compiler output",
        ),
        (
            "drop-in-abi-runtime",
            ("drop-in", "dropin", "libwebgpu"),
            "path-or-target mentions drop-in/libwebgpu",
        ),
    ]
    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    for row_id, terms, reason in checks:
        if row_id not in known_rows:
            continue
        if row_id in seen:
            continue
        if any(term in haystack for term in terms):
            rows.append({"id": row_id, "reason": reason})
            seen.add(row_id)
    return rows


def compare_report_path(claim: dict[str, Any]) -> str:
    compare_report = claim.get("compareReport")
    if not isinstance(compare_report, dict):
        return ""
    path = compare_report.get("path")
    return path if isinstance(path, str) else ""


def load_compare_report(root: Path, path: str) -> tuple[dict[str, Any] | None, str]:
    reason = unsafe_repo_path_reason(path, allow_empty=False)
    if reason:
        return None, f"unsafe_compare_report_path: {reason}"
    compare_path = root / path
    if not compare_path.exists():
        return None, "compare_report_missing"
    try:
        report = load_json_object(compare_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        return None, f"compare_report_parse_failed: {exc}"
    if report.get("artifactKind") != COMPARE_REPORT_KIND:
        return None, "compare_report_invalid_kind"
    return report, ""


def status_for_candidate(
    claim_path: str,
    claim: dict[str, Any],
    compare_status: str,
    frontier_reasons: list[str],
    indexed_entry: dict[str, Any] | None,
) -> tuple[str, list[str], bool]:
    reasons: list[str] = []
    if indexed_entry is not None and indexed_entry.get("claimState") == "claim-indexed":
        return "already_indexed", reasons, False

    if claim.get("comparisonStatus") != COMPARABLE_STATUS:
        reasons.append("claim_comparison_status_not_comparable")
    if claim.get("claimStatus") != CLAIMABLE_STATUS:
        reasons.append("claim_status_not_claimable")
    if claim.get("pass") is not True:
        reasons.append("claim_sidecar_not_passing")
    if path_is_under(claim_path, "bench/out/scratch"):
        reasons.append("scratch_artifact")
    reasons.extend(frontier_reasons)

    report_path = compare_report_path(claim)
    if not report_path:
        reasons.append("missing_compare_report_path")
    elif compare_status:
        reasons.append(compare_status)

    if reasons:
        if (
            set(reasons)
            <= {
                "claim_comparison_status_not_comparable",
                "claim_status_not_claimable",
                "claim_sidecar_not_passing",
            }
        ):
            return "diagnostic", reasons, False
        return "blocked", reasons, False
    return "index_ready", reasons, True


def build_candidate(
    root: Path,
    path: Path,
    claim: dict[str, Any],
    by_claim_path: dict[str, dict[str, Any]],
    by_report_path: dict[str, dict[str, Any]],
    known_frontier_rows: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    claim_path = repo_relative(root, path)
    report_path = compare_report_path(claim)
    indexed_entry = by_claim_path.get(claim_path)
    if indexed_entry is None and report_path:
        indexed_entry = by_report_path.get(report_path)

    compare_status = ""
    compare_kind = ""
    if report_path:
        compare, compare_status = load_compare_report(root, report_path)
        if compare is not None:
            compare_kind = str(compare.get("artifactKind", ""))

    inferred_rows = infer_frontier_rows(
        claim_path,
        claim,
        set(known_frontier_rows),
    )
    frontier_reasons: list[str] = []
    frontier_blockers: list[dict[str, Any]] = []
    for inferred_row in inferred_rows:
        row_id = inferred_row.get("id")
        frontier_row = known_frontier_rows.get(str(row_id), {})
        if frontier_row.get("claimAllowed") is True:
            continue
        blockers = frontier_row.get("blockers", [])
        if not isinstance(blockers, list):
            blockers = []
        frontier_reasons.append(f"frontier_row_not_claim_allowed:{row_id}")
        frontier_blockers.append(
            {
                "id": row_id,
                "blockers": [
                    blocker for blocker in blockers if isinstance(blocker, str)
                ],
            }
        )

    status, reasons, index_ready = status_for_candidate(
        claim_path,
        claim,
        compare_status,
        frontier_reasons,
        indexed_entry,
    )
    indexed_ids: list[str] = []
    if indexed_entry is not None and isinstance(indexed_entry.get("id"), str):
        indexed_ids.append(indexed_entry["id"])

    return {
        "claimPath": claim_path,
        "compareReportPath": report_path,
        "comparisonStatus": claim.get("comparisonStatus", ""),
        "claimStatus": claim.get("claimStatus", ""),
        "pass": claim.get("pass") is True,
        "generatedAt": claim.get("generatedAt", ""),
        "promotionStatus": status,
        "indexReady": index_ready,
        "reasons": reasons,
        "indexedClaimIds": indexed_ids,
        "compareReportKind": compare_kind,
        "inferredFrontierRows": inferred_rows,
        "frontierBlockers": frontier_blockers,
    }


def summary_for_candidates(
    scanned_json_count: int,
    parse_failure_count: int,
    candidates: list[dict[str, Any]],
) -> dict[str, int]:
    def count_status(status: str) -> int:
        return sum(1 for item in candidates if item.get("promotionStatus") == status)

    return {
        "scannedJsonCount": scanned_json_count,
        "parseFailureCount": parse_failure_count,
        "claimReportCount": len(candidates),
        "indexReadyCount": sum(1 for item in candidates if item.get("indexReady") is True),
        "alreadyIndexedCount": count_status("already_indexed"),
        "blockedCount": count_status("blocked"),
        "diagnosticCount": count_status("diagnostic"),
    }


def build_audit(
    root: Path,
    claim_index: dict[str, Any],
    frontier: dict[str, Any],
    scan_roots: list[str] | None = None,
) -> dict[str, Any]:
    paths = iter_claim_json_paths(root, scan_roots or ["bench/out"])
    by_claim_path, by_report_path = claim_entries_by_path(claim_index)
    known_rows = frontier_rows_by_id(frontier)
    candidates: list[dict[str, Any]] = []
    parse_failures: list[dict[str, str]] = []

    for path in paths:
        rel_path = repo_relative(root, path)
        try:
            payload = load_json_object(path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            parse_failures.append({"path": rel_path, "reason": str(exc)})
            continue
        if payload.get("artifactKind") != CLAIM_REPORT_KIND:
            continue
        candidates.append(
            build_candidate(
                root,
                path,
                payload,
                by_claim_path,
                by_report_path,
                known_rows,
            )
        )

    candidates.sort(
        key=lambda item: (
            str(item.get("promotionStatus", "")),
            str(item.get("claimPath", "")),
        )
    )
    return {
        "schemaVersion": 1,
        "artifactKind": "dawn-claim-candidate-audit",
        "summary": summary_for_candidates(
            len(paths),
            len(parse_failures),
            candidates,
        ),
        "scanRoots": scan_roots or ["bench/out"],
        "parseFailures": parse_failures,
        "candidates": candidates,
    }


def emit_text(report: dict[str, Any]) -> None:
    summary = report["summary"]
    print(
        "Dawn claim candidate audit: "
        f"{summary['indexReadyCount']} index-ready, "
        f"{summary['alreadyIndexedCount']} already indexed, "
        f"{summary['blockedCount']} blocked, "
        f"{summary['diagnosticCount']} diagnostic."
    )
    for item in report["candidates"]:
        if item.get("promotionStatus") not in ("index_ready", "blocked"):
            continue
        frontier_rows = [
            row["id"]
            for row in item.get("inferredFrontierRows", [])
            if isinstance(row, dict) and row.get("id")
        ]
        row_text = ", ".join(frontier_rows) if frontier_rows else "unmapped"
        reason_text = ", ".join(item.get("reasons", []))
        if not reason_text:
            reason_text = "ready for claim-index review"
        print(
            f"- {item['promotionStatus']}: {item['claimPath']} "
            f"({row_text}) -- {reason_text}"
        )


def main() -> int:
    args = parse_args()
    try:
        root = detect_repo_root(args.root)
        claim_index = load_json_object(root / args.claim_index)
        frontier = load_json_object(root / args.frontier)
        report = build_audit(root, claim_index, frontier, args.scan_root or ["bench/out"])
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: Dawn claim candidate audit input error: {exc}")
        return 1

    if args.out:
        write_json_object(root / args.out, report)
    if args.emit_json:
        print(json.dumps(report, indent=2))
    else:
        emit_text(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
