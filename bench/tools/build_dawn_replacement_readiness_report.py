#!/usr/bin/env python3
"""Build a Dawn/Tint replacement readiness report from gated frontier data."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import stat
import zipfile
from collections import Counter
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

from bench.gates import dawn_replacement_frontier_gate as frontier_gate
from bench.gates.claim_index_browser_release_proof import (
    BROWSER_GALLERY_CATEGORIES,
    validate_claim_indexed_launch_matches_proof_surface,
    validate_claim_indexed_proof_surface,
    validate_proof_surface_runtime_identity_release_hashes,
)
from bench.gates.claim_index_browser_release_receipts import (
    validate_claim_indexed_proof_surface_receipts,
)
from bench.lib.bench_utils import (
    detect_repo_root,
    load_json_object,
    unsafe_repo_path_reason,
    write_json_object,
)
from bench.tools._public_url import is_public_https_url
from bench.tools import build_webgpu_cts_backend_pass_ledger as cts_backend_ledger_builder
from bench.tools.check_browser_release_package_inputs import detect_file_identity_bytes


PRODUCT_SURFACES = {
    "native_runtime",
    "package_runtime",
    "browser_runtime",
    "shader_compiler",
    "spec_conformance",
    "drop_in_runtime",
}
BROWSER_FRONTIER_ROW_ID = "browser-chromium-runtime"
BROWSER_CLAIM_INDEX_PROMOTION_BLOCKER = "browser_claim_index_promotion"
BROWSER_RELEASE_BUILD_EVIDENCE_BLOCKER = "chromium_release_build_evidence"
BROWSER_FRONTIER_BUNDLE_PATH = Path("examples/browser-runtime-frontier-bundle.sample.json")
BROWSER_FRONTIER_BUNDLE_KIND = "browser_runtime_frontier_bundle"
BROWSER_PROVENANCE_REPORT_PATH = Path("examples/browser-release-candidate-provenance.sample.json")
BROWSER_PACKAGE_INPUTS_PATH = Path("examples/browser-release-package-inputs-check.sample.json")
BROWSER_PUBLIC_DOWNLOAD_RECEIPT_PATH = Path("examples/browser-public-download-receipt.sample.json")
BROWSER_LAUNCH_RECEIPT_PATH = Path("examples/browser-release-launch-receipt.sample.json")
BROWSER_CHROMIUM_SOURCE_CHECKOUT_PATH = Path("examples/chromium-source-checkout-check.sample.json")
BROWSER_PROOF_SURFACE_PATH = Path("examples/browser-published-proof-surface.sample.json")
BROWSER_PROOF_SURFACE_CHECK_PATH = Path("examples/browser-published-proof-surface-check.sample.json")
BROWSER_FINALIZER_REPORT_PATH = Path("examples/browser-release-candidate-finalizer.sample.json")
BROWSER_FINALIZER_CHECK_PATH = Path("examples/browser-release-candidate-finalizer-check.sample.json")
TINT_FRONTIER_ROW_ID = "wgsl-tint-compiler"
TINT_FRONTIER_BUNDLE_PATH = Path("examples/tint-compiler-frontier-bundle.sample.json")
TINT_FRONTIER_BUNDLE_KIND = "tint_compiler_frontier_bundle"
CTS_CONFORMANCE_ROW_ID = "webgpu-cts-conformance"
CTS_CLAIM_POLICY_BLOCKER = "conformance_claim_policy"
CTS_SUBSET_RECEIPT_BLOCKER = "published_cts_subset_receipt"
CTS_BACKEND_PASS_LEDGER_BLOCKER = "backend_specific_cts_pass_ledger"
CTS_EVIDENCE_PATH = Path("config/webgpu-cts-evidence.json")
CTS_SUBSET_RECEIPT_PATH = Path("examples/webgpu-cts-subset-receipt.sample.json")
CTS_BACKEND_PASS_LEDGER_PATH = Path("examples/webgpu-cts-backend-pass-ledger.sample.json")
CTS_EVIDENCE_KIND = "webgpu_cts_evidence"
CTS_SUBSET_RECEIPT_KIND = "webgpu_cts_subset_receipt"
CTS_BACKEND_PASS_LEDGER_KIND = "webgpu_cts_backend_pass_ledger"
CTS_CLAIM_POLICY_KIND = "webgpu_cts_conformance_claim_policy"
CTS_CLAIM_LANGUAGE = "diagnostic_until_full_published_pass_ledger"
CTS_SUBSET_PUBLICATION_STATUS = "repo_published"
CTS_BACKEND_PASS_LEDGER_CLAIM_SCOPE = "published_subset_backend_pass_ledger"
CTS_SUBSET_REQUIRED_ROW_FIELDS = (
    "query",
    "bucket",
    "status",
    "surface",
    "backend",
    "host",
    "os",
    "artifactPath",
)
CTS_SUBSET_STATUS_VALUES = ("pass", "fail", "skip", "not_run")
CTS_SUBSET_SUMMARY_FIELDS = (
    "coverageRowCount",
    "queryCount",
    "backendCount",
    "surfaceCount",
    "artifactPathCount",
    "passCount",
    "failCount",
    "skipCount",
    "notRunCount",
)
CTS_POLICY_REQUIREMENT_FIELDS = (
    "publishedSubsetReceipt",
    "backendSpecificPassLedger",
    "noFailingRequiredRows",
    "backendIdentityRequired",
    "artifactPathsRequired",
)
CTS_ALLOWED_CLAIM_STATES = {
    "diagnostic": True,
    "subset_conformance": False,
    "replacement_conformance": False,
}
RELEASE_DIRECT_IDENTITY_FIELDS = (
    "browserProduct",
    "platform",
    "browserExecutableArchivePath",
    "browserAppMetadataArchivePath",
    "doeRuntimeArchivePath",
    "dawnFallbackRuntimeArchivePath",
)
RELEASE_PRODUCT_IDENTITY_FIELDS = ("browserProduct", "platform")
RELEASE_ARCHIVE_MANIFEST_MEMBER_BINDINGS = (
    ("browserExecutable", "browserExecutableArchivePath", "browserBinary", True),
    ("appMetadata", "browserAppMetadataArchivePath", None, False),
    ("doeRuntime", "doeRuntimeArchivePath", "doeRuntime", False),
    ("dawnFallbackRuntime", "dawnFallbackRuntimeArchivePath", "dawnFallbackRuntime", False),
)
RELEASE_ARCHIVE_DIRECT_MEMBER_BINDINGS = (
    (
        "browser executable",
        "browserBinary",
        "browserExecutableArchivePath",
        True,
    ),
    ("Doe runtime", "doeRuntime", "doeRuntimeArchivePath", False),
    (
        "Dawn fallback runtime",
        "dawnFallbackRuntime",
        "dawnFallbackRuntimeArchivePath",
        False,
    ),
)
RELEASE_ARCHIVE_REQUIRED_MEMBER_PATH_FIELDS = (
    ("browserExecutableArchivePath", "browser executable"),
    ("browserAppMetadataArchivePath", "app metadata"),
    ("doeRuntimeArchivePath", "Doe runtime"),
    ("dawnFallbackRuntimeArchivePath", "Dawn fallback runtime"),
)
ALLOWED_BROWSER_PRODUCTS = {
    "doe-browser": "Doe Browser",
    "fawn-doe": "Fawn Doe",
}
ALLOWED_BROWSER_PRODUCT_BUNDLE_IDS = {
    "doe-browser": "dev.doe.doe-browser",
    "fawn-doe": "dev.doe.fawn-doe",
}
ALLOWED_BROWSER_PRODUCT_CHANNELS = {"diagnostic", "release_candidate", "release"}
ALLOWED_RELEASE_PLATFORM_OS = {"macos", "linux", "windows"}
ALLOWED_RELEASE_PLATFORM_ARCH = {"arm64", "x64"}
ALLOWED_RELEASE_PACKAGE_FORMATS = {"zip"}
REQUIRED_RELEASE_SUPPORT_KINDS = {
    "contracts": {"contract"},
    "claimReports": {"browser_claim_report"},
    "promotionReceipts": {"browser_claim_promotion_receipt"},
    "policies": {
        "runtime_selector_policy",
        "fork_maintenance_policy",
        "chromium_patch_manifest",
        "browser_claim_policy",
        "browser_capture_policy",
        "browser_artifact_identity_coverage",
        "browser_unsupported_reason_taxonomy",
    },
}
RELEASE_SUPPORT_KIND_SUMMARY_FIELDS = {
    "contracts": "contractKinds",
    "claimReports": "claimReportKinds",
    "promotionReceipts": "promotionReceiptKinds",
    "policies": "policyKinds",
}
RELEASE_SUPPORT_MISSING_KIND_CODES = {
    "contracts": "release_support_contract_kind_missing",
    "claimReports": "release_support_claim_report_kind_missing",
    "promotionReceipts": "release_support_promotion_receipt_kind_missing",
    "policies": "release_support_policy_kind_missing",
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
        "--browser-frontier-bundle",
        default=str(BROWSER_FRONTIER_BUNDLE_PATH),
        help="Browser runtime frontier bundle path relative to the repository root.",
    )
    parser.add_argument(
        "--browser-provenance-report",
        default=str(BROWSER_PROVENANCE_REPORT_PATH),
        help="Browser release-candidate provenance report path relative to the repository root.",
    )
    parser.add_argument(
        "--browser-package-inputs",
        default=str(BROWSER_PACKAGE_INPUTS_PATH),
        help="Browser release package-input preflight report path relative to the repository root.",
    )
    parser.add_argument(
        "--browser-public-download-receipt",
        default=str(BROWSER_PUBLIC_DOWNLOAD_RECEIPT_PATH),
        help="Browser public download receipt path relative to the repository root.",
    )
    parser.add_argument(
        "--browser-launch-receipt",
        default=str(BROWSER_LAUNCH_RECEIPT_PATH),
        help="Browser release launch receipt path relative to the repository root.",
    )
    parser.add_argument(
        "--browser-chromium-source-checkout",
        default=str(BROWSER_CHROMIUM_SOURCE_CHECKOUT_PATH),
        help="Chromium source checkout/runtime-selector report path relative to the repository root.",
    )
    parser.add_argument(
        "--browser-proof-surface",
        default=str(BROWSER_PROOF_SURFACE_PATH),
        help="Browser published proof-surface path relative to the repository root.",
    )
    parser.add_argument(
        "--browser-proof-surface-check",
        default=str(BROWSER_PROOF_SURFACE_CHECK_PATH),
        help="Browser published proof-surface checker report path relative to the repository root.",
    )
    parser.add_argument(
        "--browser-finalizer-report",
        default=str(BROWSER_FINALIZER_REPORT_PATH),
        help="Browser release-candidate finalizer report path relative to the repository root.",
    )
    parser.add_argument(
        "--browser-finalizer-check",
        default=str(BROWSER_FINALIZER_CHECK_PATH),
        help="Browser release-candidate finalizer checker report path relative to the repository root.",
    )
    parser.add_argument(
        "--tint-frontier-bundle",
        default=str(TINT_FRONTIER_BUNDLE_PATH),
        help="Tint compiler frontier bundle path relative to the repository root.",
    )
    parser.add_argument(
        "--cts-evidence",
        default=str(CTS_EVIDENCE_PATH),
        help="WebGPU CTS evidence path relative to the repository root.",
    )
    parser.add_argument(
        "--cts-subset-receipt",
        default=str(CTS_SUBSET_RECEIPT_PATH),
        help="WebGPU CTS subset receipt path relative to the repository root.",
    )
    parser.add_argument(
        "--cts-backend-pass-ledger",
        default=str(CTS_BACKEND_PASS_LEDGER_PATH),
        help="WebGPU CTS backend pass-ledger path relative to the repository root.",
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
    out: dict[str, Any] = {
        "id": entry_id,
        "claimState": entry.get("claimState", ""),
        "comparisonStatus": entry.get("comparisonStatus", ""),
        "claimStatus": entry.get("claimStatus", ""),
        "reportPath": entry.get("reportPath", ""),
        "claimPath": entry.get("claimPath", ""),
    }
    blocker = entry.get("blocker")
    if isinstance(blocker, str) and blocker:
        out["blocker"] = blocker
    browser_release = entry.get("browserRelease")
    if isinstance(browser_release, dict):
        out["browserRelease"] = browser_release
    return out


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def repo_relative_path_failure(
    path_text: Any,
    *,
    code: str,
    path: str,
    label: str,
) -> dict[str, str] | None:
    if not isinstance(path_text, str) or not path_text:
        return None
    unsafe_reason = unsafe_repo_path_reason(path_text, allow_empty=False)
    if unsafe_reason:
        return failure(code, path, f"{label} {unsafe_reason}")
    return None


def repo_relative_file_path(root: Path, path_text: Any) -> Path | None:
    if not isinstance(path_text, str) or not path_text:
        return None
    if unsafe_repo_path_reason(path_text, allow_empty=False):
        return None
    return root / Path(path_text)


def release_bundle_identity_sha256(payload: dict[str, Any]) -> str:
    projection = {
        key: value
        for key, value in payload.items()
        if key != "runtimeFrontierBundle"
    }
    encoded = json.dumps(
        projection,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def row_readiness_status(row: dict[str, Any]) -> str:
    if row.get("claimAllowed") is True:
        return "claimable"
    if row.get("currentState") == "covered":
        return "covered"
    return "blocked"


def slice_blocker_codes(
    evidence_slice: dict[str, Any],
    row_blocker_codes: list[str],
    resolved_row_blocker_codes: list[str],
) -> list[str]:
    blockers = evidence_slice.get("blockers", [])
    if not isinstance(blockers, list):
        return []
    blocker_codes = [code for code in blockers if isinstance(code, str)]
    if blocker_codes == row_blocker_codes:
        return resolved_row_blocker_codes
    return blocker_codes


def build_evidence_slice_report(
    evidence_slice: dict[str, Any],
    *,
    row_blocker_codes: list[str],
    resolved_row_blocker_codes: list[str],
    definitions_by_code: dict[str, dict[str, Any]],
    entries_by_id: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    claim_ids = evidence_slice.get("claimIndexEntryIds", [])
    if not isinstance(claim_ids, list):
        claim_ids = []
    claim_entry_ids = [
        entry_id for entry_id in claim_ids if isinstance(entry_id, str)
    ]
    blocker_codes = slice_blocker_codes(
        evidence_slice,
        row_blocker_codes,
        resolved_row_blocker_codes,
    )
    return {
        "id": evidence_slice.get("id", ""),
        "label": evidence_slice.get("label", ""),
        "os": evidence_slice.get("os", ""),
        "arch": evidence_slice.get("arch", ""),
        "gpuApi": evidence_slice.get("gpuApi", ""),
        "gpuVendor": evidence_slice.get("gpuVendor", ""),
        "runtimeHost": evidence_slice.get("runtimeHost", ""),
        "currentState": evidence_slice.get("currentState", ""),
        "claimAllowed": evidence_slice.get("claimAllowed") is True,
        "readinessStatus": row_readiness_status(evidence_slice),
        "claimIndexEntries": [
            compact_claim_entry(entry_id, entries_by_id) for entry_id in claim_entry_ids
        ],
        "blockers": [
            compact_blocker(code, definitions_by_code) for code in blocker_codes
        ],
        "evidencePaths": evidence_slice.get("evidencePaths", []),
        "notes": evidence_slice.get("notes", ""),
    }


def release_candidate_consistency_passed(bundle_evidence: dict[str, Any] | None) -> bool:
    if not isinstance(bundle_evidence, dict):
        return False
    release_candidate_evidence = bundle_evidence.get("releaseCandidateEvidence")
    if not isinstance(release_candidate_evidence, dict):
        return False
    consistency = release_candidate_evidence.get("consistency")
    return isinstance(consistency, dict) and consistency.get("status") == "pass"


def runtime_frontier_claimability_consistency_failures(
    runtime_frontier_bundle: dict[str, Any],
    *,
    proof_surface_summary: dict[str, Any] | None = None,
    release_artifact_bundle: dict[str, Any] | None = None,
) -> list[dict[str, str]]:
    if runtime_frontier_bundle.get("claimabilityStatus") != "claimable":
        return []

    failures: list[dict[str, str]] = []
    if runtime_frontier_bundle.get("status") != "pass":
        failures.append(
            failure(
                "runtime_frontier_bundle_not_pass",
                "frontierBundleEvidence.status",
                "claimable browser runtime frontier bundle must pass",
            )
        )
    if compact_failures(runtime_frontier_bundle.get("failures")):
        failures.append(
            failure(
                "runtime_frontier_bundle_failures_present",
                "frontierBundleEvidence.failures",
                "claimable browser runtime frontier bundle must carry no failures",
            )
        )
    claim_blockers = runtime_frontier_bundle.get("claimBlockers")
    if isinstance(claim_blockers, list) and claim_blockers:
        failures.append(
            failure(
                "runtime_frontier_bundle_claim_blockers_present",
                "frontierBundleEvidence.claimBlockers",
                "claimable browser runtime frontier bundle must carry no claim blockers",
            )
        )
    claim_blocker_summary = runtime_frontier_bundle.get("claimBlockerSummary")
    if isinstance(claim_blocker_summary, list) and claim_blocker_summary:
        failures.append(
            failure(
                "runtime_frontier_bundle_claim_blocker_summary_present",
                "frontierBundleEvidence.claimBlockerSummary",
                "claimable browser runtime frontier bundle must carry no claim blocker summary",
            )
        )
    summary = runtime_frontier_bundle.get("summary")
    if (
        not isinstance(summary, dict)
        or summary.get("failureCount") != 0
        or summary.get("claimBlockerCount") != 0
    ):
        failures.append(
            failure(
                "runtime_frontier_bundle_summary_not_clean",
                "frontierBundleEvidence.summary",
                "claimable browser runtime frontier bundle summary must report zero failures and claim blockers",
            )
        )
    component_receipts = runtime_frontier_bundle.get("componentReceipts")
    component_receipts = component_receipts if isinstance(component_receipts, dict) else {}
    runtime_identity_summary = component_receipts.get("runtimeIdentity")
    expected_runtime_identity_path = (
        proof_surface_summary.get("runtimeIdentityPath")
        if isinstance(proof_surface_summary, dict)
        else None
    )
    if not (
        isinstance(runtime_identity_summary, dict)
        and (
            not isinstance(expected_runtime_identity_path, str)
            or not expected_runtime_identity_path
            or runtime_identity_summary.get("path") == expected_runtime_identity_path
        )
        and runtime_identity_summary.get("status") == "pass"
        and runtime_identity_summary.get("evidenceSource") == "runtime_selection_artifact"
        and runtime_identity_summary.get("selectedRuntime") == "doe"
        and runtime_identity_summary.get("doeRuntimeActive") is True
    ):
        failures.append(
            failure(
                "runtime_frontier_bundle_runtime_identity_mismatch",
                "frontierBundleEvidence.componentReceipts.runtimeIdentity",
                "claimable browser runtime frontier bundle must bind a passing Doe runtime identity component",
            )
        )

    promotion_summary = component_receipts.get("claimPromotionReceipt")
    promotion_artifact_count = (
        promotion_summary.get("artifactCount") if isinstance(promotion_summary, dict) else None
    )
    promotion_paths: set[str] = set()
    if isinstance(release_artifact_bundle, dict):
        promotion_receipts = release_artifact_bundle.get("promotionReceipts")
        if isinstance(promotion_receipts, list):
            promotion_paths = {
                item["path"]
                for item in promotion_receipts
                if isinstance(item, dict)
                and isinstance(item.get("path"), str)
                and item.get("path")
            }
    if not (
        isinstance(promotion_summary, dict)
        and (
            not isinstance(release_artifact_bundle, dict)
            or promotion_summary.get("path") in promotion_paths
        )
        and promotion_summary.get("status") == "pass"
        and promotion_summary.get("promotionStatus") == "promotable"
        and isinstance(promotion_artifact_count, int)
        and not isinstance(promotion_artifact_count, bool)
        and promotion_artifact_count > 0
        and promotion_summary.get("hiddenFallbackPassed") is True
    ):
        failures.append(
            failure(
                "runtime_frontier_bundle_promotion_mismatch",
                "frontierBundleEvidence.componentReceipts.claimPromotionReceipt",
                "claimable browser runtime frontier bundle must bind a release-bundled promotable claim-promotion component",
            )
        )

    release_summary = component_receipts.get("releaseArtifactBundle")
    artifact_verification = (
        release_summary.get("artifactVerification") if isinstance(release_summary, dict) else None
    )
    if not (
        isinstance(release_summary, dict)
        and release_summary.get("status") == "pass"
        and release_summary.get("releaseStatus") == "release_candidate"
        and isinstance(artifact_verification, dict)
        and artifact_verification.get("requiredForClaimable") is True
        and artifact_verification.get("verifyFilesRootProvided") is True
        and artifact_verification.get("verified") is True
    ):
        failures.append(
            failure(
                "runtime_frontier_bundle_release_component_mismatch",
                "frontierBundleEvidence.componentReceipts.releaseArtifactBundle",
                "claimable browser runtime frontier bundle must bind a verified release-candidate artifact bundle component",
            )
        )
    return failures


def claim_allowance_blocker_codes(
    row: dict[str, Any],
    blocker_codes: list[str],
    bundle_evidence: dict[str, Any] | None,
) -> list[str]:
    if blocker_codes:
        return blocker_codes
    if row.get("claimAllowed") is True:
        return blocker_codes
    if row.get("id") != BROWSER_FRONTIER_ROW_ID:
        return blocker_codes
    if not isinstance(bundle_evidence, dict):
        return blocker_codes
    if bundle_evidence.get("status") != "pass":
        return [BROWSER_RELEASE_BUILD_EVIDENCE_BLOCKER]
    if bundle_evidence.get("claimabilityStatus") != "claimable":
        return [BROWSER_RELEASE_BUILD_EVIDENCE_BLOCKER]
    if not release_candidate_consistency_passed(bundle_evidence):
        return [BROWSER_RELEASE_BUILD_EVIDENCE_BLOCKER]
    return [BROWSER_CLAIM_INDEX_PROMOTION_BLOCKER]


def cts_claim_policy_validation_failures(payload: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("artifactKind") != CTS_EVIDENCE_KIND:
        failures.append(
            failure(
                "cts_evidence_artifact_kind_mismatch",
                "ctsConformanceEvidence.artifactKind",
                f"CTS evidence artifactKind must be {CTS_EVIDENCE_KIND}",
            )
        )
    policy = payload.get("claimPolicy")
    if not isinstance(policy, dict):
        return failures + [
            failure(
                "cts_claim_policy_missing",
                "ctsConformanceEvidence.claimPolicy",
                "CTS evidence must define a conformance claim policy",
            )
        ]
    if not isinstance(policy.get("policyId"), str) or not policy.get("policyId"):
        failures.append(
            failure(
                "cts_claim_policy_id_missing",
                "ctsConformanceEvidence.claimPolicy.policyId",
                "CTS claim policy policyId is required",
            )
        )
    if policy.get("artifactKind") != CTS_CLAIM_POLICY_KIND:
        failures.append(
            failure(
                "cts_claim_policy_kind_mismatch",
                "ctsConformanceEvidence.claimPolicy.artifactKind",
                f"CTS claim policy artifactKind must be {CTS_CLAIM_POLICY_KIND}",
            )
        )
    if policy.get("claimLanguage") != CTS_CLAIM_LANGUAGE:
        failures.append(
            failure(
                "cts_claim_policy_language_mismatch",
                "ctsConformanceEvidence.claimPolicy.claimLanguage",
                f"CTS claim policy claimLanguage must be {CTS_CLAIM_LANGUAGE}",
            )
        )
    if not isinstance(policy.get("diagnosticLanguage"), str) or not policy.get(
        "diagnosticLanguage"
    ):
        failures.append(
            failure(
                "cts_claim_policy_diagnostic_language_missing",
                "ctsConformanceEvidence.claimPolicy.diagnosticLanguage",
                "CTS claim policy diagnosticLanguage is required",
            )
        )
    requirements = policy.get("promotionRequirements")
    if not isinstance(requirements, dict):
        failures.append(
            failure(
                "cts_claim_policy_requirements_missing",
                "ctsConformanceEvidence.claimPolicy.promotionRequirements",
                "CTS claim policy promotionRequirements must be an object",
            )
        )
    else:
        for field in CTS_POLICY_REQUIREMENT_FIELDS:
            if requirements.get(field) is not True:
                failures.append(
                    failure(
                        "cts_claim_policy_requirement_not_true",
                        f"ctsConformanceEvidence.claimPolicy.promotionRequirements.{field}",
                        f"CTS claim policy promotionRequirements.{field} must be true",
                    )
                )
    states = policy.get("allowedClaimStates")
    if not isinstance(states, list):
        failures.append(
            failure(
                "cts_claim_policy_states_missing",
                "ctsConformanceEvidence.claimPolicy.allowedClaimStates",
                "CTS claim policy allowedClaimStates must be a list",
            )
        )
        return failures
    seen_states: set[str] = set()
    for index, state_row in enumerate(states):
        item_path = f"ctsConformanceEvidence.claimPolicy.allowedClaimStates[{index}]"
        if not isinstance(state_row, dict):
            failures.append(
                failure(
                    "cts_claim_policy_state_malformed",
                    item_path,
                    "CTS claim policy state row must be an object",
                )
            )
            continue
        state = state_row.get("state")
        allowed = state_row.get("allowed")
        requirements_list = state_row.get("requirements")
        if state in seen_states:
            failures.append(
                failure(
                    "cts_claim_policy_state_duplicate",
                    f"{item_path}.state",
                    "CTS claim policy states must be unique",
                )
            )
        if isinstance(state, str):
            seen_states.add(state)
        expected_allowed = CTS_ALLOWED_CLAIM_STATES.get(state)
        if expected_allowed is None:
            failures.append(
                failure(
                    "cts_claim_policy_state_unknown",
                    f"{item_path}.state",
                    "CTS claim policy state must be a known CTS claim state",
                )
            )
        elif allowed is not expected_allowed:
            failures.append(
                failure(
                    "cts_claim_policy_state_allowed_mismatch",
                    f"{item_path}.allowed",
                    "CTS claim policy allowed flag is too permissive for current evidence",
                )
            )
        if not (
            isinstance(requirements_list, list)
            and requirements_list
            and all(is_non_empty_string(item) for item in requirements_list)
        ):
            failures.append(
                failure(
                    "cts_claim_policy_state_requirements_missing",
                    f"{item_path}.requirements",
                    "CTS claim policy state requirements must be a non-empty string list",
                )
            )
    for state in CTS_ALLOWED_CLAIM_STATES:
        if state not in seen_states:
            failures.append(
                failure(
                    "cts_claim_policy_state_missing",
                    "ctsConformanceEvidence.claimPolicy.allowedClaimStates",
                    f"CTS claim policy missing state: {state}",
                )
            )
    return failures


def cts_claim_policy_evidence(
    root: Path,
    cts_evidence_path: Path,
) -> tuple[dict[str, Any], bool]:
    path_text = cts_evidence_path.as_posix()
    try:
        payload = load_json_object(root / cts_evidence_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        evidence = {
            "path": path_text,
            "policyStatus": "missing",
            "failures": [
                failure(
                    "cts_evidence_unreadable",
                    "ctsConformanceEvidence.path",
                    f"CTS evidence must be readable JSON: {exc}",
                )
            ],
            "summary": {
                "evidenceRowCount": 0,
                "passEvidenceRowCount": 0,
                "backendCount": 0,
                "policyFailureCount": 1,
            },
        }
        return evidence, False
    policy = payload.get("claimPolicy")
    policy = policy if isinstance(policy, dict) else {}
    evidence_rows = payload.get("evidence")
    evidence_rows = evidence_rows if isinstance(evidence_rows, list) else []
    pass_rows = [
        row
        for row in evidence_rows
        if isinstance(row, dict) and row.get("status") == "pass"
    ]
    backends = sorted(
        {
            row.get("backend")
            for row in evidence_rows
            if isinstance(row, dict) and isinstance(row.get("backend"), str)
        }
    )
    failures = cts_claim_policy_validation_failures(payload)
    policy_status = "defined" if not failures else "malformed"
    if failures and not isinstance(payload.get("claimPolicy"), dict):
        policy_status = "missing"
    evidence = {
        "path": path_text,
        "sha256": sha256_file(root / cts_evidence_path),
        "schemaVersion": payload.get("schemaVersion", 0),
        "artifactKind": payload.get("artifactKind", ""),
        "ctsSource": payload.get("ctsSource", ""),
        "ctsRevision": payload.get("ctsRevision", ""),
        "policyStatus": policy_status,
        "policyId": policy.get("policyId", ""),
        "claimLanguage": policy.get("claimLanguage", ""),
        "diagnosticLanguage": policy.get("diagnosticLanguage", ""),
        "promotionRequirements": policy.get("promotionRequirements", {}),
        "allowedClaimStates": policy.get("allowedClaimStates", []),
        "failures": failures,
        "summary": {
            "evidenceRowCount": len(evidence_rows),
            "passEvidenceRowCount": len(pass_rows),
            "backendCount": len(backends),
            "policyFailureCount": len(failures),
        },
    }
    return evidence, not failures


def cts_subset_empty_summary() -> dict[str, int]:
    return {
        "coverageRowCount": 0,
        "queryCount": 0,
        "backendCount": 0,
        "surfaceCount": 0,
        "artifactPathCount": 0,
        "passCount": 0,
        "failCount": 0,
        "skipCount": 0,
        "notRunCount": 0,
    }


def cts_subset_summary_for_rows(rows: list[dict[str, str]]) -> dict[str, int]:
    status_counts = Counter(row["status"] for row in rows)
    return {
        "coverageRowCount": len(rows),
        "queryCount": len({row["query"] for row in rows}),
        "backendCount": len({row["backend"] for row in rows}),
        "surfaceCount": len({row["surface"] for row in rows}),
        "artifactPathCount": len({row["artifactPath"] for row in rows}),
        "passCount": status_counts.get("pass", 0),
        "failCount": status_counts.get("fail", 0),
        "skipCount": status_counts.get("skip", 0),
        "notRunCount": status_counts.get("not_run", 0),
    }


def cts_subset_backend_coverage_for_rows(
    rows: list[dict[str, str]],
) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str, str], set[str]] = {}
    for row in rows:
        key = (row["backend"], row["surface"], row["host"], row["os"])
        grouped.setdefault(key, set()).add(row["artifactPath"])
    return [
        {
            "backend": backend,
            "surface": surface,
            "host": host,
            "os": os_name,
            "artifactPaths": sorted(grouped[(backend, surface, host, os_name)]),
        }
        for backend, surface, host, os_name in sorted(grouped)
    ]


def cts_subset_rows_from_value(
    value: Any,
    path: str,
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    failures: list[dict[str, str]] = []
    if not isinstance(value, list) or not value:
        return [], [
            failure(
                "cts_subset_query_coverage_missing",
                path,
                "CTS subset receipt must contain at least one query coverage row",
            )
        ]
    rows: list[dict[str, str]] = []
    for index, row in enumerate(value):
        item_path = f"{path}[{index}]"
        if not isinstance(row, dict):
            failures.append(
                failure(
                    "cts_subset_query_coverage_row_malformed",
                    item_path,
                    "CTS subset query coverage row must be an object",
                )
            )
            continue
        normalized: dict[str, str] = {}
        for field in CTS_SUBSET_REQUIRED_ROW_FIELDS:
            field_value = row.get(field)
            if not isinstance(field_value, str) or not field_value:
                failures.append(
                    failure(
                        "cts_subset_query_coverage_field_missing",
                        f"{item_path}.{field}",
                        f"CTS subset query coverage {field} must be a non-empty string",
                    )
                )
            else:
                normalized[field] = field_value
        status = normalized.get("status")
        if status is not None and status not in CTS_SUBSET_STATUS_VALUES:
            failures.append(
                failure(
                    "cts_subset_query_coverage_status_unknown",
                    f"{item_path}.status",
                    "CTS subset query coverage status must be pass, fail, skip, or not_run",
                )
            )
        notes = row.get("notes")
        if notes is not None:
            if not isinstance(notes, str):
                failures.append(
                    failure(
                        "cts_subset_query_coverage_notes_malformed",
                        f"{item_path}.notes",
                        "CTS subset query coverage notes must be a string",
                    )
                )
            else:
                normalized["notes"] = notes
        if all(field in normalized for field in CTS_SUBSET_REQUIRED_ROW_FIELDS):
            rows.append(normalized)
    return rows, failures


def cts_subset_summary_failures(
    summary: Any,
    expected: dict[str, int],
) -> list[dict[str, str]]:
    if not isinstance(summary, dict):
        return [
            failure(
                "cts_subset_summary_missing",
                "ctsConformanceEvidence.subsetReceipt.summary",
                "CTS subset receipt summary must be an object",
            )
        ]
    failures: list[dict[str, str]] = []
    for field in CTS_SUBSET_SUMMARY_FIELDS:
        if summary.get(field) != expected[field]:
            failures.append(
                failure(
                    "cts_subset_summary_mismatch",
                    f"ctsConformanceEvidence.subsetReceipt.summary.{field}",
                    f"CTS subset receipt summary.{field} must match query coverage",
                )
            )
    return failures


def cts_subset_receipt_evidence(
    root: Path,
    cts_evidence_path: Path,
    cts_subset_receipt_path: Path,
) -> tuple[dict[str, Any], bool]:
    path_text = cts_subset_receipt_path.as_posix()
    try:
        payload = load_json_object(root / cts_subset_receipt_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        missing_evidence = {
            "path": path_text,
            "status": "missing",
            "failures": [
                failure(
                    "cts_subset_receipt_unreadable",
                    "ctsConformanceEvidence.subsetReceipt.path",
                    f"CTS subset receipt must be readable JSON: {exc}",
                )
            ],
            "summary": {**cts_subset_empty_summary(), "failureCount": 1},
        }
        return missing_evidence, False

    failures: list[dict[str, str]] = []
    if payload.get("artifactKind") != CTS_SUBSET_RECEIPT_KIND:
        failures.append(
            failure(
                "cts_subset_receipt_artifact_kind_mismatch",
                "ctsConformanceEvidence.subsetReceipt.artifactKind",
                f"CTS subset receipt artifactKind must be {CTS_SUBSET_RECEIPT_KIND}",
            )
        )
    if payload.get("publicationStatus") != CTS_SUBSET_PUBLICATION_STATUS:
        failures.append(
            failure(
                "cts_subset_receipt_publication_status_mismatch",
                "ctsConformanceEvidence.subsetReceipt.publicationStatus",
                f"CTS subset receipt publicationStatus must be {CTS_SUBSET_PUBLICATION_STATUS}",
            )
        )
    if not isinstance(payload.get("receiptId"), str) or not payload.get("receiptId"):
        failures.append(
            failure(
                "cts_subset_receipt_id_missing",
                "ctsConformanceEvidence.subsetReceipt.receiptId",
                "CTS subset receipt receiptId is required",
            )
        )
    if not isinstance(payload.get("publicationChannel"), str) or not payload.get(
        "publicationChannel"
    ):
        failures.append(
            failure(
                "cts_subset_receipt_publication_channel_missing",
                "ctsConformanceEvidence.subsetReceipt.publicationChannel",
                "CTS subset receipt publicationChannel is required",
            )
        )
    if payload.get("conformanceClaimAllowed") is not False:
        failures.append(
            failure(
                "cts_subset_receipt_claim_boundary_mismatch",
                "ctsConformanceEvidence.subsetReceipt.conformanceClaimAllowed",
                "CTS subset receipt must keep conformanceClaimAllowed=false",
            )
        )
    if payload.get("claimLanguage") != CTS_CLAIM_LANGUAGE:
        failures.append(
            failure(
                "cts_subset_receipt_claim_language_mismatch",
                "ctsConformanceEvidence.subsetReceipt.claimLanguage",
                f"CTS subset receipt claimLanguage must be {CTS_CLAIM_LANGUAGE}",
            )
        )
    requirements = payload.get("remainingPromotionRequirements")
    if not (
        isinstance(requirements, list)
        and CTS_SUBSET_RECEIPT_BLOCKER not in requirements
        and "backend_specific_cts_pass_ledger" in requirements
    ):
        failures.append(
            failure(
                "cts_subset_receipt_remaining_requirements_mismatch",
                "ctsConformanceEvidence.subsetReceipt.remainingPromotionRequirements",
                "CTS subset receipt must leave backend_specific_cts_pass_ledger as a remaining requirement",
            )
        )

    source_evidence = payload.get("sourceEvidence")
    source_evidence_out: dict[str, Any] = {}
    if not isinstance(source_evidence, dict):
        failures.append(
            failure(
                "cts_subset_source_evidence_missing",
                "ctsConformanceEvidence.subsetReceipt.sourceEvidence",
                "CTS subset receipt must include sourceEvidence",
            )
        )
        source_evidence = {}
    else:
        source_evidence_out = source_evidence
        if source_evidence.get("path") != cts_evidence_path.as_posix():
            failures.append(
                failure(
                    "cts_subset_source_path_mismatch",
                    "ctsConformanceEvidence.subsetReceipt.sourceEvidence.path",
                    "CTS subset receipt sourceEvidence.path must match the CTS evidence path",
                )
            )
        if source_evidence.get("artifactKind") != CTS_EVIDENCE_KIND:
            failures.append(
                failure(
                    "cts_subset_source_artifact_kind_mismatch",
                    "ctsConformanceEvidence.subsetReceipt.sourceEvidence.artifactKind",
                    f"CTS subset receipt sourceEvidence.artifactKind must be {CTS_EVIDENCE_KIND}",
                )
            )
        if source_evidence.get("claimLanguage") != CTS_CLAIM_LANGUAGE:
            failures.append(
                failure(
                    "cts_subset_source_claim_language_mismatch",
                    "ctsConformanceEvidence.subsetReceipt.sourceEvidence.claimLanguage",
                    f"CTS subset receipt sourceEvidence.claimLanguage must be {CTS_CLAIM_LANGUAGE}",
                )
            )

    source_payload: dict[str, Any] | None = None
    try:
        source_payload = load_json_object(root / cts_evidence_path)
        source_sha256 = sha256_file(root / cts_evidence_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        source_sha256 = ""
        failures.append(
            failure(
                "cts_subset_source_unreadable",
                "ctsConformanceEvidence.subsetReceipt.sourceEvidence.path",
                f"CTS subset receipt source CTS evidence must be readable JSON: {exc}",
            )
        )
    if source_sha256 and source_evidence.get("sha256") != source_sha256:
        failures.append(
            failure(
                "cts_subset_source_hash_mismatch",
                "ctsConformanceEvidence.subsetReceipt.sourceEvidence.sha256",
                "CTS subset receipt sourceEvidence.sha256 must match the CTS evidence file",
            )
        )

    coverage_rows, coverage_failures = cts_subset_rows_from_value(
        payload.get("queryCoverage"),
        "ctsConformanceEvidence.subsetReceipt.queryCoverage",
    )
    failures.extend(coverage_failures)
    computed_summary = cts_subset_summary_for_rows(coverage_rows)
    failures.extend(cts_subset_summary_failures(payload.get("summary"), computed_summary))
    expected_backend_coverage = cts_subset_backend_coverage_for_rows(coverage_rows)
    if payload.get("backendCoverage") != expected_backend_coverage:
        failures.append(
            failure(
                "cts_subset_backend_coverage_mismatch",
                "ctsConformanceEvidence.subsetReceipt.backendCoverage",
                "CTS subset receipt backendCoverage must match query coverage backend identity",
            )
        )

    if source_payload is not None:
        if source_payload.get("artifactKind") != CTS_EVIDENCE_KIND:
            failures.append(
                failure(
                    "cts_subset_source_artifact_kind_mismatch",
                    "ctsConformanceEvidence.subsetReceipt.sourceEvidence.artifactKind",
                    f"CTS source evidence artifactKind must be {CTS_EVIDENCE_KIND}",
                )
            )
        policy = source_payload.get("claimPolicy")
        policy = policy if isinstance(policy, dict) else {}
        if source_evidence.get("policyId") != policy.get("policyId"):
            failures.append(
                failure(
                    "cts_subset_source_policy_mismatch",
                    "ctsConformanceEvidence.subsetReceipt.sourceEvidence.policyId",
                    "CTS subset receipt sourceEvidence.policyId must match the CTS evidence policy",
                )
            )
        if source_evidence.get("diagnosticLanguage") != policy.get(
            "diagnosticLanguage"
        ):
            failures.append(
                failure(
                    "cts_subset_source_diagnostic_language_mismatch",
                    "ctsConformanceEvidence.subsetReceipt.sourceEvidence.diagnosticLanguage",
                    "CTS subset receipt sourceEvidence.diagnosticLanguage must match the CTS evidence policy",
                )
            )
        source_rows, source_row_failures = cts_subset_rows_from_value(
            source_payload.get("evidence"),
            "ctsConformanceEvidence.sourceEvidence.evidence",
        )
        failures.extend(source_row_failures)
        if not source_row_failures and not coverage_failures and coverage_rows != source_rows:
            failures.append(
                failure(
                    "cts_subset_query_coverage_mismatch",
                    "ctsConformanceEvidence.subsetReceipt.queryCoverage",
                    "CTS subset receipt queryCoverage must match the CTS evidence ledger rows",
                )
            )

    evidence = {
        "path": path_text,
        "sha256": sha256_file(root / cts_subset_receipt_path),
        "schemaVersion": payload.get("schemaVersion", 0),
        "artifactKind": payload.get("artifactKind", ""),
        "receiptId": payload.get("receiptId", ""),
        "publicationStatus": payload.get("publicationStatus", ""),
        "publicationChannel": payload.get("publicationChannel", ""),
        "status": "pass" if not failures else "fail",
        "sourceEvidence": source_evidence_out,
        "failures": failures,
        "summary": {**computed_summary, "failureCount": len(failures)},
    }
    return evidence, not failures


def cts_backend_pass_ledger_empty_summary() -> dict[str, Any]:
    return {
        "backendLedgerCount": 0,
        "coverageRowCount": 0,
        "passCount": 0,
        "failCount": 0,
        "skipCount": 0,
        "notRunCount": 0,
        "failingBackendLedgerCount": 0,
        "allBackendLedgersPass": False,
    }


def cts_backend_pass_ledger_evidence(
    root: Path,
    cts_evidence_path: Path,
    cts_subset_receipt_path: Path,
    cts_backend_pass_ledger_path: Path,
) -> tuple[dict[str, Any], bool]:
    path_text = cts_backend_pass_ledger_path.as_posix()
    try:
        payload = load_json_object(root / cts_backend_pass_ledger_path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        missing_evidence = {
            "path": path_text,
            "status": "missing",
            "failures": [
                failure(
                    "cts_backend_pass_ledger_unreadable",
                    "ctsConformanceEvidence.backendPassLedger.path",
                    f"CTS backend pass ledger must be readable JSON: {exc}",
                )
            ],
            "summary": {**cts_backend_pass_ledger_empty_summary(), "failureCount": 1},
        }
        return missing_evidence, False

    failures: list[dict[str, str]] = []
    try:
        expected = cts_backend_ledger_builder.build_ledger(
            root=root,
            subset_receipt_path=cts_subset_receipt_path,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        expected = None
        failures.append(
            failure(
                "cts_backend_pass_ledger_expected_unavailable",
                "ctsConformanceEvidence.backendPassLedger.sourceReceipt.path",
                f"Expected CTS backend pass ledger could not be computed: {exc}",
            )
        )

    if payload.get("artifactKind") != CTS_BACKEND_PASS_LEDGER_KIND:
        failures.append(
            failure(
                "cts_backend_pass_ledger_artifact_kind_mismatch",
                "ctsConformanceEvidence.backendPassLedger.artifactKind",
                f"CTS backend pass ledger artifactKind must be {CTS_BACKEND_PASS_LEDGER_KIND}",
            )
        )
    if payload.get("ledgerStatus") != "pass":
        failures.append(
            failure(
                "cts_backend_pass_ledger_not_pass",
                "ctsConformanceEvidence.backendPassLedger.ledgerStatus",
                "CTS backend pass ledger must pass before clearing the backend-specific ledger blocker",
            )
        )
    if payload.get("claimScope") != CTS_BACKEND_PASS_LEDGER_CLAIM_SCOPE:
        failures.append(
            failure(
                "cts_backend_pass_ledger_claim_scope_mismatch",
                "ctsConformanceEvidence.backendPassLedger.claimScope",
                f"CTS backend pass ledger claimScope must be {CTS_BACKEND_PASS_LEDGER_CLAIM_SCOPE}",
            )
        )
    if payload.get("fullConformanceClaimAllowed") is not False:
        failures.append(
            failure(
                "cts_backend_pass_ledger_full_conformance_boundary_mismatch",
                "ctsConformanceEvidence.backendPassLedger.fullConformanceClaimAllowed",
                "CTS backend pass ledger must keep fullConformanceClaimAllowed=false",
            )
        )
    if payload.get("replacementClaimAllowed") is not False:
        failures.append(
            failure(
                "cts_backend_pass_ledger_replacement_boundary_mismatch",
                "ctsConformanceEvidence.backendPassLedger.replacementClaimAllowed",
                "CTS backend pass ledger must keep replacementClaimAllowed=false",
            )
        )
    if payload.get("claimLanguage") != CTS_CLAIM_LANGUAGE:
        failures.append(
            failure(
                "cts_backend_pass_ledger_claim_language_mismatch",
                "ctsConformanceEvidence.backendPassLedger.claimLanguage",
                f"CTS backend pass ledger claimLanguage must be {CTS_CLAIM_LANGUAGE}",
            )
        )

    if expected is not None:
        comparison_fields = (
            "sourceReceipt",
            "sourceEvidence",
            "summary",
            "backendLedgers",
        )
        for field in comparison_fields:
            if payload.get(field) != expected[field]:
                failures.append(
                    failure(
                        "cts_backend_pass_ledger_projection_mismatch",
                        f"ctsConformanceEvidence.backendPassLedger.{field}",
                        f"CTS backend pass ledger {field} must match the subset receipt projection",
                    )
                )
        if expected["sourceEvidence"]["path"] != cts_evidence_path.as_posix():
            failures.append(
                failure(
                    "cts_backend_pass_ledger_source_evidence_path_mismatch",
                    "ctsConformanceEvidence.backendPassLedger.sourceEvidence.path",
                    "CTS backend pass ledger sourceEvidence.path must match the CTS evidence path",
                )
            )
        if payload.get("ledgerStatus") != expected["ledgerStatus"]:
            failures.append(
                failure(
                    "cts_backend_pass_ledger_status_mismatch",
                    "ctsConformanceEvidence.backendPassLedger.ledgerStatus",
                    "CTS backend pass ledger ledgerStatus must match the subset receipt projection",
                )
            )
    summary = payload.get("summary")
    if not isinstance(summary, dict):
        summary = cts_backend_pass_ledger_empty_summary()
    evidence = {
        "path": path_text,
        "sha256": sha256_file(root / cts_backend_pass_ledger_path),
        "schemaVersion": payload.get("schemaVersion", 0),
        "artifactKind": payload.get("artifactKind", ""),
        "ledgerId": payload.get("ledgerId", ""),
        "ledgerStatus": payload.get("ledgerStatus", ""),
        "claimScope": payload.get("claimScope", ""),
        "fullConformanceClaimAllowed": payload.get("fullConformanceClaimAllowed"),
        "replacementClaimAllowed": payload.get("replacementClaimAllowed"),
        "status": "pass" if not failures else "fail",
        "sourceReceipt": payload.get("sourceReceipt", {}),
        "sourceEvidence": payload.get("sourceEvidence", {}),
        "failures": failures,
        "summary": {**summary, "failureCount": len(failures)},
    }
    return evidence, not failures


def cts_conformance_blocker_codes(
    root: Path,
    blocker_codes: list[str],
    cts_evidence_path: Path,
    cts_subset_receipt_path: Path,
    cts_backend_pass_ledger_path: Path,
) -> tuple[list[str], dict[str, Any]]:
    evidence, policy_ok = cts_claim_policy_evidence(root, cts_evidence_path)
    subset_evidence, subset_ok = cts_subset_receipt_evidence(
        root,
        cts_evidence_path,
        cts_subset_receipt_path,
    )
    backend_ledger_evidence, backend_pass_ledger_ok = (
        cts_backend_pass_ledger_evidence(
            root,
            cts_evidence_path,
            cts_subset_receipt_path,
            cts_backend_pass_ledger_path,
        )
    )
    evidence["subsetReceipt"] = subset_evidence
    evidence["backendPassLedger"] = backend_ledger_evidence
    filtered_codes = list(blocker_codes)
    if policy_ok:
        filtered_codes = [
            code for code in filtered_codes if code != CTS_CLAIM_POLICY_BLOCKER
        ]
    if subset_ok:
        filtered_codes = [
            code for code in filtered_codes if code != CTS_SUBSET_RECEIPT_BLOCKER
        ]
    if backend_pass_ledger_ok:
        filtered_codes = [
            code
            for code in filtered_codes
            if code != CTS_BACKEND_PASS_LEDGER_BLOCKER
        ]
    return filtered_codes, evidence


def frontier_bundle_config(
    *,
    browser_bundle_path: Path = BROWSER_FRONTIER_BUNDLE_PATH,
    browser_provenance_report_path: Path = BROWSER_PROVENANCE_REPORT_PATH,
    browser_package_inputs_path: Path = BROWSER_PACKAGE_INPUTS_PATH,
    browser_public_download_receipt_path: Path = BROWSER_PUBLIC_DOWNLOAD_RECEIPT_PATH,
    browser_launch_receipt_path: Path = BROWSER_LAUNCH_RECEIPT_PATH,
    browser_chromium_source_checkout_path: Path = BROWSER_CHROMIUM_SOURCE_CHECKOUT_PATH,
    browser_proof_surface_path: Path = BROWSER_PROOF_SURFACE_PATH,
    browser_proof_surface_check_path: Path = BROWSER_PROOF_SURFACE_CHECK_PATH,
    browser_finalizer_report_path: Path = BROWSER_FINALIZER_REPORT_PATH,
    browser_finalizer_check_path: Path = BROWSER_FINALIZER_CHECK_PATH,
    tint_bundle_path: Path = TINT_FRONTIER_BUNDLE_PATH,
) -> dict[str, dict[str, Any]]:
    return {
        BROWSER_FRONTIER_ROW_ID: {
            "path": browser_bundle_path,
            "kind": BROWSER_FRONTIER_BUNDLE_KIND,
            "provenanceReportPath": browser_provenance_report_path,
            "packageInputsPath": browser_package_inputs_path,
            "publicDownloadReceiptPath": browser_public_download_receipt_path,
            "browserLaunchReceiptPath": browser_launch_receipt_path,
            "chromiumSourceCheckoutPath": browser_chromium_source_checkout_path,
            "proofSurfacePath": browser_proof_surface_path,
            "proofSurfaceCheckPath": browser_proof_surface_check_path,
            "finalizerReportPath": browser_finalizer_report_path,
            "finalizerCheckPath": browser_finalizer_check_path,
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


def is_failure_code(value: Any) -> bool:
    return isinstance(value, str) and bool(value) and all(
        char.islower() or char.isdigit() or char == "_" for char in value
    )


def is_summary_map_schema_compatible(summary: dict[str, Any]) -> bool:
    return all(isinstance(value, str | int | float | bool) or value is None for value in summary.values())


def is_failure_summary_list_schema_compatible(items: list[Any]) -> bool:
    for item in items:
        if not isinstance(item, dict):
            return False
        if not is_failure_code(item.get("code")):
            return False
        if not isinstance(item.get("message"), str) or not item.get("message"):
            return False
        count = item.get("count")
        if not isinstance(count, int) or isinstance(count, bool) or count < 1:
            return False
    return True


def is_failure_schema_compatible(item: dict[str, Any]) -> bool:
    return (
        is_failure_code(item.get("code"))
        and isinstance(item.get("path"), str)
        and bool(item.get("path"))
        and isinstance(item.get("message"), str)
        and bool(item.get("message"))
    )


def is_non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value)


def is_non_empty_string_list(value: Any) -> bool:
    return (
        isinstance(value, list)
        and bool(value)
        and all(is_non_empty_string(item) for item in value)
    )


def is_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(char in "0123456789abcdef" for char in value)
    )


def is_receipt_status(value: Any) -> bool:
    return value in {"pass", "fail"}


def is_non_negative_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def browser_release_artifact_verification_field_failure(
    artifact_verification: dict[str, Any],
) -> tuple[str, str] | None:
    base_path = (
        "frontierBundleEvidence.componentReceipts."
        "releaseArtifactBundle.artifactVerification"
    )
    field_checks = [
        ("requiredForClaimable", lambda value: value is True, "must be true"),
        ("verifyFilesRootProvided", lambda value: isinstance(value, bool), "must be boolean"),
        ("verified", lambda value: isinstance(value, bool), "must be boolean"),
    ]
    for field, predicate, expectation in field_checks:
        if field not in artifact_verification:
            return (
                f"{base_path}.{field}",
                (
                    "browser runtime frontier bundle componentReceipts."
                    f"releaseArtifactBundle.artifactVerification.{field} is required"
                ),
            )
        if not predicate(artifact_verification.get(field)):
            return (
                f"{base_path}.{field}",
                (
                    "browser runtime frontier bundle componentReceipts."
                    f"releaseArtifactBundle.artifactVerification.{field} {expectation}"
                ),
            )
    return None


def browser_release_claim_report_summary_failure(
    claim_reports: list[Any],
) -> tuple[str, str] | None:
    base_path = "frontierBundleEvidence.componentReceipts.releaseArtifactBundle.claimReports"
    field_checks = [
        ("path", is_non_empty_string, "must be a non-empty string"),
        ("comparisonStatus", lambda value: isinstance(value, str), "must be a string"),
        ("claimStatus", lambda value: isinstance(value, str), "must be a string"),
        ("structuralStatus", lambda value: isinstance(value, str), "must be a string"),
        ("workloadCount", is_non_negative_int, "must be a non-negative integer"),
        (
            "sourceKernelDispatchWorkloadCount",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        ("claimBlockerCount", is_non_negative_int, "must be a non-negative integer"),
    ]
    for index, claim_report in enumerate(claim_reports):
        item_path = f"{base_path}[{index}]"
        if not isinstance(claim_report, dict):
            return (
                item_path,
                (
                    "browser runtime frontier bundle componentReceipts."
                    f"releaseArtifactBundle.claimReports[{index}] must be an object"
                ),
            )
        for field, predicate, expectation in field_checks:
            if field not in claim_report:
                return (
                    f"{item_path}.{field}",
                    (
                        "browser runtime frontier bundle componentReceipts."
                        f"releaseArtifactBundle.claimReports[{index}].{field} is required"
                    ),
                )
            if not predicate(claim_report.get(field)):
                return (
                    f"{item_path}.{field}",
                    (
                        "browser runtime frontier bundle componentReceipts."
                        f"releaseArtifactBundle.claimReports[{index}].{field} {expectation}"
                    ),
                )
    return None


def tint_compiler_evidence_report_failure(
    compiler_reports: list[Any],
) -> tuple[str, str] | None:
    base_path = "frontierBundleEvidence.compilerEvidenceReports"
    field_checks = [
        ("path", is_non_empty_string, "must be a non-empty string"),
        ("sha256", is_sha256, "must be a sha256 hex string"),
        ("diagnosticGateStatus", is_receipt_status, "must be pass or fail"),
        ("comparisonStatus", lambda value: isinstance(value, str), "must be a string"),
        ("claimStatus", lambda value: isinstance(value, str), "must be a string"),
        ("rowCount", is_non_negative_int, "must be a non-negative integer"),
        ("comparableRows", is_non_negative_int, "must be a non-negative integer"),
        ("claimableRows", is_non_negative_int, "must be a non-negative integer"),
        ("claimBlockerCount", is_non_negative_int, "must be a non-negative integer"),
        ("claimBlockerSummary", lambda value: isinstance(value, list), "must be a list"),
    ]
    for index, report in enumerate(compiler_reports):
        item_path = f"{base_path}[{index}]"
        if not isinstance(report, dict):
            return (
                item_path,
                f"Tint compiler frontier bundle compilerEvidenceReports[{index}] must be an object",
            )
        for field, predicate, expectation in field_checks:
            if field not in report:
                return (
                    f"{item_path}.{field}",
                    (
                        "Tint compiler frontier bundle "
                        f"compilerEvidenceReports[{index}].{field} is required"
                    ),
                )
            if not predicate(report.get(field)):
                return (
                    f"{item_path}.{field}",
                    (
                        "Tint compiler frontier bundle "
                        f"compilerEvidenceReports[{index}].{field} {expectation}"
                    ),
                )
        if not is_failure_summary_list_schema_compatible(report["claimBlockerSummary"]):
            return (
                f"{item_path}.claimBlockerSummary",
                (
                    "Tint compiler frontier bundle "
                    f"compilerEvidenceReports[{index}].claimBlockerSummary "
                    "entries must have code, message, and positive count"
                ),
            )
    return None


def tint_phase_timing_coverage_failure(coverage: dict[str, Any]) -> tuple[str, str] | None:
    base_path = "frontierBundleEvidence.phaseTimingCoverage"
    field_checks = [
        ("requiredExactPhases", is_non_empty_string_list, "must be a non-empty string list"),
        (
            "requiredBenchmarkScopes",
            is_non_empty_string_list,
            "must be a non-empty string list",
        ),
        ("rowCount", is_non_negative_int, "must be a non-negative integer"),
        ("doeOkRows", is_non_negative_int, "must be a non-negative integer"),
        ("tintOkRows", is_non_negative_int, "must be a non-negative integer"),
        (
            "doeExactPhaseCompleteRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        (
            "doeExactPhaseMissingRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        (
            "tintExactPhaseCompleteRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        (
            "tintExactPhaseMissingRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        (
            "tintBenchmarkScopeCoveredRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        (
            "tintBenchmarkScopeMissingRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        ("notApplicableRows", is_non_negative_int, "must be a non-negative integer"),
        ("coverageByEvidencePath", lambda value: isinstance(value, list), "must be a list"),
    ]
    for field, predicate, expectation in field_checks:
        if field not in coverage:
            return (
                f"{base_path}.{field}",
                f"Tint compiler frontier bundle phaseTimingCoverage.{field} is required",
            )
        if not predicate(coverage.get(field)):
            return (
                f"{base_path}.{field}",
                f"Tint compiler frontier bundle phaseTimingCoverage.{field} {expectation}",
            )

    by_evidence_path = coverage["coverageByEvidencePath"]
    item_checks = [
        ("evidencePath", is_non_empty_string, "must be a non-empty string"),
        ("targets", is_tint_target_list, "must be a target list"),
        ("rowCount", is_non_negative_int, "must be a non-negative integer"),
        ("doeOkRows", is_non_negative_int, "must be a non-negative integer"),
        ("tintOkRows", is_non_negative_int, "must be a non-negative integer"),
        (
            "doeExactPhaseCompleteRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        (
            "doeExactPhaseMissingRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        (
            "tintExactPhaseCompleteRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        (
            "tintExactPhaseMissingRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        (
            "tintBenchmarkScopeCoveredRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        (
            "tintBenchmarkScopeMissingRows",
            is_non_negative_int,
            "must be a non-negative integer",
        ),
        ("notApplicableRows", is_non_negative_int, "must be a non-negative integer"),
    ]
    summed_fields = [
        "rowCount",
        "doeOkRows",
        "tintOkRows",
        "doeExactPhaseCompleteRows",
        "doeExactPhaseMissingRows",
        "tintExactPhaseCompleteRows",
        "tintExactPhaseMissingRows",
        "tintBenchmarkScopeCoveredRows",
        "tintBenchmarkScopeMissingRows",
        "notApplicableRows",
    ]
    sums = {field: 0 for field in summed_fields}
    for index, item in enumerate(by_evidence_path):
        item_path = f"{base_path}.coverageByEvidencePath[{index}]"
        if not isinstance(item, dict):
            return item_path, (
                "Tint compiler frontier bundle phaseTimingCoverage."
                f"coverageByEvidencePath[{index}] must be an object"
            )
        for field, predicate, expectation in item_checks:
            if field not in item:
                return (
                    f"{item_path}.{field}",
                    (
                        "Tint compiler frontier bundle phaseTimingCoverage."
                        f"coverageByEvidencePath[{index}].{field} is required"
                    ),
                )
            if not predicate(item.get(field)):
                return (
                    f"{item_path}.{field}",
                    (
                        "Tint compiler frontier bundle phaseTimingCoverage."
                        f"coverageByEvidencePath[{index}].{field} {expectation}"
                    ),
                )
        for field in summed_fields:
            sums[field] += item[field]

    for field in summed_fields:
        if coverage[field] != sums[field]:
            return (
                f"{base_path}.{field}",
                f"Tint compiler frontier bundle phaseTimingCoverage.{field} must match coverageByEvidencePath sum",
            )
    return None


def is_tint_target_list(value: Any) -> bool:
    return isinstance(value, list) and all(
        target in {"msl", "spirv", "dxil", "hlsl"} for target in value
    )


def tint_evidence_path_summary_failure(
    summaries: list[Any],
    *,
    base_path: str,
    label: str,
) -> tuple[str, str] | None:
    for index, summary in enumerate(summaries):
        item_path = f"{base_path}[{index}]"
        if not isinstance(summary, dict):
            return item_path, f"{label}[{index}] must be an object"
        if not is_non_empty_string(summary.get("evidencePath")):
            return f"{item_path}.evidencePath", f"{label}[{index}].evidencePath must be a non-empty string"
        claim_blocker_summary = summary.get("claimBlockerSummary")
        if not isinstance(claim_blocker_summary, list):
            return f"{item_path}.claimBlockerSummary", f"{label}[{index}].claimBlockerSummary must be a list"
        if not is_failure_summary_list_schema_compatible(claim_blocker_summary):
            return (
                f"{item_path}.claimBlockerSummary",
                f"{label}[{index}].claimBlockerSummary entries must have code, message, and positive count",
            )
    return None


def tint_artifact_file_failure(
    *,
    root: Path,
    artifacts: list[Any],
    base_path: str,
    label: str,
) -> tuple[str, str, str] | None:
    for index, artifact in enumerate(artifacts):
        if not isinstance(artifact, dict):
            continue
        path_text = artifact.get("path")
        expected_sha256 = artifact.get("sha256")
        if not isinstance(path_text, str) or not is_sha256(expected_sha256):
            continue
        unsafe_reason = unsafe_repo_path_reason(path_text, allow_empty=False)
        if unsafe_reason:
            return (
                "path_unsafe",
                f"{base_path}[{index}].path",
                f"{label}[{index}].path {unsafe_reason}",
            )
        try:
            actual_sha256 = sha256_file(root / path_text)
        except OSError:
            return (
                "path_unreadable",
                f"{base_path}[{index}].path",
                f"{label}[{index}].path must resolve to a readable file",
            )
        if actual_sha256 != expected_sha256:
            return (
                "hash_mismatch",
                f"{base_path}[{index}].sha256",
                f"{label}[{index}].sha256 must match referenced file bytes",
            )
    return None


def tint_component_receipt_item_failure(
    *,
    component_name: str,
    receipts: list[Any],
) -> tuple[str, str] | None:
    base_path = f"frontierBundleEvidence.componentReceipts.{component_name}"
    label = f"Tint compiler frontier bundle componentReceipts.{component_name}"
    field_checks_by_component = {
        "loweringLinks": [
            ("path", is_non_empty_string, "must be a non-empty string"),
            ("sha256", is_sha256, "must be a sha256 hex string"),
            ("evidencePath", is_non_empty_string, "must be a non-empty string"),
            ("evidencePaths", is_non_empty_string_list, "must be a non-empty string list"),
            ("status", is_receipt_status, "must be pass or fail"),
            ("targets", is_tint_target_list, "must be a target list"),
            ("rowCount", is_non_negative_int, "must be a non-negative integer"),
            ("linkedRows", is_non_negative_int, "must be a non-negative integer"),
            ("diagnosticRows", is_non_negative_int, "must be a non-negative integer"),
        ],
        "targetValidations": [
            ("path", is_non_empty_string, "must be a non-empty string"),
            ("sha256", is_sha256, "must be a sha256 hex string"),
            ("evidencePath", is_non_empty_string, "must be a non-empty string"),
            ("evidencePaths", is_non_empty_string_list, "must be a non-empty string list"),
            ("status", is_receipt_status, "must be pass or fail"),
            ("targets", is_tint_target_list, "must be a target list"),
            ("summary", lambda value: isinstance(value, dict), "must be an object"),
            ("claimBlockerSummary", lambda value: isinstance(value, list), "must be a list"),
            (
                "claimBlockerSummaryByEvidencePath",
                lambda value: isinstance(value, list),
                "must be a list",
            ),
        ],
        "phaseBenchmarks": [
            ("path", is_non_empty_string, "must be a non-empty string"),
            ("sha256", is_sha256, "must be a sha256 hex string"),
            ("evidencePath", is_non_empty_string, "must be a non-empty string"),
            ("evidencePaths", is_non_empty_string_list, "must be a non-empty string list"),
            ("status", is_receipt_status, "must be pass or fail"),
            ("targets", is_tint_target_list, "must be a target list"),
            ("summary", lambda value: isinstance(value, dict), "must be an object"),
        ],
    }
    for index, receipt in enumerate(receipts):
        item_path = f"{base_path}[{index}]"
        item_label = f"{label}[{index}]"
        if not isinstance(receipt, dict):
            return item_path, f"{item_label} must be an object"
        for field, predicate, expectation in field_checks_by_component[component_name]:
            if field not in receipt:
                return f"{item_path}.{field}", f"{item_label}.{field} is required"
            if not predicate(receipt.get(field)):
                return f"{item_path}.{field}", f"{item_label}.{field} {expectation}"
        if component_name == "targetValidations":
            if not is_failure_summary_list_schema_compatible(receipt["claimBlockerSummary"]):
                return (
                    f"{item_path}.claimBlockerSummary",
                    f"{item_label}.claimBlockerSummary entries must have code, message, and positive count",
                )
            by_evidence_path_failure = tint_evidence_path_summary_failure(
                receipt["claimBlockerSummaryByEvidencePath"],
                base_path=f"{item_path}.claimBlockerSummaryByEvidencePath",
                label=f"{item_label}.claimBlockerSummaryByEvidencePath",
            )
            if by_evidence_path_failure is not None:
                return by_evidence_path_failure
    return None


def browser_component_receipt_field_failure(
    *,
    component_name: str,
    receipt: dict[str, Any],
) -> tuple[str, str] | None:
    field_checks = {
        "runtimeIdentity": [
            ("path", is_non_empty_string, "must be a non-empty string"),
            ("status", is_receipt_status, "must be pass or fail"),
            ("evidenceSource", lambda value: isinstance(value, str), "must be a string"),
            ("selectedRuntime", lambda value: isinstance(value, str), "must be a string"),
            (
                "doeRuntimeActive",
                lambda value: isinstance(value, bool) or value is None,
                "must be boolean or null",
            ),
        ],
        "claimPromotionReceipt": [
            ("path", is_non_empty_string, "must be a non-empty string"),
            ("status", is_receipt_status, "must be pass or fail"),
            ("promotionStatus", lambda value: isinstance(value, str), "must be a string"),
            ("artifactCount", is_non_negative_int, "must be a non-negative integer"),
            (
                "hiddenFallbackPassed",
                lambda value: isinstance(value, bool) or value is None,
                "must be boolean or null",
            ),
        ],
        "releaseArtifactBundle": [
            ("path", is_non_empty_string, "must be a non-empty string"),
            ("status", is_receipt_status, "must be pass or fail"),
            ("bundleId", lambda value: isinstance(value, str), "must be a string"),
            ("releaseStatus", lambda value: isinstance(value, str), "must be a string"),
            ("artifactVerification", lambda value: isinstance(value, dict), "must be an object"),
            ("claimReports", lambda value: isinstance(value, list), "must be a list"),
        ],
    }
    for field, predicate, expectation in field_checks[component_name]:
        path = f"frontierBundleEvidence.componentReceipts.{component_name}.{field}"
        if field not in receipt:
            return path, f"browser runtime frontier bundle componentReceipts.{component_name}.{field} is required"
        if not predicate(receipt.get(field)):
            return (
                path,
                f"browser runtime frontier bundle componentReceipts.{component_name}.{field} {expectation}",
            )
    if component_name == "releaseArtifactBundle":
        artifact_verification_failure = browser_release_artifact_verification_field_failure(
            receipt["artifactVerification"]
        )
        if artifact_verification_failure is not None:
            return artifact_verification_failure
        claim_report_failure = browser_release_claim_report_summary_failure(
            receipt["claimReports"]
        )
        if claim_report_failure is not None:
            return claim_report_failure
    return None


def load_expected_artifact(
    *,
    root: Path,
    path: Path,
    expected_kind: str,
) -> dict[str, Any] | None:
    try:
        payload = load_json_object(root / path)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        return None
    if payload.get("artifactKind") != expected_kind:
        return None
    return payload


def load_release_artifact_bundle(
    *,
    root: Path,
    runtime_frontier_bundle: dict[str, Any],
) -> dict[str, Any] | None:
    component_receipts = runtime_frontier_bundle.get("componentReceipts")
    if not isinstance(component_receipts, dict):
        return None
    release_bundle = component_receipts.get("releaseArtifactBundle")
    if not isinstance(release_bundle, dict):
        return None
    path_text = release_bundle.get("path")
    if not isinstance(path_text, str) or not path_text:
        return None
    return load_expected_artifact(
        root=root,
        path=Path(path_text),
        expected_kind="browser_release_artifact_bundle",
    )


def compact_failures(value: Any) -> list[dict[str, str]]:
    if not isinstance(value, list):
        return []
    return [
        compact_failure(item)
        for item in value
        if isinstance(item, dict)
    ]


def consistency_evidence(failures: list[dict[str, str]]) -> dict[str, Any]:
    return {
        "status": "fail" if failures else "pass",
        "failureCount": len(failures),
        "failureCodes": sorted(
            {
                item.get("code", "")
                for item in failures
                if isinstance(item.get("code"), str) and item.get("code")
            }
        ),
        "failures": failures,
    }


def compact_artifact(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    out: dict[str, Any] = {}
    for key in ("path", "sha256", "kind", "downloadUrl"):
        field = value.get(key)
        if isinstance(field, str) and field:
            out[key] = field
    if {"path", "sha256", "kind"}.issubset(out):
        return out
    return None


def compact_artifact_list(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    artifacts: list[dict[str, Any]] = []
    for item in value:
        artifact = compact_artifact(item)
        if artifact is not None:
            artifacts.append(artifact)
    return artifacts


def artifact_matches_path_and_sha(value: Any, *, path: str, sha256: str) -> bool:
    return (
        isinstance(value, dict)
        and value.get("path") == path
        and value.get("sha256") == sha256
    )


def artifact_identity_matches(left: Any, right: Any) -> bool:
    return (
        isinstance(left, dict)
        and isinstance(right, dict)
        and left.get("path") == right.get("path")
        and left.get("sha256") == right.get("sha256")
        and left.get("kind") == right.get("kind")
    )


def published_proof_surface_summary(
    *,
    root: Path,
    proof_surface_path: Path,
) -> dict[str, Any] | None:
    proof_surface = load_expected_artifact(
        root=root,
        path=proof_surface_path,
        expected_kind="browser_published_proof_surface",
    )
    if proof_surface is None:
        return None
    proof_page = proof_surface.get("proofPage")
    if not isinstance(proof_page, dict):
        proof_page = {}
    diagnostics = proof_page.get("diagnostics")
    if not isinstance(diagnostics, dict):
        diagnostics = {}
    release_provenance = proof_page.get("releaseProvenance")
    if not isinstance(release_provenance, dict):
        release_provenance = {}
    browser_product = release_provenance.get("browserProduct")
    platform = release_provenance.get("platform")
    release_archive = compact_artifact(release_provenance.get("releaseArchive"))
    gallery_pages = proof_surface.get("galleryPages")
    if not isinstance(gallery_pages, list):
        gallery_pages = []
    gallery_categories = sorted(
        {
            category
            for row in gallery_pages
            if isinstance(row, dict)
            for category in [row.get("category")]
            if isinstance(category, str) and category
        }
    )
    comparison_receipts = proof_surface.get("comparisonReceipts")
    if not isinstance(comparison_receipts, list):
        comparison_receipts = []
    receipt_payloads = proof_page.get("receiptPayloads")
    if not isinstance(receipt_payloads, list):
        receipt_payloads = []

    summary: dict[str, Any] = {
        "path": proof_surface_path.as_posix(),
        "sha256": sha256_file(root / proof_surface_path),
        "artifactKind": proof_surface.get("artifactKind", ""),
        "surfaceId": proof_surface.get("surfaceId", ""),
        "runtimeIdentityPath": proof_surface.get("runtimeIdentityPath", ""),
        "proofPageUrl": proof_page.get("url", ""),
        "activeBackend": diagnostics.get("activeBackend", ""),
        "webgpuAvailable": diagnostics.get("webgpuAvailable"),
        "browserProduct": browser_product if isinstance(browser_product, dict) else {},
        "platform": platform if isinstance(platform, dict) else {},
        "galleryCategories": gallery_categories,
        "galleryPageCount": len(gallery_pages),
        "comparisonReceiptCount": len(comparison_receipts),
        "receiptPayloadCount": len(receipt_payloads),
    }
    if release_archive is not None:
        summary["releaseArchive"] = release_archive
    return summary


def provenance_report_summary(
    *,
    root: Path,
    provenance_report_path: Path,
) -> dict[str, Any] | None:
    provenance_report = load_expected_artifact(
        root=root,
        path=provenance_report_path,
        expected_kind="browser_release_candidate_provenance_report",
    )
    if provenance_report is None:
        return None
    failures = compact_failures(provenance_report.get("failures"))
    summary: dict[str, Any] = {
        "path": provenance_report_path.as_posix(),
        "sha256": sha256_file(root / provenance_report_path),
        "artifactKind": provenance_report.get("artifactKind", ""),
        "status": provenance_report.get("status", ""),
        "releaseStatus": provenance_report.get("releaseStatus", ""),
        "failureCount": len(failures),
        "failures": failures,
    }
    browser_product = provenance_report.get("browserProduct")
    if isinstance(browser_product, dict):
        summary["browserProduct"] = browser_product
    platform = provenance_report.get("platform")
    if isinstance(platform, dict):
        summary["platform"] = platform
    report_summary = provenance_report.get("summary")
    if isinstance(report_summary, dict):
        summary["summary"] = report_summary
    component_artifacts = provenance_report.get("componentArtifacts")
    if isinstance(component_artifacts, dict):
        compact_components = {
            key: artifact
            for key, artifact in (
                (key, compact_artifact(value))
                for key, value in component_artifacts.items()
            )
            if artifact is not None
        }
        if compact_components:
            summary["componentArtifacts"] = compact_components
    return summary


def proof_surface_check_summary(
    *,
    root: Path,
    proof_surface_check_path: Path,
) -> dict[str, Any] | None:
    proof_surface_check = load_expected_artifact(
        root=root,
        path=proof_surface_check_path,
        expected_kind="browser_published_proof_surface_check",
    )
    if proof_surface_check is None:
        return None
    failures = compact_failures(proof_surface_check.get("failures"))
    return {
        "path": proof_surface_check_path.as_posix(),
        "sha256": sha256_file(root / proof_surface_check_path),
        "artifactKind": proof_surface_check.get("artifactKind", ""),
        "surfacePath": proof_surface_check.get("surfacePath", ""),
        "surfaceSha256": proof_surface_check.get("surfaceSha256", ""),
        "verifyFilesRootProvided": proof_surface_check.get("verifyFilesRootProvided") is True,
        "requirePublicUrls": proof_surface_check.get("requirePublicUrls") is True,
        "status": proof_surface_check.get("status", ""),
        "failureCount": len(failures),
        "failures": failures,
    }


def public_download_receipt_summary(
    *,
    root: Path,
    public_download_receipt_path: Path,
) -> dict[str, Any] | None:
    receipt = load_expected_artifact(
        root=root,
        path=public_download_receipt_path,
        expected_kind="browser_public_download_receipt",
    )
    if receipt is None:
        return None
    summary: dict[str, Any] = {
        "path": public_download_receipt_path.as_posix(),
        "sha256": sha256_file(root / public_download_receipt_path),
        "schemaVersion": receipt.get("schemaVersion", 0),
        "artifactKind": receipt.get("artifactKind", ""),
        "receiptId": receipt.get("receiptId", ""),
        "url": receipt.get("url", ""),
        "method": receipt.get("method", ""),
        "statusCode": receipt.get("statusCode", 0),
        "contentSha256": receipt.get("contentSha256", ""),
        "contentLengthBytes": receipt.get("contentLengthBytes", 0),
        "releaseArchivePath": receipt.get("releaseArchivePath", ""),
        "releaseArchiveManifestPath": receipt.get("releaseArchiveManifestPath", ""),
        "releaseArchiveManifestSha256": receipt.get("releaseArchiveManifestSha256", ""),
        "browserExecutableArchivePath": receipt.get("browserExecutableArchivePath", ""),
        "browserAppMetadataArchivePath": receipt.get("browserAppMetadataArchivePath", ""),
        "doeRuntimeArchivePath": receipt.get("doeRuntimeArchivePath", ""),
        "dawnFallbackRuntimeArchivePath": receipt.get("dawnFallbackRuntimeArchivePath", ""),
        "observedAt": receipt.get("observedAt", ""),
    }
    browser_product = receipt.get("browserProduct")
    if isinstance(browser_product, dict):
        summary["browserProduct"] = browser_product
    platform = receipt.get("platform")
    if isinstance(platform, dict):
        summary["platform"] = platform
    return summary


def chromium_source_checkout_summary(
    *,
    root: Path,
    chromium_source_checkout_path: Path,
) -> dict[str, Any] | None:
    report = load_expected_artifact(
        root=root,
        path=chromium_source_checkout_path,
        expected_kind="chromium_source_checkout_check",
    )
    if report is None:
        return None
    checks = report.get("checks")
    missing_required = report.get("missingRequired")
    missing_required_well_formed = (
        isinstance(missing_required, list)
        and all(isinstance(item, str) and item for item in missing_required)
    )
    return {
        "path": chromium_source_checkout_path.as_posix(),
        "sha256": sha256_file(root / chromium_source_checkout_path),
        "schemaVersion": report.get("schemaVersion", 0),
        "artifactKind": report.get("artifactKind", ""),
        "sourceRoot": report.get("sourceRoot", ""),
        "requireReady": report.get("requireReady") is True,
        "requireRuntimeSelector": report.get("requireRuntimeSelector") is True,
        "status": report.get("status", ""),
        "checkCount": len(checks) if isinstance(checks, list) else 0,
        "missingRequiredWellFormed": missing_required_well_formed,
        "missingRequired": missing_required if missing_required_well_formed else [],
    }


def browser_launch_receipt_summary(
    *,
    root: Path,
    browser_launch_receipt_path: Path,
) -> dict[str, Any] | None:
    receipt = load_expected_artifact(
        root=root,
        path=browser_launch_receipt_path,
        expected_kind="browser_release_launch_receipt",
    )
    if receipt is None:
        return None
    proof_page = receipt.get("proofPage")
    if not isinstance(proof_page, dict):
        proof_page = {}
    gallery_page = receipt.get("galleryPage")
    if not isinstance(gallery_page, dict):
        gallery_page = {}
    comparison = receipt.get("comparisonReceipt")
    if not isinstance(comparison, dict):
        comparison = {}
    comparison_modes = comparison.get("modes")
    if not isinstance(comparison_modes, list):
        comparison_modes = []
    observed_receipt_ids = receipt.get("observedReceiptIds")
    if not isinstance(observed_receipt_ids, list):
        observed_receipt_ids = []

    summary: dict[str, Any] = {
        "path": browser_launch_receipt_path.as_posix(),
        "sha256": sha256_file(root / browser_launch_receipt_path),
        "schemaVersion": receipt.get("schemaVersion", 0),
        "artifactKind": receipt.get("artifactKind", ""),
        "receiptId": receipt.get("receiptId", ""),
        "observedAt": receipt.get("observedAt", ""),
        "launchSource": receipt.get("launchSource", ""),
        "runtimeMode": receipt.get("runtimeMode", ""),
        "activeRuntime": receipt.get("activeRuntime", ""),
        "activeBackend": receipt.get("activeBackend", ""),
        "hiddenFallbackAllowed": receipt.get("hiddenFallbackAllowed"),
        "hiddenFallbackUsed": receipt.get("hiddenFallbackUsed"),
        "webgpuAvailable": receipt.get("webgpuAvailable"),
        "browserExecutableArchivePath": receipt.get("browserExecutableArchivePath", ""),
        "browserAppMetadataArchivePath": receipt.get("browserAppMetadataArchivePath", ""),
        "doeRuntimeArchivePath": receipt.get("doeRuntimeArchivePath", ""),
        "dawnFallbackRuntimeArchivePath": receipt.get("dawnFallbackRuntimeArchivePath", ""),
        "proofPageUrl": proof_page.get("url", ""),
        "proofPageLoaded": proof_page.get("loaded"),
        "proofPageArtifactPath": proof_page.get("artifactPath", ""),
        "proofPageReceiptId": proof_page.get("receiptId", ""),
        "galleryUrl": gallery_page.get("url", ""),
        "galleryLoaded": gallery_page.get("loaded"),
        "galleryCategory": gallery_page.get("category", ""),
        "galleryArtifactPath": gallery_page.get("artifactPath", ""),
        "galleryReceiptId": gallery_page.get("receiptId", ""),
        "comparisonId": comparison.get("comparisonId", ""),
        "comparisonWorkloadId": comparison.get("workloadId", ""),
        "comparisonPageArtifactPath": comparison.get("pageArtifactPath", ""),
        "comparisonLoaded": comparison.get("loaded"),
        "comparisonExecutionScope": comparison.get("executionScope", ""),
        "comparisonModes": [
            mode for mode in comparison_modes if isinstance(mode, str)
        ],
        "comparisonEmitsSideBySideReceipts": comparison.get("emitsSideBySideReceipts"),
        "comparisonArtifactPath": comparison.get("comparisonArtifactPath", ""),
        "comparisonDawnReceiptId": comparison.get("dawnReceiptId", ""),
        "comparisonDoeReceiptId": comparison.get("doeReceiptId", ""),
        "observedReceiptIds": [
            receipt_id for receipt_id in observed_receipt_ids if isinstance(receipt_id, str)
        ],
    }
    browser_product = receipt.get("browserProduct")
    if isinstance(browser_product, dict):
        summary["browserProduct"] = browser_product
    platform = receipt.get("platform")
    if isinstance(platform, dict):
        summary["platform"] = platform
    release_archive = compact_artifact(receipt.get("releaseArchive"))
    if release_archive is not None:
        summary["releaseArchive"] = release_archive
    release_archive_manifest = compact_artifact(receipt.get("releaseArchiveManifest"))
    if release_archive_manifest is not None:
        summary["releaseArchiveManifest"] = release_archive_manifest
    proof_surface = compact_artifact(receipt.get("proofSurface"))
    if proof_surface is not None:
        summary["proofSurface"] = proof_surface
    return summary


def browser_package_inputs_summary(
    *,
    root: Path,
    package_inputs_path: Path,
) -> dict[str, Any] | None:
    package_inputs = load_expected_artifact(
        root=root,
        path=package_inputs_path,
        expected_kind="browser_release_package_inputs_check",
    )
    if package_inputs is None:
        return None
    inputs = package_inputs.get("inputs")
    if not isinstance(inputs, dict):
        inputs = {}
    compact_inputs: dict[str, dict[str, Any]] = {}
    for role in (
        "browserExecutable",
        "appMetadata",
        "doeRuntime",
        "dawnFallbackRuntime",
        "shaderCompiler",
    ):
        row = inputs.get(role)
        if not isinstance(row, dict):
            continue
        compact_row: dict[str, Any] = {}
        for key in ("kind", "path", "archivePath", "sha256"):
            value = row.get(key)
            if isinstance(value, str) and value:
                compact_row[key] = value
        detected_format = row.get("detectedFormat")
        if isinstance(detected_format, str) and detected_format:
            compact_row["detectedFormat"] = detected_format
        detected_architectures = row.get("detectedArchitectures")
        if isinstance(detected_architectures, list):
            compact_row["detectedArchitectures"] = [
                arch for arch in detected_architectures if isinstance(arch, str)
            ]
        for key in ("exists", "generated", "executable"):
            value = row.get(key)
            if isinstance(value, bool):
                compact_row[key] = value
        byte_length = row.get("byteLength")
        if isinstance(byte_length, int):
            compact_row["byteLength"] = byte_length
        if compact_row:
            compact_inputs[role] = compact_row

    summary = package_inputs.get("summary")
    if not isinstance(summary, dict):
        summary = {}
    failures = compact_failures(package_inputs.get("failures"))
    release_candidate_blockers = compact_failures(
        package_inputs.get("releaseCandidateBlockers")
    )
    return {
        "path": package_inputs_path.as_posix(),
        "sha256": sha256_file(root / package_inputs_path),
        "schemaVersion": package_inputs.get("schemaVersion", 0),
        "artifactKind": package_inputs.get("artifactKind", ""),
        "status": package_inputs.get("status", ""),
        "evidenceMode": package_inputs.get("evidenceMode", ""),
        "releaseCandidateEligible": package_inputs.get("releaseCandidateEligible") is True,
        "releaseCandidateBlockers": release_candidate_blockers,
        "failureCount": len(failures),
        "failures": failures,
        "packageDir": package_inputs.get("packageDir", {})
        if isinstance(package_inputs.get("packageDir"), dict)
        else {},
        "packageRootName": package_inputs.get("packageRootName", ""),
        "browserProduct": package_inputs.get("browserProduct", {})
        if isinstance(package_inputs.get("browserProduct"), dict)
        else {},
        "platform": package_inputs.get("platform", {})
        if isinstance(package_inputs.get("platform"), dict)
        else {},
        "inputs": compact_inputs,
        "summary": summary,
    }


def compact_manifest_member(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    out: dict[str, Any] = {}
    for key in ("archivePath", "sha256", "sourcePath"):
        field = value.get(key)
        if isinstance(field, str) and field:
            out[key] = field
    if {"archivePath", "sha256"}.issubset(out):
        return out
    return None


def load_release_archive_manifest_from_bundle(
    *,
    root: Path,
    release_artifact_bundle: dict[str, Any],
) -> dict[str, Any] | None:
    manifest_artifact = release_artifact_bundle.get("releaseArchiveManifest")
    if not isinstance(manifest_artifact, dict):
        return None
    manifest_path = manifest_artifact.get("path")
    if not isinstance(manifest_path, str) or not manifest_path:
        return None
    if unsafe_repo_path_reason(manifest_path, allow_empty=False):
        return None
    try:
        return load_json_object(root / Path(manifest_path))
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        return None


def artifact_file_hash_consistency_failures(
    *,
    root: Path,
    artifact: Any,
    code: str,
    path: str,
    message: str,
    unsafe_code: str | None = None,
    unsafe_path: str | None = None,
    unsafe_label: str | None = None,
) -> list[dict[str, str]]:
    if not isinstance(artifact, dict):
        return [failure(code, path, message)]
    artifact_path = artifact.get("path")
    expected_sha = artifact.get("sha256")
    if (
        not isinstance(artifact_path, str)
        or not artifact_path
        or not isinstance(expected_sha, str)
        or not expected_sha
    ):
        return [failure(code, path, message)]
    unsafe_failure = repo_relative_path_failure(
        artifact_path,
        code=unsafe_code or code,
        path=unsafe_path or path,
        label=unsafe_label or "artifact path",
    )
    if unsafe_failure is not None:
        return [unsafe_failure]
    try:
        actual_sha = sha256_file(root / Path(artifact_path))
    except OSError:
        return [failure(code, path, message)]
    if actual_sha != expected_sha:
        return [failure(code, path, message)]
    return []


def release_support_artifacts_summary(
    release_artifact_bundle: dict[str, Any],
) -> dict[str, Any]:
    summary: dict[str, Any] = {}
    for section, kind_field in RELEASE_SUPPORT_KIND_SUMMARY_FIELDS.items():
        artifacts = compact_artifact_list(release_artifact_bundle.get(section))
        summary[section] = artifacts
        summary[kind_field] = sorted(
            {
                artifact["kind"]
                for artifact in artifacts
                if isinstance(artifact.get("kind"), str)
            }
        )
    return summary


def release_support_artifacts_consistency_failures(
    *,
    root: Path,
    release_artifact_bundle: dict[str, Any],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for section, required_kinds in REQUIRED_RELEASE_SUPPORT_KINDS.items():
        section_value = release_artifact_bundle.get(section)
        rows = section_value if isinstance(section_value, list) else []
        seen_kinds = {
            row.get("kind")
            for row in rows
            if isinstance(row, dict) and isinstance(row.get("kind"), str)
        }
        missing_code = RELEASE_SUPPORT_MISSING_KIND_CODES[section]
        for kind in sorted(required_kinds - seen_kinds):
            failures.append(
                failure(
                    missing_code,
                    f"releaseCandidateEvidence.releaseSupportArtifacts.{section}",
                    f"release artifact bundle must include support artifact kind {kind}",
                )
            )
        for index, artifact in enumerate(rows):
            failures.extend(
                artifact_file_hash_consistency_failures(
                    root=root,
                    artifact=artifact,
                    code="release_support_artifact_hash_mismatch",
                    path=f"releaseCandidateEvidence.releaseSupportArtifacts.{section}[{index}].sha256",
                    message="release support artifact sha256 must match referenced file bytes",
                    unsafe_code="release_support_artifact_path_unsafe",
                    unsafe_path=f"releaseCandidateEvidence.releaseSupportArtifacts.{section}[{index}].path",
                    unsafe_label="release support artifact",
                )
            )
    return failures


def release_artifact_bundle_product_platform_failures(
    release_artifact_bundle: dict[str, Any],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    release_status = release_artifact_bundle.get("releaseStatus")
    browser_product = release_artifact_bundle.get("browserProduct")
    if not isinstance(browser_product, dict):
        failures.append(
            failure(
                "release_artifact_bundle_browser_product_missing",
                "releaseCandidateEvidence.releaseArtifactBundle.browserProduct",
                "release artifact bundle must declare Doe Browser or Fawn Doe identity",
            )
        )
    else:
        product_id = browser_product.get("productId")
        display_name = browser_product.get("displayName")
        version = browser_product.get("version")
        channel = browser_product.get("channel")
        expected_display_name = (
            ALLOWED_BROWSER_PRODUCTS.get(product_id)
            if isinstance(product_id, str)
            else None
        )
        if expected_display_name is None:
            failures.append(
                failure(
                    "release_artifact_bundle_browser_product_id_invalid",
                    "releaseCandidateEvidence.releaseArtifactBundle.browserProduct.productId",
                    "release artifact bundle browserProduct.productId must be doe-browser or fawn-doe",
                )
            )
        elif display_name != expected_display_name:
            failures.append(
                failure(
                    "release_artifact_bundle_browser_product_name_mismatch",
                    "releaseCandidateEvidence.releaseArtifactBundle.browserProduct.displayName",
                    f"release artifact bundle browserProduct.displayName must be {expected_display_name}",
                )
            )
        if not isinstance(display_name, str) or not display_name:
            failures.append(
                failure(
                    "release_artifact_bundle_browser_product_display_name_missing",
                    "releaseCandidateEvidence.releaseArtifactBundle.browserProduct.displayName",
                    "release artifact bundle browserProduct.displayName is required",
                )
            )
        if not isinstance(version, str) or not version:
            failures.append(
                failure(
                    "release_artifact_bundle_browser_product_version_missing",
                    "releaseCandidateEvidence.releaseArtifactBundle.browserProduct.version",
                    "release artifact bundle browserProduct.version is required",
                )
            )
        if channel not in ALLOWED_BROWSER_PRODUCT_CHANNELS:
            failures.append(
                failure(
                    "release_artifact_bundle_browser_product_channel_invalid",
                    "releaseCandidateEvidence.releaseArtifactBundle.browserProduct.channel",
                    "release artifact bundle browserProduct.channel must be diagnostic, release_candidate, or release",
                )
            )
        elif release_status in {"diagnostic", "release_candidate"} and channel != release_status:
            failures.append(
                failure(
                    "release_artifact_bundle_browser_product_channel_mismatch",
                    "releaseCandidateEvidence.releaseArtifactBundle.browserProduct.channel",
                    "release artifact bundle browserProduct.channel must match releaseStatus",
                )
            )

    platform = release_artifact_bundle.get("platform")
    if not isinstance(platform, dict):
        failures.append(
            failure(
                "release_artifact_bundle_platform_missing",
                "releaseCandidateEvidence.releaseArtifactBundle.platform",
                "release artifact bundle platform is required",
            )
        )
    else:
        os_name = platform.get("os")
        arch = platform.get("arch")
        package_format = platform.get("packageFormat")
        if os_name not in ALLOWED_RELEASE_PLATFORM_OS:
            failures.append(
                failure(
                    "release_artifact_bundle_platform_os_invalid",
                    "releaseCandidateEvidence.releaseArtifactBundle.platform.os",
                    "release artifact bundle platform.os must be macos, linux, or windows",
                )
            )
        if arch not in ALLOWED_RELEASE_PLATFORM_ARCH:
            failures.append(
                failure(
                    "release_artifact_bundle_platform_arch_invalid",
                    "releaseCandidateEvidence.releaseArtifactBundle.platform.arch",
                    "release artifact bundle platform.arch must be arm64 or x64",
                )
            )
        if package_format not in ALLOWED_RELEASE_PACKAGE_FORMATS:
            failures.append(
                failure(
                    "release_artifact_bundle_platform_format_invalid",
                    "releaseCandidateEvidence.releaseArtifactBundle.platform.packageFormat",
                    "release artifact bundle platform.packageFormat must be zip",
                )
            )
        if (
            release_status == "release_candidate"
            and (os_name, arch, package_format) != ("macos", "arm64", "zip")
        ):
            failures.append(
                failure(
                    "release_artifact_bundle_platform_not_macos_arm64",
                    "releaseCandidateEvidence.releaseArtifactBundle.platform",
                    "initial release candidates must target macOS arm64 zip",
                )
            )
    return failures


def release_archive_zip_failures(
    *,
    root: Path,
    release_artifact_bundle: dict[str, Any],
) -> list[dict[str, str]]:
    platform = release_artifact_bundle.get("platform")
    if not isinstance(platform, dict) or platform.get("packageFormat") != "zip":
        return []
    release_archive = release_artifact_bundle.get("releaseArchive")
    archive_path = release_archive.get("path") if isinstance(release_archive, dict) else None
    if not isinstance(archive_path, str) or not archive_path:
        return []
    resolved_path = repo_relative_file_path(root, archive_path)
    if resolved_path is None:
        return []
    if not resolved_path.is_file():
        return []
    if not zipfile.is_zipfile(resolved_path):
        return [
            failure(
                "release_archive_zip_invalid",
                "releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.path",
                "release archive must be a valid zip file",
            )
        ]
    try:
        with zipfile.ZipFile(resolved_path) as archive:
            bad_member = archive.testzip()
    except zipfile.BadZipFile:
        return [
            failure(
                "release_archive_zip_invalid",
                "releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.path",
                "release archive must be a valid zip file",
            )
        ]
    if bad_member is not None:
        return [
            failure(
                "release_archive_zip_corrupt_member",
                "releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.path",
                f"release archive zip member failed integrity check: {bad_member}",
            )
        ]
    return []


def safe_archive_member_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    raw_parts = path_text.split("/")
    return (
        bool(path_text)
        and not path.is_absolute()
        and "\\" not in path_text
        and not any(part in ("", ".", "..") for part in raw_parts)
    )


def release_archive_member_artifact_failures(
    *,
    root: Path,
    release_artifact_bundle: dict[str, Any],
) -> list[dict[str, str]]:
    release_archive = release_artifact_bundle.get("releaseArchive")
    archive_path = release_archive.get("path") if isinstance(release_archive, dict) else None
    if not isinstance(archive_path, str) or not archive_path:
        return []
    zip_path = repo_relative_file_path(root, archive_path)
    if zip_path is None:
        return []
    if not zip_path.is_file() or not zipfile.is_zipfile(zip_path):
        return []

    failures: list[dict[str, str]] = []
    try:
        with zipfile.ZipFile(zip_path) as archive:
            for (
                label,
                artifact_field,
                member_path_field,
                require_executable,
            ) in RELEASE_ARCHIVE_DIRECT_MEMBER_BINDINGS:
                member_path = release_artifact_bundle.get(member_path_field)
                member_failure_path = (
                    f"releaseCandidateEvidence.releaseArtifactBundle.{member_path_field}"
                )
                if not isinstance(member_path, str) or not member_path:
                    failures.append(
                        failure(
                            "release_archive_member_path_missing",
                            member_failure_path,
                            f"release archive requires {label} path inside archive",
                        )
                    )
                    continue
                if not safe_archive_member_path(member_path):
                    failures.append(
                        failure(
                            "release_archive_member_path_unsafe",
                            member_failure_path,
                            f"{label} archive path must be relative and safe",
                        )
                    )
                    continue
                artifact = release_artifact_bundle.get(artifact_field)
                expected_sha = (
                    artifact.get("sha256")
                    if isinstance(artifact, dict)
                    else None
                )
                if not isinstance(expected_sha, str) or len(expected_sha) != 64:
                    continue
                try:
                    info = archive.getinfo(member_path)
                except KeyError:
                    failures.append(
                        failure(
                            "release_archive_member_missing",
                            member_failure_path,
                            f"{label} archive member not found: {member_path}",
                        )
                    )
                    continue
                if info.is_dir():
                    failures.append(
                        failure(
                            "release_archive_member_is_directory",
                            member_failure_path,
                            f"{label} archive member is a directory: {member_path}",
                        )
                    )
                    continue
                if require_executable:
                    mode = (info.external_attr >> 16) & 0o777
                    if not mode & 0o100:
                        failures.append(
                            failure(
                                "release_archive_member_not_executable",
                                member_failure_path,
                                f"{label} archive member must be executable",
                            )
                        )
                        continue
                member_sha = hashlib.sha256(archive.read(info)).hexdigest()
                if member_sha != expected_sha:
                    failures.append(
                        failure(
                            "release_archive_member_hash_mismatch",
                            (
                                "releaseCandidateEvidence.releaseArtifactBundle."
                                f"{artifact_field}.sha256"
                            ),
                            (
                                f"{label} archive member hash must match "
                                f"release artifact bundle {artifact_field}.sha256"
                            ),
                        )
                    )
    except zipfile.BadZipFile:
        return []
    return failures


def release_archive_binary_identity_failures(
    *,
    root: Path,
    release_artifact_bundle: dict[str, Any],
) -> list[dict[str, str]]:
    if release_artifact_bundle.get("releaseStatus") != "release_candidate":
        return []
    platform = release_artifact_bundle.get("platform")
    if not isinstance(platform, dict) or platform.get("os") != "macos":
        return []
    expected_arch = platform.get("arch")
    if not isinstance(expected_arch, str):
        return []
    release_archive = release_artifact_bundle.get("releaseArchive")
    archive_path = release_archive.get("path") if isinstance(release_archive, dict) else None
    if not isinstance(archive_path, str) or not archive_path:
        return []
    zip_path = repo_relative_file_path(root, archive_path)
    if zip_path is None or not zip_path.is_file() or not zipfile.is_zipfile(zip_path):
        return []

    failures: list[dict[str, str]] = []
    member_fields = (
        ("browserExecutableArchivePath", "browser_binary", "browser executable"),
        ("doeRuntimeArchivePath", "doe_runtime", "Doe runtime"),
        ("dawnFallbackRuntimeArchivePath", "dawn_fallback_runtime", "Dawn fallback runtime"),
    )
    try:
        with zipfile.ZipFile(zip_path) as archive:
            for member_path_field, kind, label in member_fields:
                member_path = release_artifact_bundle.get(member_path_field)
                if not isinstance(member_path, str) or not member_path:
                    continue
                try:
                    info = archive.getinfo(member_path)
                except KeyError:
                    continue
                if info.is_dir():
                    continue
                identity = detect_file_identity_bytes(archive.read(info), kind)
                failure_path = (
                    "releaseCandidateEvidence.releaseArtifactBundle."
                    f"{member_path_field}"
                )
                if identity.get("detectedFormat") != "macho":
                    failures.append(
                        failure(
                            "release_archive_binary_format_mismatch",
                            failure_path,
                            (
                                f"macOS {label} archive member must be "
                                f"Mach-O: {member_path}"
                            ),
                        )
                    )
                architectures = identity.get("detectedArchitectures")
                if not isinstance(architectures, list) or expected_arch not in architectures:
                    failures.append(
                        failure(
                            "release_archive_binary_arch_mismatch",
                            failure_path,
                            (
                                f"macOS {label} archive member must include "
                                f"{expected_arch} code: {member_path}"
                            ),
                        )
                    )
    except zipfile.BadZipFile:
        return []
    return failures


def release_archive_member_path_uniqueness_failures(
    release_artifact_bundle: dict[str, Any],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    seen: dict[str, tuple[str, str]] = {}
    for field, label in RELEASE_ARCHIVE_REQUIRED_MEMBER_PATH_FIELDS:
        member_path = release_artifact_bundle.get(field)
        if not isinstance(member_path, str) or not member_path:
            continue
        previous = seen.get(member_path)
        if previous is not None:
            previous_field, previous_label = previous
            failures.append(
                failure(
                    "release_archive_member_path_duplicate",
                    f"releaseCandidateEvidence.releaseArtifactBundle.{field}",
                    (
                        f"{label} archive path must not duplicate "
                        f"{previous_label} archive path from {previous_field}"
                    ),
                )
            )
            continue
        seen[member_path] = (field, label)
    return failures


def release_archive_macos_app_metadata_failures(
    *,
    root: Path,
    release_artifact_bundle: dict[str, Any],
) -> list[dict[str, str]]:
    platform = release_artifact_bundle.get("platform")
    if not isinstance(platform, dict) or platform.get("os") != "macos":
        return []
    member_path = release_artifact_bundle.get("browserAppMetadataArchivePath")
    if not isinstance(member_path, str) or not member_path:
        return [
            failure(
                "release_archive_app_metadata_path_missing",
                "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                "macOS release archive requires browserAppMetadataArchivePath",
            )
        ]
    if not safe_archive_member_path(member_path):
        return [
            failure(
                "release_archive_app_metadata_path_unsafe",
                "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                f"app metadata archive path must be relative and safe: {member_path}",
            )
        ]
    release_archive = release_artifact_bundle.get("releaseArchive")
    archive_path = release_archive.get("path") if isinstance(release_archive, dict) else None
    if not isinstance(archive_path, str) or not archive_path:
        return []
    archive_file_path = repo_relative_file_path(root, archive_path)
    if archive_file_path is None:
        return []
    try:
        with zipfile.ZipFile(archive_file_path) as archive:
            try:
                info = archive.getinfo(member_path)
            except KeyError:
                return [
                    failure(
                        "release_archive_app_metadata_missing",
                        "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                        f"app metadata archive member not found: {member_path}",
                    )
                ]
            if info.is_dir():
                return [
                    failure(
                        "release_archive_app_metadata_is_directory",
                        "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                        f"app metadata archive member is a directory: {member_path}",
                    )
                ]
            plist = plistlib.loads(archive.read(info))
    except FileNotFoundError:
        return []
    except (zipfile.BadZipFile, plistlib.InvalidFileException, TypeError, ValueError) as exc:
        return [
            failure(
                "release_archive_app_metadata_invalid_plist",
                "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                f"app metadata Info.plist is invalid: {exc}",
            )
        ]
    if not isinstance(plist, dict):
        return [
            failure(
                "release_archive_app_metadata_invalid_plist",
                "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                "app metadata Info.plist must be a dictionary",
            )
        ]

    failures: list[dict[str, str]] = []
    product = release_artifact_bundle.get("browserProduct")
    if isinstance(product, dict):
        display_name = product.get("displayName")
        product_id = product.get("productId")
        version = product.get("version")
        bundle_id = (
            ALLOWED_BROWSER_PRODUCT_BUNDLE_IDS.get(product_id)
            if isinstance(product_id, str)
            else None
        )
        for field in ("CFBundleName", "CFBundleDisplayName"):
            if plist.get(field) != display_name:
                failures.append(
                    failure(
                        "release_archive_app_metadata_product_mismatch",
                        f"releaseCandidateEvidence.releaseArchiveAppMetadata.{field}",
                        f"app metadata {field} must match browserProduct.displayName",
                    )
                )
        if bundle_id is not None and plist.get("CFBundleIdentifier") != bundle_id:
            failures.append(
                failure(
                    "release_archive_app_metadata_bundle_id_mismatch",
                    "releaseCandidateEvidence.releaseArchiveAppMetadata.CFBundleIdentifier",
                    "app metadata CFBundleIdentifier must match browserProduct.productId",
                )
            )
        for field in ("CFBundleShortVersionString", "CFBundleVersion"):
            if isinstance(version, str) and plist.get(field) != version:
                failures.append(
                    failure(
                        "release_archive_app_metadata_version_mismatch",
                        f"releaseCandidateEvidence.releaseArchiveAppMetadata.{field}",
                        f"app metadata {field} must match browserProduct.version",
                    )
                )
    executable_path = release_artifact_bundle.get("browserExecutableArchivePath")
    if isinstance(executable_path, str) and executable_path:
        executable_name = PurePosixPath(executable_path).name
        if plist.get("CFBundleExecutable") != executable_name:
            failures.append(
                failure(
                    "release_archive_app_metadata_executable_mismatch",
                    "releaseCandidateEvidence.releaseArchiveAppMetadata.CFBundleExecutable",
                    "app metadata CFBundleExecutable must match browserExecutableArchivePath",
                )
            )
    if plist.get("CFBundlePackageType") != "APPL":
        failures.append(
            failure(
                "release_archive_app_metadata_package_type_mismatch",
                "releaseCandidateEvidence.releaseArchiveAppMetadata.CFBundlePackageType",
                "app metadata CFBundlePackageType must be APPL",
            )
        )
    return failures


def release_archive_non_macos_app_metadata_failures(
    *,
    root: Path,
    release_artifact_bundle: dict[str, Any],
) -> list[dict[str, str]]:
    platform = release_artifact_bundle.get("platform")
    if not isinstance(platform, dict) or platform.get("os") == "macos":
        return []
    member_path = release_artifact_bundle.get("browserAppMetadataArchivePath")
    if not isinstance(member_path, str) or not member_path:
        return [
            failure(
                "release_archive_app_metadata_path_missing",
                "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                "non-macOS release archive requires browserAppMetadataArchivePath",
            )
        ]
    if not safe_archive_member_path(member_path):
        return [
            failure(
                "release_archive_app_metadata_path_unsafe",
                "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                f"browser metadata archive path must be relative and safe: {member_path}",
            )
        ]
    release_archive = release_artifact_bundle.get("releaseArchive")
    archive_path = release_archive.get("path") if isinstance(release_archive, dict) else None
    if not isinstance(archive_path, str) or not archive_path:
        return []
    archive_file_path = repo_relative_file_path(root, archive_path)
    if archive_file_path is None:
        return []
    try:
        with zipfile.ZipFile(archive_file_path) as archive:
            try:
                info = archive.getinfo(member_path)
            except KeyError:
                return [
                    failure(
                        "release_archive_app_metadata_missing",
                        "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                        f"browser metadata archive member not found: {member_path}",
                    )
                ]
            if info.is_dir():
                return [
                    failure(
                        "release_archive_app_metadata_is_directory",
                        "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                        f"browser metadata archive member is a directory: {member_path}",
                    )
                ]
            metadata = json.loads(archive.read(info).decode("utf-8"))
    except FileNotFoundError:
        return []
    except (UnicodeDecodeError, json.JSONDecodeError, zipfile.BadZipFile) as exc:
        return [
            failure(
                "release_archive_app_metadata_invalid_json",
                "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                f"browser metadata JSON is invalid: {exc}",
            )
        ]
    if not isinstance(metadata, dict):
        return [
            failure(
                "release_archive_app_metadata_invalid_json",
                "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
                "browser metadata JSON must be an object",
            )
        ]

    failures: list[dict[str, str]] = []
    for field, expected, code, message in (
        (
            "browserProduct",
            release_artifact_bundle.get("browserProduct"),
            "release_archive_app_metadata_product_mismatch",
            "browser metadata browserProduct must match the release artifact bundle",
        ),
        (
            "platform",
            release_artifact_bundle.get("platform"),
            "release_archive_app_metadata_platform_mismatch",
            "browser metadata platform must match the release artifact bundle",
        ),
        (
            "browserExecutableArchivePath",
            release_artifact_bundle.get("browserExecutableArchivePath"),
            "release_archive_app_metadata_executable_mismatch",
            "browser metadata browserExecutableArchivePath must match the release artifact bundle",
        ),
        (
            "doeRuntimeArchivePath",
            release_artifact_bundle.get("doeRuntimeArchivePath"),
            "release_archive_app_metadata_doe_runtime_mismatch",
            "browser metadata doeRuntimeArchivePath must match the release artifact bundle",
        ),
        (
            "dawnFallbackRuntimeArchivePath",
            release_artifact_bundle.get("dawnFallbackRuntimeArchivePath"),
            "release_archive_app_metadata_dawn_runtime_mismatch",
            "browser metadata dawnFallbackRuntimeArchivePath must match the release artifact bundle",
        ),
    ):
        if metadata.get(field) != expected:
            failures.append(
                failure(
                    code,
                    f"releaseCandidateEvidence.releaseArchiveAppMetadata.{field}",
                    message,
                )
            )
    return failures


def release_archive_manifest_archive_failures(
    *,
    root: Path,
    release_artifact_bundle: dict[str, Any],
    release_archive_manifest: dict[str, Any] | None,
) -> list[dict[str, str]]:
    if release_archive_manifest is None:
        return []
    archive = release_archive_manifest.get("archive")
    if not isinstance(archive, dict):
        return [
            failure(
                "release_archive_manifest_archive_mismatch",
                "releaseCandidateEvidence.releaseArchiveManifest.archive",
                "release archive manifest must bind release archive identity",
            )
        ]
    release_archive = release_artifact_bundle.get("releaseArchive")
    failures: list[dict[str, str]] = []
    for key in ("path", "sha256", "kind"):
        expected = release_archive.get(key) if isinstance(release_archive, dict) else None
        if archive.get(key) == expected:
            continue
        failures.append(
            failure(
                "release_archive_manifest_archive_mismatch",
                f"releaseCandidateEvidence.releaseArchiveManifest.archive.{key}",
                (
                    f"release archive manifest archive.{key} must match "
                    f"release artifact bundle releaseArchive.{key}"
                ),
            )
        )
    if isinstance(release_archive, dict):
        archive_path = release_archive.get("path")
        byte_length = archive.get("byteLength")
        if isinstance(archive_path, str) and isinstance(byte_length, int):
            archive_file_path = repo_relative_file_path(root, archive_path)
            if archive_file_path is None:
                actual_byte_length = None
            else:
                try:
                    actual_byte_length = archive_file_path.stat().st_size
                except OSError:
                    actual_byte_length = None
            if actual_byte_length is not None and byte_length != actual_byte_length:
                failures.append(
                    failure(
                        "release_archive_manifest_archive_mismatch",
                        "releaseCandidateEvidence.releaseArchiveManifest.archive.byteLength",
                        "release archive manifest archive.byteLength must match release archive file bytes",
                    )
                )
    return failures


def release_archive_manifest_identity_failures(
    *,
    release_artifact_bundle: dict[str, Any],
    release_archive_manifest: dict[str, Any] | None,
) -> list[dict[str, str]]:
    if release_archive_manifest is None:
        return [
            failure(
                "release_archive_manifest_missing",
                "releaseCandidateEvidence.releaseArtifactBundle.releaseArchiveManifest",
                "release archive manifest must be readable when checking release artifact identity",
            )
        ]
    failures: list[dict[str, str]] = []
    if release_archive_manifest.get("schemaVersion") != 1:
        failures.append(
            failure(
                "release_archive_manifest_schema_version_mismatch",
                "releaseCandidateEvidence.releaseArchiveManifest.schemaVersion",
                "release archive manifest schemaVersion must be 1",
            )
        )
    if release_archive_manifest.get("artifactKind") != "browser_release_archive_manifest":
        failures.append(
            failure(
                "release_archive_manifest_artifact_kind_mismatch",
                "releaseCandidateEvidence.releaseArchiveManifest.artifactKind",
                "release archive manifest artifactKind must be browser_release_archive_manifest",
            )
        )
    for field in RELEASE_PRODUCT_IDENTITY_FIELDS:
        if release_archive_manifest.get(field) == release_artifact_bundle.get(field):
            continue
        failures.append(
            failure(
                "release_archive_manifest_identity_mismatch",
                f"releaseCandidateEvidence.releaseArchiveManifest.{field}",
                f"release archive manifest {field} must match the release artifact bundle",
            )
        )
    return failures


def release_archive_manifest_member_failures(
    *,
    release_artifact_bundle: dict[str, Any],
    release_archive_manifest: dict[str, Any] | None,
) -> list[dict[str, str]]:
    if release_archive_manifest is None:
        return []
    members = release_archive_manifest.get("members")
    if not isinstance(members, dict):
        return [
            failure(
                "release_archive_manifest_member_mismatch",
                "releaseCandidateEvidence.releaseArchiveManifest.members",
                "release archive manifest must bind required packaged members",
            )
        ]
    failures: list[dict[str, str]] = []
    for role, bundle_path_field, bundle_artifact_field, require_executable in (
        RELEASE_ARCHIVE_MANIFEST_MEMBER_BINDINGS
    ):
        member = members.get(role)
        member_path = f"releaseCandidateEvidence.releaseArchiveManifest.members.{role}"
        if not isinstance(member, dict):
            failures.append(
                failure(
                    "release_archive_manifest_member_mismatch",
                    member_path,
                    f"release archive manifest must bind {role} member",
                )
            )
            continue
        if member.get("archivePath") != release_artifact_bundle.get(bundle_path_field):
            failures.append(
                failure(
                    "release_archive_manifest_member_mismatch",
                    f"{member_path}.archivePath",
                    (
                        f"release archive manifest {role}.archivePath must match "
                        f"release artifact bundle {bundle_path_field}"
                    ),
                )
            )
        if bundle_artifact_field is not None:
            bundle_artifact = release_artifact_bundle.get(bundle_artifact_field)
            expected_sha = (
                bundle_artifact.get("sha256")
                if isinstance(bundle_artifact, dict)
                else None
            )
            if member.get("sha256") != expected_sha:
                failures.append(
                    failure(
                        "release_archive_manifest_member_mismatch",
                        f"{member_path}.sha256",
                        (
                            f"release archive manifest {role}.sha256 must match "
                            f"release artifact bundle {bundle_artifact_field}.sha256"
                        ),
                    )
                )
        if require_executable and member.get("executable") is not True:
            failures.append(
                failure(
                    "release_archive_manifest_member_mismatch",
                    f"{member_path}.executable",
                    f"release archive manifest {role} must be executable",
                )
            )
    return failures


def release_archive_manifest_archive_member_failures(
    *,
    root: Path,
    release_artifact_bundle: dict[str, Any],
    release_archive_manifest: dict[str, Any] | None,
) -> list[dict[str, str]]:
    if release_archive_manifest is None:
        return []
    members = release_archive_manifest.get("members")
    archive_members = release_archive_manifest.get("archiveMembers")
    if not isinstance(members, dict) or not isinstance(archive_members, list):
        return [
            failure(
                "release_archive_manifest_archive_member_mismatch",
                "releaseCandidateEvidence.releaseArchiveManifest.archiveMembers",
                "release archive manifest must index packaged members in archiveMembers",
            )
        ]
    failures: list[dict[str, str]] = []
    seen_manifest_member_paths: set[str] = set()
    for row in archive_members:
        if not isinstance(row, dict) or not isinstance(row.get("archivePath"), str):
            continue
        archive_member_path = row["archivePath"]
        if not safe_archive_member_path(archive_member_path):
            failures.append(
                failure(
                    "release_archive_manifest_archive_member_path_unsafe",
                    "releaseCandidateEvidence.releaseArchiveManifest.archiveMembers",
                    (
                        "release archive manifest archiveMembers path must be "
                        f"relative and safe: {archive_member_path}"
                    ),
                )
            )
            continue
        if archive_member_path in seen_manifest_member_paths:
            failures.append(
                failure(
                    "release_archive_manifest_archive_member_duplicate",
                    "releaseCandidateEvidence.releaseArchiveManifest.archiveMembers",
                    (
                        "release archive manifest archiveMembers must not "
                        f"repeat member path: {archive_member_path}"
                    ),
                )
            )
            continue
        seen_manifest_member_paths.add(archive_member_path)
    indexed_members = {
        row.get("archivePath"): row
        for row in archive_members
        if isinstance(row, dict) and isinstance(row.get("archivePath"), str)
    }
    for role, _, _, _ in RELEASE_ARCHIVE_MANIFEST_MEMBER_BINDINGS:
        member = members.get(role)
        member_path = f"releaseCandidateEvidence.releaseArchiveManifest.members.{role}"
        if not isinstance(member, dict):
            continue
        if indexed_members.get(member.get("archivePath")) != member:
            failures.append(
                failure(
                    "release_archive_manifest_archive_member_mismatch",
                    "releaseCandidateEvidence.releaseArchiveManifest.archiveMembers",
                    f"release archive manifest archiveMembers must include {role} member",
                )
            )
        if not isinstance(member.get("byteLength"), int):
            failures.append(
                failure(
                    "release_archive_manifest_archive_member_mismatch",
                    f"{member_path}.byteLength",
                    f"release archive manifest {role}.byteLength must be recorded",
                )
            )
    release_archive = release_artifact_bundle.get("releaseArchive")
    archive_path = release_archive.get("path") if isinstance(release_archive, dict) else None
    if not isinstance(archive_path, str) or not archive_path:
        return failures
    zip_path = repo_relative_file_path(root, archive_path)
    if zip_path is None:
        return failures
    if not zip_path.is_file() or not zipfile.is_zipfile(zip_path):
        failures.append(
            failure(
                "release_archive_manifest_zip_mismatch",
                "releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.path",
                "release archive must be a readable zip when checking release archive manifest members",
            )
        )
        return failures
    with zipfile.ZipFile(zip_path) as archive:
        zip_records: dict[str, dict[str, Any]] = {}
        for info in archive.infolist():
            if info.is_dir():
                continue
            if info.filename in zip_records:
                failures.append(
                    failure(
                        "release_archive_zip_member_duplicate",
                        "releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.path",
                        f"release archive zip must not repeat member path: {info.filename}",
                    )
                )
                continue
            data = archive.read(info)
            mode = (info.external_attr >> 16) & 0o777
            zip_records[info.filename] = {
                "archivePath": info.filename,
                "sha256": hashlib.sha256(data).hexdigest(),
                "byteLength": len(data),
                "executable": bool(mode & stat.S_IXUSR),
            }
    for archive_path_value, manifest_member in indexed_members.items():
        zip_record = zip_records.get(str(archive_path_value))
        if zip_record is None:
            failures.append(
                failure(
                    "release_archive_manifest_zip_mismatch",
                    "releaseCandidateEvidence.releaseArchiveManifest.archiveMembers",
                    f"release archive zip must contain manifest member: {archive_path_value}",
                )
            )
            continue
        if any(zip_record.get(key) != manifest_member.get(key) for key in ("sha256", "byteLength", "executable")):
            failures.append(
                failure(
                    "release_archive_manifest_zip_mismatch",
                    "releaseCandidateEvidence.releaseArchiveManifest.archiveMembers",
                    f"release archive manifest member metadata must match zip member: {archive_path_value}",
                )
            )
    return failures


def release_runtime_frontier_bundle_binding_failures(
    *,
    root: Path,
    release_artifact_bundle: dict[str, Any],
    runtime_frontier_path: Any,
) -> list[dict[str, str]]:
    if not isinstance(runtime_frontier_path, Path):
        return [
            failure(
                "release_runtime_frontier_bundle_target_missing",
                "releaseCandidateEvidence.releaseArtifactBundle.runtimeFrontierBundle",
                "release artifact bundle must be checked against a configured runtime frontier bundle",
            )
        ]
    artifact = release_artifact_bundle.get("runtimeFrontierBundle")
    if not isinstance(artifact, dict):
        return [
            failure(
                "release_runtime_frontier_bundle_mismatch",
                "releaseCandidateEvidence.releaseArtifactBundle.runtimeFrontierBundle",
                "release artifact bundle must hash-bind the runtime frontier bundle",
            )
        ]
    expected_path = runtime_frontier_path.as_posix()
    try:
        expected_sha = sha256_file(root / runtime_frontier_path)
    except OSError:
        return [
            failure(
                "release_runtime_frontier_bundle_target_missing",
                "releaseCandidateEvidence.releaseArtifactBundle.runtimeFrontierBundle",
                "configured runtime frontier bundle must be readable",
            )
        ]
    if not (
        artifact.get("path") == expected_path
        and artifact.get("sha256") == expected_sha
        and artifact.get("kind") == BROWSER_FRONTIER_BUNDLE_KIND
    ):
        return [
            failure(
                "release_runtime_frontier_bundle_mismatch",
                "releaseCandidateEvidence.releaseArtifactBundle.runtimeFrontierBundle",
                "release artifact bundle runtimeFrontierBundle must match the readiness runtime frontier bundle path and hash",
            )
        ]
    return []


def runtime_frontier_release_component_identity_failures(
    *,
    root: Path,
    runtime_frontier_bundle: dict[str, Any],
    release_artifact_bundle: dict[str, Any],
) -> list[dict[str, str]]:
    component_receipts = runtime_frontier_bundle.get("componentReceipts")
    release_summary = (
        component_receipts.get("releaseArtifactBundle")
        if isinstance(component_receipts, dict)
        else None
    )
    if not isinstance(release_summary, dict):
        return [
            failure(
                "runtime_frontier_release_component_missing",
                "frontierBundleEvidence.componentReceipts.releaseArtifactBundle",
                "runtime frontier bundle must summarize the release artifact bundle",
            )
        ]
    failures: list[dict[str, str]] = []
    path_text = release_summary.get("path")
    if not isinstance(path_text, str) or not path_text:
        failures.append(
            failure(
                "runtime_frontier_release_component_identity_mismatch",
                "frontierBundleEvidence.componentReceipts.releaseArtifactBundle.path",
                "runtime frontier release artifact component must identify the loaded release artifact bundle path",
            )
        )
    else:
        summary_sha = release_summary.get("sha256")
        if isinstance(summary_sha, str) and summary_sha != sha256_file(root / Path(path_text)):
            failures.append(
                failure(
                    "runtime_frontier_release_component_identity_mismatch",
                    "frontierBundleEvidence.componentReceipts.releaseArtifactBundle.sha256",
                    "runtime frontier release artifact component sha256 must match the loaded release artifact bundle bytes",
                )
            )
    for field in ("artifactKind", "bundleId", "releaseStatus"):
        if release_summary.get(field) != release_artifact_bundle.get(field):
            failures.append(
                failure(
                    "runtime_frontier_release_component_identity_mismatch",
                    f"frontierBundleEvidence.componentReceipts.releaseArtifactBundle.{field}",
                    f"runtime frontier release artifact component {field} must match the loaded release artifact bundle",
                )
            )
    if (
        release_summary.get("releaseBundleIdentitySha256")
        != release_bundle_identity_sha256(release_artifact_bundle)
    ):
        failures.append(
            failure(
                "runtime_frontier_release_component_identity_mismatch",
                "frontierBundleEvidence.componentReceipts.releaseArtifactBundle.releaseBundleIdentitySha256",
                "runtime frontier release artifact component releaseBundleIdentitySha256 must match the loaded release artifact bundle identity",
            )
        )
    return failures


def artifact_field_matches(
    artifact: Any,
    *,
    path: str | None = None,
    sha256: str | None = None,
) -> bool:
    if not isinstance(artifact, dict):
        return False
    if path is not None and artifact.get("path") != path:
        return False
    if sha256 is not None and artifact.get("sha256") != sha256:
        return False
    return True


def member_matches_input(member: Any, input_row: Any) -> bool:
    if not isinstance(member, dict) or not isinstance(input_row, dict):
        return False
    return (
        member.get("archivePath") == input_row.get("archivePath")
        and member.get("sha256") == input_row.get("sha256")
    )


def source_path_matches(left: Any, right: Any, root: Path) -> bool:
    if not isinstance(left, str) or not isinstance(right, str) or not left or not right:
        return False
    if left == right:
        return True
    left_path = repo_relative_file_path(root, left)
    right_path = repo_relative_file_path(root, right)
    return left_path is not None and right_path is not None and left_path == right_path


def package_inputs_binary_identity_failures(
    package_inputs_summary: dict[str, Any],
) -> list[dict[str, str]]:
    platform = package_inputs_summary.get("platform")
    if not isinstance(platform, dict) or platform.get("os") != "macos":
        return []
    expected_arch = platform.get("arch")
    inputs = package_inputs_summary.get("inputs")
    if not isinstance(expected_arch, str) or not isinstance(inputs, dict):
        return []
    failures: list[dict[str, str]] = []
    for role in ("browserExecutable", "doeRuntime", "dawnFallbackRuntime", "shaderCompiler"):
        row = inputs.get(role)
        if not isinstance(row, dict):
            continue
        if row.get("detectedFormat") != "macho":
            failures.append(
                failure(
                    "package_inputs_binary_platform_mismatch",
                    f"releaseCandidateEvidence.packageInputs.inputs.{role}.detectedFormat",
                    f"package-input {role} must be detected as Mach-O for macOS release-candidate evidence",
                )
            )
        architectures = row.get("detectedArchitectures")
        if not isinstance(architectures, list) or expected_arch not in architectures:
            failures.append(
                failure(
                    "package_inputs_binary_arch_mismatch",
                    f"releaseCandidateEvidence.packageInputs.inputs.{role}.detectedArchitectures",
                    f"package-input {role} must include {expected_arch} code for macOS release-candidate evidence",
                )
            )
    return failures


def browser_release_candidate_evidence(
    *,
    root: Path,
    bundle_config: dict[str, Any],
    runtime_frontier_bundle: dict[str, Any],
) -> dict[str, Any] | None:
    evidence: dict[str, Any] = {}
    provenance_report_summary_: dict[str, Any] | None = None
    package_inputs_summary_: dict[str, Any] | None = None
    public_download_summary: dict[str, Any] | None = None
    browser_launch_summary: dict[str, Any] | None = None
    browser_launch_receipt_raw: dict[str, Any] | None = None
    chromium_source_checkout_summary_: dict[str, Any] | None = None
    proof_surface_summary: dict[str, Any] | None = None
    proof_surface_raw: dict[str, Any] | None = None
    proof_surface_check_summary_: dict[str, Any] | None = None
    finalizer_summary: dict[str, Any] | None = None
    finalizer_check_summary: dict[str, Any] | None = None
    release_support_summary: dict[str, Any] | None = None
    missing_evidence_failures: list[dict[str, str]] = []

    provenance_report_path = bundle_config.get("provenanceReportPath")
    if isinstance(provenance_report_path, Path):
        provenance_report_summary_ = provenance_report_summary(
            root=root,
            provenance_report_path=provenance_report_path,
        )
        if provenance_report_summary_ is not None:
            evidence["provenanceReport"] = provenance_report_summary_
        else:
            try:
                provenance_report_raw = load_json_object(root / provenance_report_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                provenance_report_raw = None
            if (
                isinstance(provenance_report_raw, dict)
                and provenance_report_raw.get("artifactKind")
                != "browser_release_candidate_provenance_report"
            ):
                missing_evidence_failures.append(
                    failure(
                        "provenance_report_artifact_kind_mismatch",
                        "releaseCandidateEvidence.provenanceReport.artifactKind",
                        "provenance report artifactKind must be browser_release_candidate_provenance_report",
                    )
                )
            missing_evidence_failures.append(
                failure(
                    "provenance_report_missing",
                    "releaseCandidateEvidence.provenanceReport",
                    f"configured provenance report is missing or has the wrong artifact kind: {provenance_report_path.as_posix()}",
                )
            )

    package_inputs_path = bundle_config.get("packageInputsPath")
    if isinstance(package_inputs_path, Path):
        package_inputs_summary_ = browser_package_inputs_summary(
            root=root,
            package_inputs_path=package_inputs_path,
        )
        if package_inputs_summary_ is not None:
            evidence["packageInputs"] = package_inputs_summary_
        else:
            try:
                package_inputs_raw = load_json_object(root / package_inputs_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                package_inputs_raw = None
            if (
                isinstance(package_inputs_raw, dict)
                and package_inputs_raw.get("artifactKind")
                != "browser_release_package_inputs_check"
            ):
                missing_evidence_failures.append(
                    failure(
                        "package_inputs_artifact_kind_mismatch",
                        "releaseCandidateEvidence.packageInputs.artifactKind",
                        "package-input report artifactKind must be browser_release_package_inputs_check",
                    )
                )
            missing_evidence_failures.append(
                failure(
                    "package_inputs_missing",
                    "releaseCandidateEvidence.packageInputs",
                    f"configured package-input report is missing or has the wrong artifact kind: {package_inputs_path.as_posix()}",
                )
            )

    public_download_path = bundle_config.get("publicDownloadReceiptPath")
    if isinstance(public_download_path, Path):
        public_download_summary = public_download_receipt_summary(
            root=root,
            public_download_receipt_path=public_download_path,
        )
        if public_download_summary is not None:
            evidence["publicDownloadReceipt"] = public_download_summary
        else:
            try:
                public_download_raw = load_json_object(root / public_download_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                public_download_raw = None
            if (
                isinstance(public_download_raw, dict)
                and public_download_raw.get("artifactKind")
                != "browser_public_download_receipt"
            ):
                missing_evidence_failures.append(
                    failure(
                        "public_download_artifact_kind_mismatch",
                        "releaseCandidateEvidence.publicDownloadReceipt.artifactKind",
                        "public download receipt artifactKind must be browser_public_download_receipt",
                    )
                )
            missing_evidence_failures.append(
                failure(
                    "public_download_receipt_missing",
                    "releaseCandidateEvidence.publicDownloadReceipt",
                    f"configured public download receipt is missing or has the wrong artifact kind: {public_download_path.as_posix()}",
                )
            )

    browser_launch_path = bundle_config.get("browserLaunchReceiptPath")
    if isinstance(browser_launch_path, Path):
        browser_launch_summary = browser_launch_receipt_summary(
            root=root,
            browser_launch_receipt_path=browser_launch_path,
        )
        if browser_launch_summary is not None:
            evidence["browserLaunchReceipt"] = browser_launch_summary
            browser_launch_receipt_raw = load_expected_artifact(
                root=root,
                path=browser_launch_path,
                expected_kind="browser_release_launch_receipt",
            )
        else:
            try:
                browser_launch_raw = load_json_object(root / browser_launch_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                browser_launch_raw = None
            if (
                isinstance(browser_launch_raw, dict)
                and browser_launch_raw.get("artifactKind")
                != "browser_release_launch_receipt"
            ):
                missing_evidence_failures.append(
                    failure(
                        "browser_launch_artifact_kind_mismatch",
                        "releaseCandidateEvidence.browserLaunchReceipt.artifactKind",
                        "browser launch receipt artifactKind must be browser_release_launch_receipt",
                    )
                )
            missing_evidence_failures.append(
                failure(
                    "browser_launch_receipt_missing",
                    "releaseCandidateEvidence.browserLaunchReceipt",
                    f"configured browser launch receipt is missing or has the wrong artifact kind: {browser_launch_path.as_posix()}",
                )
            )

    chromium_source_checkout_path = bundle_config.get("chromiumSourceCheckoutPath")
    if isinstance(chromium_source_checkout_path, Path):
        chromium_source_checkout_summary_ = chromium_source_checkout_summary(
            root=root,
            chromium_source_checkout_path=chromium_source_checkout_path,
        )
        if chromium_source_checkout_summary_ is not None:
            evidence["chromiumSourceCheckout"] = chromium_source_checkout_summary_
        else:
            try:
                chromium_source_checkout_raw = load_json_object(
                    root / chromium_source_checkout_path
                )
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                chromium_source_checkout_raw = None
            if (
                isinstance(chromium_source_checkout_raw, dict)
                and chromium_source_checkout_raw.get("artifactKind")
                != "chromium_source_checkout_check"
            ):
                missing_evidence_failures.append(
                    failure(
                        "chromium_source_checkout_artifact_kind_mismatch",
                        "releaseCandidateEvidence.chromiumSourceCheckout.artifactKind",
                        "Chromium source checkout report artifactKind must be chromium_source_checkout_check",
                    )
                )
            missing_evidence_failures.append(
                failure(
                    "chromium_source_checkout_missing",
                    "releaseCandidateEvidence.chromiumSourceCheckout",
                    f"configured Chromium source checkout report is missing or has the wrong artifact kind: {chromium_source_checkout_path.as_posix()}",
                )
            )

    proof_surface_path = bundle_config.get("proofSurfacePath")
    if isinstance(proof_surface_path, Path):
        proof_surface_summary = published_proof_surface_summary(
            root=root,
            proof_surface_path=proof_surface_path,
        )
        if proof_surface_summary is not None:
            evidence["publishedProofSurface"] = proof_surface_summary
            proof_surface_raw = load_expected_artifact(
                root=root,
                path=proof_surface_path,
                expected_kind="browser_published_proof_surface",
            )
        else:
            try:
                proof_surface_raw = load_json_object(root / proof_surface_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                proof_surface_raw = None
            if (
                isinstance(proof_surface_raw, dict)
                and proof_surface_raw.get("artifactKind")
                != "browser_published_proof_surface"
            ):
                missing_evidence_failures.append(
                    failure(
                        "published_proof_surface_artifact_kind_mismatch",
                        "releaseCandidateEvidence.publishedProofSurface.artifactKind",
                        "published proof surface artifactKind must be browser_published_proof_surface",
                    )
                )
            missing_evidence_failures.append(
                failure(
                    "published_proof_surface_missing",
                    "releaseCandidateEvidence.publishedProofSurface",
                    f"configured published proof surface is missing or has the wrong artifact kind: {proof_surface_path.as_posix()}",
                )
            )

    proof_surface_check_path = bundle_config.get("proofSurfaceCheckPath")
    if isinstance(proof_surface_check_path, Path):
        proof_surface_check_summary_ = proof_surface_check_summary(
            root=root,
            proof_surface_check_path=proof_surface_check_path,
        )
        if proof_surface_check_summary_ is not None:
            evidence["proofSurfaceCheck"] = proof_surface_check_summary_
        else:
            try:
                proof_surface_check_raw = load_json_object(root / proof_surface_check_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                proof_surface_check_raw = None
            if (
                isinstance(proof_surface_check_raw, dict)
                and proof_surface_check_raw.get("artifactKind")
                != "browser_published_proof_surface_check"
            ):
                missing_evidence_failures.append(
                    failure(
                        "proof_surface_check_artifact_kind_mismatch",
                        "releaseCandidateEvidence.proofSurfaceCheck.artifactKind",
                        "proof-surface checker report artifactKind must be browser_published_proof_surface_check",
                    )
                )
            missing_evidence_failures.append(
                failure(
                    "proof_surface_check_missing",
                    "releaseCandidateEvidence.proofSurfaceCheck",
                    f"configured proof-surface checker report is missing or has the wrong artifact kind: {proof_surface_check_path.as_posix()}",
                )
            )

    finalizer_path = bundle_config.get("finalizerReportPath")
    if isinstance(finalizer_path, Path):
        finalizer = load_expected_artifact(
            root=root,
            path=finalizer_path,
            expected_kind="browser_release_candidate_finalizer",
        )
        if finalizer is not None:
            failures = compact_failures(finalizer.get("failures"))
            finalizer_summary: dict[str, Any] = {
                "path": finalizer_path.as_posix(),
                "sha256": sha256_file(root / finalizer_path),
                "artifactKind": finalizer.get("artifactKind", ""),
                "status": finalizer.get("status", ""),
                "failureCount": len(failures),
            }
            phase = finalizer.get("phase")
            if isinstance(phase, str):
                finalizer_summary["phase"] = phase
            summary = finalizer.get("summary")
            if isinstance(summary, dict):
                finalizer_summary["summary"] = summary
            outputs = finalizer.get("outputs")
            if isinstance(outputs, dict):
                compact_outputs = {
                    key: artifact
                    for key, artifact in (
                        (key, compact_artifact(value))
                        for key, value in outputs.items()
                    )
                    if artifact is not None
                }
                if compact_outputs:
                    finalizer_summary["outputs"] = compact_outputs
            inputs = finalizer.get("inputs")
            if isinstance(inputs, dict):
                compact_inputs = {
                    key: artifact
                    for key, artifact in (
                        (key, compact_artifact(value))
                        for key, value in inputs.items()
                    )
                    if artifact is not None
                }
                if compact_inputs:
                    finalizer_summary["inputs"] = compact_inputs
            if failures:
                finalizer_summary["failures"] = failures
            evidence["finalizerReport"] = finalizer_summary
        else:
            try:
                finalizer_raw = load_json_object(root / finalizer_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                finalizer_raw = None
            if (
                isinstance(finalizer_raw, dict)
                and finalizer_raw.get("artifactKind")
                != "browser_release_candidate_finalizer"
            ):
                missing_evidence_failures.append(
                    failure(
                        "finalizer_report_artifact_kind_mismatch",
                        "releaseCandidateEvidence.finalizerReport.artifactKind",
                        "finalizer report artifactKind must be browser_release_candidate_finalizer",
                    )
                )
            missing_evidence_failures.append(
                failure(
                    "finalizer_report_missing",
                    "releaseCandidateEvidence.finalizerReport",
                    f"configured finalizer report is missing or has the wrong artifact kind: {finalizer_path.as_posix()}",
                )
            )

    finalizer_check_path = bundle_config.get("finalizerCheckPath")
    if isinstance(finalizer_check_path, Path):
        finalizer_check = load_expected_artifact(
            root=root,
            path=finalizer_check_path,
            expected_kind="browser_release_candidate_finalizer_check",
        )
        if finalizer_check is not None:
            failures = compact_failures(finalizer_check.get("failures"))
            finalizer_check_summary = {
                "path": finalizer_check_path.as_posix(),
                "sha256": sha256_file(root / finalizer_check_path),
                "artifactKind": finalizer_check.get("artifactKind", ""),
                "status": finalizer_check.get("status", ""),
                "finalizerStatus": finalizer_check.get("finalizerStatus", ""),
                "finalizerReportPath": finalizer_check.get("finalizerReportPath", ""),
                "finalizerReportSha256": finalizer_check.get("finalizerReportSha256", ""),
                "verifyFilesRootProvided": finalizer_check.get("verifyFilesRootProvided") is True,
                "requirePass": finalizer_check.get("requirePass") is True,
                "failureCount": len(failures),
                "failures": failures,
            }
            outputs = finalizer_check.get("outputs")
            if isinstance(outputs, dict):
                compact_outputs = {
                    key: artifact
                    for key, artifact in (
                        (key, compact_artifact(value))
                        for key, value in outputs.items()
                    )
                    if artifact is not None
                }
                if compact_outputs:
                    finalizer_check_summary["outputs"] = compact_outputs
            inputs = finalizer_check.get("inputs")
            if isinstance(inputs, dict):
                compact_inputs = {
                    key: artifact
                    for key, artifact in (
                        (key, compact_artifact(value))
                        for key, value in inputs.items()
                    )
                    if artifact is not None
                }
                if compact_inputs:
                    finalizer_check_summary["inputs"] = compact_inputs
            evidence["finalizerCheck"] = finalizer_check_summary
        else:
            try:
                finalizer_check_raw = load_json_object(root / finalizer_check_path)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                finalizer_check_raw = None
            if (
                isinstance(finalizer_check_raw, dict)
                and finalizer_check_raw.get("artifactKind")
                != "browser_release_candidate_finalizer_check"
            ):
                missing_evidence_failures.append(
                    failure(
                        "finalizer_check_artifact_kind_mismatch",
                        "releaseCandidateEvidence.finalizerCheck.artifactKind",
                        "finalizer-check receipt artifactKind must be browser_release_candidate_finalizer_check",
                    )
                )
            missing_evidence_failures.append(
                failure(
                    "finalizer_check_missing",
                    "releaseCandidateEvidence.finalizerCheck",
                    f"configured finalizer-check receipt is missing or has the wrong artifact kind: {finalizer_check_path.as_posix()}",
                )
            )

    release_artifact_bundle = load_release_artifact_bundle(
        root=root,
        runtime_frontier_bundle=runtime_frontier_bundle,
    )
    release_artifact_bundle_load_failures: list[dict[str, str]] = []
    if release_artifact_bundle is None:
        component_receipts = runtime_frontier_bundle.get("componentReceipts")
        release_summary = (
            component_receipts.get("releaseArtifactBundle")
            if isinstance(component_receipts, dict)
            else None
        )
        release_path = (
            release_summary.get("path")
            if isinstance(release_summary, dict)
            else None
        )
        if isinstance(release_path, str) and release_path:
            try:
                release_raw = load_json_object(root / Path(release_path))
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                release_raw = None
            if (
                isinstance(release_raw, dict)
                and release_raw.get("artifactKind")
                != "browser_release_artifact_bundle"
            ):
                release_artifact_bundle_load_failures.append(
                    failure(
                        "release_artifact_bundle_artifact_kind_mismatch",
                        "releaseCandidateEvidence.releaseArtifactBundle.artifactKind",
                        "browser release artifact bundle artifactKind must be browser_release_artifact_bundle",
                    )
                )
    if release_artifact_bundle is not None:
        release_support_summary = release_support_artifacts_summary(release_artifact_bundle)
        evidence["releaseSupportArtifacts"] = release_support_summary
    if (
        finalizer_summary is not None
        or finalizer_check_summary is not None
        or provenance_report_summary_ is not None
        or public_download_summary is not None
        or browser_launch_summary is not None
        or chromium_source_checkout_summary_ is not None
        or proof_surface_summary is not None
        or proof_surface_check_summary_ is not None
        or release_support_summary is not None
        or missing_evidence_failures
        or release_artifact_bundle_load_failures
    ):
        consistency_failures: list[dict[str, str]] = [
            *missing_evidence_failures,
            *release_artifact_bundle_load_failures,
        ]
        if release_artifact_bundle is None:
            consistency_failures.append(
                failure(
                    "release_artifact_bundle_missing",
                    "frontierBundleEvidence.componentReceipts.releaseArtifactBundle.path",
                    "runtime frontier bundle must identify a readable browser release artifact bundle",
                )
            )
        consistency_failures.extend(
            runtime_frontier_claimability_consistency_failures(
                runtime_frontier_bundle,
                proof_surface_summary=proof_surface_summary,
                release_artifact_bundle=release_artifact_bundle,
            )
        )
        if release_artifact_bundle is not None:
            release_archive_manifest = load_release_archive_manifest_from_bundle(
                root=root,
                release_artifact_bundle=release_artifact_bundle,
            )
            if release_artifact_bundle.get("releaseStatus") != "release_candidate":
                consistency_failures.append(
                    failure(
                        "release_artifact_bundle_not_release_candidate",
                        "releaseCandidateEvidence.releaseArtifactBundle.releaseStatus",
                        "browser release artifact bundle must be a release_candidate",
                    )
                )
            if release_artifact_bundle.get("failureCodes") != []:
                consistency_failures.append(
                    failure(
                        "release_artifact_bundle_failures_present",
                        "releaseCandidateEvidence.releaseArtifactBundle.failureCodes",
                        "release artifact bundle failureCodes must be empty for release-candidate evidence",
                    )
                )
            consistency_failures.extend(
                release_artifact_bundle_product_platform_failures(
                    release_artifact_bundle
                )
            )
            consistency_failures.extend(
                release_archive_zip_failures(
                    root=root,
                    release_artifact_bundle=release_artifact_bundle,
                )
            )
            consistency_failures.extend(
                release_archive_member_path_uniqueness_failures(
                    release_artifact_bundle
                )
            )
            consistency_failures.extend(
                release_archive_member_artifact_failures(
                    root=root,
                    release_artifact_bundle=release_artifact_bundle,
                )
            )
            consistency_failures.extend(
                release_archive_binary_identity_failures(
                    root=root,
                    release_artifact_bundle=release_artifact_bundle,
                )
            )
            consistency_failures.extend(
                release_archive_macos_app_metadata_failures(
                    root=root,
                    release_artifact_bundle=release_artifact_bundle,
                )
            )
            consistency_failures.extend(
                release_archive_non_macos_app_metadata_failures(
                    root=root,
                    release_artifact_bundle=release_artifact_bundle,
                )
            )
            consistency_failures.extend(
                artifact_file_hash_consistency_failures(
                    root=root,
                    artifact=release_artifact_bundle.get("releaseArchive"),
                    code="release_archive_file_hash_mismatch",
                    path="releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.sha256",
                    message="release archive sha256 must match release archive file bytes",
                    unsafe_code="release_archive_file_path_unsafe",
                    unsafe_path="releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.path",
                    unsafe_label="release archive",
                )
            )
            consistency_failures.extend(
                artifact_file_hash_consistency_failures(
                    root=root,
                    artifact=release_artifact_bundle.get("releaseArchiveManifest"),
                    code="release_archive_manifest_file_hash_mismatch",
                    path="releaseCandidateEvidence.releaseArtifactBundle.releaseArchiveManifest.sha256",
                    message="release archive manifest sha256 must match release archive manifest file bytes",
                    unsafe_code="release_archive_manifest_file_path_unsafe",
                    unsafe_path="releaseCandidateEvidence.releaseArtifactBundle.releaseArchiveManifest.path",
                    unsafe_label="release archive manifest",
                )
            )
            consistency_failures.extend(
                release_archive_manifest_archive_failures(
                    root=root,
                    release_artifact_bundle=release_artifact_bundle,
                    release_archive_manifest=release_archive_manifest,
                )
            )
            consistency_failures.extend(
                release_archive_manifest_identity_failures(
                    release_artifact_bundle=release_artifact_bundle,
                    release_archive_manifest=release_archive_manifest,
                )
            )
            consistency_failures.extend(
                release_archive_manifest_member_failures(
                    release_artifact_bundle=release_artifact_bundle,
                    release_archive_manifest=release_archive_manifest,
                )
            )
            consistency_failures.extend(
                release_archive_manifest_archive_member_failures(
                    root=root,
                    release_artifact_bundle=release_artifact_bundle,
                    release_archive_manifest=release_archive_manifest,
                )
            )
            consistency_failures.extend(
                release_runtime_frontier_bundle_binding_failures(
                    root=root,
                    release_artifact_bundle=release_artifact_bundle,
                    runtime_frontier_path=bundle_config.get("path"),
                )
            )
            consistency_failures.extend(
                runtime_frontier_release_component_identity_failures(
                    root=root,
                    runtime_frontier_bundle=runtime_frontier_bundle,
                    release_artifact_bundle=release_artifact_bundle,
                )
            )
            consistency_failures.extend(
                release_support_artifacts_consistency_failures(
                    root=root,
                    release_artifact_bundle=release_artifact_bundle,
                )
            )
        if chromium_source_checkout_summary_ is not None:
            if chromium_source_checkout_summary_.get("schemaVersion") != 1:
                consistency_failures.append(
                    failure(
                        "chromium_source_checkout_schema_version_mismatch",
                        "releaseCandidateEvidence.chromiumSourceCheckout.schemaVersion",
                        "Chromium source checkout report schemaVersion must be 1",
                    )
                )
            if (
                not isinstance(chromium_source_checkout_summary_.get("sourceRoot"), str)
                or not chromium_source_checkout_summary_.get("sourceRoot")
            ):
                consistency_failures.append(
                    failure(
                        "chromium_source_checkout_missing_source_root",
                        "releaseCandidateEvidence.chromiumSourceCheckout.sourceRoot",
                        "Chromium source checkout report sourceRoot is required",
                    )
                )
            if chromium_source_checkout_summary_.get("requireRuntimeSelector") is not True:
                consistency_failures.append(
                    failure(
                        "chromium_source_checkout_runtime_selector_not_required",
                        "releaseCandidateEvidence.chromiumSourceCheckout.requireRuntimeSelector",
                        "release-candidate Chromium source checkout must require runtime selector markers",
                    )
                )
            if chromium_source_checkout_summary_.get("status") != "pass":
                consistency_failures.append(
                    failure(
                        "chromium_source_checkout_not_pass",
                        "releaseCandidateEvidence.chromiumSourceCheckout.status",
                        "release-candidate Chromium source checkout report must pass",
                    )
                )
            if (
                chromium_source_checkout_summary_.get("missingRequiredWellFormed") is not True
                or chromium_source_checkout_summary_.get("missingRequired") != []
            ):
                consistency_failures.append(
                    failure(
                        "chromium_source_checkout_missing_required",
                        "releaseCandidateEvidence.chromiumSourceCheckout.missingRequired",
                        "release-candidate Chromium source checkout report must have no missing required checks",
                    )
                )
            if release_artifact_bundle is not None and not artifact_matches_path_and_sha(
                release_artifact_bundle.get("chromiumSourceCheckout"),
                path=str(chromium_source_checkout_summary_.get("path", "")),
                sha256=str(chromium_source_checkout_summary_.get("sha256", "")),
            ):
                consistency_failures.append(
                    failure(
                        "chromium_source_checkout_release_bundle_mismatch",
                        "releaseCandidateEvidence.chromiumSourceCheckout",
                        "Chromium source checkout report must match release artifact bundle chromiumSourceCheckout",
                    )
                )
        if (
            finalizer_summary is not None
            and finalizer_check_summary is not None
            and finalizer_summary.get("status") != finalizer_check_summary.get("finalizerStatus")
        ):
            consistency_failures.append(
                failure(
                    "finalizer_check_status_mismatch",
                    "releaseCandidateEvidence.finalizerCheck.finalizerStatus",
                    "finalizer-check receipt finalizerStatus must match the finalizer report status",
                )
            )
        if finalizer_summary is not None and finalizer_check_summary is not None:
            if (
                finalizer_check_summary.get("finalizerReportPath")
                != finalizer_summary.get("path")
                or finalizer_check_summary.get("finalizerReportSha256")
                != finalizer_summary.get("sha256")
            ):
                consistency_failures.append(
                    failure(
                        "finalizer_check_report_mismatch",
                        "releaseCandidateEvidence.finalizerCheck.finalizerReportPath",
                        "finalizer-check receipt must bind the same finalizer report path and hash as release-candidate evidence",
                    )
                )
        if (
            finalizer_check_summary is not None
            and finalizer_check_summary.get("verifyFilesRootProvided") is not True
        ):
            consistency_failures.append(
                failure(
                    "finalizer_check_without_file_verification",
                    "releaseCandidateEvidence.finalizerCheck.verifyFilesRootProvided",
                    "release-candidate finalizer check must run with --verify-files-root",
                )
            )
        if (
            finalizer_check_summary is not None
            and finalizer_check_summary.get("requirePass") is not True
        ):
            consistency_failures.append(
                failure(
                    "finalizer_check_without_require_pass",
                    "releaseCandidateEvidence.finalizerCheck.requirePass",
                    "release-candidate finalizer check must run with --require-pass",
                )
            )
        if (
            finalizer_summary is not None
            and finalizer_summary.get("status") == "pass"
            and finalizer_check_summary is not None
            and finalizer_check_summary.get("status") == "pass"
            and finalizer_check_summary.get("finalizerStatus") == "pass"
        ):
            finalizer_outputs = finalizer_summary.get("outputs")
            finalizer_check_outputs = finalizer_check_summary.get("outputs")
            if not isinstance(finalizer_check_outputs, dict):
                consistency_failures.append(
                    failure(
                        "finalizer_check_outputs_missing",
                        "releaseCandidateEvidence.finalizerCheck.outputs",
                        "passing finalizer-check receipt must bind checked finalizer output artifacts",
                    )
                )
            elif isinstance(finalizer_outputs, dict):
                for key, code, message in (
                    (
                        "releaseArtifactBundle",
                        "finalizer_check_release_output_mismatch",
                        "finalizer-check releaseArtifactBundle output must match finalizer report output",
                    ),
                    (
                        "runtimeFrontierBundle",
                        "finalizer_check_runtime_frontier_output_mismatch",
                        "finalizer-check runtimeFrontierBundle output must match finalizer report output",
                    ),
                ):
                    if not artifact_identity_matches(
                        finalizer_check_outputs.get(key),
                        finalizer_outputs.get(key),
                    ):
                        consistency_failures.append(
                            failure(
                                code,
                                f"releaseCandidateEvidence.finalizerCheck.outputs.{key}",
                                message,
                            )
                        )
            finalizer_inputs = finalizer_summary.get("inputs")
            finalizer_check_inputs = finalizer_check_summary.get("inputs")
            if not isinstance(finalizer_check_inputs, dict):
                consistency_failures.append(
                    failure(
                        "finalizer_check_inputs_missing",
                        "releaseCandidateEvidence.finalizerCheck.inputs",
                        "passing finalizer-check receipt must bind checked finalizer input artifacts",
                    )
                )
            elif isinstance(finalizer_inputs, dict):
                for key, code, message in (
                    (
                        "packageInputs",
                        "finalizer_check_package_inputs_mismatch",
                        "finalizer-check packageInputs input must match finalizer report input",
                    ),
                    (
                        "provenanceReport",
                        "finalizer_check_provenance_report_mismatch",
                        "finalizer-check provenanceReport input must match finalizer report input",
                    ),
                ):
                    if not artifact_identity_matches(
                        finalizer_check_inputs.get(key),
                        finalizer_inputs.get(key),
                    ):
                        consistency_failures.append(
                            failure(
                                code,
                                f"releaseCandidateEvidence.finalizerCheck.inputs.{key}",
                                message,
                            )
                        )
        if (
            finalizer_summary is not None
            and finalizer_summary.get("status") == "pass"
        ):
            finalizer_outputs = finalizer_summary.get("outputs")
            if not isinstance(finalizer_outputs, dict):
                consistency_failures.append(
                    failure(
                        "finalizer_outputs_missing",
                        "releaseCandidateEvidence.finalizerReport.outputs",
                        "passing finalizer report must bind output release and runtime frontier bundles",
                    )
                )
            else:
                release_output = finalizer_outputs.get("releaseArtifactBundle")
                frontier_output = finalizer_outputs.get("runtimeFrontierBundle")
                component_receipts = runtime_frontier_bundle.get("componentReceipts")
                release_receipt = (
                    component_receipts.get("releaseArtifactBundle")
                    if isinstance(component_receipts, dict)
                    else None
                )
                release_bundle_path = (
                    release_receipt.get("path")
                    if isinstance(release_receipt, dict)
                    else None
                )
                if not isinstance(release_bundle_path, str) or not release_bundle_path:
                    consistency_failures.append(
                        failure(
                            "finalizer_release_output_missing_target",
                            "releaseCandidateEvidence.finalizerReport.outputs.releaseArtifactBundle",
                            "runtime frontier bundle must identify the release artifact bundle checked by finalizer output",
                        )
                    )
                elif not (
                    isinstance(release_output, dict)
                    and release_output.get("kind") == "browser_release_artifact_bundle"
                    and artifact_matches_path_and_sha(
                        release_output,
                        path=release_bundle_path,
                        sha256=sha256_file(root / Path(release_bundle_path)),
                    )
                ):
                    consistency_failures.append(
                        failure(
                            "finalizer_release_output_mismatch",
                            "releaseCandidateEvidence.finalizerReport.outputs.releaseArtifactBundle",
                            "finalizer releaseArtifactBundle output must match the runtime frontier release bundle path and hash",
                        )
                    )
                runtime_frontier_path = bundle_config.get("path")
                if not isinstance(runtime_frontier_path, Path):
                    consistency_failures.append(
                        failure(
                            "finalizer_runtime_frontier_output_missing_target",
                            "releaseCandidateEvidence.finalizerReport.outputs.runtimeFrontierBundle",
                            "readiness config must identify the runtime frontier bundle checked by finalizer output",
                        )
                    )
                elif not (
                    isinstance(frontier_output, dict)
                    and frontier_output.get("kind") == "browser_runtime_frontier_bundle"
                    and artifact_matches_path_and_sha(
                        frontier_output,
                        path=runtime_frontier_path.as_posix(),
                        sha256=sha256_file(root / runtime_frontier_path),
                    )
                ):
                    consistency_failures.append(
                        failure(
                            "finalizer_runtime_frontier_output_mismatch",
                            "releaseCandidateEvidence.finalizerReport.outputs.runtimeFrontierBundle",
                            "finalizer runtimeFrontierBundle output must match the readiness runtime frontier bundle path and hash",
                        )
                    )
            finalizer_inputs = finalizer_summary.get("inputs")
            finalizer_package_inputs = (
                finalizer_inputs.get("packageInputs")
                if isinstance(finalizer_inputs, dict)
                else None
            )
            finalizer_provenance_report = (
                finalizer_inputs.get("provenanceReport")
                if isinstance(finalizer_inputs, dict)
                else None
            )
            if not isinstance(finalizer_package_inputs, dict):
                consistency_failures.append(
                    failure(
                        "finalizer_package_inputs_missing",
                        "releaseCandidateEvidence.finalizerReport.inputs.packageInputs",
                        "passing finalizer report must bind input package-input evidence",
                    )
                )
            elif (
                package_inputs_summary_ is not None
                and (
                    finalizer_package_inputs.get("kind")
                    != "browser_release_package_inputs_check"
                    or not artifact_matches_path_and_sha(
                        finalizer_package_inputs,
                        path=str(package_inputs_summary_.get("path", "")),
                        sha256=str(package_inputs_summary_.get("sha256", "")),
                    )
                )
            ):
                consistency_failures.append(
                    failure(
                        "finalizer_package_inputs_mismatch",
                        "releaseCandidateEvidence.finalizerReport.inputs.packageInputs",
                        "finalizer packageInputs input must match release-candidate package-input evidence",
                    )
                )
            if not isinstance(finalizer_provenance_report, dict):
                consistency_failures.append(
                    failure(
                        "finalizer_provenance_report_missing",
                        "releaseCandidateEvidence.finalizerReport.inputs.provenanceReport",
                        "passing finalizer report must bind input provenance-report evidence",
                    )
                )
            elif (
                provenance_report_summary_ is not None
                and (
                    finalizer_provenance_report.get("kind")
                    != "browser_release_candidate_provenance_report"
                    or not artifact_matches_path_and_sha(
                        finalizer_provenance_report,
                        path=str(provenance_report_summary_.get("path", "")),
                        sha256=str(provenance_report_summary_.get("sha256", "")),
                    )
                )
            ):
                consistency_failures.append(
                    failure(
                        "finalizer_provenance_report_mismatch",
                        "releaseCandidateEvidence.finalizerReport.inputs.provenanceReport",
                        "finalizer provenanceReport input must match release-candidate provenance evidence",
                    )
                )
        if (
            provenance_report_summary_ is not None
            and provenance_report_summary_.get("status") != "pass"
        ):
            consistency_failures.append(
                failure(
                    "provenance_report_not_pass",
                    "releaseCandidateEvidence.provenanceReport.status",
                    "release-candidate provenance report must pass",
                )
            )
        if (
            provenance_report_summary_ is not None
            and provenance_report_summary_.get("status") == "pass"
            and provenance_report_summary_.get("failureCount") != 0
        ):
            consistency_failures.append(
                failure(
                    "provenance_report_failures_present",
                    "releaseCandidateEvidence.provenanceReport.failureCount",
                    "passing provenance report must carry no failures",
                )
            )
        if (
            provenance_report_summary_ is not None
            and provenance_report_summary_.get("status") == "pass"
        ):
            provenance_summary = provenance_report_summary_.get("summary")
            if (
                not isinstance(provenance_summary, dict)
                or provenance_summary.get("failureCount") != 0
            ):
                consistency_failures.append(
                    failure(
                        "provenance_summary_failure_count_not_zero",
                        "releaseCandidateEvidence.provenanceReport.summary.failureCount",
                        "passing provenance report summary failureCount must be zero",
                    )
                )
        if (
            provenance_report_summary_ is not None
            and release_artifact_bundle is not None
        ):
            for field in RELEASE_PRODUCT_IDENTITY_FIELDS:
                if provenance_report_summary_.get(field) != release_artifact_bundle.get(field):
                    consistency_failures.append(
                        failure(
                            "provenance_identity_mismatch",
                            f"releaseCandidateEvidence.provenanceReport.{field}",
                            f"provenance report {field} must match the release artifact bundle",
                        )
                    )
        if (
            finalizer_summary is not None
            and finalizer_summary.get("status") != "pass"
        ):
            consistency_failures.append(
                failure(
                    "finalizer_report_not_pass",
                    "releaseCandidateEvidence.finalizerReport.status",
                    "release-candidate finalizer report must pass",
                )
            )
        if (
            finalizer_check_summary is not None
            and finalizer_check_summary.get("status") != "pass"
        ):
            consistency_failures.append(
                failure(
                    "finalizer_check_not_pass",
                    "releaseCandidateEvidence.finalizerCheck.status",
                    "release-candidate finalizer check must pass",
                )
            )
        if (
            finalizer_summary is not None
            and finalizer_summary.get("status") == "pass"
            and finalizer_summary.get("failureCount") != 0
        ):
            consistency_failures.append(
                failure(
                    "finalizer_report_failures_present",
                    "releaseCandidateEvidence.finalizerReport.failureCount",
                    "passing finalizer report must carry no failures",
                )
            )
        if (
            finalizer_summary is not None
            and finalizer_summary.get("status") == "pass"
        ):
            finalizer_report_summary = finalizer_summary.get("summary")
            if (
                not isinstance(finalizer_report_summary, dict)
                or finalizer_report_summary.get("failureCount") != 0
            ):
                consistency_failures.append(
                    failure(
                        "finalizer_summary_failure_count_not_zero",
                        "releaseCandidateEvidence.finalizerReport.summary.failureCount",
                        "passing finalizer report summary failureCount must be zero",
                    )
                )
            elif (
                finalizer_report_summary.get("claimabilityStatus")
                != runtime_frontier_bundle.get("claimabilityStatus")
            ):
                consistency_failures.append(
                    failure(
                        "finalizer_summary_claimability_mismatch",
                        "releaseCandidateEvidence.finalizerReport.summary.claimabilityStatus",
                        "finalizer summary claimabilityStatus must match the runtime frontier bundle",
                    )
                )
            if (
                isinstance(finalizer_report_summary, dict)
                and release_artifact_bundle is not None
                and finalizer_report_summary.get("releaseBundleIdentitySha256")
                != release_bundle_identity_sha256(release_artifact_bundle)
            ):
                consistency_failures.append(
                    failure(
                        "finalizer_summary_release_identity_mismatch",
                        "releaseCandidateEvidence.finalizerReport.summary.releaseBundleIdentitySha256",
                        "finalizer summary releaseBundleIdentitySha256 must match the release artifact bundle identity",
                    )
                )
        if (
            finalizer_check_summary is not None
            and finalizer_check_summary.get("status") == "pass"
            and finalizer_check_summary.get("failureCount") != 0
        ):
            consistency_failures.append(
                failure(
                    "finalizer_check_failures_present",
                    "releaseCandidateEvidence.finalizerCheck.failureCount",
                    "passing finalizer-check receipt must carry no failures",
                )
            )
        if package_inputs_summary_ is not None:
            if package_inputs_summary_.get("schemaVersion") != 1:
                consistency_failures.append(
                    failure(
                        "package_inputs_schema_version_mismatch",
                        "releaseCandidateEvidence.packageInputs.schemaVersion",
                        "package-input report schemaVersion must be 1",
                    )
                )
            if package_inputs_summary_.get("status") != "pass":
                consistency_failures.append(
                    failure(
                        "package_inputs_not_pass",
                        "releaseCandidateEvidence.packageInputs.status",
                        "browser release package inputs preflight must pass",
                    )
                )
            if package_inputs_summary_.get("releaseCandidateEligible") is not True:
                consistency_failures.append(
                    failure(
                        "package_inputs_not_release_candidate_eligible",
                        "releaseCandidateEvidence.packageInputs.releaseCandidateEligible",
                        "browser release package inputs must be release-candidate eligible",
                    )
                )
            if package_inputs_summary_.get("evidenceMode") != "release_candidate":
                consistency_failures.append(
                    failure(
                        "package_inputs_not_release_candidate",
                        "releaseCandidateEvidence.packageInputs.evidenceMode",
                        "browser release package inputs evidenceMode must be release_candidate",
                    )
                )
            if (
                package_inputs_summary_.get("status") == "pass"
                and package_inputs_summary_.get("failureCount") != 0
            ):
                consistency_failures.append(
                    failure(
                        "package_inputs_failures_present",
                        "releaseCandidateEvidence.packageInputs.failureCount",
                        "passing package-input preflight must carry no failures",
                    )
                )
            if (
                package_inputs_summary_.get("status") == "pass"
                and package_inputs_summary_.get("releaseCandidateBlockers") != []
            ):
                consistency_failures.append(
                    failure(
                        "package_inputs_blockers_present",
                        "releaseCandidateEvidence.packageInputs.releaseCandidateBlockers",
                        "passing package-input preflight must carry no release-candidate blockers",
                        )
                    )
            consistency_failures.extend(
                package_inputs_binary_identity_failures(package_inputs_summary_)
            )
            if package_inputs_summary_.get("status") == "pass":
                package_summary = package_inputs_summary_.get("summary")
                if (
                    not isinstance(package_summary, dict)
                    or package_summary.get("packageable") is not True
                ):
                    consistency_failures.append(
                        failure(
                            "package_inputs_summary_not_packageable",
                            "releaseCandidateEvidence.packageInputs.summary.packageable",
                            "passing package-input preflight summary.packageable must be true",
                        )
                    )
            if provenance_report_summary_ is not None:
                provenance_components = provenance_report_summary_.get("componentArtifacts")
                provenance_package_inputs = (
                    provenance_components.get("packageInputs")
                    if isinstance(provenance_components, dict)
                    else None
                )
                if not isinstance(provenance_package_inputs, dict):
                    consistency_failures.append(
                        failure(
                            "package_inputs_provenance_missing",
                            "releaseCandidateEvidence.provenanceReport.componentArtifacts.packageInputs",
                            "provenance report must bind the package-input preflight used by release-candidate evidence",
                        )
                    )
                elif (
                    not artifact_matches_path_and_sha(
                        provenance_package_inputs,
                        path=str(package_inputs_summary_.get("path", "")),
                        sha256=str(package_inputs_summary_.get("sha256", "")),
                    )
                    or provenance_package_inputs.get("kind")
                    != "browser_release_package_inputs_check"
                ):
                    consistency_failures.append(
                        failure(
                            "package_inputs_provenance_mismatch",
                            "releaseCandidateEvidence.provenanceReport.componentArtifacts.packageInputs",
                            "provenance report packageInputs artifact must match release-candidate package-input evidence",
                        )
                    )
            package_inputs = package_inputs_summary_.get("inputs")
            if not isinstance(package_inputs, dict):
                package_inputs = {}
            browser_input = package_inputs.get("browserExecutable")
            app_metadata_input = package_inputs.get("appMetadata")
            doe_input = package_inputs.get("doeRuntime")
            dawn_input = package_inputs.get("dawnFallbackRuntime")
            shader_compiler_input = package_inputs.get("shaderCompiler")
            if release_artifact_bundle is not None:
                release_package_inputs = release_artifact_bundle.get("packageInputs")
                if not isinstance(release_package_inputs, dict):
                    consistency_failures.append(
                        failure(
                            "package_inputs_release_bundle_missing",
                            "releaseCandidateEvidence.releaseArtifactBundle.packageInputs",
                            "release artifact bundle must hash-bind package-input evidence",
                        )
                    )
                elif (
                    not artifact_matches_path_and_sha(
                        release_package_inputs,
                        path=str(package_inputs_summary_.get("path", "")),
                        sha256=str(package_inputs_summary_.get("sha256", "")),
                    )
                    or release_package_inputs.get("kind")
                    != "browser_release_package_inputs_check"
                ):
                    consistency_failures.append(
                        failure(
                            "package_inputs_release_bundle_mismatch",
                            "releaseCandidateEvidence.releaseArtifactBundle.packageInputs",
                            "release artifact bundle packageInputs must match package-input evidence",
                        )
                    )
                for field in RELEASE_PRODUCT_IDENTITY_FIELDS:
                    if package_inputs_summary_.get(field) != release_artifact_bundle.get(field):
                        consistency_failures.append(
                            failure(
                                "package_inputs_identity_mismatch",
                                f"releaseCandidateEvidence.packageInputs.{field}",
                                f"package-input {field} must match the release artifact bundle",
                            )
                        )
                if not artifact_field_matches(
                    release_artifact_bundle.get("browserBinary"),
                    path=browser_input.get("path") if isinstance(browser_input, dict) else None,
                    sha256=browser_input.get("sha256") if isinstance(browser_input, dict) else None,
                ):
                    consistency_failures.append(
                        failure(
                            "package_inputs_browser_binary_mismatch",
                            "releaseCandidateEvidence.packageInputs.inputs.browserExecutable",
                            "package-input browser executable must match release bundle browserBinary",
                        )
                    )
                if not artifact_field_matches(
                    release_artifact_bundle.get("doeRuntime"),
                    path=doe_input.get("path") if isinstance(doe_input, dict) else None,
                    sha256=doe_input.get("sha256") if isinstance(doe_input, dict) else None,
                ):
                    consistency_failures.append(
                        failure(
                            "package_inputs_doe_runtime_mismatch",
                            "releaseCandidateEvidence.packageInputs.inputs.doeRuntime",
                            "package-input Doe runtime must match release bundle doeRuntime",
                        )
                    )
                if not artifact_field_matches(
                    release_artifact_bundle.get("dawnFallbackRuntime"),
                    path=dawn_input.get("path") if isinstance(dawn_input, dict) else None,
                    sha256=dawn_input.get("sha256") if isinstance(dawn_input, dict) else None,
                ):
                    consistency_failures.append(
                        failure(
                            "package_inputs_dawn_runtime_mismatch",
                            "releaseCandidateEvidence.packageInputs.inputs.dawnFallbackRuntime",
                            "package-input Dawn fallback runtime must match release bundle dawnFallbackRuntime",
                        )
                    )
                if not artifact_field_matches(
                    release_artifact_bundle.get("shaderCompiler"),
                    path=shader_compiler_input.get("path") if isinstance(shader_compiler_input, dict) else None,
                    sha256=shader_compiler_input.get("sha256") if isinstance(shader_compiler_input, dict) else None,
                ):
                    consistency_failures.append(
                        failure(
                            "package_inputs_shader_compiler_mismatch",
                            "releaseCandidateEvidence.packageInputs.inputs.shaderCompiler",
                            "package-input shader compiler must match release bundle shaderCompiler",
                        )
                    )
                expected_archive_paths = (
                    ("browserExecutableArchivePath", browser_input, "browserExecutable", "browser_executable"),
                    ("browserAppMetadataArchivePath", app_metadata_input, "appMetadata", "app_metadata"),
                    ("doeRuntimeArchivePath", doe_input, "doeRuntime", "doe_runtime"),
                    ("dawnFallbackRuntimeArchivePath", dawn_input, "dawnFallbackRuntime", "dawn_fallback_runtime"),
                )
                for bundle_field, input_row, role, role_code in expected_archive_paths:
                    if not isinstance(input_row, dict):
                        continue
                    if release_artifact_bundle.get(bundle_field) != input_row.get("archivePath"):
                        consistency_failures.append(
                            failure(
                                f"package_inputs_{role_code}_archive_path_mismatch",
                                f"releaseCandidateEvidence.packageInputs.inputs.{role}.archivePath",
                                f"package-input {role} archive path must match release bundle {bundle_field}",
                            )
                        )
                release_archive_manifest = load_release_archive_manifest_from_bundle(
                    root=root,
                    release_artifact_bundle=release_artifact_bundle,
                )
                if release_archive_manifest is None:
                    consistency_failures.append(
                        failure(
                            "package_inputs_manifest_missing",
                            "releaseCandidateEvidence.packageInputs",
                            "release archive manifest must be readable when checking package-input evidence",
                        )
                    )
                elif not isinstance(release_archive_manifest.get("sourcePackageInputs"), dict):
                    consistency_failures.append(
                        failure(
                            "package_inputs_manifest_source_missing",
                            "releaseCandidateEvidence.packageInputs",
                            "release archive manifest must bind sourcePackageInputs matching package-input evidence",
                        )
                    )
                else:
                    source_package_inputs = release_archive_manifest["sourcePackageInputs"]
                    if (
                        source_package_inputs.get("path") != package_inputs_summary_.get("path")
                        or source_package_inputs.get("sha256") != package_inputs_summary_.get("sha256")
                        or source_package_inputs.get("kind") != "browser_release_package_inputs_check"
                    ):
                        consistency_failures.append(
                            failure(
                                "package_inputs_manifest_source_mismatch",
                                "releaseCandidateEvidence.packageInputs",
                                "release archive manifest sourcePackageInputs must match package-input evidence",
                            )
                        )
                manifest_members = (
                    release_archive_manifest.get("members")
                    if isinstance(release_archive_manifest, dict)
                    else None
                )
                if isinstance(manifest_members, dict):
                    manifest_rows = {
                        role: compact_manifest_member(manifest_members.get(role))
                        for role in (
                            "browserExecutable",
                            "appMetadata",
                            "doeRuntime",
                            "dawnFallbackRuntime",
                        )
                    }
                    for role, role_code, input_row in (
                        ("browserExecutable", "browser_executable", browser_input),
                        ("appMetadata", "app_metadata", app_metadata_input),
                        ("doeRuntime", "doe_runtime", doe_input),
                        ("dawnFallbackRuntime", "dawn_fallback_runtime", dawn_input),
                    ):
                        member_row = manifest_rows.get(role)
                        if not member_matches_input(member_row, input_row):
                            consistency_failures.append(
                                failure(
                                    f"package_inputs_{role_code}_manifest_mismatch",
                                    f"releaseCandidateEvidence.packageInputs.inputs.{role}",
                                    f"package-input {role} must match release archive manifest member",
                                )
                            )
                        if not isinstance(input_row, dict) or input_row.get("generated") is True:
                            continue
                        if not isinstance(member_row, dict) or not isinstance(member_row.get("sourcePath"), str):
                            consistency_failures.append(
                                failure(
                                    f"package_inputs_{role_code}_manifest_source_missing",
                                    f"releaseCandidateEvidence.releaseArchiveManifest.members.{role}.sourcePath",
                                    f"release archive manifest {role} sourcePath must be present for package-input sourced members",
                                )
                            )
                        elif not source_path_matches(member_row.get("sourcePath"), input_row.get("path"), root):
                            consistency_failures.append(
                                failure(
                                    f"package_inputs_{role_code}_manifest_source_mismatch",
                                    f"releaseCandidateEvidence.releaseArchiveManifest.members.{role}.sourcePath",
                                    f"release archive manifest {role} sourcePath must match package-input path",
                                )
                            )
        if public_download_summary is not None:
            if public_download_summary.get("schemaVersion") != 1:
                consistency_failures.append(
                    failure(
                        "public_download_schema_version_mismatch",
                        "releaseCandidateEvidence.publicDownloadReceipt.schemaVersion",
                        "public download receipt schemaVersion must be 1",
                    )
                )
            if (
                public_download_summary.get("method") != "GET"
                or public_download_summary.get("statusCode") != 200
            ):
                consistency_failures.append(
                    failure(
                        "public_download_not_successful",
                        "releaseCandidateEvidence.publicDownloadReceipt.statusCode",
                        "public download receipt must prove a successful GET",
                    )
                )
            if not is_public_https_url(public_download_summary.get("url")):
                consistency_failures.append(
                    failure(
                        "public_download_url_not_public",
                        "releaseCandidateEvidence.publicDownloadReceipt.url",
                        "public download receipt URL must be public HTTPS",
                    )
                )
            for field in ("receiptId", "observedAt"):
                if (
                    not isinstance(public_download_summary.get(field), str)
                    or not public_download_summary.get(field)
                ):
                    consistency_failures.append(
                        failure(
                            "public_download_incomplete",
                            f"releaseCandidateEvidence.publicDownloadReceipt.{field}",
                            f"public download receipt must include {field}",
                        )
                    )
            content_length = public_download_summary.get("contentLengthBytes")
            if (
                not isinstance(content_length, int)
                or isinstance(content_length, bool)
                or content_length <= 0
            ):
                consistency_failures.append(
                    failure(
                        "public_download_incomplete",
                        "releaseCandidateEvidence.publicDownloadReceipt.contentLengthBytes",
                        "public download receipt must include positive contentLengthBytes",
                    )
                )
            if provenance_report_summary_ is not None:
                provenance_components = provenance_report_summary_.get("componentArtifacts")
                provenance_public_download = (
                    provenance_components.get("publicDownloadReceipt")
                    if isinstance(provenance_components, dict)
                    else None
                )
                if not artifact_matches_path_and_sha(
                    provenance_public_download,
                    path=str(public_download_summary.get("path", "")),
                    sha256=str(public_download_summary.get("sha256", "")),
                ):
                    consistency_failures.append(
                        failure(
                            "public_download_provenance_mismatch",
                            "releaseCandidateEvidence.publicDownloadReceipt",
                            "public download receipt must match provenance report component artifact",
                        )
                    )
            if release_artifact_bundle is not None:
                if not artifact_matches_path_and_sha(
                    release_artifact_bundle.get("publicDownloadReceipt"),
                    path=str(public_download_summary.get("path", "")),
                    sha256=str(public_download_summary.get("sha256", "")),
                ):
                    consistency_failures.append(
                        failure(
                            "public_download_release_bundle_mismatch",
                            "releaseCandidateEvidence.publicDownloadReceipt",
                            "public download receipt must match release artifact bundle publicDownloadReceipt",
                        )
                    )
                release_archive = release_artifact_bundle.get("releaseArchive")
                release_archive_download_url = (
                    release_archive.get("downloadUrl")
                    if isinstance(release_archive, dict)
                    else None
                )
                if not is_public_https_url(release_archive_download_url):
                    consistency_failures.append(
                        failure(
                            "release_archive_download_url_not_public",
                            "releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.downloadUrl",
                            "release archive download URL must be public HTTPS",
                        )
                    )
                if not (
                    isinstance(release_archive, dict)
                    and public_download_summary.get("releaseArchivePath") == release_archive.get("path")
                    and public_download_summary.get("contentSha256") == release_archive.get("sha256")
                    and public_download_summary.get("url") == release_archive.get("downloadUrl")
                ):
                    consistency_failures.append(
                        failure(
                            "public_download_release_archive_mismatch",
                            "releaseCandidateEvidence.publicDownloadReceipt.releaseArchivePath",
                            "public download receipt must match release archive path, hash, and URL",
                        )
                    )
                if isinstance(release_archive, dict):
                    release_archive_path = release_archive.get("path")
                    if isinstance(release_archive_path, str) and release_archive_path:
                        archive_file_path = repo_relative_file_path(
                            root,
                            release_archive_path,
                        )
                        if archive_file_path is None:
                            archive_size = None
                        else:
                            try:
                                archive_size = archive_file_path.stat().st_size
                            except OSError:
                                archive_size = None
                        if archive_size is not None and content_length != archive_size:
                            consistency_failures.append(
                                failure(
                                    "public_download_length_mismatch",
                                    "releaseCandidateEvidence.publicDownloadReceipt.contentLengthBytes",
                                    "public download receipt contentLengthBytes must match release archive bytes",
                                )
                            )
                release_manifest = release_artifact_bundle.get("releaseArchiveManifest")
                if not (
                    isinstance(release_manifest, dict)
                    and public_download_summary.get("releaseArchiveManifestPath") == release_manifest.get("path")
                    and public_download_summary.get("releaseArchiveManifestSha256") == release_manifest.get("sha256")
                ):
                    consistency_failures.append(
                        failure(
                            "public_download_manifest_mismatch",
                            "releaseCandidateEvidence.publicDownloadReceipt.releaseArchiveManifestPath",
                            "public download receipt must match release archive manifest path and hash",
                        )
                    )
                for field in RELEASE_DIRECT_IDENTITY_FIELDS:
                    if public_download_summary.get(field) != release_artifact_bundle.get(field):
                        consistency_failures.append(
                            failure(
                                "public_download_identity_mismatch",
                                f"releaseCandidateEvidence.publicDownloadReceipt.{field}",
                                f"public download receipt {field} must match the release artifact bundle",
                            )
                        )
        if browser_launch_summary is not None:
            if browser_launch_summary.get("schemaVersion") != 1:
                consistency_failures.append(
                    failure(
                        "browser_launch_schema_version_mismatch",
                        "releaseCandidateEvidence.browserLaunchReceipt.schemaVersion",
                        "browser launch receipt schemaVersion must be 1",
                    )
                )
            for field in ("receiptId", "observedAt"):
                if (
                    not isinstance(browser_launch_summary.get(field), str)
                    or not browser_launch_summary.get(field)
                ):
                    consistency_failures.append(
                        failure(
                            "browser_launch_incomplete",
                            f"releaseCandidateEvidence.browserLaunchReceipt.{field}",
                            f"browser launch receipt must include {field}",
                        )
                    )
            if (
                browser_launch_summary.get("launchSource") != "release_archive"
                or browser_launch_summary.get("runtimeMode") != "doe"
                or browser_launch_summary.get("activeRuntime") != "doe"
                or browser_launch_summary.get("activeBackend") != "webgpu-doe"
                or browser_launch_summary.get("hiddenFallbackAllowed") is not False
                or browser_launch_summary.get("hiddenFallbackUsed") is not False
                or browser_launch_summary.get("webgpuAvailable") is not True
            ):
                consistency_failures.append(
                    failure(
                        "browser_launch_runtime_state_mismatch",
                        "releaseCandidateEvidence.browserLaunchReceipt.activeRuntime",
                        "browser launch receipt must prove a release-archive Doe WebGPU launch with hidden fallback disabled",
                    )
                )
            if (
                browser_launch_summary.get("proofPageLoaded") is not True
                or browser_launch_summary.get("proofPageUrl") != "about:doe"
                or not browser_launch_summary.get("proofPageArtifactPath")
                or not browser_launch_summary.get("proofPageReceiptId")
            ):
                consistency_failures.append(
                    failure(
                        "browser_launch_proof_page_mismatch",
                        "releaseCandidateEvidence.browserLaunchReceipt.proofPageUrl",
                        "browser launch receipt must prove the packaged browser loaded about:doe proof diagnostics",
                    )
                )
            gallery_url = browser_launch_summary.get("galleryUrl")
            gallery_category = browser_launch_summary.get("galleryCategory")
            if (
                browser_launch_summary.get("galleryLoaded") is not True
                or not gallery_url
                or not isinstance(gallery_category, str)
                or not gallery_category
                or not browser_launch_summary.get("galleryArtifactPath")
                or not browser_launch_summary.get("galleryReceiptId")
            ):
                consistency_failures.append(
                    failure(
                        "browser_launch_gallery_mismatch",
                        "releaseCandidateEvidence.browserLaunchReceipt.galleryUrl",
                        "browser launch receipt must prove a hosted proof-gallery page loaded",
                    )
                )
            elif not is_public_https_url(gallery_url):
                consistency_failures.append(
                    failure(
                        "browser_launch_gallery_url_not_public",
                        "releaseCandidateEvidence.browserLaunchReceipt.galleryUrl",
                        "browser launch receipt gallery URL must be public HTTPS",
                    )
                )
            elif gallery_category not in BROWSER_GALLERY_CATEGORIES:
                consistency_failures.append(
                    failure(
                        "browser_launch_gallery_category_unrecognized",
                        "releaseCandidateEvidence.browserLaunchReceipt.galleryCategory",
                        "browser launch receipt gallery category must be recognized",
                    )
                )
            if (
                browser_launch_summary.get("comparisonLoaded") is not True
                or browser_launch_summary.get("comparisonExecutionScope") != "same_page"
                or browser_launch_summary.get("comparisonModes") != ["dawn", "doe"]
                or browser_launch_summary.get("comparisonEmitsSideBySideReceipts") is not True
                or not browser_launch_summary.get("comparisonDawnReceiptId")
                or not browser_launch_summary.get("comparisonDoeReceiptId")
            ):
                consistency_failures.append(
                    failure(
                        "browser_launch_comparison_mismatch",
                        "releaseCandidateEvidence.browserLaunchReceipt.comparisonId",
                        "browser launch receipt must prove same-page Dawn-vs-Doe comparison evidence",
                    )
                )
            if (
                not browser_launch_summary.get("comparisonId")
                or not browser_launch_summary.get("comparisonWorkloadId")
            ):
                consistency_failures.append(
                    failure(
                        "browser_launch_comparison_identity_missing",
                        "releaseCandidateEvidence.browserLaunchReceipt.comparisonId",
                        "browser launch receipt must identify comparisonId and workloadId",
                    )
                )
            if not browser_launch_summary.get("comparisonArtifactPath"):
                consistency_failures.append(
                    failure(
                        "browser_launch_comparison_artifact_missing",
                        "releaseCandidateEvidence.browserLaunchReceipt.comparisonArtifactPath",
                        "browser launch receipt must identify the same-page comparison artifact",
                    )
                )
            if proof_surface_raw is not None:
                expected_comparison_artifact_path = None
                comparison_id = browser_launch_summary.get("comparisonId")
                for row in proof_surface_raw.get("comparisonReceipts", []):
                    if isinstance(row, dict) and row.get("comparisonId") == comparison_id:
                        comparison_artifact = row.get("comparisonArtifact")
                        if isinstance(comparison_artifact, dict):
                            expected_comparison_artifact_path = comparison_artifact.get("path")
                        break
                if (
                    isinstance(expected_comparison_artifact_path, str)
                    and expected_comparison_artifact_path
                    and browser_launch_summary.get("comparisonArtifactPath")
                    != expected_comparison_artifact_path
                ):
                    consistency_failures.append(
                        failure(
                            "browser_launch_comparison_artifact_mismatch",
                            "releaseCandidateEvidence.browserLaunchReceipt.comparisonArtifactPath",
                            "browser launch comparisonArtifactPath must match the published proof surface",
                        )
                    )
            if (
                browser_launch_summary.get("comparisonPageArtifactPath")
                != browser_launch_summary.get("galleryArtifactPath")
            ):
                consistency_failures.append(
                    failure(
                        "browser_launch_comparison_page_mismatch",
                        "releaseCandidateEvidence.browserLaunchReceipt.comparisonPageArtifactPath",
                        "browser launch comparison pageArtifactPath must match the loaded gallery artifactPath",
                    )
                )
            observed_receipt_ids = browser_launch_summary.get("observedReceiptIds")
            if not isinstance(observed_receipt_ids, list):
                observed_receipt_ids = []
            observed_seen: set[str] = set()
            for receipt_id in observed_receipt_ids:
                if not isinstance(receipt_id, str) or not receipt_id:
                    continue
                if receipt_id in observed_seen:
                    consistency_failures.append(
                        failure(
                            "browser_launch_observed_receipts_duplicate",
                            "releaseCandidateEvidence.browserLaunchReceipt.observedReceiptIds",
                            "browser launch observedReceiptIds must uniquely identify observed receipts",
                        )
                    )
                    break
                observed_seen.add(receipt_id)
            required_observed = [
                browser_launch_summary.get("proofPageReceiptId"),
                browser_launch_summary.get("galleryReceiptId"),
                browser_launch_summary.get("comparisonDawnReceiptId"),
                browser_launch_summary.get("comparisonDoeReceiptId"),
            ]
            if any(
                not isinstance(receipt_id, str)
                or not receipt_id
                or receipt_id not in observed_receipt_ids
                for receipt_id in required_observed
            ):
                consistency_failures.append(
                    failure(
                        "browser_launch_observed_receipts_missing",
                        "releaseCandidateEvidence.browserLaunchReceipt.observedReceiptIds",
                        "browser launch receipt must observe the proof, gallery, Dawn, and Doe receipt IDs",
                    )
                )
            expected_observed = {
                receipt_id
                for receipt_id in required_observed
                if isinstance(receipt_id, str) and receipt_id
            }
            if set(observed_receipt_ids) != expected_observed:
                consistency_failures.append(
                    failure(
                        "browser_launch_observed_receipts_unlinked",
                        "releaseCandidateEvidence.browserLaunchReceipt.observedReceiptIds",
                        "browser launch observedReceiptIds must exactly match proof, gallery, Dawn, and Doe receipt IDs",
                    )
                )
            launch_path = str(browser_launch_summary.get("path", ""))
            launch_sha = str(browser_launch_summary.get("sha256", ""))
            if provenance_report_summary_ is not None:
                provenance_components = provenance_report_summary_.get("componentArtifacts")
                provenance_browser_launch = (
                    provenance_components.get("browserLaunchReceipt")
                    if isinstance(provenance_components, dict)
                    else None
                )
                if not artifact_matches_path_and_sha(
                    provenance_browser_launch,
                    path=launch_path,
                    sha256=launch_sha,
                ):
                    consistency_failures.append(
                        failure(
                            "browser_launch_provenance_mismatch",
                            "releaseCandidateEvidence.browserLaunchReceipt",
                            "browser launch receipt must match provenance report component artifact",
                        )
                    )
            if release_artifact_bundle is not None:
                if not artifact_matches_path_and_sha(
                    release_artifact_bundle.get("browserLaunchReceipt"),
                    path=launch_path,
                    sha256=launch_sha,
                ):
                    consistency_failures.append(
                        failure(
                            "browser_launch_release_bundle_mismatch",
                            "releaseCandidateEvidence.browserLaunchReceipt",
                            "browser launch receipt must match release artifact bundle browserLaunchReceipt",
                        )
                    )
                launch_release_archive = browser_launch_summary.get("releaseArchive")
                release_archive = release_artifact_bundle.get("releaseArchive")
                if not (
                    isinstance(release_archive, dict)
                    and artifact_matches_path_and_sha(
                        launch_release_archive,
                        path=str(release_archive.get("path", "")),
                        sha256=str(release_archive.get("sha256", "")),
                    )
                    and isinstance(launch_release_archive, dict)
                    and launch_release_archive.get("downloadUrl") == release_archive.get("downloadUrl")
                ):
                    consistency_failures.append(
                        failure(
                            "browser_launch_archive_mismatch",
                            "releaseCandidateEvidence.browserLaunchReceipt.releaseArchive",
                            "browser launch receipt must match release archive path, hash, and URL",
                        )
                    )
                launch_release_manifest = browser_launch_summary.get("releaseArchiveManifest")
                release_manifest = release_artifact_bundle.get("releaseArchiveManifest")
                if not (
                    isinstance(release_manifest, dict)
                    and artifact_matches_path_and_sha(
                        launch_release_manifest,
                        path=str(release_manifest.get("path", "")),
                        sha256=str(release_manifest.get("sha256", "")),
                    )
                ):
                    consistency_failures.append(
                        failure(
                            "browser_launch_manifest_mismatch",
                            "releaseCandidateEvidence.browserLaunchReceipt.releaseArchiveManifest",
                            "browser launch receipt must match release archive manifest path and hash",
                        )
                    )
                launch_proof_surface = browser_launch_summary.get("proofSurface")
                release_proof_surface = release_artifact_bundle.get("proofSurface")
                if not (
                    isinstance(release_proof_surface, dict)
                    and artifact_matches_path_and_sha(
                        launch_proof_surface,
                        path=str(release_proof_surface.get("path", "")),
                        sha256=str(release_proof_surface.get("sha256", "")),
                    )
                ):
                    consistency_failures.append(
                        failure(
                            "browser_launch_proof_surface_mismatch",
                            "releaseCandidateEvidence.browserLaunchReceipt.proofSurface",
                            "browser launch receipt must match release artifact bundle proof surface",
                        )
                    )
                for field in RELEASE_DIRECT_IDENTITY_FIELDS:
                    if browser_launch_summary.get(field) != release_artifact_bundle.get(field):
                        consistency_failures.append(
                            failure(
                                "browser_launch_identity_mismatch",
                                f"releaseCandidateEvidence.browserLaunchReceipt.{field}",
                                f"browser launch receipt {field} must match the release artifact bundle",
                            )
                        )
            if proof_surface_summary is not None:
                launch_proof_surface = browser_launch_summary.get("proofSurface")
                if not artifact_matches_path_and_sha(
                    launch_proof_surface,
                    path=str(proof_surface_summary.get("path", "")),
                    sha256=str(proof_surface_summary.get("sha256", "")),
                ):
                    consistency_failures.append(
                        failure(
                            "browser_launch_published_proof_surface_mismatch",
                            "releaseCandidateEvidence.browserLaunchReceipt.proofSurface",
                            "browser launch receipt proof surface must match release-candidate proof-surface evidence",
                        )
                    )
            if (
                browser_launch_receipt_raw is not None
                and proof_surface_raw is not None
            ):
                for launch_failure in validate_claim_indexed_launch_matches_proof_surface(
                    browser_launch_receipt_raw,
                    proof_surface_raw,
                    "releaseCandidateEvidence",
                    root=root,
                ):
                    consistency_failures.append(
                        failure(
                            "browser_launch_proof_surface_field_mismatch",
                            "releaseCandidateEvidence.browserLaunchReceipt",
                            launch_failure.get(
                                "message",
                                "browser launch receipt must match the published proof surface",
                            ),
                        )
                    )
        if proof_surface_summary is not None:
            proof_path = str(proof_surface_summary.get("path", ""))
            proof_sha = str(proof_surface_summary.get("sha256", ""))
            if proof_surface_raw is not None:
                consistency_failures.extend(
                    validate_claim_indexed_proof_surface(
                        proof_surface_raw,
                        "releaseCandidateEvidence",
                        release_bundle=release_artifact_bundle,
                        root=root,
                    )
                )
                consistency_failures.extend(
                    validate_claim_indexed_proof_surface_receipts(
                        root,
                        proof_surface_raw,
                        "releaseCandidateEvidence",
                        release_bundle=release_artifact_bundle,
                    )
                )
            if provenance_report_summary_ is not None:
                provenance_components = provenance_report_summary_.get("componentArtifacts")
                provenance_proof_surface = (
                    provenance_components.get("proofSurface")
                    if isinstance(provenance_components, dict)
                    else None
                )
                if not artifact_matches_path_and_sha(
                    provenance_proof_surface,
                    path=proof_path,
                    sha256=proof_sha,
                ):
                    consistency_failures.append(
                        failure(
                            "proof_surface_provenance_mismatch",
                            "releaseCandidateEvidence.publishedProofSurface",
                            "published proof surface must match provenance report component artifact",
                        )
                    )
            if release_artifact_bundle is not None:
                if not artifact_matches_path_and_sha(
                    release_artifact_bundle.get("proofSurface"),
                    path=proof_path,
                    sha256=proof_sha,
                ):
                    consistency_failures.append(
                        failure(
                            "proof_surface_release_bundle_mismatch",
                            "releaseCandidateEvidence.publishedProofSurface",
                            "published proof surface must match release artifact bundle proofSurface",
                        )
                    )
                for field in RELEASE_PRODUCT_IDENTITY_FIELDS:
                    if proof_surface_summary.get(field) != release_artifact_bundle.get(field):
                        consistency_failures.append(
                            failure(
                                "proof_surface_identity_mismatch",
                                f"releaseCandidateEvidence.publishedProofSurface.{field}",
                                f"published proof surface {field} must match the release artifact bundle",
                            )
                        )
                proof_surface_release_archive = proof_surface_summary.get("releaseArchive")
                release_archive = release_artifact_bundle.get("releaseArchive")
                if not (
                    isinstance(release_archive, dict)
                    and isinstance(proof_surface_release_archive, dict)
                    and proof_surface_release_archive.get("path") == release_archive.get("path")
                    and proof_surface_release_archive.get("sha256") == release_archive.get("sha256")
                    and proof_surface_release_archive.get("downloadUrl") == release_archive.get("downloadUrl")
                ):
                    consistency_failures.append(
                        failure(
                            "proof_surface_archive_identity_mismatch",
                            "releaseCandidateEvidence.publishedProofSurface.releaseArchive",
                            "published proof surface releaseArchive must match the release artifact bundle",
                        )
                    )
                if proof_surface_raw is not None:
                    proof_page = proof_surface_raw.get("proofPage")
                    diagnostics = (
                        proof_page.get("diagnostics")
                        if isinstance(proof_page, dict)
                        else None
                    )
                    diagnostics_compiler_path = (
                        diagnostics.get("compilerPath")
                        if isinstance(diagnostics, dict)
                        else None
                    )
                    shader_compiler = release_artifact_bundle.get("shaderCompiler")
                    release_compiler_path = (
                        shader_compiler.get("path")
                        if isinstance(shader_compiler, dict)
                        else None
                    )
                    if (
                        isinstance(release_compiler_path, str)
                        and release_compiler_path
                        and diagnostics_compiler_path != release_compiler_path
                    ):
                        consistency_failures.append(
                            failure(
                                "proof_surface_compiler_identity_mismatch",
                                "releaseCandidateEvidence.publishedProofSurface.proofPage.diagnostics.compilerPath",
                                "published proof surface compilerPath must match release artifact bundle shaderCompiler.path",
                            )
                        )
                    for proof_failure in validate_proof_surface_runtime_identity_release_hashes(
                        proof_surface_raw,
                        release_artifact_bundle,
                        root,
                        "releaseCandidateEvidence",
                    ):
                        consistency_failures.append(
                            failure(
                                "proof_surface_runtime_identity_release_mismatch",
                                "releaseCandidateEvidence.publishedProofSurface.runtimeIdentityPath",
                                proof_failure.get(
                                    "message",
                                    "published proof surface runtime identity hashes must match the release artifact bundle",
                                ),
                            )
                        )
            if proof_surface_check_summary_ is not None:
                if provenance_report_summary_ is not None:
                    provenance_components = provenance_report_summary_.get("componentArtifacts")
                    provenance_proof_surface_check = (
                        provenance_components.get("proofSurfaceCheck")
                        if isinstance(provenance_components, dict)
                        else None
                    )
                    if not artifact_matches_path_and_sha(
                        provenance_proof_surface_check,
                        path=str(proof_surface_check_summary_.get("path", "")),
                        sha256=str(proof_surface_check_summary_.get("sha256", "")),
                    ):
                        consistency_failures.append(
                            failure(
                                "proof_surface_check_provenance_mismatch",
                                "releaseCandidateEvidence.proofSurfaceCheck",
                                "proof-surface checker report must match provenance report component artifact",
                            )
                        )
                if (
                    proof_surface_check_summary_.get("surfacePath") != proof_path
                    or proof_surface_check_summary_.get("surfaceSha256") != proof_sha
                ):
                    consistency_failures.append(
                        failure(
                            "proof_surface_check_identity_mismatch",
                            "releaseCandidateEvidence.proofSurfaceCheck",
                            "published proof-surface checker report must match the proof surface path and hash",
                        )
                    )
                if release_artifact_bundle is not None:
                    if not artifact_matches_path_and_sha(
                        release_artifact_bundle.get("proofSurfaceCheck"),
                        path=str(proof_surface_check_summary_.get("path", "")),
                        sha256=str(proof_surface_check_summary_.get("sha256", "")),
                    ):
                        consistency_failures.append(
                            failure(
                                "proof_surface_check_release_bundle_mismatch",
                                "releaseCandidateEvidence.proofSurfaceCheck",
                                "proof-surface checker report must match release artifact bundle proofSurfaceCheck",
                            )
                        )
                if proof_surface_check_summary_.get("status") != "pass":
                    consistency_failures.append(
                        failure(
                            "proof_surface_check_not_pass",
                            "releaseCandidateEvidence.proofSurfaceCheck.status",
                            "published proof-surface checker report must pass",
                        )
                    )
                if (
                    proof_surface_check_summary_.get("status") == "pass"
                    and proof_surface_check_summary_.get("failureCount") != 0
                ):
                    consistency_failures.append(
                        failure(
                            "proof_surface_check_failures_present",
                            "releaseCandidateEvidence.proofSurfaceCheck.failureCount",
                            "passing proof-surface checker report must carry no failures",
                        )
                    )
                if proof_surface_check_summary_.get("verifyFilesRootProvided") is not True:
                    consistency_failures.append(
                        failure(
                            "proof_surface_check_without_file_verification",
                            "releaseCandidateEvidence.proofSurfaceCheck.verifyFilesRootProvided",
                            "published proof-surface checker report must verify referenced files",
                        )
                    )
                if proof_surface_check_summary_.get("requirePublicUrls") is not True:
                    consistency_failures.append(
                        failure(
                            "proof_surface_check_without_public_urls",
                            "releaseCandidateEvidence.proofSurfaceCheck.requirePublicUrls",
                            "published proof-surface checker report must require public gallery URLs",
                        )
                    )
        evidence["consistency"] = consistency_evidence(consistency_failures)

    return evidence or None


def malformed_frontier_bundle_evidence(
    *,
    root: Path,
    bundle_path: Path,
    bundle: dict[str, Any],
    code: str,
    path: str,
    message: str,
) -> dict[str, Any]:
    actual_kind = bundle.get("artifactKind")
    if not isinstance(actual_kind, str) or not actual_kind:
        actual_kind = "unknown"
    summary = bundle.get("summary")
    if not isinstance(summary, dict) or not is_summary_map_schema_compatible(summary):
        summary = {}
    return {
        "path": str(bundle_path),
        "sha256": sha256_file(root / bundle_path),
        "artifactKind": actual_kind,
        "status": "fail",
        "claimabilityStatus": "blocked",
        "claimBlockers": [],
        "summary": summary,
        "consistency": consistency_evidence([
            failure(
                code,
                path,
                message,
            )
        ]),
    }


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
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_artifact_kind_mismatch",
            path="frontierBundleEvidence.artifactKind",
            message=f"frontier bundle artifactKind must be {bundle_config['kind']}",
        )
    claim_blockers = bundle.get("claimBlockers")
    if not isinstance(claim_blockers, list):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_claim_blockers_malformed",
            path="frontierBundleEvidence.claimBlockers",
            message="frontier bundle claimBlockers must be a list",
        )
    if bundle.get("status") not in {"pass", "fail"}:
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_status_malformed",
            path="frontierBundleEvidence.status",
            message="frontier bundle status must be pass or fail",
        )
    if bundle.get("claimabilityStatus") not in {"claimable", "blocked"}:
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_claimability_status_malformed",
            path="frontierBundleEvidence.claimabilityStatus",
            message="frontier bundle claimabilityStatus must be claimable or blocked",
        )
    if not isinstance(bundle.get("summary"), dict):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_summary_malformed",
            path="frontierBundleEvidence.summary",
            message="frontier bundle summary must be an object",
        )
    if not is_summary_map_schema_compatible(bundle["summary"]):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_summary_values_malformed",
            path="frontierBundleEvidence.summary",
            message="frontier bundle summary values must be scalar",
        )
    claim_blocker_summary = bundle.get("claimBlockerSummary")
    if "claimBlockerSummary" in bundle and not isinstance(claim_blocker_summary, list):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_claim_blocker_summary_malformed",
            path="frontierBundleEvidence.claimBlockerSummary",
            message="frontier bundle claimBlockerSummary must be a list",
        )
    if isinstance(claim_blocker_summary, list) and not is_failure_summary_list_schema_compatible(
        claim_blocker_summary
    ):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_claim_blocker_summary_items_malformed",
            path="frontierBundleEvidence.claimBlockerSummary",
            message=(
                "frontier bundle claimBlockerSummary entries must have code, "
                "message, and positive count"
            ),
        )
    if (
        bundle_config["kind"] == BROWSER_FRONTIER_BUNDLE_KIND
        and "claimBlockerSummary" not in bundle
    ):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_claim_blocker_summary_missing",
            path="frontierBundleEvidence.claimBlockerSummary",
            message="browser runtime frontier bundle claimBlockerSummary is required",
        )
    failures = bundle.get("failures")
    if not isinstance(failures, list):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_failures_malformed",
            path="frontierBundleEvidence.failures",
            message="frontier bundle failures must be a list",
        )
    if any(not isinstance(item, dict) or not is_failure_schema_compatible(item) for item in failures):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_failures_items_malformed",
            path="frontierBundleEvidence.failures",
            message="frontier bundle failures entries must have code, path, and message",
        )
    summary = bundle["summary"]
    if summary.get("claimBlockerCount") != len(claim_blockers):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_summary_claim_blocker_count_mismatch",
            path="frontierBundleEvidence.summary.claimBlockerCount",
            message="frontier bundle summary claimBlockerCount must match claimBlockers length",
        )
    if summary.get("failureCount") != len(failures):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_summary_failure_count_mismatch",
            path="frontierBundleEvidence.summary.failureCount",
            message="frontier bundle summary failureCount must match failures length",
        )
    component_receipts = bundle.get("componentReceipts")
    if not isinstance(component_receipts, dict):
        return fallback_codes, malformed_frontier_bundle_evidence(
            root=root,
            bundle_path=bundle_config["path"],
            bundle=bundle,
            code="frontier_bundle_component_receipts_malformed",
            path="frontierBundleEvidence.componentReceipts",
            message="frontier bundle componentReceipts must be an object",
        )
    if bundle_config["kind"] == TINT_FRONTIER_BUNDLE_KIND:
        required_targets = bundle.get("requiredTargets")
        if (
            not isinstance(required_targets, list)
            or not required_targets
            or len(set(required_targets)) != len(required_targets)
            or any(target not in {"msl", "spirv", "dxil", "hlsl"} for target in required_targets)
        ):
            return fallback_codes, malformed_frontier_bundle_evidence(
                root=root,
                bundle_path=bundle_config["path"],
                bundle=bundle,
                code="frontier_bundle_required_targets_malformed",
                path="frontierBundleEvidence.requiredTargets",
                message=(
                    "Tint compiler frontier bundle requiredTargets must be a "
                    "non-empty unique target list"
                ),
            )
        if not isinstance(bundle.get("compilerEvidenceReports"), list):
            return fallback_codes, malformed_frontier_bundle_evidence(
                root=root,
                bundle_path=bundle_config["path"],
                bundle=bundle,
                code="frontier_bundle_compiler_evidence_reports_malformed",
                path="frontierBundleEvidence.compilerEvidenceReports",
                message="Tint compiler frontier bundle compilerEvidenceReports must be a list",
            )
        compiler_report_failure = tint_compiler_evidence_report_failure(
            bundle["compilerEvidenceReports"]
        )
        if compiler_report_failure is not None:
            failure_path, failure_message = compiler_report_failure
            return fallback_codes, malformed_frontier_bundle_evidence(
                root=root,
                bundle_path=bundle_config["path"],
                bundle=bundle,
                code="frontier_bundle_compiler_evidence_report_items_malformed",
                path=failure_path,
                message=failure_message,
            )
        compiler_report_file_failure = tint_artifact_file_failure(
            root=root,
            artifacts=bundle["compilerEvidenceReports"],
            base_path="frontierBundleEvidence.compilerEvidenceReports",
            label="Tint compiler frontier bundle compilerEvidenceReports",
        )
        if compiler_report_file_failure is not None:
            failure_kind, failure_path, failure_message = compiler_report_file_failure
            return fallback_codes, malformed_frontier_bundle_evidence(
                root=root,
                bundle_path=bundle_config["path"],
                bundle=bundle,
                code=f"frontier_bundle_compiler_evidence_report_{failure_kind}",
                path=failure_path,
                message=failure_message,
            )
        if not isinstance(bundle.get("coverageByTarget"), list):
            return fallback_codes, malformed_frontier_bundle_evidence(
                root=root,
                bundle_path=bundle_config["path"],
                bundle=bundle,
                code="frontier_bundle_coverage_by_target_malformed",
                path="frontierBundleEvidence.coverageByTarget",
                message="Tint compiler frontier bundle coverageByTarget must be a list",
            )
        if not isinstance(bundle.get("phaseTimingCoverage"), dict):
            return fallback_codes, malformed_frontier_bundle_evidence(
                root=root,
                bundle_path=bundle_config["path"],
                bundle=bundle,
                code="frontier_bundle_phase_timing_coverage_malformed",
                path="frontierBundleEvidence.phaseTimingCoverage",
                message="Tint compiler frontier bundle phaseTimingCoverage must be an object",
            )
        phase_timing_coverage_failure = tint_phase_timing_coverage_failure(
            bundle["phaseTimingCoverage"]
        )
        if phase_timing_coverage_failure is not None:
            failure_path, failure_message = phase_timing_coverage_failure
            return fallback_codes, malformed_frontier_bundle_evidence(
                root=root,
                bundle_path=bundle_config["path"],
                bundle=bundle,
                code="frontier_bundle_phase_timing_coverage_items_malformed",
                path=failure_path,
                message=failure_message,
            )
        for component_name in ("loweringLinks", "targetValidations", "phaseBenchmarks"):
            if component_name not in component_receipts:
                return fallback_codes, malformed_frontier_bundle_evidence(
                    root=root,
                    bundle_path=bundle_config["path"],
                    bundle=bundle,
                    code="frontier_bundle_tint_component_receipt_missing",
                    path=f"frontierBundleEvidence.componentReceipts.{component_name}",
                    message=f"Tint compiler frontier bundle componentReceipts.{component_name} is required",
                )
            if not isinstance(component_receipts.get(component_name), list):
                return fallback_codes, malformed_frontier_bundle_evidence(
                    root=root,
                    bundle_path=bundle_config["path"],
                    bundle=bundle,
                    code="frontier_bundle_tint_component_receipt_malformed",
                    path=f"frontierBundleEvidence.componentReceipts.{component_name}",
                    message=(
                        "Tint compiler frontier bundle componentReceipts."
                        f"{component_name} must be a list"
                    ),
                )
            component_item_failure = tint_component_receipt_item_failure(
                component_name=component_name,
                receipts=component_receipts[component_name],
            )
            if component_item_failure is not None:
                failure_path, failure_message = component_item_failure
                return fallback_codes, malformed_frontier_bundle_evidence(
                    root=root,
                    bundle_path=bundle_config["path"],
                    bundle=bundle,
                    code="frontier_bundle_tint_component_receipt_items_malformed",
                    path=failure_path,
                    message=failure_message,
                )
            component_file_failure = tint_artifact_file_failure(
                root=root,
                artifacts=component_receipts[component_name],
                base_path=f"frontierBundleEvidence.componentReceipts.{component_name}",
                label=f"Tint compiler frontier bundle componentReceipts.{component_name}",
            )
            if component_file_failure is not None:
                failure_kind, failure_path, failure_message = component_file_failure
                return fallback_codes, malformed_frontier_bundle_evidence(
                    root=root,
                    bundle_path=bundle_config["path"],
                    bundle=bundle,
                    code=f"frontier_bundle_tint_component_receipt_{failure_kind}",
                    path=failure_path,
                    message=failure_message,
                )
    if bundle_config["kind"] == BROWSER_FRONTIER_BUNDLE_KIND:
        for component_name in (
            "runtimeIdentity",
            "claimPromotionReceipt",
            "releaseArtifactBundle",
        ):
            if component_name not in component_receipts:
                return fallback_codes, malformed_frontier_bundle_evidence(
                    root=root,
                    bundle_path=bundle_config["path"],
                    bundle=bundle,
                    code="frontier_bundle_component_receipt_missing",
                    path=f"frontierBundleEvidence.componentReceipts.{component_name}",
                    message=(
                        "browser runtime frontier bundle componentReceipts."
                        f"{component_name} is required"
                    ),
                )
            if not isinstance(component_receipts.get(component_name), dict):
                return fallback_codes, malformed_frontier_bundle_evidence(
                    root=root,
                    bundle_path=bundle_config["path"],
                    bundle=bundle,
                    code="frontier_bundle_component_receipt_malformed",
                    path=f"frontierBundleEvidence.componentReceipts.{component_name}",
                    message=(
                        "browser runtime frontier bundle componentReceipts."
                        f"{component_name} must be an object"
                    ),
                )
            field_failure = browser_component_receipt_field_failure(
                component_name=component_name,
                receipt=component_receipts[component_name],
            )
            if field_failure is not None:
                failure_path, failure_message = field_failure
                return fallback_codes, malformed_frontier_bundle_evidence(
                    root=root,
                    bundle_path=bundle_config["path"],
                    bundle=bundle,
                    code="frontier_bundle_component_receipt_field_malformed",
                    path=failure_path,
                    message=failure_message,
                )

    fallback_set = set(fallback_codes)
    relevant_claim_blockers: list[dict[str, Any]] = []
    for blocker in claim_blockers:
        if not isinstance(blocker, dict):
            continue
        code = blocker.get("code")
        if isinstance(code, str) and code in fallback_set:
            if not is_failure_schema_compatible(blocker):
                return fallback_codes, malformed_frontier_bundle_evidence(
                    root=root,
                    bundle_path=bundle_config["path"],
                    bundle=bundle,
                    code="frontier_bundle_claim_blocker_items_malformed",
                    path="frontierBundleEvidence.claimBlockers",
                    message=(
                        "frontier bundle claimBlockers entries must have code, "
                        "path, and message"
                    ),
                )
            relevant_claim_blockers.append(compact_failure(blocker))

    evidence_codes = unique_codes_from_failures(relevant_claim_blockers)
    if bundle.get("claimabilityStatus") != "claimable" and not evidence_codes:
        blocker_codes = fallback_codes
    else:
        blocker_codes = evidence_codes

    evidence: dict[str, Any] = {
        "path": str(bundle_config["path"]),
        "sha256": sha256_file(root / bundle_config["path"]),
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
    phase_timing_coverage = bundle.get("phaseTimingCoverage")
    if isinstance(phase_timing_coverage, dict):
        evidence["phaseTimingCoverage"] = phase_timing_coverage
    component_receipts = bundle.get("componentReceipts")
    if isinstance(component_receipts, dict):
        component_receipt_evidence = dict(component_receipts)
        release_artifact_bundle = component_receipts.get("releaseArtifactBundle")
        if isinstance(release_artifact_bundle, dict):
            release_artifact_bundle_evidence = dict(release_artifact_bundle)
            release_artifact_bundle_path = release_artifact_bundle_evidence.get("path")
            if isinstance(release_artifact_bundle_path, str) and release_artifact_bundle_path:
                try:
                    release_artifact_bundle_evidence["sha256"] = sha256_file(
                        root / release_artifact_bundle_path
                    )
                except OSError:
                    pass
            component_receipt_evidence["releaseArtifactBundle"] = release_artifact_bundle_evidence
        evidence["componentReceipts"] = component_receipt_evidence
    if row.get("id") == BROWSER_FRONTIER_ROW_ID:
        release_candidate_evidence = browser_release_candidate_evidence(
            root=root,
            bundle_config=bundle_config,
            runtime_frontier_bundle=bundle,
        )
        if release_candidate_evidence is not None:
            evidence["releaseCandidateEvidence"] = release_candidate_evidence
    return blocker_codes, evidence


def build_row_report(
    row: dict[str, Any],
    definitions_by_code: dict[str, dict[str, Any]],
    entries_by_id: dict[str, dict[str, Any]],
    root: Path,
    bundle_configs: dict[str, dict[str, Any]],
    cts_evidence_path: Path = CTS_EVIDENCE_PATH,
    cts_subset_receipt_path: Path = CTS_SUBSET_RECEIPT_PATH,
    cts_backend_pass_ledger_path: Path = CTS_BACKEND_PASS_LEDGER_PATH,
) -> dict[str, Any]:
    blockers = row.get("blockers", [])
    if not isinstance(blockers, list):
        blockers = []
    claim_ids = row.get("claimIndexEntryIds", [])
    if not isinstance(claim_ids, list):
        claim_ids = []

    row_blocker_codes = [code for code in blockers if isinstance(code, str)]
    blocker_codes = row_blocker_codes
    blocker_codes, bundle_evidence = frontier_bundle_evidence(
        row=row,
        root=root,
        fallback_codes=blocker_codes,
        bundle_configs=bundle_configs,
    )
    blocker_codes = claim_allowance_blocker_codes(row, blocker_codes, bundle_evidence)
    cts_evidence = None
    if row.get("id") == CTS_CONFORMANCE_ROW_ID:
        blocker_codes, cts_evidence = cts_conformance_blocker_codes(
            root,
            blocker_codes,
            cts_evidence_path,
            cts_subset_receipt_path,
            cts_backend_pass_ledger_path,
        )
    claim_entry_ids = [entry_id for entry_id in claim_ids if isinstance(entry_id, str)]
    evidence_slices = row.get("evidenceSlices", [])
    if not isinstance(evidence_slices, list):
        evidence_slices = []
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
        "evidenceSlices": [
            build_evidence_slice_report(
                evidence_slice,
                row_blocker_codes=row_blocker_codes,
                resolved_row_blocker_codes=blocker_codes,
                definitions_by_code=definitions_by_code,
                entries_by_id=entries_by_id,
            )
            for evidence_slice in evidence_slices
            if isinstance(evidence_slice, dict)
        ],
    }
    if bundle_evidence is not None:
        row_report["frontierBundleEvidence"] = bundle_evidence
    if cts_evidence is not None:
        row_report["ctsConformanceEvidence"] = cts_evidence
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
    evidence_slices = [
        evidence_slice
        for row in rows
        for evidence_slice in row.get("evidenceSlices", [])
        if isinstance(evidence_slice, dict)
    ]
    claim_allowed_slices = [
        evidence_slice
        for evidence_slice in evidence_slices
        if evidence_slice.get("claimAllowed") is True
    ]
    blocked_slices = [
        evidence_slice
        for evidence_slice in evidence_slices
        if evidence_slice.get("readinessStatus") == "blocked"
    ]
    unique_blockers = {
        blocker.get("code")
        for row in rows
        for blocker in (
            list(row.get("blockers", []))
            + [
                slice_blocker
                for evidence_slice in row.get("evidenceSlices", [])
                if isinstance(evidence_slice, dict)
                for slice_blocker in evidence_slice.get("blockers", [])
            ]
        )
        if isinstance(blocker, dict) and blocker.get("code")
    }
    return {
        "frontierRowCount": len(rows),
        "productRowCount": len(product_rows),
        "claimAllowedProductRowCount": len(claim_allowed_rows),
        "blockedProductRowCount": len(blocked_rows),
        "coveredEvidenceReleaseRowCount": len(covered_rows),
        "evidenceSliceCount": len(evidence_slices),
        "claimAllowedEvidenceSliceCount": len(claim_allowed_slices),
        "blockedEvidenceSliceCount": len(blocked_slices),
        "uniqueBlockerCount": len(unique_blockers),
    }


def build_report(
    frontier: dict[str, Any],
    schema: dict[str, Any],
    claim_index: dict[str, Any],
    root: Path,
    bundle_configs: dict[str, dict[str, Any]] | None = None,
    cts_evidence_path: Path = CTS_EVIDENCE_PATH,
    cts_subset_receipt_path: Path = CTS_SUBSET_RECEIPT_PATH,
    cts_backend_pass_ledger_path: Path = CTS_BACKEND_PASS_LEDGER_PATH,
) -> dict[str, Any]:
    gate_report = frontier_gate.evaluate_frontier(frontier, schema, claim_index, root)
    definitions_by_code = blocker_map(frontier)
    entries_by_id = claim_entry_map(claim_index)
    resolved_bundle_configs = bundle_configs or frontier_bundle_config()
    raw_rows = frontier.get("rows", [])
    rows = [
        build_row_report(
            row,
            definitions_by_code,
            entries_by_id,
            root,
            resolved_bundle_configs,
            cts_evidence_path,
            cts_subset_receipt_path,
            cts_backend_pass_ledger_path,
        )
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
        f"{summary['claimAllowedEvidenceSliceCount']}/"
        f"{summary['evidenceSliceCount']} evidence slices claim-allowed; "
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
        blockers_text = (
            ", ".join(blocker_codes)
            if blocker_codes
            else "no active evidence blockers; claimAllowed=false"
        )
        print(f"- {row['id']}: {blockers_text}")


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
            browser_provenance_report_path=Path(args.browser_provenance_report),
            browser_package_inputs_path=Path(args.browser_package_inputs),
            browser_public_download_receipt_path=Path(args.browser_public_download_receipt),
            browser_launch_receipt_path=Path(args.browser_launch_receipt),
            browser_chromium_source_checkout_path=Path(args.browser_chromium_source_checkout),
            browser_proof_surface_path=Path(args.browser_proof_surface),
            browser_proof_surface_check_path=Path(args.browser_proof_surface_check),
            browser_finalizer_report_path=Path(args.browser_finalizer_report),
            browser_finalizer_check_path=Path(args.browser_finalizer_check),
            tint_bundle_path=Path(args.tint_frontier_bundle),
        ),
        Path(args.cts_evidence),
        Path(args.cts_subset_receipt),
        Path(args.cts_backend_pass_ledger),
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
