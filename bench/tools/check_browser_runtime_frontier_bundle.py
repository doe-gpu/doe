#!/usr/bin/env python3
"""Compose browser runtime frontier evidence into one diagnostic bundle."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

from bench.tools import check_browser_claim_promotion_receipt as promotion_check  # noqa: E402
from bench.tools import check_browser_release_artifact_bundle as release_check  # noqa: E402


EXPECTED_KIND = "browser_runtime_frontier_bundle"
RUNTIME_IDENTITY_PATH = (
    REPO_ROOT / "browser" / "chromium" / "scripts" / "check-browser-runtime-identity.py"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--runtime-identity",
        required=True,
        help="browser_runtime_identity artifact path.",
    )
    parser.add_argument(
        "--claim-promotion-receipt",
        required=True,
        help="browser_claim_promotion_receipt artifact path.",
    )
    parser.add_argument(
        "--release-artifact-bundle",
        required=True,
        help="browser_release_artifact_bundle artifact path.",
    )
    parser.add_argument(
        "--verify-files-root",
        default="",
        help="Resolve referenced artifact paths under this root and verify hashes.",
    )
    parser.add_argument(
        "--require-claimable",
        action="store_true",
        help="Fail when the composed browser runtime evidence remains diagnostic.",
    )
    parser.add_argument("--out", default="", help="Optional output bundle path.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def summarize_claim_blockers(blockers: list[dict[str, str]]) -> list[dict[str, Any]]:
    summary: list[dict[str, Any]] = []
    for blocker in blockers:
        code = blocker.get("code", "")
        message = blocker.get("message", "")
        for item in summary:
            if item["code"] == code and item["message"] == message:
                item["count"] += 1
                break
        else:
            summary.append({"code": code, "message": message, "count": 1})
    return summary


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def load_runtime_identity_checker():
    spec = importlib.util.spec_from_file_location(
        "browser_runtime_identity_for_frontier_bundle",
        RUNTIME_IDENTITY_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load runtime identity checker: {RUNTIME_IDENTITY_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resolve_repo_path(path_text: str, root: Path) -> Path | None:
    if not isinstance(path_text, str) or not path_text:
        return None
    path = Path(path_text)
    candidate = path if path.is_absolute() else root.joinpath(*PurePosixPath(path_text).parts)
    try:
        resolved = candidate.resolve()
        resolved.relative_to(root.resolve())
    except (OSError, ValueError):
        return None
    return resolved


def browser_identity_claim_blockers(identity: dict[str, Any]) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []
    if identity.get("evidenceSource") != "runtime_selection_artifact":
        blockers.append(
            failure(
                "claim_grade_browser_runtime_identity",
                "runtimeIdentity.evidenceSource",
                "claim-grade browser identity requires Chromium runtime-selection evidence",
            )
        )
    if identity.get("executionOwner") != "chromium_runtime_selector":
        blockers.append(
            failure(
                "claim_grade_browser_runtime_identity",
                "runtimeIdentity.executionOwner",
                "claim-grade browser identity requires chromium_runtime_selector ownership",
            )
        )
    if identity.get("selectedRuntime") != "doe":
        blockers.append(
            failure(
                "claim_grade_browser_runtime_identity",
                "runtimeIdentity.selectedRuntime",
                "claim-grade browser identity must select Doe",
            )
        )
    if identity.get("doeRuntimeActive") is not True:
        blockers.append(
            failure(
                "claim_grade_browser_runtime_identity",
                "runtimeIdentity.doeRuntimeActive",
                "claim-grade browser identity must prove Doe runtime is active",
            )
        )
    runtime_selection = identity.get("runtimeSelection")
    if not isinstance(runtime_selection, dict):
        blockers.append(
            failure(
                "claim_grade_browser_runtime_identity",
                "runtimeIdentity.runtimeSelection",
                "claim-grade browser identity must embed runtime selection state",
            )
        )
        return blockers
    if runtime_selection.get("hiddenFallbackAllowed") is not False:
        blockers.append(
            failure(
                "claim_grade_browser_runtime_identity",
                "runtimeIdentity.runtimeSelection.hiddenFallbackAllowed",
                "claim-grade browser identity requires hidden fallback disabled",
            )
        )
    if runtime_selection.get("fallbackApplied") is not False:
        blockers.append(
            failure(
                "claim_grade_browser_runtime_identity",
                "runtimeIdentity.runtimeSelection.fallbackApplied",
                "claim-grade browser identity cannot have applied fallback",
            )
        )
    return blockers


def promotion_claim_blockers(promotion: dict[str, Any]) -> list[dict[str, str]]:
    if promotion.get("promotionStatus") == "promotable":
        return []
    return [
        failure(
            "claim_grade_browser_runtime_identity",
            "claimPromotionReceipt.promotionStatus",
            "browser claim promotion receipt must be promotable",
        )
    ]


def promotion_failure_claim_blockers(
    promotion_failures: list[dict[str, str]],
) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []
    for item in promotion_failures:
        if item.get("code") not in release_check.PROMOTION_RECEIPT_CLAIM_FAILURE_CODES:
            continue
        blockers.append(
            failure(
                "claim_grade_browser_runtime_identity",
                f"claimPromotionReceipt.{item.get('path', '')}",
                str(item.get("message", "")),
            )
        )
    return blockers


def split_promotion_failures(
    promotion_failures: list[dict[str, str]],
    *,
    release_status: str,
    require_claimable: bool,
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    if require_claimable or release_status == "release_candidate":
        return promotion_failures, []
    hard_failures: list[dict[str, str]] = []
    claim_failures: list[dict[str, str]] = []
    for item in promotion_failures:
        if item.get("code") in release_check.PROMOTION_RECEIPT_CLAIM_FAILURE_CODES:
            claim_failures.append(item)
        else:
            hard_failures.append(item)
    return hard_failures, claim_failures


def claim_reports_from_bundle(
    release_bundle: dict[str, Any],
    root: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    claim_reports: list[dict[str, Any]] = []
    blockers: list[dict[str, str]] = []
    for index, artifact in enumerate(release_bundle.get("claimReports", [])):
        if not isinstance(artifact, dict):
            continue
        artifact_path = artifact.get("path")
        resolved = resolve_repo_path(artifact_path, root) if isinstance(artifact_path, str) else None
        if resolved is None or not resolved.is_file():
            blockers.append(
                failure(
                    "browser_structural_equivalence_receipts",
                    f"releaseBundle.claimReports[{index}].path",
                    f"claim report cannot be loaded: {artifact_path}",
                )
            )
            continue
        try:
            payload = load_json(resolved)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            blockers.append(
                failure(
                    "browser_structural_equivalence_receipts",
                    f"releaseBundle.claimReports[{index}].path",
                    f"claim report cannot be loaded: {exc}",
                )
            )
            continue
        claim_reports.append({"path": artifact_path, "payload": payload})
    return claim_reports, blockers


def claim_report_structural_status(payload: dict[str, Any]) -> str:
    structural = payload.get("structuralReceipts")
    if not isinstance(structural, dict):
        return "missing"
    return str(structural.get("status", ""))


def structural_receipt_blockers(
    payload: dict[str, Any],
    index: int,
) -> list[dict[str, str]]:
    structural = payload.get("structuralReceipts")
    if not isinstance(structural, dict):
        return [
            failure(
                "browser_structural_equivalence_receipts",
                f"claimReports[{index}].structuralReceipts",
                "browser claim report must include structural receipt summary",
            )
        ]

    blockers: list[dict[str, str]] = []
    if structural.get("status") != "pass":
        blockers.append(
            failure(
                "browser_structural_equivalence_receipts",
                f"claimReports[{index}].structuralReceipts.status",
                "browser structural receipts must pass",
            )
        )
    if not isinstance(structural.get("sourceKernelDispatchWorkloadCount"), int) or structural.get("sourceKernelDispatchWorkloadCount") <= 0:
        blockers.append(
            failure(
                "browser_structural_equivalence_receipts",
                f"claimReports[{index}].structuralReceipts.sourceKernelDispatchWorkloadCount",
                "browser structural receipts must cover at least one source-kernel dispatch workload",
            )
        )
    source_identity = structural.get("sourceCommandIdentity")
    if not isinstance(source_identity, dict) or source_identity.get("verified") is not True:
        blockers.append(
            failure(
                "browser_structural_equivalence_receipts",
                f"claimReports[{index}].structuralReceipts.sourceCommandIdentity.verified",
                "browser structural receipts must verify source command identity",
            )
        )
    dispatch_parity = structural.get("dispatchShapeParity")
    if not isinstance(dispatch_parity, dict) or dispatch_parity.get("verified") is not True:
        blockers.append(
            failure(
                "browser_structural_equivalence_receipts",
                f"claimReports[{index}].structuralReceipts.dispatchShapeParity.verified",
                "browser structural receipts must verify dispatch-shape parity",
            )
        )
    checker_reports = structural.get("checkerReports")
    if not isinstance(checker_reports, list) or not checker_reports:
        blockers.append(
            failure(
                "browser_structural_equivalence_receipts",
                f"claimReports[{index}].structuralReceipts.checkerReports",
                "browser structural receipts must name browser superset checker reports",
            )
        )
    else:
        for checker_index, checker_report in enumerate(checker_reports):
            if not isinstance(checker_report, dict):
                blockers.append(
                    failure(
                        "browser_structural_equivalence_receipts",
                        f"claimReports[{index}].structuralReceipts.checkerReports[{checker_index}]",
                        "browser structural checker report summary must be an object",
                    )
                )
                continue
            if checker_report.get("status") != "pass" or checker_report.get("errorCount") != 0:
                blockers.append(
                    failure(
                        "browser_structural_equivalence_receipts",
                        f"claimReports[{index}].structuralReceipts.checkerReports[{checker_index}]",
                        "browser structural checker report must pass without errors",
                    )
                )
    failure_codes = structural.get("failureCodes")
    if isinstance(failure_codes, list) and failure_codes:
        blockers.append(
            failure(
                "browser_structural_equivalence_receipts",
                f"claimReports[{index}].structuralReceipts.failureCodes",
                "browser structural receipts must not carry failure codes",
            )
        )
    return blockers


def claim_report_summary_and_blockers(
    claim_reports: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    summaries: list[dict[str, Any]] = []
    blockers: list[dict[str, str]] = []
    if not claim_reports:
        blockers.append(
            failure(
                "browser_structural_equivalence_receipts",
                "releaseBundle.claimReports",
                "at least one browser claim report must be inspectable",
            )
        )
        return summaries, blockers
    for index, item in enumerate(claim_reports):
        payload = item["payload"]
        path = item["path"]
        workloads = payload.get("workloads") if isinstance(payload.get("workloads"), list) else []
        report_blockers = []
        for workload_index, workload in enumerate(workloads):
            if not isinstance(workload, dict):
                continue
            if workload.get("comparisonStatus") != "comparable":
                report_blockers.append(
                    failure(
                        "browser_structural_equivalence_receipts",
                        f"claimReports[{index}].workloads[{workload_index}].comparisonStatus",
                        "browser workload must be comparable",
                    )
                )
            claimability = workload.get("claimability")
            if not isinstance(claimability, dict) or claimability.get("claimable") is not True:
                report_blockers.append(
                    failure(
                        "browser_structural_equivalence_receipts",
                        f"claimReports[{index}].workloads[{workload_index}].claimability",
                        "browser workload must be claimable",
                    )
                )
        if payload.get("reportKind") != "browser-claim-report":
            blockers.append(
                failure(
                    "browser_structural_equivalence_receipts",
                    f"claimReports[{index}].reportKind",
                    "claim report must have reportKind=browser-claim-report",
                )
            )
        if payload.get("comparisonStatus") != "comparable":
            report_blockers.append(
                failure(
                    "browser_structural_equivalence_receipts",
                    f"claimReports[{index}].comparisonStatus",
                    "browser claim report must be comparable",
                )
            )
        if payload.get("claimStatus") != "claimable":
            report_blockers.append(
                failure(
                    "browser_structural_equivalence_receipts",
                    f"claimReports[{index}].claimStatus",
                    "browser claim report must be claimable",
                )
            )
        report_blockers.extend(structural_receipt_blockers(payload, index))
        blockers.extend(report_blockers)
        structural = payload.get("structuralReceipts")
        source_kernel_count = (
            structural.get("sourceKernelDispatchWorkloadCount")
            if isinstance(structural, dict)
            and isinstance(structural.get("sourceKernelDispatchWorkloadCount"), int)
            else 0
        )
        summaries.append(
            {
                "path": str(path),
                "comparisonStatus": str(payload.get("comparisonStatus", "")),
                "claimStatus": str(payload.get("claimStatus", "")),
                "structuralStatus": claim_report_structural_status(payload),
                "workloadCount": len(workloads),
                "sourceKernelDispatchWorkloadCount": source_kernel_count,
                "claimBlockerCount": len(report_blockers),
            }
        )
    return summaries, blockers


def release_claim_blockers(
    release_bundle: dict[str, Any],
    *,
    artifacts_verified: bool,
) -> list[dict[str, str]]:
    blockers: list[dict[str, str]] = []
    release_status = release_bundle.get("releaseStatus")
    if release_status != "release_candidate":
        blockers.append(
            failure(
                "chromium_release_build_evidence",
                "releaseBundle.releaseStatus",
                "browser release artifact bundle must be a release_candidate",
            )
        )
    failure_codes = release_bundle.get("failureCodes")
    if isinstance(failure_codes, list) and failure_codes:
        blockers.append(
            failure(
                "chromium_release_build_evidence",
                "releaseBundle.failureCodes",
                "browser release artifact bundle must not carry failure codes",
            )
        )
    if release_status == "release_candidate" and not failure_codes and not artifacts_verified:
        blockers.append(
            failure(
                "chromium_release_build_evidence",
                "releaseBundle.artifactVerification.verified",
                "browser release artifact bundle must verify files and hashes with --verify-files-root",
            )
        )
    return blockers


def summarize_promotion(
    promotion: dict[str, Any],
    path: str,
    failures: list[dict[str, str]],
    *,
    loaded: bool = True,
) -> dict[str, Any]:
    hidden = promotion.get("hiddenFallbackCheck")
    hidden_passed = hidden.get("passed") if isinstance(hidden, dict) else None
    artifacts = promotion.get("artifacts") if isinstance(promotion.get("artifacts"), list) else []
    return {
        "path": path,
        "status": "fail" if failures or not loaded else "pass",
        "promotionStatus": str(promotion.get("promotionStatus", "")),
        "artifactCount": len(artifacts),
        "hiddenFallbackPassed": hidden_passed,
    }


def release_bundle_identity_sha256(release_bundle: dict[str, Any]) -> str:
    projection = {
        key: value
        for key, value in release_bundle.items()
        if key != "runtimeFrontierBundle"
    }
    encoded = json.dumps(
        projection,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def summarize_release(
    release_bundle: dict[str, Any],
    path: str,
    failures: list[dict[str, str]],
    claim_report_summaries: list[dict[str, Any]],
    artifact_verification: dict[str, Any],
    *,
    loaded: bool = True,
) -> dict[str, Any]:
    return {
        "path": path,
        "status": "fail" if failures or not loaded else "pass",
        "artifactKind": str(release_bundle.get("artifactKind", "")),
        "bundleId": str(release_bundle.get("bundleId", "")),
        "releaseStatus": str(release_bundle.get("releaseStatus", "")),
        "releaseBundleIdentitySha256": (
            release_bundle_identity_sha256(release_bundle)
            if release_bundle
            else ""
        ),
        "artifactVerification": artifact_verification,
        "claimReports": claim_report_summaries,
    }


def summarize_artifact_verification(
    *,
    verify_files_root: Path | None,
    release_loaded: bool,
    release_failures: list[dict[str, str]],
) -> dict[str, bool]:
    return {
        "requiredForClaimable": True,
        "verifyFilesRootProvided": verify_files_root is not None,
        "verified": release_loaded and verify_files_root is not None and not release_failures,
    }


def path_matches(path_text: str, candidates: set[str], root: Path) -> bool:
    resolved = resolve_repo_path(path_text, root)
    return any(path_text == candidate or (resolved is not None and resolved == resolve_repo_path(candidate, root)) for candidate in candidates)


def release_input_binding_failures(
    release_bundle: dict[str, Any],
    *,
    runtime_identity_path: str,
    claim_promotion_receipt_path: str,
    root: Path,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    promotion_paths = {row.get("path") for row in release_bundle.get("promotionReceipts", []) if isinstance(row, dict) and isinstance(row.get("path"), str)}
    if not path_matches(claim_promotion_receipt_path, promotion_paths, root):
        failures.append(failure("claim_promotion_receipt_release_mismatch", "claimPromotionReceipt.path", "claim promotion receipt path must match release bundle promotionReceipts"))
    proof_surface = release_bundle.get("proofSurface")
    proof_path = proof_surface.get("path") if isinstance(proof_surface, dict) else None
    resolved_proof = resolve_repo_path(proof_path, root) if isinstance(proof_path, str) else None
    proof_payload: dict[str, Any] = {}
    if resolved_proof is not None and resolved_proof.is_file():
        try:
            proof_payload = load_json(resolved_proof)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            failures.append(failure("proof_surface_load_failed", "releaseBundle.proofSurface.path", f"proof surface cannot be loaded: {exc}"))
    if proof_payload and not path_matches(runtime_identity_path, {str(proof_payload.get("runtimeIdentityPath", ""))}, root):
        failures.append(failure("runtime_identity_release_mismatch", "runtimeIdentity.path", "runtime identity path must match proof surface runtimeIdentityPath"))
    return failures


def build_report(
    *,
    runtime_identity_path: str,
    claim_promotion_receipt_path: str,
    release_artifact_bundle_path: str,
    release_artifact_bundle_summary_path: str | None = None,
    root: Path,
    verify_files_root: Path | None = None,
    require_claimable: bool = False,
) -> dict[str, Any]:
    failures: list[dict[str, str]] = []
    claim_blockers: list[dict[str, str]] = []
    runtime_checker = load_runtime_identity_checker()

    identity_loaded = True
    try:
        identity = load_json(resolve_repo_path(runtime_identity_path, root) or Path(runtime_identity_path))
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        identity_loaded = False
        identity = {}
        failures.append(
            failure(
                "runtime_identity_load_failed",
                "runtimeIdentity",
                str(exc),
            )
        )
    promotion_loaded = True
    try:
        promotion = load_json(
            resolve_repo_path(claim_promotion_receipt_path, root) or Path(claim_promotion_receipt_path)
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        promotion_loaded = False
        promotion = {}
        failures.append(
            failure(
                "claim_promotion_receipt_load_failed",
                "claimPromotionReceipt",
                str(exc),
            )
        )
    release_loaded = True
    try:
        release_bundle = load_json(
            resolve_repo_path(release_artifact_bundle_path, root) or Path(release_artifact_bundle_path)
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        release_loaded = False
        release_bundle = {}
        failures.append(
            failure(
                "release_artifact_bundle_load_failed",
                "releaseBundle",
                str(exc),
            )
        )

    identity_failures = runtime_checker.check_identity(identity) if identity else []
    raw_promotion_failures = (
        promotion_check.check_receipt(promotion, verify_files_root) if promotion else []
    )
    release_failures = (
        release_check.check_bundle(
            release_bundle,
            verify_files_root,
            bundle_path=release_artifact_bundle_path,
            skip_runtime_frontier_bundle_artifact=True,
        )
        if release_bundle
        else []
    )
    if release_bundle:
        release_failures.extend(release_input_binding_failures(release_bundle, runtime_identity_path=runtime_identity_path, claim_promotion_receipt_path=claim_promotion_receipt_path, root=root))
    release_status = str(release_bundle.get("releaseStatus", "")) if release_bundle else ""
    promotion_failures, promotion_claim_failures = split_promotion_failures(
        raw_promotion_failures,
        release_status=release_status,
        require_claimable=require_claimable,
    )
    release_artifact_verification = summarize_artifact_verification(
        verify_files_root=verify_files_root,
        release_loaded=release_loaded,
        release_failures=release_failures,
    )
    failures.extend(
        failure("runtime_identity_failure", item["path"], item["message"])
        for item in identity_failures
    )
    failures.extend(
        failure("claim_promotion_receipt_failure", item["path"], item["message"])
        for item in promotion_failures
    )
    failures.extend(
        failure("release_artifact_bundle_failure", item["path"], item["message"])
        for item in release_failures
    )

    if not identity_failures and identity:
        claim_blockers.extend(browser_identity_claim_blockers(identity))
    if promotion:
        if not promotion_failures:
            claim_blockers.extend(promotion_claim_blockers(promotion))
            claim_blockers.extend(
                promotion_failure_claim_blockers(promotion_claim_failures)
            )

    claim_reports, claim_report_load_blockers = (
        claim_reports_from_bundle(release_bundle, root) if release_bundle else ([], [])
    )
    claim_report_summaries, claim_report_blockers = claim_report_summary_and_blockers(
        claim_reports
    )
    claim_blockers.extend(claim_report_load_blockers)
    claim_blockers.extend(claim_report_blockers)
    if release_bundle:
        claim_blockers.extend(
            release_claim_blockers(
                release_bundle,
                artifacts_verified=release_artifact_verification["verified"],
            )
        )

    if require_claimable and claim_blockers:
        failures.extend(claim_blockers)

    claimability_status = "claimable" if not claim_blockers else "blocked"
    release_summary_path = (
        release_artifact_bundle_summary_path or release_artifact_bundle_path
    )
    report = {
        "schemaVersion": 1,
        "artifactKind": EXPECTED_KIND,
        "status": "fail" if failures else "pass",
        "claimabilityStatus": claimability_status,
        "componentReceipts": {
            "runtimeIdentity": {
                "path": runtime_identity_path,
                "status": "fail" if identity_failures or not identity_loaded else "pass",
                "evidenceSource": str(identity.get("evidenceSource", "")),
                "selectedRuntime": str(identity.get("selectedRuntime", "")),
                "doeRuntimeActive": identity.get("doeRuntimeActive")
                if isinstance(identity.get("doeRuntimeActive"), bool)
                else None,
            },
            "claimPromotionReceipt": summarize_promotion(
                promotion,
                claim_promotion_receipt_path,
                promotion_failures,
                loaded=promotion_loaded,
            ),
            "releaseArtifactBundle": summarize_release(
                release_bundle,
                release_summary_path,
                release_failures,
                claim_report_summaries,
                release_artifact_verification,
                loaded=release_loaded,
            ),
        },
        "claimBlockers": claim_blockers,
        "claimBlockerSummary": summarize_claim_blockers(claim_blockers),
        "failures": failures,
        "summary": {
            "claimReportCount": len(claim_report_summaries),
            "claimBlockerCount": len(claim_blockers),
            "failureCount": len(failures),
        },
    }
    return report


def main() -> int:
    args = parse_args()
    verify_files_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    try:
        report = build_report(
            runtime_identity_path=args.runtime_identity,
            claim_promotion_receipt_path=args.claim_promotion_receipt,
            release_artifact_bundle_path=args.release_artifact_bundle,
            root=REPO_ROOT,
            verify_files_root=verify_files_root,
            require_claimable=args.require_claimable,
        )
    except (OSError, RuntimeError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        report = {
            "schemaVersion": 1,
            "artifactKind": EXPECTED_KIND,
            "status": "fail",
            "claimabilityStatus": "blocked",
            "componentReceipts": {
                "runtimeIdentity": {
                    "path": args.runtime_identity,
                    "status": "fail",
                    "evidenceSource": "",
                    "selectedRuntime": "",
                    "doeRuntimeActive": None,
                },
                "claimPromotionReceipt": {
                    "path": args.claim_promotion_receipt,
                    "status": "fail",
                    "promotionStatus": "",
                    "artifactCount": 0,
                    "hiddenFallbackPassed": None,
                },
                "releaseArtifactBundle": {
                    "path": args.release_artifact_bundle,
                    "status": "fail",
                    "artifactKind": "",
                    "bundleId": "",
                    "releaseStatus": "",
                    "releaseBundleIdentitySha256": "",
                    "artifactVerification": {
                        "requiredForClaimable": True,
                        "verifyFilesRootProvided": verify_files_root is not None,
                        "verified": False,
                    },
                    "claimReports": [],
                },
            },
            "claimBlockers": [],
            "claimBlockerSummary": [],
            "failures": [failure("input_load_failed", "input", str(exc))],
            "summary": {
                "claimReportCount": 0,
                "claimBlockerCount": 0,
                "failureCount": 1,
            },
        }
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif report["failures"]:
        print("FAIL: browser runtime frontier bundle")
        for item in report["failures"]:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser runtime frontier bundle")
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
