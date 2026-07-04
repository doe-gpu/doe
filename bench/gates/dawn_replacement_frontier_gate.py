#!/usr/bin/env python3
"""Gate the Dawn replacement frontier against evidence and claim boundaries."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import jsonschema

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import detect_repo_root, load_json_object


REQUIRED_FRONTIER_IDS = {
    "native-metal-runtime",
    "native-vulkan-runtime",
    "native-d3d12-runtime",
    "package-node-runtime",
    "package-bun-runtime",
    "package-deno-runtime",
    "browser-chromium-runtime",
    "wgsl-tint-compiler",
    "webgpu-cts-conformance",
    "drop-in-abi-runtime",
    "release-claim-index",
}
EXCLUDED_FRONTIER_TERMS = ("cerebras", "csl")
CLAIM_INDEXED_STATE = "claim-indexed"
COMPARABLE_STATUS = "comparable"
CLAIMABLE_STATUS = "claimable"


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
        help="Dawn replacement frontier path relative to repository root.",
    )
    parser.add_argument(
        "--schema",
        default="config/dawn-replacement-frontier.schema.json",
        help="Dawn replacement frontier schema path relative to repository root.",
    )
    parser.add_argument(
        "--claim-index",
        default="reports/claim-index.json",
        help="Claim index path relative to repository root.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def format_schema_path(error: jsonschema.ValidationError) -> str:
    if not error.absolute_path:
        return "<root>"
    return ".".join(str(part) for part in error.absolute_path)


def schema_failures(payload: dict[str, Any], schema: dict[str, Any]) -> list[dict[str, str]]:
    try:
        validator = jsonschema.Draft202012Validator(schema)
    except jsonschema.SchemaError as exc:
        return [failure("invalid_schema", "<schema>", exc.message)]

    errors = sorted(
        validator.iter_errors(payload),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    return [
        failure("schema_validation", format_schema_path(error), error.message)
        for error in errors
    ]


def unsafe_repo_path_reason(value: Any) -> str:
    if not isinstance(value, str) or not value:
        return "path must be a non-empty string"
    if "\\" in value:
        return "path must use forward slashes"
    if value.startswith("/"):
        return "path must be repository-relative"
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return "path must not contain empty, current, or parent segments"
    return ""


def contains_excluded_term(value: str) -> str:
    lowered = value.lower()
    for term in EXCLUDED_FRONTIER_TERMS:
        if term in lowered:
            return term
    return ""


def excluded_term_failures(value: Any, path: str) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if isinstance(value, str):
        term = contains_excluded_term(value)
        if term:
            failures.append(
                failure(
                    "excluded_frontier_scope",
                    path,
                    f"Dawn replacement frontier must not include excluded scope term: {term}",
                )
            )
        return failures
    if isinstance(value, list):
        for index, item in enumerate(value):
            failures.extend(excluded_term_failures(item, f"{path}[{index}]"))
        return failures
    if isinstance(value, dict):
        for key, item in value.items():
            failures.extend(excluded_term_failures(item, f"{path}.{key}"))
    return failures


def claim_entries_by_id(claim_index: dict[str, Any]) -> dict[str, dict[str, Any]]:
    entries: dict[str, dict[str, Any]] = {}
    for entry in claim_index.get("entries", []):
        if not isinstance(entry, dict):
            continue
        entry_id = entry.get("id")
        if isinstance(entry_id, str):
            entries[entry_id] = entry
    return entries


def validate_evidence_paths(
    paths: Any,
    paths_path: str,
    root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if not isinstance(paths, list):
        return failures

    for index, value in enumerate(paths):
        path = f"{paths_path}[{index}]"
        reason = unsafe_repo_path_reason(value)
        if reason:
            failures.append(failure("unsafe_evidence_path", path, reason))
            continue
        if not (root / value).exists():
            failures.append(
                failure(
                    "evidence_path_missing",
                    path,
                    f"evidence path does not exist: {value}",
                )
            )
    return failures


def validate_claim_index_references(
    row: dict[str, Any],
    row_path: str,
    entries_by_id: dict[str, dict[str, Any]],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    claim_allowed = row.get("claimAllowed") is True
    claim_ids = row.get("claimIndexEntryIds", [])
    if not isinstance(claim_ids, list):
        return failures

    if claim_allowed and not claim_ids:
        failures.append(
            failure(
                "claim_allowed_missing_claim_index_entry",
                f"{row_path}.claimIndexEntryIds",
                "claim-allowed rows require at least one public claim-index entry",
            )
        )

    for index, claim_id in enumerate(claim_ids):
        path = f"{row_path}.claimIndexEntryIds[{index}]"
        entry = entries_by_id.get(str(claim_id))
        if entry is None:
            failures.append(
                failure(
                    "unknown_claim_index_entry",
                    path,
                    f"claim index entry not found: {claim_id}",
                )
            )
            continue

        if claim_allowed:
            expected = {
                "claimState": CLAIM_INDEXED_STATE,
                "comparisonStatus": COMPARABLE_STATUS,
                "claimStatus": CLAIMABLE_STATUS,
            }
            for field, expected_value in expected.items():
                if entry.get(field) != expected_value:
                    failures.append(
                        failure(
                            "claim_index_entry_not_claimable",
                            path,
                            (
                                f"{claim_id}: {field} must be {expected_value}, "
                                f"got {entry.get(field)!r}"
                            ),
                        )
                    )
            if not entry.get("claimPath"):
                failures.append(
                    failure(
                        "claim_index_entry_missing_claim_path",
                        path,
                        f"{claim_id}: claim-allowed frontier rows require claimPath",
                    )
                )
        elif entry.get("claimState") == CLAIM_INDEXED_STATE:
            failures.append(
                failure(
                    "nonclaim_row_references_claim_indexed_entry",
                    path,
                    f"{claim_id}: non-claimable frontier rows must not borrow claim-indexed evidence",
                )
            )
    return failures


def validate_row(
    row: dict[str, Any],
    row_path: str,
    root: Path,
    entries_by_id: dict[str, dict[str, Any]],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    state = row.get("currentState")
    claim_allowed = row.get("claimAllowed") is True
    blockers = row.get("blockers", [])
    evidence_paths = row.get("evidencePaths", [])
    claim_ids = row.get("claimIndexEntryIds", [])

    failures.extend(excluded_term_failures(row, row_path))

    if claim_allowed and state != "claimable":
        failures.append(
            failure(
                "claim_allowed_state_mismatch",
                f"{row_path}.currentState",
                "claimAllowed=true requires currentState=claimable",
            )
        )
    if state == "claimable" and not claim_allowed:
        failures.append(
            failure(
                "claimable_state_not_allowed",
                f"{row_path}.claimAllowed",
                "currentState=claimable requires claimAllowed=true",
            )
        )
    if claim_allowed and blockers:
        failures.append(
            failure(
                "claim_allowed_row_has_blockers",
                f"{row_path}.blockers",
                "claim-allowed rows must not carry blockers",
            )
        )
    if not claim_allowed and not blockers:
        failures.append(
            failure(
                "nonclaim_row_missing_blocker",
                f"{row_path}.blockers",
                "non-claimable frontier rows require at least one blocker",
            )
        )
    if not evidence_paths and not claim_ids:
        failures.append(
            failure(
                "frontier_row_missing_evidence",
                row_path,
                "frontier rows require evidencePaths or claimIndexEntryIds",
            )
        )

    failures.extend(
        validate_evidence_paths(evidence_paths, f"{row_path}.evidencePaths", root)
    )
    failures.extend(validate_claim_index_references(row, row_path, entries_by_id))
    return failures


def validate_evidence_slices(
    row: dict[str, Any],
    row_path: str,
    root: Path,
    entries_by_id: dict[str, dict[str, Any]],
    definitions_by_code: dict[str, dict[str, Any]],
    seen_slice_ids: set[str],
) -> tuple[list[dict[str, str]], set[str], int, int]:
    failures: list[dict[str, str]] = []
    used_blockers: set[str] = set()
    slice_count = 0
    claim_allowed_slice_count = 0
    slices = row.get("evidenceSlices", [])
    row_claim_allowed = row.get("claimAllowed") is True

    if not isinstance(slices, list):
        return failures, used_blockers, slice_count, claim_allowed_slice_count

    for index, evidence_slice in enumerate(slices):
        slice_path = f"{row_path}.evidenceSlices[{index}]"
        if not isinstance(evidence_slice, dict):
            continue
        slice_count += 1
        slice_id = evidence_slice.get("id")
        if isinstance(slice_id, str):
            if slice_id in seen_slice_ids:
                failures.append(
                    failure("duplicate_evidence_slice", f"{slice_path}.id", slice_id)
                )
            seen_slice_ids.add(slice_id)
        if evidence_slice.get("claimAllowed") is True:
            claim_allowed_slice_count += 1
        elif row_claim_allowed:
            failures.append(
                failure(
                    "claim_allowed_row_has_blocked_slice",
                    f"{slice_path}.claimAllowed",
                    "claim-allowed rows require every evidence slice to be claim-allowed",
                )
            )
        blockers = evidence_slice.get("blockers", [])
        if isinstance(blockers, list):
            for blocker_index, blocker in enumerate(blockers):
                if not isinstance(blocker, str):
                    continue
                used_blockers.add(blocker)
                if blocker not in definitions_by_code:
                    failures.append(
                        failure(
                            "undefined_blocker",
                            f"{slice_path}.blockers[{blocker_index}]",
                            f"blocker is not defined: {blocker}",
                        )
                    )
        failures.extend(validate_row(evidence_slice, slice_path, root, entries_by_id))
    return failures, used_blockers, slice_count, claim_allowed_slice_count


def blocker_definition_failures(
    frontier: dict[str, Any],
    root: Path,
) -> tuple[list[dict[str, str]], dict[str, dict[str, Any]]]:
    failures: list[dict[str, str]] = []
    definitions_by_code: dict[str, dict[str, Any]] = {}
    definitions = frontier.get("blockerDefinitions", [])
    if not isinstance(definitions, list):
        return failures, definitions_by_code

    for index, definition in enumerate(definitions):
        definition_path = f"blockerDefinitions[{index}]"
        if not isinstance(definition, dict):
            continue
        failures.extend(excluded_term_failures(definition, definition_path))
        code = definition.get("code")
        if isinstance(code, str):
            if code in definitions_by_code:
                failures.append(
                    failure(
                        "duplicate_blocker_definition",
                        f"{definition_path}.code",
                        code,
                    )
                )
            definitions_by_code[code] = definition
        failures.extend(
            validate_evidence_paths(
                definition.get("evidencePaths", []),
                f"{definition_path}.evidencePaths",
                root,
            )
        )
    return failures, definitions_by_code


def validate_universal_claim(frontier: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    universal_claim = frontier.get("universalClaim", {})
    rows = [row for row in frontier.get("rows", []) if isinstance(row, dict)]
    allowed = universal_claim.get("allowed") is True
    reason_code = universal_claim.get("reasonCode")
    all_rows_ready = bool(rows) and all(
        row.get("claimAllowed") is True
        if row.get("surface") != "evidence_release"
        else row.get("currentState") in ("covered", "claimable")
        for row in rows
    )

    if allowed and not all_rows_ready:
        failures.append(
            failure(
                "universal_claim_overstates_frontier",
                "universalClaim.allowed",
                (
                    "universal Dawn replacement claims require every product "
                    "frontier row to be claim-allowed and every evidence-release "
                    "row to be covered or claimable"
                ),
            )
        )
    if allowed and reason_code:
        failures.append(
            failure(
                "universal_claim_has_reason",
                "universalClaim.reasonCode",
                "allowed universal claims must not carry a blocker reasonCode",
            )
        )
    if not allowed and not reason_code:
        failures.append(
            failure(
                "universal_claim_missing_reason",
                "universalClaim.reasonCode",
                "blocked universal claims require a reasonCode",
            )
        )
    return failures


def evaluate_frontier(
    frontier: dict[str, Any],
    schema: dict[str, Any],
    claim_index: dict[str, Any],
    root: Path,
) -> dict[str, Any]:
    failures = schema_failures(frontier, schema)
    rows = frontier.get("rows", [])
    entries_by_id = claim_entries_by_id(claim_index)
    blocker_failures, definitions_by_code = blocker_definition_failures(frontier, root)
    failures.extend(blocker_failures)
    seen_ids: set[str] = set()
    seen_slice_ids: set[str] = set()
    used_blockers: set[str] = set()
    claim_allowed_count = 0
    evidence_slice_count = 0
    claim_allowed_evidence_slice_count = 0

    if isinstance(rows, list):
        for index, row in enumerate(rows):
            row_path = f"rows[{index}]"
            if not isinstance(row, dict):
                continue
            row_id = row.get("id")
            if isinstance(row_id, str):
                if row_id in seen_ids:
                    failures.append(
                        failure("duplicate_frontier_row", f"{row_path}.id", row_id)
                    )
                seen_ids.add(row_id)
                if row_id not in REQUIRED_FRONTIER_IDS:
                    failures.append(
                        failure("unexpected_frontier_row", f"{row_path}.id", row_id)
                    )
            if row.get("claimAllowed") is True:
                claim_allowed_count += 1
            blockers = row.get("blockers", [])
            if isinstance(blockers, list):
                for blocker_index, blocker in enumerate(blockers):
                    if not isinstance(blocker, str):
                        continue
                    used_blockers.add(blocker)
                    if blocker not in definitions_by_code:
                        failures.append(
                            failure(
                                "undefined_blocker",
                                f"{row_path}.blockers[{blocker_index}]",
                                f"blocker is not defined: {blocker}",
                            )
                        )
            failures.extend(validate_row(row, row_path, root, entries_by_id))
            (
                slice_failures,
                slice_blockers,
                row_slice_count,
                row_claim_allowed_slice_count,
            ) = validate_evidence_slices(
                row,
                row_path,
                root,
                entries_by_id,
                definitions_by_code,
                seen_slice_ids,
            )
            failures.extend(slice_failures)
            used_blockers.update(slice_blockers)
            evidence_slice_count += row_slice_count
            claim_allowed_evidence_slice_count += row_claim_allowed_slice_count

    for required_id in sorted(REQUIRED_FRONTIER_IDS - seen_ids):
        failures.append(
            failure(
                "missing_frontier_row",
                "rows",
                f"missing Dawn replacement frontier row: {required_id}",
            )
        )
    for unused_blocker in sorted(set(definitions_by_code) - used_blockers):
        failures.append(
            failure(
                "unused_blocker_definition",
                "blockerDefinitions",
                f"blocker definition is not referenced by any row: {unused_blocker}",
            )
        )
    failures.extend(validate_universal_claim(frontier))

    return {
        "ok": not failures,
        "failures": failures,
        "summary": {
            "frontierRowCount": len(rows) if isinstance(rows, list) else 0,
            "claimAllowedRowCount": claim_allowed_count,
            "evidenceSliceCount": evidence_slice_count,
            "claimAllowedEvidenceSliceCount": claim_allowed_evidence_slice_count,
            "requiredRowCount": len(REQUIRED_FRONTIER_IDS),
        },
    }


def main() -> int:
    args = parse_args()
    try:
        root = detect_repo_root(args.root)
        frontier = load_json_object(root / args.frontier)
        schema = load_json_object(root / args.schema)
        claim_index = load_json_object(root / args.claim_index)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: Dawn replacement frontier gate input error: {exc}")
        return 1

    report = {
        "schemaVersion": 1,
        "artifactKind": "dawn-replacement-frontier-gate-report",
        **evaluate_frontier(frontier, schema, claim_index, root),
    }

    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif report["failures"]:
        print("FAIL: Dawn replacement frontier gate")
        for item in report["failures"]:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        summary = report["summary"]
        print(
            "PASS: Dawn replacement frontier gate "
            f"({summary['claimAllowedRowCount']}/"
            f"{summary['frontierRowCount']} rows claim-allowed)"
        )
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
