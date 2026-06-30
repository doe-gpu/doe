#!/usr/bin/env python3
"""Build a Dawn/Tint replacement readiness report from gated frontier data."""

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

from bench.gates import dawn_replacement_frontier_gate as frontier_gate
from bench.lib.bench_utils import detect_repo_root, load_json_object, write_json_object


PRODUCT_SURFACES = {
    "native_runtime",
    "package_runtime",
    "browser_runtime",
    "shader_compiler",
    "spec_conformance",
    "drop_in_runtime",
}
BROWSER_FRONTIER_ROW_ID = "browser-chromium-runtime"
BROWSER_FRONTIER_BUNDLE_PATH = Path("examples/browser-runtime-frontier-bundle.sample.json")
BROWSER_FRONTIER_BUNDLE_KIND = "browser_runtime_frontier_bundle"
TINT_FRONTIER_ROW_ID = "wgsl-tint-compiler"
TINT_FRONTIER_BUNDLE_PATH = Path("examples/tint-compiler-frontier-bundle.sample.json")
TINT_FRONTIER_BUNDLE_KIND = "tint_compiler_frontier_bundle"
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        default="",
        help="Repository root. Auto-detected when omitted.",
    )
    parser.add_argument(
        "--frontier",
        default="config/dawn-replacement-frontier.json",
        help="Dawn replacement frontier path relative to the repository root.",
    )
    parser.add_argument(
        "--schema",
        default="config/dawn-replacement-frontier.schema.json",
        help="Dawn replacement frontier schema path relative to the repository root.",
    )
    parser.add_argument(
        "--claim-index",
        default="reports/claim-index.json",
        help="Claim index path relative to the repository root.",
    )
    parser.add_argument(
        "--browser-frontier-bundle",
        default=str(BROWSER_FRONTIER_BUNDLE_PATH),
        help="Browser runtime frontier bundle path relative to the repository root.",
    )
    parser.add_argument(
        "--tint-frontier-bundle",
        default=str(TINT_FRONTIER_BUNDLE_PATH),
        help="Tint compiler frontier bundle path relative to the repository root.",
    )
    parser.add_argument(
        "--out",
        default="",
        help="Optional JSON report output path relative to the repository root.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def blocker_map(frontier: dict[str, Any]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    definitions = frontier.get("blockerDefinitions", [])
    if not isinstance(definitions, list):
        return out
    for definition in definitions:
        if not isinstance(definition, dict):
            continue
        code = definition.get("code")
        if isinstance(code, str) and code:
            out[code] = definition
    return out


def claim_entry_map(claim_index: dict[str, Any]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    entries = claim_index.get("entries", [])
    if not isinstance(entries, list):
        return out
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        entry_id = entry.get("id")
        if isinstance(entry_id, str) and entry_id:
            out[entry_id] = entry
    return out


def compact_blocker(
    code: str,
    definitions_by_code: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    definition = definitions_by_code.get(code, {})
    return {
        "code": code,
        "exitCriteria": definition.get("exitCriteria", ""),
        "evidencePaths": definition.get("evidencePaths", []),
    }


def compact_claim_entry(entry_id: str, entries_by_id: dict[str, dict[str, Any]]) -> dict[str, Any]:
    entry = entries_by_id.get(entry_id, {})
    return {
        "id": entry_id,
        "claimState": entry.get("claimState", ""),
        "comparisonStatus": entry.get("comparisonStatus", ""),
        "claimStatus": entry.get("claimStatus", ""),
        "reportPath": entry.get("reportPath", ""),
        "claimPath": entry.get("claimPath", ""),
    }


def row_readiness_status(row: dict[str, Any]) -> str:
    if row.get("claimAllowed") is True:
        return "claimable"
    if row.get("surface") == "evidence_release" and row.get("currentState") == "covered":
        return "covered"
    return "blocked"


def frontier_bundle_config(
    *,
    browser_bundle_path: Path = BROWSER_FRONTIER_BUNDLE_PATH,
    tint_bundle_path: Path = TINT_FRONTIER_BUNDLE_PATH,
) -> dict[str, dict[str, Any]]:
    return {
        BROWSER_FRONTIER_ROW_ID: {
            "path": browser_bundle_path,
            "kind": BROWSER_FRONTIER_BUNDLE_KIND,
        },
        TINT_FRONTIER_ROW_ID: {
            "path": tint_bundle_path,
            "kind": TINT_FRONTIER_BUNDLE_KIND,
        },
    }


def compact_failure(failure: dict[str, Any]) -> dict[str, str]:
    code = failure.get("code")
    path = failure.get("path")
    message = failure.get("message")
    return {
        "code": code if isinstance(code, str) else "",
        "path": path if isinstance(path, str) else "",
        "message": message if isinstance(message, str) else "",
    }


def unique_codes_from_failures(failures: list[dict[str, Any]]) -> list[str]:
    codes: list[str] = []
    for failure in failures:
        code = failure.get("code")
        if isinstance(code, str) and code and code not in codes:
            codes.append(code)
    return codes


def frontier_bundle_evidence(
    *,
    row: dict[str, Any],
    root: Path,
    fallback_codes: list[str],
    bundle_configs: dict[str, dict[str, Any]],
) -> tuple[list[str], dict[str, Any] | None]:
    bundle_config = bundle_configs.get(str(row.get("id", "")))
    if not bundle_config:
        return fallback_codes, None

    try:
        bundle = load_json_object(root / bundle_config["path"])
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        return fallback_codes, None

    if bundle.get("artifactKind") != bundle_config["kind"]:
        return fallback_codes, None
    claim_blockers = bundle.get("claimBlockers")
    if not isinstance(claim_blockers, list):
        return fallback_codes, None

    fallback_set = set(fallback_codes)
    relevant_claim_blockers: list[dict[str, Any]] = []
    for blocker in claim_blockers:
        if not isinstance(blocker, dict):
            continue
        code = blocker.get("code")
        if isinstance(code, str) and code in fallback_set:
            relevant_claim_blockers.append(compact_failure(blocker))

    evidence_codes = unique_codes_from_failures(relevant_claim_blockers)
    if bundle.get("claimabilityStatus") != "claimable" and not evidence_codes:
        blocker_codes = fallback_codes
    else:
        blocker_codes = evidence_codes

    evidence: dict[str, Any] = {
        "path": str(bundle_config["path"]),
        "artifactKind": bundle.get("artifactKind", ""),
        "status": bundle.get("status", ""),
        "claimabilityStatus": bundle.get("claimabilityStatus", ""),
        "claimBlockers": relevant_claim_blockers,
        "summary": bundle.get("summary", {}),
    }
    claim_blocker_summary = bundle.get("claimBlockerSummary")
    if isinstance(claim_blocker_summary, list):
        evidence["claimBlockerSummary"] = claim_blocker_summary
    compiler_evidence_reports = bundle.get("compilerEvidenceReports")
    if isinstance(compiler_evidence_reports, list):
        evidence["compilerEvidenceReports"] = compiler_evidence_reports
    component_receipts = bundle.get("componentReceipts")
    if isinstance(component_receipts, dict):
        evidence["componentReceipts"] = component_receipts
    return blocker_codes, evidence


def build_row_report(
    row: dict[str, Any],
    definitions_by_code: dict[str, dict[str, Any]],
    entries_by_id: dict[str, dict[str, Any]],
    root: Path,
    bundle_configs: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    blockers = row.get("blockers", [])
    if not isinstance(blockers, list):
        blockers = []
    claim_ids = row.get("claimIndexEntryIds", [])
    if not isinstance(claim_ids, list):
        claim_ids = []

    blocker_codes = [code for code in blockers if isinstance(code, str)]
    blocker_codes, bundle_evidence = frontier_bundle_evidence(
        row=row,
        root=root,
        fallback_codes=blocker_codes,
        bundle_configs=bundle_configs,
    )
    claim_entry_ids = [entry_id for entry_id in claim_ids if isinstance(entry_id, str)]
    row_report = {
        "id": row.get("id", ""),
        "surface": row.get("surface", ""),
        "dawnComparator": row.get("dawnComparator", ""),
        "doeTarget": row.get("doeTarget", ""),
        "currentState": row.get("currentState", ""),
        "claimAllowed": row.get("claimAllowed") is True,
        "readinessStatus": row_readiness_status(row),
        "claimIndexEntries": [
            compact_claim_entry(entry_id, entries_by_id) for entry_id in claim_entry_ids
        ],
        "blockers": [
            compact_blocker(code, definitions_by_code) for code in blocker_codes
        ],
        "evidencePaths": row.get("evidencePaths", []),
    }
    if bundle_evidence is not None:
        row_report["frontierBundleEvidence"] = bundle_evidence
    return row_report


def summary_for_rows(rows: list[dict[str, Any]]) -> dict[str, int]:
    product_rows = [row for row in rows if row.get("surface") in PRODUCT_SURFACES]
    claim_allowed_rows = [row for row in product_rows if row.get("claimAllowed") is True]
    blocked_rows = [
        row
        for row in product_rows
        if row.get("readinessStatus") == "blocked"
    ]
    covered_rows = [row for row in rows if row.get("readinessStatus") == "covered"]
    unique_blockers = {
        blocker.get("code")
        for row in rows
        for blocker in row.get("blockers", [])
        if isinstance(blocker, dict) and blocker.get("code")
    }
    return {
        "frontierRowCount": len(rows),
        "productRowCount": len(product_rows),
        "claimAllowedProductRowCount": len(claim_allowed_rows),
        "blockedProductRowCount": len(blocked_rows),
        "coveredEvidenceReleaseRowCount": len(covered_rows),
        "uniqueBlockerCount": len(unique_blockers),
    }


def build_report(
    frontier: dict[str, Any],
    schema: dict[str, Any],
    claim_index: dict[str, Any],
    root: Path,
    bundle_configs: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    gate_report = frontier_gate.evaluate_frontier(frontier, schema, claim_index, root)
    definitions_by_code = blocker_map(frontier)
    entries_by_id = claim_entry_map(claim_index)
    resolved_bundle_configs = bundle_configs or frontier_bundle_config()
    raw_rows = frontier.get("rows", [])
    rows = [
        build_row_report(row, definitions_by_code, entries_by_id, root, resolved_bundle_configs)
        for row in raw_rows
        if isinstance(row, dict)
    ]
    return {
        "schemaVersion": 1,
        "artifactKind": "dawn-replacement-readiness-report",
        "frontierId": frontier.get("frontierId", ""),
        "universalClaim": frontier.get("universalClaim", {}),
        "gate": {
            "ok": gate_report["ok"],
            "failures": gate_report["failures"],
            "summary": gate_report["summary"],
        },
        "summary": summary_for_rows(rows),
        "rows": rows,
    }


def emit_text(report: dict[str, Any]) -> None:
    summary = report["summary"]
    print(
        "Dawn replacement readiness: "
        f"{summary['claimAllowedProductRowCount']}/"
        f"{summary['productRowCount']} product rows claim-allowed; "
        f"{summary['blockedProductRowCount']} blocked."
    )
    for row in report["rows"]:
        if row.get("readinessStatus") != "blocked":
            continue
        blocker_codes = [
            blocker["code"]
            for blocker in row.get("blockers", [])
            if isinstance(blocker, dict) and blocker.get("code")
        ]
        print(f"- {row['id']}: {', '.join(blocker_codes)}")


def main() -> int:
    args = parse_args()
    try:
        root = detect_repo_root(args.root)
        frontier = load_json_object(root / args.frontier)
        schema = load_json_object(root / args.schema)
        claim_index = load_json_object(root / args.claim_index)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: Dawn replacement readiness input error: {exc}")
        return 1

    report = build_report(
        frontier,
        schema,
        claim_index,
        root,
        frontier_bundle_config(
            browser_bundle_path=Path(args.browser_frontier_bundle),
            tint_bundle_path=Path(args.tint_frontier_bundle),
        ),
    )
    if args.out:
        write_json_object(root / args.out, report)
    if args.emit_json:
        print(json.dumps(report, indent=2))
    else:
        emit_text(report)
    return 0 if report["gate"]["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
