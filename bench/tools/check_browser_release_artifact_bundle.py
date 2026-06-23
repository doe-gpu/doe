#!/usr/bin/env python3
"""Check browser release artifact bundle completeness."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib.bench_utils import load_json_object as load_json

try:
    from bench.tools import check_browser_claim_promotion_receipt as promotion_check
except ModuleNotFoundError:
    import check_browser_claim_promotion_receipt as promotion_check  # type: ignore


REQUIRED_CONTRACT_KINDS = {"contract"}
REQUIRED_CLAIM_KINDS = {"browser_claim_report"}
REQUIRED_PROMOTION_RECEIPT_KINDS = {"browser_claim_promotion_receipt"}
REQUIRED_POLICY_KINDS = {
    "runtime_selector_policy",
    "fork_maintenance_policy",
    "chromium_patch_manifest",
    "browser_claim_policy",
    "browser_capture_policy",
    "browser_artifact_identity_coverage",
    "browser_unsupported_reason_taxonomy",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", required=True, help="Browser release artifact bundle JSON.")
    parser.add_argument(
        "--verify-files-root",
        default="",
        help="Resolve relative artifact paths under this root and verify sha256 values.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def resolve_artifact_path(path_text: str, verify_files_root: Path) -> Path | None:
    root = verify_files_root.resolve()
    path = Path(path_text)
    candidate = path if path.is_absolute() else root.joinpath(*PurePosixPath(path_text).parts)
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        return None
    return resolved


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_artifact(
    artifact: Any,
    path: str,
    expected_kind: str | None = None,
    verify_files_root: Path | None = None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if not isinstance(artifact, dict):
        return [failure("invalid_artifact", path, "artifact must be object")]
    if expected_kind is not None and artifact.get("kind") != expected_kind:
        failures.append(failure("wrong_artifact_kind", f"{path}.kind", f"expected {expected_kind}"))
    artifact_path = artifact.get("path")
    artifact_hash = artifact.get("sha256")
    if not artifact_path:
        failures.append(failure("missing_artifact_path", f"{path}.path", "artifact path is required"))
    if not isinstance(artifact_hash, str) or len(artifact_hash) != 64:
        failures.append(failure("missing_artifact_hash", f"{path}.sha256", "artifact sha256 is required"))
    if verify_files_root is not None and isinstance(artifact_path, str) and isinstance(artifact_hash, str):
        resolved_path = resolve_artifact_path(artifact_path, verify_files_root)
        if resolved_path is None:
            failures.append(
                failure(
                    "unsafe_artifact_path",
                    f"{path}.path",
                    f"artifact path must resolve under verify-files-root: {artifact_path}",
                )
            )
            return failures
        if not resolved_path.is_file():
            failures.append(failure("artifact_file_missing", f"{path}.path", f"artifact file not found: {artifact_path}"))
        else:
            actual_hash = sha256_file(resolved_path)
            if actual_hash != artifact_hash:
                failures.append(
                    failure(
                        "artifact_hash_mismatch",
                        f"{path}.sha256",
                        f"expected {actual_hash} for {artifact_path}",
                    )
                )
    return failures


def check_promotion_receipt_matches_claims(
    promotion_receipts: Any,
    claim_reports: Any,
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    if verify_files_root is None or not isinstance(promotion_receipts, list) or not isinstance(claim_reports, list):
        return []

    claim_hashes = {
        row.get("sha256")
        for row in claim_reports
        if isinstance(row, dict) and isinstance(row.get("sha256"), str)
    }
    covered_hashes: set[str] = set()
    failures: list[dict[str, str]] = []
    for index, artifact in enumerate(promotion_receipts):
        if not isinstance(artifact, dict) or artifact.get("kind") != "browser_claim_promotion_receipt":
            continue
        artifact_path = artifact.get("path")
        if not isinstance(artifact_path, str) or not artifact_path:
            continue
        resolved_path = resolve_artifact_path(artifact_path, verify_files_root)
        if resolved_path is None:
            continue
        if not resolved_path.is_file():
            continue
        payload = load_json(resolved_path)
        for item in promotion_check.check_receipt(payload, verify_files_root):
            failures.append(
                failure(
                    f"promotion_receipt_{item['code']}",
                    f"promotionReceipts[{index}].{item['path']}",
                    item["message"],
                )
            )
        for row in payload.get("artifacts", []):
            if isinstance(row, dict) and isinstance(row.get("sha256"), str):
                covered_hashes.add(row["sha256"])

    for index, claim_report in enumerate(claim_reports):
        if not isinstance(claim_report, dict):
            continue
        claim_hash = claim_report.get("sha256")
        if isinstance(claim_hash, str) and claim_hash not in covered_hashes:
            failures.append(
                failure(
                    "promotion_receipt_missing_claim_report",
                    f"claimReports[{index}].sha256",
                    "promotion receipts must cover every bundled claim report hash",
                )
            )
    return failures


def check_bundle(payload: dict[str, Any], verify_files_root: Path | None = None) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    failures.extend(check_artifact(payload.get("browserBinary"), "browserBinary", "browser_binary", verify_files_root))
    failures.extend(check_artifact(payload.get("doeRuntime"), "doeRuntime", "doe_runtime", verify_files_root))
    failures.extend(check_artifact(payload.get("shaderCompiler"), "shaderCompiler", "shader_compiler", verify_files_root))

    contracts = payload.get("contracts", [])
    claim_reports = payload.get("claimReports", [])
    promotion_receipts = payload.get("promotionReceipts", [])
    policies = payload.get("policies", [])
    for index, artifact in enumerate(contracts if isinstance(contracts, list) else []):
        failures.extend(check_artifact(artifact, f"contracts[{index}]", verify_files_root=verify_files_root))
    for index, artifact in enumerate(claim_reports if isinstance(claim_reports, list) else []):
        failures.extend(check_artifact(artifact, f"claimReports[{index}]", verify_files_root=verify_files_root))
    for index, artifact in enumerate(promotion_receipts if isinstance(promotion_receipts, list) else []):
        failures.extend(check_artifact(artifact, f"promotionReceipts[{index}]", verify_files_root=verify_files_root))
    for index, artifact in enumerate(policies if isinstance(policies, list) else []):
        failures.extend(check_artifact(artifact, f"policies[{index}]", verify_files_root=verify_files_root))

    contract_kinds = {row.get("kind") for row in contracts if isinstance(row, dict)}
    claim_kinds = {row.get("kind") for row in claim_reports if isinstance(row, dict)}
    promotion_receipt_kinds = {row.get("kind") for row in promotion_receipts if isinstance(row, dict)}
    policy_kinds = {row.get("kind") for row in policies if isinstance(row, dict)}
    for kind in sorted(REQUIRED_CONTRACT_KINDS - contract_kinds):
        failures.append(failure("missing_contract_kind", "contracts", f"missing contract artifact kind {kind}"))
    for kind in sorted(REQUIRED_CLAIM_KINDS - claim_kinds):
        failures.append(failure("missing_claim_report_kind", "claimReports", f"missing claim report artifact kind {kind}"))
    for kind in sorted(REQUIRED_PROMOTION_RECEIPT_KINDS - promotion_receipt_kinds):
        failures.append(
            failure(
                "missing_promotion_receipt_kind",
                "promotionReceipts",
                f"missing promotion receipt artifact kind {kind}",
            )
        )
    for kind in sorted(REQUIRED_POLICY_KINDS - policy_kinds):
        failures.append(failure("missing_policy_kind", "policies", f"missing policy artifact kind {kind}"))
    failures.extend(check_promotion_receipt_matches_claims(promotion_receipts, claim_reports, verify_files_root))
    if payload.get("releaseStatus") == "release_candidate" and payload.get("failureCodes"):
        failures.append(failure("release_candidate_has_failures", "failureCodes", "release candidates cannot carry failureCodes"))
    return failures


def main() -> int:
    args = parse_args()
    verify_files_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    failures = check_bundle(load_json(Path(args.bundle)), verify_files_root)
    report = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_artifact_bundle_check",
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: browser release artifact bundle")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser release artifact bundle")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
