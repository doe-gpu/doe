#!/usr/bin/env python3
"""Gate the public claim index against claim/report boundary rules."""

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


OPTIONAL_ARTIFACT_PREFIXES = ("bench/out/",)
VALID_REPORT_KIND = "compare-report"
VALID_CLAIM_KIND = "claim-report"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        default="",
        help="Repository root. Auto-detected when omitted.",
    )
    parser.add_argument(
        "--index",
        default="reports/claim-index.json",
        help="Claim index path relative to the repository root.",
    )
    parser.add_argument(
        "--schema",
        default="config/claim-index.schema.json",
        help="Claim index JSON Schema path relative to the repository root.",
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
        return [
            failure(
                "invalid_schema",
                "<schema>",
                exc.message,
            )
        ]

    errors = sorted(
        validator.iter_errors(payload),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    return [
        failure(
            "schema_validation",
            format_schema_path(error),
            error.message,
        )
        for error in errors
    ]


def is_optional_artifact(path: str) -> bool:
    return any(path.startswith(prefix) for prefix in OPTIONAL_ARTIFACT_PREFIXES)


def unsafe_path_reason(path: Any) -> str:
    if not isinstance(path, str) or not path:
        return "path must be a non-empty string"
    if "\\" in path:
        return "path must use forward slashes"
    if path.startswith("/"):
        return "path must be repository-relative"
    if not path.endswith(".json"):
        return "path must end in .json"
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return "path must not contain empty, current, or parent segments"
    return ""


def local_artifact_path(root: Path, rel_path: str) -> Path:
    return root / rel_path


def load_optional_artifact(root: Path, rel_path: str) -> tuple[dict[str, Any] | None, str]:
    artifact_path = local_artifact_path(root, rel_path)
    if not artifact_path.exists():
        if is_optional_artifact(rel_path):
            return None, "missing_optional"
        return None, "missing_required"
    try:
        return load_json_object(artifact_path), ""
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        return None, f"parse_failed: {exc}"


def validate_report_artifact(
    root: Path,
    entry_path: str,
    report_path: str,
    expected_comparison_status: str,
) -> tuple[list[dict[str, str]], bool]:
    failures: list[dict[str, str]] = []
    report, load_status = load_optional_artifact(root, report_path)
    if load_status == "missing_optional":
        return failures, False
    if load_status:
        failures.append(
            failure(
                "report_artifact_unavailable",
                f"{entry_path}.reportPath",
                f"{report_path}: {load_status}",
            )
        )
        return failures, False
    if report is None:
        return failures, False

    if report.get("artifactKind") != VALID_REPORT_KIND:
        failures.append(
            failure(
                "invalid_report_artifact_kind",
                f"{entry_path}.reportPath",
                f"{report_path}: artifactKind must be {VALID_REPORT_KIND}",
            )
        )
    if report.get("comparisonStatus") != expected_comparison_status:
        failures.append(
            failure(
                "report_comparison_status_mismatch",
                f"{entry_path}.comparisonStatus",
                (
                    f"{report_path}: index comparisonStatus={expected_comparison_status} "
                    f"but report has {report.get('comparisonStatus')}"
                ),
            )
        )
    return failures, True


def validate_claim_artifact(
    root: Path,
    entry_path: str,
    claim_path: str,
    report_path: str,
    expected_comparison_status: str,
    expected_claim_status: str,
    claim_state: str,
) -> tuple[list[dict[str, str]], bool]:
    failures: list[dict[str, str]] = []
    claim, load_status = load_optional_artifact(root, claim_path)
    if load_status == "missing_optional":
        return failures, False
    if load_status:
        failures.append(
            failure(
                "claim_artifact_unavailable",
                f"{entry_path}.claimPath",
                f"{claim_path}: {load_status}",
            )
        )
        return failures, False
    if claim is None:
        return failures, False

    if claim.get("artifactKind") != VALID_CLAIM_KIND:
        failures.append(
            failure(
                "invalid_claim_artifact_kind",
                f"{entry_path}.claimPath",
                f"{claim_path}: artifactKind must be {VALID_CLAIM_KIND}",
            )
        )
    if claim.get("comparisonStatus") != expected_comparison_status:
        failures.append(
            failure(
                "claim_comparison_status_mismatch",
                f"{entry_path}.comparisonStatus",
                (
                    f"{claim_path}: index comparisonStatus={expected_comparison_status} "
                    f"but claim has {claim.get('comparisonStatus')}"
                ),
            )
        )
    if claim.get("claimStatus") != expected_claim_status:
        failures.append(
            failure(
                "claim_status_mismatch",
                f"{entry_path}.claimStatus",
                (
                    f"{claim_path}: index claimStatus={expected_claim_status} "
                    f"but claim has {claim.get('claimStatus')}"
                ),
            )
        )
    if claim_state == "claim-indexed" and claim.get("pass") is not True:
        failures.append(
            failure(
                "claim_indexed_sidecar_not_passing",
                f"{entry_path}.claimPath",
                f"{claim_path}: claim-indexed entries require pass=true",
            )
        )

    compare_report = claim.get("compareReport")
    claim_report_path = compare_report.get("path") if isinstance(compare_report, dict) else None
    if claim_report_path != report_path:
        failures.append(
            failure(
                "claim_sidecar_report_mismatch",
                f"{entry_path}.claimPath",
                (
                    f"{claim_path}: compareReport.path must be {report_path}, "
                    f"got {claim_report_path}"
                ),
            )
        )
    return failures, True


def evaluate_index(
    index: dict[str, Any],
    schema: dict[str, Any],
    root: Path,
) -> dict[str, Any]:
    failures = schema_failures(index, schema)
    entries = index.get("entries", [])
    seen_ids: set[str] = set()
    local_report_count = 0
    local_claim_count = 0
    missing_local_artifact_count = 0

    if not isinstance(entries, list):
        return {
            "ok": False,
            "failures": failures,
            "summary": {
                "entryCount": 0,
                "localReportCount": 0,
                "localClaimCount": 0,
                "missingLocalArtifactCount": 0,
            },
        }

    for index_num, entry in enumerate(entries):
        entry_path = f"entries[{index_num}]"
        if not isinstance(entry, dict):
            failures.append(
                failure(
                    "invalid_entry",
                    entry_path,
                    "entry must be an object",
                )
            )
            continue

        entry_id = entry.get("id")
        if isinstance(entry_id, str):
            if entry_id in seen_ids:
                failures.append(
                    failure(
                        "duplicate_id",
                        f"{entry_path}.id",
                        f"duplicate claim index id: {entry_id}",
                    )
                )
            seen_ids.add(entry_id)

        report_path = entry.get("reportPath")
        claim_path = entry.get("claimPath")
        claim_state = entry.get("claimState")
        comparison_status = entry.get("comparisonStatus")
        claim_status = entry.get("claimStatus")

        report_path_reason = unsafe_path_reason(report_path)
        if report_path_reason:
            failures.append(
                failure(
                    "unsafe_report_path",
                    f"{entry_path}.reportPath",
                    report_path_reason,
                )
            )
            continue
        if isinstance(claim_path, str):
            claim_path_reason = unsafe_path_reason(claim_path)
            if claim_path_reason:
                failures.append(
                    failure(
                        "unsafe_claim_path",
                        f"{entry_path}.claimPath",
                        claim_path_reason,
                    )
                )
                continue

        if claim_state == "claim-indexed":
            if not isinstance(claim_path, str):
                failures.append(
                    failure(
                        "claim_indexed_missing_claim_path",
                        f"{entry_path}.claimPath",
                        "claim-indexed entries require claimPath",
                    )
                )
            if comparison_status != "comparable":
                failures.append(
                    failure(
                        "claim_indexed_not_comparable",
                        f"{entry_path}.comparisonStatus",
                        "claim-indexed entries require comparisonStatus=comparable",
                    )
                )
            if claim_status != "claimable":
                failures.append(
                    failure(
                        "claim_indexed_not_claimable",
                        f"{entry_path}.claimStatus",
                        "claim-indexed entries require claimStatus=claimable",
                    )
                )
        elif claim_status == "claimable":
            failures.append(
                failure(
                    "claimable_without_claim_indexed_state",
                    f"{entry_path}.claimState",
                    "claimStatus=claimable requires claimState=claim-indexed",
                )
            )

        if isinstance(report_path, str):
            report_failures, report_present = validate_report_artifact(
                root,
                entry_path,
                report_path,
                str(comparison_status),
            )
            failures.extend(report_failures)
            if report_present:
                local_report_count += 1
            elif is_optional_artifact(report_path):
                missing_local_artifact_count += 1

        if isinstance(claim_path, str) and isinstance(report_path, str):
            claim_failures, claim_present = validate_claim_artifact(
                root,
                entry_path,
                claim_path,
                report_path,
                str(comparison_status),
                str(claim_status),
                str(claim_state),
            )
            failures.extend(claim_failures)
            if claim_present:
                local_claim_count += 1
            elif is_optional_artifact(claim_path):
                missing_local_artifact_count += 1

    return {
        "ok": not failures,
        "failures": failures,
        "summary": {
            "entryCount": len(entries),
            "localReportCount": local_report_count,
            "localClaimCount": local_claim_count,
            "missingLocalArtifactCount": missing_local_artifact_count,
        },
    }


def main() -> int:
    args = parse_args()
    try:
        root = detect_repo_root(args.root)
        index = load_json_object(root / args.index)
        schema = load_json_object(root / args.schema)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: claim index gate input error: {exc}")
        return 1

    report = {
        "schemaVersion": 1,
        "artifactKind": "claim-index-gate-report",
        **evaluate_index(index, schema, root),
    }

    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif report["failures"]:
        print("FAIL: claim index gate")
        for item in report["failures"]:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        summary = report["summary"]
        print(
            "PASS: claim index gate "
            f"({summary['entryCount']} entries, "
            f"{summary['localReportCount']} local reports, "
            f"{summary['localClaimCount']} local claim sidecars)"
        )
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
