#!/usr/bin/env python3
"""Validate developer-visible browser fallback explanations."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from browser_runtime_identity_reference import check_runtime_identity_reference

REPO_ROOT = Path(__file__).resolve().parents[3]
EXPECTED_KIND = "browser_fallback_explanations"
EXPECTED_SCHEMA_VERSION = 1

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--explanations", required=True, help="browser_fallback_explanations JSON path.")
    parser.add_argument(
        "--taxonomy-root",
        default=str(REPO_ROOT),
        help="Repository root used to resolve taxonomyPath.",
    )
    parser.add_argument(
        "--runtime-identity-root",
        default="",
        help="Optional repository root used to resolve runtimeIdentity.runtimeIdentityPath.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def check_artifact_path(path_text: Any, path: str, label: str) -> list[dict[str, str]]:
    if not isinstance(path_text, str) or not path_text:
        return []
    if safe_repo_path(path_text):
        return []
    return [
        failure(
            "unsafe_artifact_path",
            path,
            f"{label} must be repo-relative",
        )
    ]


def resolve_repo_path(root: Path, path_text: str) -> Path | None:
    if not safe_repo_path(path_text):
        return None
    resolved = root.joinpath(*PurePosixPath(path_text).parts).resolve()
    try:
        resolved.relative_to(root.resolve())
    except ValueError:
        return None
    return resolved


def load_taxonomy(
    payload: dict[str, Any],
    root: Path,
) -> tuple[dict[str, dict[str, Any]], dict[str, str], list[dict[str, str]]]:
    taxonomy_path_text = payload.get("taxonomyPath")
    if not isinstance(taxonomy_path_text, str) or not taxonomy_path_text:
        return {}, {}, [
            failure(
                "missing_taxonomy_path",
                "taxonomyPath",
                "fallback explanations must reference browser unsupported reason taxonomy",
            )
        ]
    taxonomy_path = resolve_repo_path(root, taxonomy_path_text)
    if taxonomy_path is None:
        return {}, {}, [
            failure(
                "unsafe_taxonomy_path",
                "taxonomyPath",
                "taxonomy path must be repo-relative",
            )
        ]
    if not taxonomy_path.is_file():
        return {}, {}, [
            failure(
                "missing_taxonomy_file",
                "taxonomyPath",
                f"taxonomy file not found: {taxonomy_path_text}",
            )
        ]
    try:
        taxonomy = load_json(taxonomy_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return {}, {}, [
            failure(
                "invalid_taxonomy",
                "taxonomyPath",
                f"taxonomy is not a valid JSON object: {exc}",
            )
        ]
    if taxonomy.get("artifactKind") != "browser_unsupported_reason_taxonomy":
        return {}, {}, [
            failure(
                "invalid_taxonomy_kind",
                "taxonomyPath",
                "taxonomy artifactKind must be browser_unsupported_reason_taxonomy",
            )
        ]
    codes: dict[str, dict[str, Any]] = {}
    evidence_blocker_map = {
        str(reason_code): str(blocker_code)
        for reason_code, blocker_code in taxonomy.get("evidenceBlockerMap", {}).items()
        if isinstance(reason_code, str) and isinstance(blocker_code, str)
    } if isinstance(taxonomy.get("evidenceBlockerMap"), dict) else {}
    failures: list[dict[str, str]] = []
    for index, row in enumerate(taxonomy.get("codes", [])):
        if not isinstance(row, dict):
            continue
        code = row.get("reasonCode")
        if not isinstance(code, str) or not code:
            continue
        if code in codes:
            failures.append(
                failure(
                    "duplicate_taxonomy_reason_code",
                    f"taxonomy.codes[{index}].reasonCode",
                    f"duplicate taxonomy reasonCode {code}",
                )
            )
        codes[code] = row
    return codes, evidence_blocker_map, failures


def load_evidence_blocker_codes(payload: dict[str, Any], root: Path) -> tuple[set[str], list[dict[str, str]]]:
    path_text = payload.get("evidenceBlockerTaxonomyPath")
    if not isinstance(path_text, str) or not path_text:
        return set(), [
            failure(
                "missing_evidence_blocker_taxonomy_path",
                "evidenceBlockerTaxonomyPath",
                "fallback explanations must reference the evidence blocker taxonomy",
            )
        ]
    path = resolve_repo_path(root, path_text)
    if path is None:
        return set(), [
            failure(
                "unsafe_evidence_blocker_taxonomy_path",
                "evidenceBlockerTaxonomyPath",
                "evidence blocker taxonomy path must be repo-relative",
            )
        ]
    if not path.is_file():
        return set(), [
            failure(
                "missing_evidence_blocker_taxonomy_file",
                "evidenceBlockerTaxonomyPath",
                f"evidence blocker taxonomy file not found: {path_text}",
            )
        ]
    try:
        taxonomy = load_json(path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return set(), [
            failure(
                "invalid_evidence_blocker_taxonomy",
                "evidenceBlockerTaxonomyPath",
                f"evidence blocker taxonomy is not a valid JSON object: {exc}",
            )
        ]
    if taxonomy.get("artifactKind") != "evidence_blocker_taxonomy":
        return set(), [
            failure(
                "invalid_evidence_blocker_taxonomy_kind",
                "evidenceBlockerTaxonomyPath",
                "evidence blocker taxonomy artifactKind must be evidence_blocker_taxonomy",
            )
        ]
    codes = taxonomy.get("codes", [])
    if not isinstance(codes, list):
        return set(), [
            failure(
                "invalid_evidence_blocker_taxonomy",
                "evidenceBlockerTaxonomyPath",
                "evidence blocker taxonomy codes must be an array",
            )
        ]
    return {
        str(row["blockerCode"])
        for row in codes
        if isinstance(row, dict) and isinstance(row.get("blockerCode"), str)
    }, []


def check_explanations(
    payload: dict[str, Any],
    taxonomy_root: Path | None = None,
    runtime_identity_root: Path | None = None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("schemaVersion") != EXPECTED_SCHEMA_VERSION:
        failures.append(
            failure(
                "invalid_schema_version",
                "schemaVersion",
                f"schemaVersion must be {EXPECTED_SCHEMA_VERSION}",
            )
        )
    if payload.get("artifactKind") != EXPECTED_KIND:
        failures.append(
            failure(
                "invalid_artifact_kind",
                "artifactKind",
                f"artifactKind must be {EXPECTED_KIND}",
            )
        )
    if runtime_identity_root is not None:
        failures.extend(check_runtime_identity_reference(payload, runtime_identity_root))
    root = taxonomy_root or REPO_ROOT
    taxonomy, evidence_blocker_map, taxonomy_failures = load_taxonomy(payload, root)
    failures.extend(taxonomy_failures)
    evidence_blocker_codes, evidence_blocker_failures = load_evidence_blocker_codes(payload, root)
    failures.extend(evidence_blocker_failures)
    explanations = payload.get("explanations", [])
    for index, explanation in enumerate(explanations):
        if not isinstance(explanation, dict):
            continue
        explanation_path = f"explanations[{index}]"
        failures.extend(
            check_artifact_path(
                explanation.get("evidencePath"),
                f"{explanation_path}.evidencePath",
                "fallback explanation evidence path",
            )
        )
        if explanation.get("hiddenFallbackAllowed") is not False:
            failures.append(
                failure(
                    "hidden_fallback_allowed",
                    f"{explanation_path}.hiddenFallbackAllowed",
                    "hidden fallback must be false",
                )
            )
        if not explanation.get("reasonCode"):
            failures.append(
                failure(
                    "missing_reason_code",
                    f"{explanation_path}.reasonCode",
                    "explanation requires reasonCode",
                )
            )
        evidence_blocker_code = explanation.get("evidenceBlockerCode")
        if not isinstance(evidence_blocker_code, str) or not evidence_blocker_code:
            failures.append(
                failure(
                    "missing_evidence_blocker_code",
                    f"{explanation_path}.evidenceBlockerCode",
                    "explanation requires evidenceBlockerCode",
                )
            )
        elif evidence_blocker_code not in evidence_blocker_codes:
            failures.append(
                failure(
                    "unknown_evidence_blocker_code",
                    f"{explanation_path}.evidenceBlockerCode",
                    f"evidenceBlockerCode {evidence_blocker_code!r} is not defined in the evidence blocker taxonomy",
                )
            )
        if not explanation.get("developerAction"):
            failures.append(
                failure(
                    "missing_developer_action",
                    f"{explanation_path}.developerAction",
                    "explanation requires developerAction",
                )
            )
        reason_code = explanation.get("reasonCode")
        taxonomy_row = taxonomy.get(reason_code) if isinstance(reason_code, str) else None
        if isinstance(reason_code, str) and reason_code and taxonomy_row is None:
            failures.append(
                failure(
                    "unknown_reason_code",
                    f"{explanation_path}.reasonCode",
                    f"reasonCode {reason_code!r} is not defined in browser unsupported reason taxonomy",
                )
            )
        elif taxonomy_row is not None:
            expected_blocker_code = evidence_blocker_map.get(reason_code)
            if (
                expected_blocker_code
                and isinstance(evidence_blocker_code, str)
                and evidence_blocker_code != expected_blocker_code
            ):
                failures.append(
                    failure(
                        "evidence_blocker_code_mismatch",
                        f"{explanation_path}.evidenceBlockerCode",
                        f"reasonCode {reason_code!r} must map to evidenceBlockerCode {expected_blocker_code!r}",
                    )
                )
            capabilities = taxonomy_row.get("capabilities", [])
            statuses = taxonomy_row.get("statuses", [])
            if explanation.get("capability") not in capabilities:
                failures.append(
                    failure(
                        "reason_code_capability_mismatch",
                        f"{explanation_path}.reasonCode",
                        f"reasonCode {reason_code!r} is not valid for capability {explanation.get('capability')!r}",
                    )
                )
            if explanation.get("status") not in statuses:
                failures.append(
                    failure(
                        "reason_code_status_mismatch",
                        f"{explanation_path}.reasonCode",
                        f"reasonCode {reason_code!r} is not valid for status {explanation.get('status')!r}",
                    )
                )
        if explanation.get("fallbackApplied") is True and explanation.get("status") != "fallback":
            failures.append(
                failure(
                    "fallback_status_mismatch",
                    f"{explanation_path}.status",
                    "applied fallback requires status=fallback",
                )
            )

    privacy = payload.get("privacy", {})
    if (
        not isinstance(privacy, dict)
        or privacy.get("originScoped") is not True
        or privacy.get("rawPageDataIncluded") is not False
    ):
        failures.append(
            failure(
                "unsafe_privacy_policy",
                "privacy",
                "fallback explanations must be origin-scoped and exclude raw page data",
            )
        )

    return failures


def main() -> int:
    args = parse_args()
    runtime_identity_root = (
        Path(args.runtime_identity_root).resolve()
        if args.runtime_identity_root.strip()
        else None
    )
    failures = check_explanations(
        load_json(Path(args.explanations)),
        Path(args.taxonomy_root),
        runtime_identity_root,
    )
    report = {
        "schemaVersion": 1,
        "artifactKind": "browser_fallback_explanations_check",
        "explanationsPath": args.explanations,
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: browser fallback explanations")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser fallback explanations")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
