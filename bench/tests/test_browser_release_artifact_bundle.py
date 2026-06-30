#!/usr/bin/env python3
"""Tests for browser release artifact bundle checks."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from bench.tools import check_browser_release_artifact_bundle as bundle_check
from bench.tools import build_browser_release_artifact_bundle as builder


REPO_ROOT = Path(__file__).resolve().parents[2]
BUNDLE_PATH = REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json"


def _load() -> dict:
    return json.loads(BUNDLE_PATH.read_text(encoding="utf-8"))


def _write_file(path: Path, content: str) -> Path:
    path.write_text(content, encoding="utf-8")
    return path


def _write_promotion_receipt(path: Path, claim_report: Path) -> Path:
    payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_claim_promotion_receipt",
        "receiptId": "test-browser-claim-promotion",
        "claimPolicyPath": "config/browser-claim-policy.json",
        "promotionStatus": "promotable",
        "artifacts": [
            {
                "path": str(claim_report),
                "sha256": builder.sha256_file(claim_report),
                "mode": "doe",
                "forcedDoe": True,
                "hiddenFallbackUsed": False,
                "claimPolicyPassed": True,
            }
        ],
        "hiddenFallbackCheck": {
            "required": True,
            "passed": True,
        },
        "failureCodes": [],
    }
    path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    return path


def _write_diagnostic_promotion_receipt(path: Path, claim_report: Path) -> Path:
    payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_claim_promotion_receipt",
        "receiptId": "test-browser-claim-promotion-diagnostic",
        "claimPolicyPath": "config/browser-claim-policy.json",
        "promotionStatus": "diagnostic",
        "artifacts": [
            {
                "path": str(claim_report),
                "sha256": builder.sha256_file(claim_report),
                "mode": "doe",
                "forcedDoe": False,
                "hiddenFallbackUsed": False,
                "claimPolicyPassed": False,
            }
        ],
        "hiddenFallbackCheck": {
            "required": True,
            "passed": False,
        },
        "failureCodes": [],
    }
    path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    return path


def _release_bundle_inputs(tmp_path: Path) -> dict[str, Any]:
    claim_report = _write_file(tmp_path / "browser-claim-report.json", "{}\n")
    return {
        "browser_binary": _write_file(tmp_path / "chrome", "browser"),
        "doe_runtime": _write_file(tmp_path / "libwebgpu_doe.dylib", "runtime"),
        "shader_compiler": _write_file(tmp_path / "doe-zig-runtime", "compiler"),
        "contracts": [
            _write_file(tmp_path / "browser-claim-methodology.contract.md", "contract")
        ],
        "claim_reports": [claim_report],
        "promotion_receipts": [
            _write_promotion_receipt(
                tmp_path / "browser-claim-report.promotion-receipt.json",
                claim_report,
            )
        ],
        "policies": [
            _write_file(tmp_path / "browser-runtime-selector-policy.json", "{}\n"),
            _write_file(tmp_path / "chromium-fork-maintenance-policy.json", "{}\n"),
            _write_file(tmp_path / "chromium-patch-manifest.json", "{}\n"),
            _write_file(tmp_path / "browser-claim-policy.json", "{}\n"),
            _write_file(tmp_path / "browser-capture-policy.json", "{}\n"),
            _write_file(tmp_path / "browser-artifact-identity-coverage.json", "{}\n"),
            _write_file(tmp_path / "browser-unsupported-reason-taxonomy.json", "{}\n"),
        ],
    }


def _build_test_bundle(tmp_path: Path, *, release_status: str) -> dict:
    paths = _release_bundle_inputs(tmp_path)
    return builder.build_bundle(
        bundle_id="test-bundle",
        release_status=release_status,
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        shader_compiler=paths["shader_compiler"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=paths["promotion_receipts"],
        policies=paths["policies"],
    )


def test_browser_release_artifact_bundle_passes_check() -> None:
    assert bundle_check.check_bundle(_load()) == []


def test_browser_release_artifact_bundle_requires_runtime_hash() -> None:
    payload = _load()
    payload["doeRuntime"]["sha256"] = ""

    assert {
        "code": "missing_artifact_hash",
        "path": "doeRuntime.sha256",
        "message": "artifact sha256 is required",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_requires_claim_report() -> None:
    payload = _load()
    payload["claimReports"] = []

    assert {
        "code": "missing_claim_report_kind",
        "path": "claimReports",
        "message": "missing claim report artifact kind browser_claim_report",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_requires_promotion_receipt() -> None:
    payload = _load()
    payload["promotionReceipts"] = []

    assert {
        "code": "missing_promotion_receipt_kind",
        "path": "promotionReceipts",
        "message": "missing promotion receipt artifact kind browser_claim_promotion_receipt",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_defaults_include_browser_contract_surface() -> None:
    contract_paths = {
        path.relative_to(REPO_ROOT).as_posix()
        for path in builder.defaulted_paths([], builder.DEFAULT_CONTRACTS)
    }

    assert "browser/chromium/contracts/browser-benchmark-superset.contract.md" in contract_paths
    assert "browser/chromium/contracts/browser-gpu-flight-recorder.contract.md" in contract_paths
    assert "browser/chromium/contracts/browser-shader-links.contract.md" in contract_paths
    assert "browser/chromium/contracts/browser-pipeline-cache-receipts.contract.md" in contract_paths
    assert "browser/chromium/contracts/browser-cts-subset.contract.md" in contract_paths


def test_browser_release_artifact_bundle_defaults_include_chromium_patch_manifest() -> None:
    policy_paths = {
        path.relative_to(REPO_ROOT).as_posix()
        for path in builder.defaulted_paths([], builder.DEFAULT_POLICIES)
    }

    assert "config/chromium-fork-maintenance-policy.json" in policy_paths
    assert "config/chromium-patch-manifest.json" in policy_paths
    assert "config/browser-artifact-identity-coverage.json" in policy_paths
    assert "config/browser-unsupported-reason-taxonomy.json" in policy_paths


def test_browser_release_artifact_bundle_requires_claim_policy() -> None:
    payload = _load()
    payload["policies"] = [
        row
        for row in payload["policies"]
        if row["kind"] != "browser_claim_policy"
    ]

    assert {
        "code": "missing_policy_kind",
        "path": "policies",
        "message": "missing policy artifact kind browser_claim_policy",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_requires_capture_policy() -> None:
    payload = _load()
    payload["policies"] = [
        row
        for row in payload["policies"]
        if row["kind"] != "browser_capture_policy"
    ]

    assert {
        "code": "missing_policy_kind",
        "path": "policies",
        "message": "missing policy artifact kind browser_capture_policy",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_requires_chromium_patch_manifest() -> None:
    payload = _load()
    payload["policies"] = [
        row
        for row in payload["policies"]
        if row["kind"] != "chromium_patch_manifest"
    ]

    assert {
        "code": "missing_policy_kind",
        "path": "policies",
        "message": "missing policy artifact kind chromium_patch_manifest",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_rejects_candidate_failures() -> None:
    payload = _load()
    payload["releaseStatus"] = "release_candidate"
    payload["failureCodes"] = [{"code": "x", "path": "y", "message": "z"}]

    assert {
        "code": "release_candidate_has_failures",
        "path": "failureCodes",
        "message": "release candidates cannot carry failureCodes",
    } in bundle_check.check_bundle(payload)


def test_browser_release_artifact_bundle_require_candidate_rejects_diagnostic() -> None:
    assert {
        "code": "release_candidate_required",
        "path": "releaseStatus",
        "message": "browser release artifact bundle must be a release_candidate",
    } in bundle_check.check_bundle(_load(), require_release_candidate=True)


def test_browser_release_artifact_bundle_require_candidate_requires_verification_root() -> None:
    payload = _load()
    payload["releaseStatus"] = "release_candidate"

    assert {
        "code": "release_candidate_requires_verification",
        "path": "verifyFilesRoot",
        "message": "release-candidate browser release bundles require --verify-files-root",
    } in bundle_check.check_bundle(payload, require_release_candidate=True)


def test_browser_release_artifact_bundle_builder_hashes_artifacts(tmp_path: Path) -> None:
    browser_binary = _write_file(tmp_path / "chrome", "browser")
    doe_runtime = _write_file(tmp_path / "libwebgpu_doe.dylib", "runtime")
    shader_compiler = _write_file(tmp_path / "doe-zig-runtime", "compiler")
    contract = _write_file(tmp_path / "browser-claim-methodology.contract.md", "contract")
    claim_report = _write_file(tmp_path / "browser-claim-report.json", "{}\n")
    promotion_receipt = _write_promotion_receipt(tmp_path / "browser-claim-report.promotion-receipt.json", claim_report)
    runtime_policy = _write_file(tmp_path / "browser-runtime-selector-policy.json", "{}\n")
    fork_policy = _write_file(tmp_path / "chromium-fork-maintenance-policy.json", "{}\n")
    patch_manifest = _write_file(tmp_path / "chromium-patch-manifest.json", "{}\n")
    claim_policy = _write_file(tmp_path / "browser-claim-policy.json", "{}\n")
    capture_policy = _write_file(tmp_path / "browser-capture-policy.json", "{}\n")
    identity_coverage = _write_file(tmp_path / "browser-artifact-identity-coverage.json", "{}\n")
    unsupported_taxonomy = _write_file(tmp_path / "browser-unsupported-reason-taxonomy.json", "{}\n")

    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        browser_binary=browser_binary,
        doe_runtime=doe_runtime,
        shader_compiler=shader_compiler,
        contracts=[contract],
        claim_reports=[claim_report],
        promotion_receipts=[promotion_receipt],
        policies=[
            runtime_policy,
            fork_policy,
            patch_manifest,
            claim_policy,
            capture_policy,
            identity_coverage,
            unsupported_taxonomy,
        ],
    )

    assert payload["browserBinary"]["sha256"] == builder.sha256_file(browser_binary)
    assert payload["doeRuntime"]["sha256"] == builder.sha256_file(doe_runtime)
    assert payload["promotionReceipts"][0]["sha256"] == builder.sha256_file(promotion_receipt)
    assert bundle_check.check_bundle(payload) == []
    assert bundle_check.check_bundle(payload, verify_files_root=tmp_path) == []


def test_browser_release_artifact_bundle_builder_requires_verification_for_candidate(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")

    assert {
        "code": "release_candidate_requires_verification",
        "path": "verifyFilesRoot",
        "message": "release_candidate browser release bundles require --verify-files-root",
    } in builder.bundle_verification_failures(payload, None)


def test_browser_release_artifact_bundle_builder_accepts_verified_candidate(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")

    assert builder.bundle_verification_failures(payload, tmp_path) == []


def test_browser_release_artifact_bundle_require_candidate_accepts_verified_bundle(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="release_candidate")

    assert bundle_check.check_bundle(
        payload,
        verify_files_root=tmp_path,
        require_release_candidate=True,
    ) == []


def test_browser_release_artifact_bundle_builder_verifies_diagnostic_when_root_is_set(tmp_path: Path) -> None:
    payload = _build_test_bundle(tmp_path, release_status="diagnostic")
    payload["browserBinary"]["sha256"] = "0" * 64

    assert any(
        failure["code"] == "artifact_hash_mismatch"
        for failure in builder.bundle_verification_failures(payload, tmp_path)
    )


def test_browser_release_artifact_bundle_verifies_artifact_hash(tmp_path: Path) -> None:
    browser_binary = _write_file(tmp_path / "chrome", "browser")
    doe_runtime = _write_file(tmp_path / "libwebgpu_doe.dylib", "runtime")
    shader_compiler = _write_file(tmp_path / "doe-zig-runtime", "compiler")
    contract = _write_file(tmp_path / "browser-claim-methodology.contract.md", "contract")
    claim_report = _write_file(tmp_path / "browser-claim-report.json", "{}\n")
    promotion_receipt = _write_promotion_receipt(tmp_path / "browser-claim-report.promotion-receipt.json", claim_report)
    runtime_policy = _write_file(tmp_path / "browser-runtime-selector-policy.json", "{}\n")
    fork_policy = _write_file(tmp_path / "chromium-fork-maintenance-policy.json", "{}\n")
    patch_manifest = _write_file(tmp_path / "chromium-patch-manifest.json", "{}\n")
    claim_policy = _write_file(tmp_path / "browser-claim-policy.json", "{}\n")
    capture_policy = _write_file(tmp_path / "browser-capture-policy.json", "{}\n")
    identity_coverage = _write_file(tmp_path / "browser-artifact-identity-coverage.json", "{}\n")
    unsupported_taxonomy = _write_file(tmp_path / "browser-unsupported-reason-taxonomy.json", "{}\n")
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        browser_binary=browser_binary,
        doe_runtime=doe_runtime,
        shader_compiler=shader_compiler,
        contracts=[contract],
        claim_reports=[claim_report],
        promotion_receipts=[promotion_receipt],
        policies=[
            runtime_policy,
            fork_policy,
            patch_manifest,
            claim_policy,
            capture_policy,
            identity_coverage,
            unsupported_taxonomy,
        ],
    )
    payload["browserBinary"]["sha256"] = "0" * 64

    assert any(
        failure["code"] == "artifact_hash_mismatch"
        for failure in bundle_check.check_bundle(payload, verify_files_root=tmp_path)
    )


def test_browser_release_artifact_bundle_rejects_artifact_path_escape(tmp_path: Path) -> None:
    payload = _load()
    payload["browserBinary"]["path"] = "../chrome"

    failures = bundle_check.check_bundle(payload, verify_files_root=tmp_path)

    assert {
        "code": "unsafe_artifact_path",
        "path": "browserBinary.path",
        "message": "artifact path must resolve under verify-files-root: ../chrome",
    } in failures


def test_browser_release_artifact_bundle_verifies_promotion_receipt_covers_claim(tmp_path: Path) -> None:
    browser_binary = _write_file(tmp_path / "chrome", "browser")
    doe_runtime = _write_file(tmp_path / "libwebgpu_doe.dylib", "runtime")
    shader_compiler = _write_file(tmp_path / "doe-zig-runtime", "compiler")
    contract = _write_file(tmp_path / "browser-claim-methodology.contract.md", "contract")
    claim_report = _write_file(tmp_path / "browser-claim-report.json", "{}\n")
    other_claim_report = _write_file(tmp_path / "other-browser-claim-report.json", "{\"other\": true}\n")
    promotion_receipt = _write_promotion_receipt(
        tmp_path / "browser-claim-report.promotion-receipt.json",
        other_claim_report,
    )
    runtime_policy = _write_file(tmp_path / "browser-runtime-selector-policy.json", "{}\n")
    fork_policy = _write_file(tmp_path / "chromium-fork-maintenance-policy.json", "{}\n")
    patch_manifest = _write_file(tmp_path / "chromium-patch-manifest.json", "{}\n")
    claim_policy = _write_file(tmp_path / "browser-claim-policy.json", "{}\n")
    capture_policy = _write_file(tmp_path / "browser-capture-policy.json", "{}\n")
    identity_coverage = _write_file(tmp_path / "browser-artifact-identity-coverage.json", "{}\n")
    unsupported_taxonomy = _write_file(tmp_path / "browser-unsupported-reason-taxonomy.json", "{}\n")

    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        browser_binary=browser_binary,
        doe_runtime=doe_runtime,
        shader_compiler=shader_compiler,
        contracts=[contract],
        claim_reports=[claim_report],
        promotion_receipts=[promotion_receipt],
        policies=[
            runtime_policy,
            fork_policy,
            patch_manifest,
            claim_policy,
            capture_policy,
            identity_coverage,
            unsupported_taxonomy,
        ],
    )

    assert any(
        failure["code"] == "promotion_receipt_missing_claim_report"
        for failure in bundle_check.check_bundle(payload, verify_files_root=tmp_path)
    )


def test_browser_release_artifact_bundle_accepts_diagnostic_promotion_claim_failures(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path)
    diagnostic_receipt = _write_diagnostic_promotion_receipt(
        tmp_path / "browser-claim-report.diagnostic-promotion-receipt.json",
        paths["claim_reports"][0],
    )
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="diagnostic",
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        shader_compiler=paths["shader_compiler"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=[diagnostic_receipt],
        policies=paths["policies"],
    )

    failures = bundle_check.check_bundle(payload, verify_files_root=tmp_path)

    assert failures == []


def test_browser_release_artifact_bundle_candidate_rejects_diagnostic_promotion_claim_failures(tmp_path: Path) -> None:
    paths = _release_bundle_inputs(tmp_path)
    diagnostic_receipt = _write_diagnostic_promotion_receipt(
        tmp_path / "browser-claim-report.diagnostic-promotion-receipt.json",
        paths["claim_reports"][0],
    )
    payload = builder.build_bundle(
        bundle_id="test-bundle",
        release_status="release_candidate",
        browser_binary=paths["browser_binary"],
        doe_runtime=paths["doe_runtime"],
        shader_compiler=paths["shader_compiler"],
        contracts=paths["contracts"],
        claim_reports=paths["claim_reports"],
        promotion_receipts=[diagnostic_receipt],
        policies=paths["policies"],
    )

    failure_codes = {
        failure["code"]
        for failure in bundle_check.check_bundle(payload, verify_files_root=tmp_path)
    }

    assert "promotion_receipt_artifact_not_forced_doe" in failure_codes
    assert "promotion_receipt_claim_policy_not_passed" in failure_codes
    assert "promotion_receipt_hidden_fallback_check_failed" in failure_codes
