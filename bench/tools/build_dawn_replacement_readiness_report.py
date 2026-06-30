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


def build_row_report(
    row: dict[str, Any],
    definitions_by_code: dict[str, dict[str, Any]],
    entries_by_id: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    blockers = row.get("blockers", [])
    if not isinstance(blockers, list):
        blockers = []
    claim_ids = row.get("claimIndexEntryIds", [])
    if not isinstance(claim_ids, list):
        claim_ids = []

    blocker_codes = [code for code in blockers if isinstance(code, str)]
    claim_entry_ids = [entry_id for entry_id in claim_ids if isinstance(entry_id, str)]
    return {
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
) -> dict[str, Any]:
    gate_report = frontier_gate.evaluate_frontier(frontier, schema, claim_index, root)
    definitions_by_code = blocker_map(frontier)
    entries_by_id = claim_entry_map(claim_index)
    raw_rows = frontier.get("rows", [])
    rows = [
        build_row_report(row, definitions_by_code, entries_by_id)
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

    report = build_report(frontier, schema, claim_index, root)
    if args.out:
        write_json_object(root / args.out, report)
    if args.emit_json:
        print(json.dumps(report, indent=2))
    else:
        emit_text(report)
    return 0 if report["gate"]["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
