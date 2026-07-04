#!/usr/bin/env python3
"""Tests for the Dawn replacement readiness report builder."""

from __future__ import annotations

import hashlib
import json
import plistlib
import tempfile
import warnings
import zipfile
from collections.abc import Callable
from pathlib import Path

import jsonschema

from bench.browser.browser_gate import stable_hash
from bench.tools import build_dawn_replacement_readiness_report as report_builder


REPO_ROOT = Path(__file__).resolve().parents[2]
FRONTIER_PATH = REPO_ROOT / "config" / "dawn-replacement-frontier.json"
SCHEMA_PATH = REPO_ROOT / "config" / "dawn-replacement-frontier.schema.json"
READINESS_SCHEMA_PATH = REPO_ROOT / "config" / "dawn-replacement-readiness-report.schema.json"
CLAIM_INDEX_PATH = REPO_ROOT / "reports" / "claim-index.json"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _refresh_smoke_report_hashes(report: dict) -> None:
    previous_hash = None
    for row in report["modeResults"]:
        entry = {
            key: value
            for key, value in row.items()
            if key not in {"previousHash", "hash"}
        }
        row["previousHash"] = previous_hash
        row["hash"] = stable_hash(
            {
                "previousHash": previous_hash,
                "entry": entry,
            }
        )
        previous_hash = row["hash"]
    report["reportHash"] = stable_hash(
        {
            key: value
            for key, value in report.items()
            if key != "reportHash"
        }
    )


def _copy_zip_info(info: zipfile.ZipInfo) -> zipfile.ZipInfo:
    copied = zipfile.ZipInfo(info.filename, info.date_time)
    copied.compress_type = info.compress_type
    copied.external_attr = info.external_attr
    return copied


def _build_report_with_release_bundle_payload(
    tmp_path: Path,
    release_bundle: dict,
) -> dict:
    release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
    release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
    release_bundle_path.write_text(
        json.dumps(release_bundle, indent=2) + "\n",
        encoding="utf-8",
    )

    frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
    frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
    frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
    frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
    frontier_release_ref["path"] = release_bundle_rel.as_posix()
    frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
    frontier_bundle_path.write_text(
        json.dumps(frontier_bundle, indent=2) + "\n",
        encoding="utf-8",
    )

    return report_builder.build_report(
        _load(FRONTIER_PATH),
        _load(SCHEMA_PATH),
        _load(CLAIM_INDEX_PATH),
        REPO_ROOT,
        report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
    )


def _write_release_archive_with_plist(
    tmpdir: str,
    mutate_plist: Callable[[dict], None],
) -> Path:
    source_path = REPO_ROOT / "examples" / "browser-release-archive.sample.zip"
    archive_path = Path(tmpdir) / "browser-release-archive.zip"
    with zipfile.ZipFile(source_path) as source, zipfile.ZipFile(archive_path, "w") as out:
        for info in source.infolist():
            data = source.read(info.filename)
            if info.filename == "Fawn.app/Contents/Info.plist":
                plist = plistlib.loads(data)
                mutate_plist(plist)
                data = plistlib.dumps(plist)
            out.writestr(info, data)
    return archive_path


def _write_release_archive_with_browser_metadata(
    tmpdir: str,
    member_path: str,
    metadata: dict,
) -> Path:
    archive_path = Path(tmpdir) / "browser-release-archive.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr(member_path, json.dumps(metadata, sort_keys=True).encode("utf-8"))
    return archive_path


def _write_release_archive_with_member_data(
    tmpdir: str,
    member_path: str,
    data: bytes,
) -> Path:
    source_path = REPO_ROOT / "examples" / "browser-release-archive.sample.zip"
    archive_path = Path(tmpdir) / "browser-release-archive.zip"
    with zipfile.ZipFile(source_path) as source, zipfile.ZipFile(archive_path, "w") as out:
        for info in source.infolist():
            member_data = data if info.filename == member_path else source.read(info.filename)
            out.writestr(info, member_data)
    return archive_path


def _write_release_archive_with_duplicate_member(tmp_path: Path) -> Path:
    source_path = REPO_ROOT / "examples" / "browser-release-archive.sample.zip"
    archive_path = tmp_path / "browser-release-archive.duplicate-member.zip"
    with zipfile.ZipFile(source_path) as source:
        entries = [
            (info, source.read(info.filename))
            for info in source.infolist()
            if not info.is_dir()
        ]
    duplicate_info, duplicate_payload = entries[0]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        with zipfile.ZipFile(archive_path, "w") as out:
            for info, data in entries:
                out.writestr(_copy_zip_info(info), data)
            out.writestr(_copy_zip_info(duplicate_info), duplicate_payload)
    return archive_path


def _report() -> dict:
    return report_builder.build_report(
        _load(FRONTIER_PATH),
        _load(SCHEMA_PATH),
        _load(CLAIM_INDEX_PATH),
        REPO_ROOT,
    )


def _build_report_with_browser_frontier_payload(payload: dict) -> tuple[Path, dict]:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )
    return custom_rel, report


def _assert_malformed_browser_frontier_field(
    mutate_payload: Callable[[dict], None],
    *,
    code: str,
    path: str,
    message: str,
) -> None:
    payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
    mutate_payload(payload)
    custom_rel, report = _build_report_with_browser_frontier_payload(payload)

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    bundle_evidence = browser_row["frontierBundleEvidence"]
    consistency = bundle_evidence["consistency"]

    assert bundle_evidence["path"] == custom_rel.as_posix()
    assert bundle_evidence["artifactKind"] == "browser_runtime_frontier_bundle"
    assert bundle_evidence["status"] == "fail"
    assert bundle_evidence["claimabilityStatus"] == "blocked"
    assert bundle_evidence["claimBlockers"] == []
    assert "releaseCandidateEvidence" not in bundle_evidence
    assert consistency["status"] == "fail"
    assert {
        "code": code,
        "path": path,
        "message": message,
    } in consistency["failures"]


def _build_report_with_tint_frontier_payload(payload: dict) -> tuple[Path, dict]:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "tint-compiler-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(tint_bundle_path=custom_rel),
        )
    return custom_rel, report


def _build_report_with_cts_payload(payload: dict) -> tuple[Path, dict]:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "webgpu-cts-evidence.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            cts_evidence_path=custom_rel,
        )
    return custom_rel, report


def _build_report_with_cts_subset_receipt_payload(payload: dict) -> tuple[Path, dict]:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "webgpu-cts-subset-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            cts_subset_receipt_path=custom_rel,
        )
    return custom_rel, report


def _build_report_with_cts_backend_pass_ledger_payload(payload: dict) -> tuple[Path, dict]:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "webgpu-cts-backend-pass-ledger.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            cts_backend_pass_ledger_path=custom_rel,
        )
    return custom_rel, report


def _assert_malformed_tint_frontier_field(
    mutate_payload: Callable[[dict], None],
    *,
    code: str,
    path: str,
    message: str,
) -> None:
    payload = _load(REPO_ROOT / "examples" / "tint-compiler-frontier-bundle.sample.json")
    mutate_payload(payload)
    custom_rel, report = _build_report_with_tint_frontier_payload(payload)

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    compiler_row = next(row for row in report["rows"] if row["id"] == "wgsl-tint-compiler")
    bundle_evidence = compiler_row["frontierBundleEvidence"]
    consistency = bundle_evidence["consistency"]

    assert bundle_evidence["path"] == custom_rel.as_posix()
    assert bundle_evidence["artifactKind"] == "tint_compiler_frontier_bundle"
    assert bundle_evidence["status"] == "fail"
    assert bundle_evidence["claimabilityStatus"] == "blocked"
    assert bundle_evidence["claimBlockers"] == []
    assert "compilerEvidenceReports" not in bundle_evidence
    assert consistency["status"] == "fail"
    assert {
        "code": code,
        "path": path,
        "message": message,
    } in consistency["failures"]


def test_readiness_report_uses_frontier_gate_result() -> None:
    report = _report()

    assert report["artifactKind"] == "dawn-replacement-readiness-report"
    assert report["gate"]["ok"] is True
    assert report["summary"]["frontierRowCount"] == 11
    assert report["summary"]["productRowCount"] == 10
    assert report["summary"]["claimAllowedProductRowCount"] == 5
    assert report["summary"]["evidenceSliceCount"] == 16
    assert report["summary"]["claimAllowedEvidenceSliceCount"] == 5
    assert report["summary"]["blockedEvidenceSliceCount"] == 10


def test_readiness_report_preserves_blocker_exit_criteria() -> None:
    report = _report()
    d3d12_row = next(row for row in report["rows"] if row["id"] == "native-d3d12-runtime")
    blocker_codes = {blocker["code"] for blocker in d3d12_row["blockers"]}

    assert d3d12_row["readinessStatus"] == "blocked"
    assert "fresh_windows_d3d12_runtime_artifact" in blocker_codes
    assert all(blocker["exitCriteria"] for blocker in d3d12_row["blockers"])


def test_readiness_report_splits_rows_by_platform_backend_slice() -> None:
    report = _report()
    slices = {
        evidence_slice["id"]: evidence_slice
        for row in report["rows"]
        for evidence_slice in row["evidenceSlices"]
    }

    assert slices["native-linux-x64-amd-vulkan"]["readinessStatus"] == "claimable"
    assert slices["dropin-linux-x64-amd-vulkan"]["readinessStatus"] == "claimable"
    assert slices["chromium-macos-arm64-apple-metal"]["readinessStatus"] == "blocked"
    assert slices["chromium-linux-x64-amd-vulkan"]["readinessStatus"] == "blocked"
    assert slices["chromium-windows-x64-d3d12"]["readinessStatus"] == "blocked"
    assert [
        blocker["code"]
        for blocker in slices["chromium-linux-x64-amd-vulkan"]["blockers"]
    ] == ["chromium_release_build_evidence"]


def test_readiness_report_links_claimable_rows_to_claim_index() -> None:
    report = _report()
    metal_row = next(row for row in report["rows"] if row["id"] == "native-metal-runtime")
    claim_ids = {entry["id"] for entry in metal_row["claimIndexEntries"]}

    assert metal_row["readinessStatus"] == "claimable"
    assert claim_ids == {"native-strict-apple-metal", "native-release-apple-metal"}
    assert all(entry["claimStatus"] == "claimable" for entry in metal_row["claimIndexEntries"])


def test_cts_readiness_uses_receipts_to_clear_cts_evidence_blockers() -> None:
    report = _report()
    cts_row = next(row for row in report["rows"] if row["id"] == "webgpu-cts-conformance")
    blocker_codes = [blocker["code"] for blocker in cts_row["blockers"]]
    cts_evidence = cts_row["ctsConformanceEvidence"]
    subset_receipt = cts_evidence["subsetReceipt"]
    backend_pass_ledger = cts_evidence["backendPassLedger"]

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    assert cts_row["readinessStatus"] == "blocked"
    assert blocker_codes == []
    assert cts_evidence["path"] == "config/webgpu-cts-evidence.json"
    assert cts_evidence["policyStatus"] == "defined"
    assert cts_evidence["claimLanguage"] == "diagnostic_until_full_published_pass_ledger"
    assert cts_evidence["summary"]["policyFailureCount"] == 0
    assert subset_receipt["path"] == "examples/webgpu-cts-subset-receipt.sample.json"
    assert subset_receipt["status"] == "pass"
    assert subset_receipt["summary"]["failureCount"] == 0
    assert subset_receipt["sourceEvidence"]["path"] == "config/webgpu-cts-evidence.json"
    assert backend_pass_ledger["path"] == "examples/webgpu-cts-backend-pass-ledger.sample.json"
    assert backend_pass_ledger["status"] == "pass"
    assert backend_pass_ledger["ledgerStatus"] == "pass"
    assert backend_pass_ledger["summary"]["failureCount"] == 0
    assert backend_pass_ledger["fullConformanceClaimAllowed"] is False
    assert backend_pass_ledger["replacementClaimAllowed"] is False
    assert backend_pass_ledger["sourceReceipt"]["path"] == subset_receipt["path"]


def test_cts_readiness_keeps_backend_ledger_blocker_for_stale_projection() -> None:
    payload = _load(REPO_ROOT / "examples" / "webgpu-cts-backend-pass-ledger.sample.json")
    payload["sourceReceipt"]["sha256"] = "0" * 64
    custom_rel, report = _build_report_with_cts_backend_pass_ledger_payload(payload)
    cts_row = next(row for row in report["rows"] if row["id"] == "webgpu-cts-conformance")
    blocker_codes = [blocker["code"] for blocker in cts_row["blockers"]]
    backend_pass_ledger = cts_row["ctsConformanceEvidence"]["backendPassLedger"]

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    assert "backend_specific_cts_pass_ledger" in blocker_codes
    assert backend_pass_ledger["path"] == custom_rel.as_posix()
    assert backend_pass_ledger["status"] == "fail"
    assert {
        "code": "cts_backend_pass_ledger_projection_mismatch",
        "path": "ctsConformanceEvidence.backendPassLedger.sourceReceipt",
        "message": "CTS backend pass ledger sourceReceipt must match the subset receipt projection",
    } in backend_pass_ledger["failures"]


def test_cts_readiness_keeps_subset_blocker_for_stale_receipt_hash() -> None:
    payload = _load(REPO_ROOT / "examples" / "webgpu-cts-subset-receipt.sample.json")
    payload["sourceEvidence"]["sha256"] = "0" * 64
    custom_rel, report = _build_report_with_cts_subset_receipt_payload(payload)
    cts_row = next(row for row in report["rows"] if row["id"] == "webgpu-cts-conformance")
    blocker_codes = [blocker["code"] for blocker in cts_row["blockers"]]
    subset_receipt = cts_row["ctsConformanceEvidence"]["subsetReceipt"]

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    assert "published_cts_subset_receipt" in blocker_codes
    assert subset_receipt["path"] == custom_rel.as_posix()
    assert subset_receipt["status"] == "fail"
    assert {
        "code": "cts_subset_source_hash_mismatch",
        "path": "ctsConformanceEvidence.subsetReceipt.sourceEvidence.sha256",
        "message": "CTS subset receipt sourceEvidence.sha256 must match the CTS evidence file",
    } in subset_receipt["failures"]


def test_cts_readiness_keeps_policy_blocker_for_missing_policy() -> None:
    payload = _load(REPO_ROOT / "config" / "webgpu-cts-evidence.json")
    del payload["claimPolicy"]
    custom_rel, report = _build_report_with_cts_payload(payload)
    cts_row = next(row for row in report["rows"] if row["id"] == "webgpu-cts-conformance")
    blocker_codes = [blocker["code"] for blocker in cts_row["blockers"]]
    cts_evidence = cts_row["ctsConformanceEvidence"]

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    assert "conformance_claim_policy" in blocker_codes
    assert cts_evidence["path"] == custom_rel.as_posix()
    assert cts_evidence["policyStatus"] == "missing"
    assert {
        "code": "cts_claim_policy_missing",
        "path": "ctsConformanceEvidence.claimPolicy",
        "message": "CTS evidence must define a conformance claim policy",
    } in cts_evidence["failures"]


def test_browser_readiness_uses_frontier_bundle_blockers() -> None:
    report = _report()
    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    blocker_codes = [blocker["code"] for blocker in browser_row["blockers"]]
    claim_entries = {entry["id"]: entry for entry in browser_row["claimIndexEntries"]}
    bundle_evidence = browser_row["frontierBundleEvidence"]
    release_bundle = bundle_evidence["componentReceipts"]["releaseArtifactBundle"]
    release_candidate = bundle_evidence["releaseCandidateEvidence"]
    provenance_report = release_candidate["provenanceReport"]
    package_inputs = release_candidate["packageInputs"]
    release_support = release_candidate["releaseSupportArtifacts"]
    public_download = release_candidate["publicDownloadReceipt"]
    browser_launch = release_candidate["browserLaunchReceipt"]
    chromium_source_checkout = release_candidate["chromiumSourceCheckout"]
    proof_surface = release_candidate["publishedProofSurface"]
    proof_surface_check = release_candidate["proofSurfaceCheck"]

    assert browser_row["readinessStatus"] == "blocked"
    assert blocker_codes == ["chromium_release_build_evidence"]
    assert sorted(claim_entries) == ["browser-chromium-release", "ort-browser-apple-metal"]
    assert claim_entries["browser-chromium-release"]["claimState"] == "scaffolded"
    assert (
        claim_entries["browser-chromium-release"]["browserRelease"]["runtimeFrontierBundlePath"]
        == "examples/browser-runtime-frontier-bundle.sample.json"
    )
    assert bundle_evidence["path"] == "examples/browser-runtime-frontier-bundle.sample.json"
    assert bundle_evidence["sha256"] == "d5b3a1a83cb1a6a1afc8b2b9d1361741e9c0fc0655b11655fbe5fc5a4d8fd61f"
    assert bundle_evidence["status"] == "pass"
    assert bundle_evidence["claimabilityStatus"] == "blocked"
    assert bundle_evidence["claimBlockerSummary"] == [
        {
            "code": "chromium_release_build_evidence",
            "message": "browser release artifact bundle must be a release_candidate",
            "count": 1,
        }
    ]
    assert release_bundle["path"] == "examples/browser-release-artifact-bundle.sample.json"
    assert release_bundle["sha256"] == "e63260d71669a86765287fd1e58a286234cff23855bb6cb05332ce0d3fea6648"
    assert release_bundle["releaseStatus"] == "diagnostic"
    assert release_bundle["artifactVerification"] == {
        "requiredForClaimable": True,
        "verifyFilesRootProvided": True,
        "verified": True,
    }
    assert release_support["contractKinds"] == ["contract"]
    assert release_support["claimReportKinds"] == ["browser_claim_report"]
    assert release_support["promotionReceiptKinds"] == ["browser_claim_promotion_receipt"]
    assert release_support["policyKinds"] == [
        "browser_artifact_identity_coverage",
        "browser_capture_policy",
        "browser_claim_policy",
        "browser_unsupported_reason_taxonomy",
        "chromium_patch_manifest",
        "fork_maintenance_policy",
        "runtime_selector_policy",
    ]
    assert len(release_support["contracts"]) == 16
    assert release_support["claimReports"] == [
        {
            "path": "examples/browser-claim-report.sample.json",
            "sha256": "a6bd9f81550992e8c296f7105e4ac6411ca6ee39bb29a76cf147302dc81b8dfe",
            "kind": "browser_claim_report",
        }
    ]
    assert release_support["promotionReceipts"] == [
        {
            "path": "examples/browser-claim-promotion-receipt.sample.json",
            "sha256": "86b1763e2b287b4615e97c9cb7f27b523f060e4793eaf08d9ba10be426600f87",
            "kind": "browser_claim_promotion_receipt",
        }
    ]
    assert release_support["policies"][-1] == {
        "path": "config/browser-unsupported-reason-taxonomy.json",
        "sha256": "33eda11e97afc55b48d1403523bcc9fb3809613f9ae201f22e6dd4dae5006bec",
        "kind": "browser_unsupported_reason_taxonomy",
    }
    assert provenance_report["path"] == "examples/browser-release-candidate-provenance.sample.json"
    assert provenance_report["sha256"] == "4ae0005d89d49277fc153aef13f0c290bdcfcc270faa56f78db4f71ca2f93171"
    assert provenance_report["status"] == "fail"
    assert provenance_report["releaseStatus"] == "release_candidate"
    assert provenance_report["failureCount"] == 5
    assert provenance_report["componentArtifacts"]["proofSurface"] == {
        "path": "examples/browser-published-proof-surface.sample.json",
        "sha256": "608fa51413bc866a2a6e8f0835a53aab7ec48c1e5c37ea4305c69e435ce58eaa",
        "kind": "browser_published_proof_surface",
    }
    assert provenance_report["componentArtifacts"]["proofSurfaceCheck"] == {
        "path": "examples/browser-published-proof-surface-check.sample.json",
        "sha256": "2206e419a0ed36e8d580e40a7f869f56e6988eaff93d7fbe82ab2edcd9539ec1",
        "kind": "browser_published_proof_surface_check",
    }
    assert provenance_report["componentArtifacts"]["browserLaunchReceipt"] == {
        "path": "examples/browser-release-launch-receipt.sample.json",
        "sha256": "76674a2d2dc75d06b4e682a07ae42908f7e0e951a2cd84dd3b6ab9f559f5c67b",
        "kind": "browser_release_launch_receipt",
    }
    assert provenance_report["componentArtifacts"]["packageInputs"] == {
        "path": "examples/browser-release-package-inputs-check.sample.json",
        "sha256": "9346d49694f6bf786cc6235d933a5a2fa1f93b52ab8029cd76699cff9636f4b4",
        "kind": "browser_release_package_inputs_check",
    }
    assert package_inputs["path"] == "examples/browser-release-package-inputs-check.sample.json"
    assert package_inputs["sha256"] == "9346d49694f6bf786cc6235d933a5a2fa1f93b52ab8029cd76699cff9636f4b4"
    assert package_inputs["schemaVersion"] == 1
    assert package_inputs["status"] == "pass"
    assert package_inputs["evidenceMode"] == "diagnostic"
    assert package_inputs["releaseCandidateEligible"] is False
    assert [item["code"] for item in package_inputs["releaseCandidateBlockers"]] == [
        "release_candidate_channel_required",
        "initial_macos_arm64_release_required",
    ]
    assert package_inputs["packageDir"] == {
        "path": "browser/chromium/src/out/fawn_release",
        "exists": True,
    }
    assert package_inputs["packageRootName"] == "Fawn-Doe-linux-x64"
    assert package_inputs["platform"] == {"os": "linux", "arch": "x64", "packageFormat": "zip"}
    assert package_inputs["inputs"]["browserExecutable"]["archivePath"] == "Fawn-Doe-linux-x64/chrome-wrapper"
    assert package_inputs["inputs"]["doeRuntime"]["sha256"] == "1bf01661b9b48fc1811a0668aa18ce8642f7b568b1e4fffda82268ff79e0c527"
    assert package_inputs["inputs"]["dawnFallbackRuntime"]["sha256"] == "3f8a4266e31f22c662208f2371f14c7cb570a5b85df09ebb7da5c766957c2854"
    assert package_inputs["inputs"]["shaderCompiler"]["sha256"] == "fdef3b47a9b3f4f75ecb1587e9053e587be290e1035381ce5e9d38207aec3d62"
    assert package_inputs["summary"]["packageable"] is True
    assert package_inputs["summary"]["metadataSource"] == "generated"
    assert public_download == {
        "path": "examples/browser-public-download-receipt.sample.json",
        "sha256": "fbb04fddc5e8f2250c577eddc93a8b5299af292ed923346b24f580f3f942723c",
        "schemaVersion": 1,
        "artifactKind": "browser_public_download_receipt",
        "receiptId": "browser-public-download-sample-linux-x64",
        "url": "https://downloads.doe.dev/Fawn-Doe-linux-x64.zip",
        "method": "GET",
        "statusCode": 200,
        "contentSha256": "4c6bc417b08d3762b0c55be6a817f2fd948c9665c343792b7e2e9fdaff3f5158",
        "contentLengthBytes": 11325471,
        "releaseArchivePath": "examples/browser-release-archive.sample.zip",
        "releaseArchiveManifestPath": "examples/browser-release-archive-manifest.sample.json",
        "releaseArchiveManifestSha256": "f7c6456a63a3d5c8b5e6ce1def004c6c2035eb2103e0cdc77bbc830e8889ee5b",
        "browserProduct": {
            "productId": "fawn-doe",
            "displayName": "Fawn Doe",
            "version": "0.0.0-sample",
            "channel": "diagnostic",
        },
        "platform": {"os": "linux", "arch": "x64", "packageFormat": "zip"},
        "browserExecutableArchivePath": "Fawn-Doe-linux-x64/chrome-wrapper",
        "browserAppMetadataArchivePath": "Fawn-Doe-linux-x64/browser-product.json",
        "doeRuntimeArchivePath": "Fawn-Doe-linux-x64/libwebgpu_doe.so",
        "dawnFallbackRuntimeArchivePath": "Fawn-Doe-linux-x64/libdawn_native.so",
        "observedAt": "2026-06-30T00:00:00Z",
    }
    assert browser_launch == {
        "path": "examples/browser-release-launch-receipt.sample.json",
        "sha256": "76674a2d2dc75d06b4e682a07ae42908f7e0e951a2cd84dd3b6ab9f559f5c67b",
        "schemaVersion": 1,
        "artifactKind": "browser_release_launch_receipt",
        "receiptId": "browser-release-launch-sample",
        "observedAt": "2026-06-30T00:00:00Z",
        "launchSource": "release_archive",
        "runtimeMode": "doe",
        "activeRuntime": "doe",
        "activeBackend": "webgpu-doe",
        "hiddenFallbackAllowed": False,
        "hiddenFallbackUsed": False,
        "webgpuAvailable": True,
        "browserProduct": {
            "productId": "fawn-doe",
            "displayName": "Fawn Doe",
            "version": "0.0.0-sample",
            "channel": "diagnostic",
        },
        "platform": {"os": "linux", "arch": "x64", "packageFormat": "zip"},
        "releaseArchive": {
            "path": "examples/browser-release-archive.sample.zip",
            "sha256": "4c6bc417b08d3762b0c55be6a817f2fd948c9665c343792b7e2e9fdaff3f5158",
            "kind": "browser_release_archive",
            "downloadUrl": "https://downloads.doe.dev/Fawn-Doe-linux-x64.zip",
        },
        "releaseArchiveManifest": {
            "path": "examples/browser-release-archive-manifest.sample.json",
            "sha256": "f7c6456a63a3d5c8b5e6ce1def004c6c2035eb2103e0cdc77bbc830e8889ee5b",
            "kind": "browser_release_archive_manifest",
        },
        "proofSurface": {
            "path": "examples/browser-published-proof-surface.sample.json",
            "sha256": "608fa51413bc866a2a6e8f0835a53aab7ec48c1e5c37ea4305c69e435ce58eaa",
            "kind": "browser_published_proof_surface",
        },
        "browserExecutableArchivePath": "Fawn-Doe-linux-x64/chrome-wrapper",
        "browserAppMetadataArchivePath": "Fawn-Doe-linux-x64/browser-product.json",
        "doeRuntimeArchivePath": "Fawn-Doe-linux-x64/libwebgpu_doe.so",
        "dawnFallbackRuntimeArchivePath": "Fawn-Doe-linux-x64/libdawn_native.so",
        "proofPageUrl": "about:doe",
        "proofPageLoaded": True,
        "proofPageArtifactPath": "examples/browser-proof-page.sample.html",
        "proofPageReceiptId": "browser-proof-page-sample",
        "galleryUrl": "https://gallery.doe.dev/doe/compute.html",
        "galleryLoaded": True,
        "galleryCategory": "compute",
        "galleryArtifactPath": "examples/browser-gallery-compute.sample.html",
        "galleryReceiptId": "browser-public-gallery-compute-sample",
        "comparisonId": "browser-smoke-compute-dawn-vs-doe",
        "comparisonWorkloadId": "browser-smoke-compute",
        "comparisonPageArtifactPath": "examples/browser-gallery-compute.sample.html",
        "comparisonLoaded": True,
        "comparisonExecutionScope": "same_page",
        "comparisonModes": ["dawn", "doe"],
        "comparisonEmitsSideBySideReceipts": True,
        "comparisonArtifactPath": "examples/browser-smoke-report.sample.json",
        "comparisonDawnReceiptId": "browser-smoke-compute-dawn",
        "comparisonDoeReceiptId": "browser-smoke-compute-doe",
        "observedReceiptIds": [
            "browser-proof-page-sample",
            "browser-public-gallery-compute-sample",
            "browser-smoke-compute-dawn",
            "browser-smoke-compute-doe",
        ],
    }
    assert chromium_source_checkout == {
        "path": "examples/chromium-source-checkout-check.sample.json",
        "sha256": "3d52e6ff56d31ebad69a56e3a82dad675f2d277c0aedf783ab9ef55e159f31d1",
        "schemaVersion": 1,
        "artifactKind": "chromium_source_checkout_check",
        "sourceRoot": "browser/chromium/src",
        "requireReady": False,
        "requireRuntimeSelector": True,
        "status": "pass",
        "checkCount": 37,
        "missingRequiredWellFormed": True,
        "missingRequired": [],
    }
    assert proof_surface["path"] == "examples/browser-published-proof-surface.sample.json"
    assert proof_surface["sha256"] == "608fa51413bc866a2a6e8f0835a53aab7ec48c1e5c37ea4305c69e435ce58eaa"
    assert proof_surface["surfaceId"] == "browser-published-proof-surface-sample-v1"
    assert proof_surface["runtimeIdentityPath"] == "examples/browser-runtime-identity.selector.sample.json"
    assert proof_surface["proofPageUrl"] == "about:doe"
    assert proof_surface["activeBackend"] == "webgpu-doe"
    assert proof_surface["webgpuAvailable"] is True
    assert proof_surface["browserProduct"]["productId"] == "fawn-doe"
    assert proof_surface["browserProduct"]["channel"] == "diagnostic"
    assert proof_surface["platform"] == {"os": "linux", "arch": "x64", "packageFormat": "zip"}
    assert proof_surface["releaseArchive"] == {
        "path": "examples/browser-release-archive.sample.zip",
        "sha256": "4c6bc417b08d3762b0c55be6a817f2fd948c9665c343792b7e2e9fdaff3f5158",
        "kind": "browser_release_archive",
        "downloadUrl": "https://downloads.doe.dev/Fawn-Doe-linux-x64.zip",
    }
    assert proof_surface["galleryCategories"] == [
        "benchmark_trace",
        "compute",
        "rendering",
        "shader_edge",
        "tensor",
    ]
    assert proof_surface["galleryPageCount"] == 5
    assert proof_surface["comparisonReceiptCount"] == 1
    assert proof_surface["receiptPayloadCount"] == 2
    assert proof_surface_check == {
        "path": "examples/browser-published-proof-surface-check.sample.json",
        "sha256": "2206e419a0ed36e8d580e40a7f869f56e6988eaff93d7fbe82ab2edcd9539ec1",
        "artifactKind": "browser_published_proof_surface_check",
        "surfacePath": "examples/browser-published-proof-surface.sample.json",
        "surfaceSha256": "608fa51413bc866a2a6e8f0835a53aab7ec48c1e5c37ea4305c69e435ce58eaa",
        "verifyFilesRootProvided": True,
        "requirePublicUrls": True,
        "status": "pass",
        "failureCount": 0,
        "failures": [],
    }
    assert release_candidate["finalizerReport"]["path"] == "examples/browser-release-candidate-finalizer.sample.json"
    assert release_candidate["finalizerReport"]["sha256"] == "4889b5b8f979c4b848f62a67f246b0c589b57f1dac8394fe913f7626caff5c2d"
    assert release_candidate["finalizerReport"]["status"] == "fail"
    assert release_candidate["finalizerReport"]["phase"] == "package_inputs_preflight"
    assert release_candidate["finalizerReport"]["failureCount"] == 5
    assert release_candidate["finalizerCheck"]["path"] == "examples/browser-release-candidate-finalizer-check.sample.json"
    assert release_candidate["finalizerCheck"]["sha256"] == "ba685a520dc8e620b2bcbd1a00f6b99e570226531848c0de1a6e0b6c086e38e8"
    assert release_candidate["finalizerCheck"]["status"] == "fail"
    assert release_candidate["finalizerCheck"]["finalizerStatus"] == "fail"
    assert release_candidate["finalizerCheck"]["finalizerReportPath"] == "examples/browser-release-candidate-finalizer.sample.json"
    assert release_candidate["finalizerCheck"]["finalizerReportSha256"] == "4889b5b8f979c4b848f62a67f246b0c589b57f1dac8394fe913f7626caff5c2d"
    assert release_candidate["finalizerCheck"]["verifyFilesRootProvided"] is True
    assert release_candidate["finalizerCheck"]["requirePass"] is True
    assert release_candidate["finalizerCheck"]["failureCount"] == 1
    consistency = release_candidate["consistency"]
    assert consistency["status"] == "fail"
    failure_codes = [item["code"] for item in consistency["failures"]]
    assert consistency["failureCount"] == len(consistency["failures"])
    assert consistency["failureCodes"] == sorted(set(failure_codes))
    assert failure_codes == [
        "release_artifact_bundle_not_release_candidate",
        "provenance_report_not_pass",
        "finalizer_report_not_pass",
        "finalizer_check_not_pass",
        "package_inputs_not_release_candidate_eligible",
        "package_inputs_not_release_candidate",
        "package_inputs_blockers_present",
    ]


def test_compiler_readiness_uses_frontier_bundle_blockers() -> None:
    report = _report()
    compiler_row = next(row for row in report["rows"] if row["id"] == "wgsl-tint-compiler")
    blocker_codes = [blocker["code"] for blocker in compiler_row["blockers"]]
    bundle_evidence = compiler_row["frontierBundleEvidence"]
    target_validations = bundle_evidence["componentReceipts"]["targetValidations"]

    assert compiler_row["readinessStatus"] == "blocked"
    assert blocker_codes == ["claimable_tint_compiler_evidence_report"]
    assert bundle_evidence["path"] == "examples/tint-compiler-frontier-bundle.sample.json"
    assert bundle_evidence["sha256"] == "84d02ebacf8659e26617622f6e4d5a12acdde4b6c70b8387504eec6e021edbe1"
    assert bundle_evidence["status"] == "pass"
    assert bundle_evidence["claimabilityStatus"] == "blocked"
    assert {blocker["code"] for blocker in bundle_evidence["claimBlockers"]} == {
        "claimable_tint_compiler_evidence_report"
    }
    assert bundle_evidence["summary"]["claimBlockerCount"] == len(
        bundle_evidence["claimBlockers"]
    )
    assert [item["path"] for item in bundle_evidence["compilerEvidenceReports"]] == [
        "examples/tint-compiler-evidence.browser-corpus.spirv.sample.json",
        "examples/tint-compiler-evidence.benchmark-corpus.spirv.sample.json",
    ]
    assert bundle_evidence["phaseTimingCoverage"] == {
        "requiredExactPhases": ["parse", "sema", "lower", "emit"],
        "requiredBenchmarkScopes": [
            "parseWgsl",
            "validateIr",
            "generateBackend",
        ],
        "rowCount": 15,
        "doeOkRows": 15,
        "tintOkRows": 15,
        "doeExactPhaseCompleteRows": 15,
        "doeExactPhaseMissingRows": 0,
        "tintExactPhaseCompleteRows": 0,
        "tintExactPhaseMissingRows": 15,
        "tintBenchmarkScopeCoveredRows": 15,
        "tintBenchmarkScopeMissingRows": 0,
        "notApplicableRows": 0,
        "coverageByEvidencePath": [
            {
                "evidencePath": "examples/tint-compiler-evidence.browser-corpus.spirv.sample.json",
                "targets": ["spirv"],
                "rowCount": 1,
                "doeOkRows": 1,
                "tintOkRows": 1,
                "doeExactPhaseCompleteRows": 1,
                "doeExactPhaseMissingRows": 0,
                "tintExactPhaseCompleteRows": 0,
                "tintExactPhaseMissingRows": 1,
                "tintBenchmarkScopeCoveredRows": 1,
                "tintBenchmarkScopeMissingRows": 0,
                "notApplicableRows": 0,
            },
            {
                "evidencePath": "examples/tint-compiler-evidence.benchmark-corpus.spirv.sample.json",
                "targets": ["spirv"],
                "rowCount": 14,
                "doeOkRows": 14,
                "tintOkRows": 14,
                "doeExactPhaseCompleteRows": 14,
                "doeExactPhaseMissingRows": 0,
                "tintExactPhaseCompleteRows": 0,
                "tintExactPhaseMissingRows": 14,
                "tintBenchmarkScopeCoveredRows": 14,
                "tintBenchmarkScopeMissingRows": 0,
                "notApplicableRows": 0,
            },
        ],
    }
    assert bundle_evidence["compilerEvidenceReports"][0]["claimBlockerSummary"] == [
        {
            "code": "claimable_tint_compiler_evidence_report",
            "message": "tint: missing integer phase timing: parse",
            "count": 1,
        },
        {
            "code": "claimable_tint_compiler_evidence_report",
            "message": "tint: missing integer phase timing: sema",
            "count": 1,
        },
        {
            "code": "claimable_tint_compiler_evidence_report",
            "message": "tint: missing integer phase timing: lower",
            "count": 1,
        },
        {
            "code": "claimable_tint_compiler_evidence_report",
            "message": "tint: missing integer phase timing: emit",
            "count": 1,
        },
        {
            "code": "claimable_tint_compiler_evidence_report",
            "message": "compiler evidence must be claimable before it can support a Tint replacement claim",
            "count": 1,
        },
    ]
    assert target_validations[0]["summary"]["claimBlockerCount"] == 0
    assert target_validations[0]["claimBlockerSummary"] == []
    assert target_validations[0]["evidencePaths"] == [
        "examples/tint-compiler-evidence.browser-corpus.spirv.sample.json",
        "examples/tint-compiler-evidence.benchmark-corpus.spirv.sample.json",
    ]
    assert [item["path"] for item in bundle_evidence["componentReceipts"]["phaseBenchmarks"]] == [
        "examples/tint-phase-benchmark-evidence.browser-corpus.spirv.sample.json",
        "examples/tint-phase-benchmark-evidence.benchmark-corpus.spirv.sample.json",
    ]
    assert target_validations[0]["claimBlockerSummaryByEvidencePath"] == [
        {
            "evidencePath": "examples/tint-compiler-evidence.browser-corpus.spirv.sample.json",
            "claimBlockerSummary": [],
        },
        {
            "evidencePath": "examples/tint-compiler-evidence.benchmark-corpus.spirv.sample.json",
            "claimBlockerSummary": [],
        }
    ]


def test_compiler_readiness_can_use_custom_frontier_bundle_path() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "compiler-frontier.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        bundle = _load(REPO_ROOT / "examples" / "tint-compiler-frontier-bundle.sample.json")
        bundle["claimBlockers"] = [
            blocker
            for blocker in bundle["claimBlockers"]
            if blocker["code"] != "shader_artifact_validation_for_target_backends"
        ]
        bundle["summary"]["claimBlockerCount"] = len(bundle["claimBlockers"])
        target_validation = bundle["componentReceipts"]["targetValidations"][0]
        target_validation["summary"]["claimBlockerCount"] = 0
        target_validation["claimBlockerSummary"] = []
        target_validation["claimBlockerSummaryByEvidencePath"] = [
            {
                "evidencePath": "examples/tint-compiler-evidence.browser-corpus.spirv.sample.json",
                "claimBlockerSummary": [],
            },
            {
                "evidencePath": "examples/tint-compiler-evidence.benchmark-corpus.spirv.sample.json",
                "claimBlockerSummary": [],
            }
        ]
        custom_path.write_text(json.dumps(bundle, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(tint_bundle_path=custom_rel),
        )

    compiler_row = next(row for row in report["rows"] if row["id"] == "wgsl-tint-compiler")
    blocker_codes = [blocker["code"] for blocker in compiler_row["blockers"]]

    assert compiler_row["frontierBundleEvidence"]["path"] == custom_rel.as_posix()
    assert blocker_codes == ["claimable_tint_compiler_evidence_report"]


def test_compiler_readiness_flags_frontier_bundle_malformed_compiler_evidence_reports() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload.update({"compilerEvidenceReports": {"path": "bad"}}),
        code="frontier_bundle_compiler_evidence_reports_malformed",
        path="frontierBundleEvidence.compilerEvidenceReports",
        message="Tint compiler frontier bundle compilerEvidenceReports must be a list",
    )


def test_compiler_readiness_flags_frontier_bundle_malformed_compiler_evidence_report_item() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["compilerEvidenceReports"][0].update({"rowCount": True}),
        code="frontier_bundle_compiler_evidence_report_items_malformed",
        path="frontierBundleEvidence.compilerEvidenceReports[0].rowCount",
        message=(
            "Tint compiler frontier bundle compilerEvidenceReports[0]."
            "rowCount must be a non-negative integer"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_missing_compiler_evidence_hash() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["compilerEvidenceReports"][0].pop("sha256"),
        code="frontier_bundle_compiler_evidence_report_items_malformed",
        path="frontierBundleEvidence.compilerEvidenceReports[0].sha256",
        message=(
            "Tint compiler frontier bundle compilerEvidenceReports[0]."
            "sha256 is required"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_stale_compiler_evidence_hash() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["compilerEvidenceReports"][0].update({"sha256": "0" * 64}),
        code="frontier_bundle_compiler_evidence_report_hash_mismatch",
        path="frontierBundleEvidence.compilerEvidenceReports[0].sha256",
        message=(
            "Tint compiler frontier bundle compilerEvidenceReports[0]."
            "sha256 must match referenced file bytes"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_unsafe_compiler_evidence_path() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["compilerEvidenceReports"][0].update(
            {"path": "../outside.json"}
        ),
        code="frontier_bundle_compiler_evidence_report_path_unsafe",
        path="frontierBundleEvidence.compilerEvidenceReports[0].path",
        message=(
            "Tint compiler frontier bundle compilerEvidenceReports[0]."
            "path path must not contain empty, current, or parent segments"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_malformed_compiler_evidence_report_summary() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["compilerEvidenceReports"][0]["claimBlockerSummary"][
            0
        ].update({"count": 0}),
        code="frontier_bundle_compiler_evidence_report_items_malformed",
        path="frontierBundleEvidence.compilerEvidenceReports[0].claimBlockerSummary",
        message=(
            "Tint compiler frontier bundle compilerEvidenceReports[0]."
            "claimBlockerSummary entries must have code, message, and positive count"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_malformed_required_targets() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload.update({"requiredTargets": ["spirv", "spirv"]}),
        code="frontier_bundle_required_targets_malformed",
        path="frontierBundleEvidence.requiredTargets",
        message=(
            "Tint compiler frontier bundle requiredTargets must be a "
            "non-empty unique target list"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_stale_claim_blocker_count() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["summary"].update({"claimBlockerCount": 0}),
        code="frontier_bundle_summary_claim_blocker_count_mismatch",
        path="frontierBundleEvidence.summary.claimBlockerCount",
        message="frontier bundle summary claimBlockerCount must match claimBlockers length",
    )


def test_compiler_readiness_flags_frontier_bundle_stale_failure_count() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["summary"].update({"failureCount": 1}),
        code="frontier_bundle_summary_failure_count_mismatch",
        path="frontierBundleEvidence.summary.failureCount",
        message="frontier bundle summary failureCount must match failures length",
    )


def test_compiler_readiness_flags_frontier_bundle_malformed_coverage_by_target() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload.update({"coverageByTarget": {"target": "spirv"}}),
        code="frontier_bundle_coverage_by_target_malformed",
        path="frontierBundleEvidence.coverageByTarget",
        message="Tint compiler frontier bundle coverageByTarget must be a list",
    )


def test_compiler_readiness_flags_frontier_bundle_malformed_phase_timing_coverage() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload.update({"phaseTimingCoverage": []}),
        code="frontier_bundle_phase_timing_coverage_malformed",
        path="frontierBundleEvidence.phaseTimingCoverage",
        message="Tint compiler frontier bundle phaseTimingCoverage must be an object",
    )


def test_compiler_readiness_flags_frontier_bundle_stale_phase_timing_coverage_sum() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["phaseTimingCoverage"].update({"rowCount": 0}),
        code="frontier_bundle_phase_timing_coverage_items_malformed",
        path="frontierBundleEvidence.phaseTimingCoverage.rowCount",
        message=(
            "Tint compiler frontier bundle phaseTimingCoverage.rowCount "
            "must match coverageByEvidencePath sum"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_missing_component_receipt() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["componentReceipts"].pop("phaseBenchmarks"),
        code="frontier_bundle_tint_component_receipt_missing",
        path="frontierBundleEvidence.componentReceipts.phaseBenchmarks",
        message="Tint compiler frontier bundle componentReceipts.phaseBenchmarks is required",
    )


def test_compiler_readiness_flags_frontier_bundle_malformed_component_receipt() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["componentReceipts"].update({"loweringLinks": {}}),
        code="frontier_bundle_tint_component_receipt_malformed",
        path="frontierBundleEvidence.componentReceipts.loweringLinks",
        message="Tint compiler frontier bundle componentReceipts.loweringLinks must be a list",
    )


def test_compiler_readiness_flags_frontier_bundle_malformed_lowering_link_receipt() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["componentReceipts"]["loweringLinks"][0].update(
            {"linkedRows": True}
        ),
        code="frontier_bundle_tint_component_receipt_items_malformed",
        path="frontierBundleEvidence.componentReceipts.loweringLinks[0].linkedRows",
        message=(
            "Tint compiler frontier bundle componentReceipts.loweringLinks[0]."
            "linkedRows must be a non-negative integer"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_missing_component_evidence_paths() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["componentReceipts"]["targetValidations"][0].pop(
            "evidencePaths"
        ),
        code="frontier_bundle_tint_component_receipt_items_malformed",
        path="frontierBundleEvidence.componentReceipts.targetValidations[0].evidencePaths",
        message=(
            "Tint compiler frontier bundle componentReceipts."
            "targetValidations[0].evidencePaths is required"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_missing_component_hash() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["componentReceipts"]["targetValidations"][0].pop("sha256"),
        code="frontier_bundle_tint_component_receipt_items_malformed",
        path="frontierBundleEvidence.componentReceipts.targetValidations[0].sha256",
        message=(
            "Tint compiler frontier bundle componentReceipts."
            "targetValidations[0].sha256 is required"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_stale_component_hash() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["componentReceipts"]["targetValidations"][0].update(
            {"sha256": "0" * 64}
        ),
        code="frontier_bundle_tint_component_receipt_hash_mismatch",
        path="frontierBundleEvidence.componentReceipts.targetValidations[0].sha256",
        message=(
            "Tint compiler frontier bundle componentReceipts."
            "targetValidations[0].sha256 must match referenced file bytes"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_unsafe_component_path() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["componentReceipts"]["targetValidations"][0].update(
            {"path": "/tmp/target-validation.json"}
        ),
        code="frontier_bundle_tint_component_receipt_path_unsafe",
        path="frontierBundleEvidence.componentReceipts.targetValidations[0].path",
        message=(
            "Tint compiler frontier bundle componentReceipts."
            "targetValidations[0].path path must be repository-relative"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_malformed_target_validation_receipt() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["componentReceipts"]["targetValidations"][0].update(
            {
                "claimBlockerSummary": [
                    {
                        "code": "doe_result_not_ok",
                        "message": "Doe compiler result is not ok",
                        "count": 0,
                    }
                ]
            }
        ),
        code="frontier_bundle_tint_component_receipt_items_malformed",
        path="frontierBundleEvidence.componentReceipts.targetValidations[0].claimBlockerSummary",
        message=(
            "Tint compiler frontier bundle componentReceipts.targetValidations[0]."
            "claimBlockerSummary entries must have code, message, and positive count"
        ),
    )


def test_compiler_readiness_flags_frontier_bundle_malformed_phase_benchmark_receipt() -> None:
    _assert_malformed_tint_frontier_field(
        lambda payload: payload["componentReceipts"]["phaseBenchmarks"][0].update(
            {"targets": ["spirv", "bad"]}
        ),
        code="frontier_bundle_tint_component_receipt_items_malformed",
        path="frontierBundleEvidence.componentReceipts.phaseBenchmarks[0].targets",
        message=(
            "Tint compiler frontier bundle componentReceipts.phaseBenchmarks[0]."
            "targets must be a target list"
        ),
    )


def test_browser_readiness_flags_dirty_claimable_runtime_frontier_bundle() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["status"] = "fail"
        payload["claimabilityStatus"] = "claimable"
        payload["failures"] = [
            {
                "code": "release_bundle_not_claimable",
                "path": "componentReceipts.releaseArtifactBundle",
                "message": "release bundle must be claimable",
            }
        ]
        payload["claimBlockers"] = [
            {
                "code": "chromium_release_build_evidence",
                "path": "releaseBundle.releaseStatus",
                "message": "browser release artifact bundle must be a release_candidate",
            }
        ]
        payload["claimBlockerSummary"] = [
            {
                "code": "chromium_release_build_evidence",
                "message": "browser release artifact bundle must be a release_candidate",
                "count": 1,
            }
        ]
        payload["summary"]["failureCount"] = 1
        payload["summary"]["claimBlockerCount"] = 1
        component_receipts = payload["componentReceipts"]
        component_receipts["runtimeIdentity"]["selectedRuntime"] = "dawn"
        component_receipts["claimPromotionReceipt"]["promotionStatus"] = "diagnostic"
        component_receipts["releaseArtifactBundle"]["releaseStatus"] = "diagnostic"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]
    failure_codes = {item["code"] for item in consistency["failures"]}

    assert consistency["status"] == "fail"
    assert failure_codes.issuperset({
        "runtime_frontier_bundle_not_pass",
        "runtime_frontier_bundle_failures_present",
        "runtime_frontier_bundle_claim_blockers_present",
        "runtime_frontier_bundle_claim_blocker_summary_present",
        "runtime_frontier_bundle_summary_not_clean",
        "runtime_frontier_bundle_runtime_identity_mismatch",
        "runtime_frontier_bundle_promotion_mismatch",
        "runtime_frontier_bundle_release_component_mismatch",
    })


def test_browser_readiness_flags_runtime_frontier_bundle_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["artifactKind"] = "browser_runtime_frontier_bundle_preview"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    bundle_evidence = browser_row["frontierBundleEvidence"]
    consistency = bundle_evidence["consistency"]

    assert bundle_evidence["path"] == custom_rel.as_posix()
    assert bundle_evidence["artifactKind"] == "browser_runtime_frontier_bundle_preview"
    assert bundle_evidence["status"] == "fail"
    assert bundle_evidence["claimabilityStatus"] == "blocked"
    assert "releaseCandidateEvidence" not in bundle_evidence
    assert consistency["status"] == "fail"
    assert {
        "code": "frontier_bundle_artifact_kind_mismatch",
        "path": "frontierBundleEvidence.artifactKind",
        "message": "frontier bundle artifactKind must be browser_runtime_frontier_bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_claim_blockers() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["claimBlockers"] = {"code": "chromium_release_build_evidence"}
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    bundle_evidence = browser_row["frontierBundleEvidence"]
    consistency = bundle_evidence["consistency"]

    assert bundle_evidence["path"] == custom_rel.as_posix()
    assert bundle_evidence["artifactKind"] == "browser_runtime_frontier_bundle"
    assert bundle_evidence["status"] == "fail"
    assert bundle_evidence["claimabilityStatus"] == "blocked"
    assert bundle_evidence["claimBlockers"] == []
    assert "releaseCandidateEvidence" not in bundle_evidence
    assert consistency["status"] == "fail"
    assert {
        "code": "frontier_bundle_claim_blockers_malformed",
        "path": "frontierBundleEvidence.claimBlockers",
        "message": "frontier bundle claimBlockers must be a list",
    } in consistency["failures"]


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_claim_blocker_items() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload["claimBlockers"][0].pop("path"),
        code="frontier_bundle_claim_blocker_items_malformed",
        path="frontierBundleEvidence.claimBlockers",
        message="frontier bundle claimBlockers entries must have code, path, and message",
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_status() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload.update({"status": "diagnostic"}),
        code="frontier_bundle_status_malformed",
        path="frontierBundleEvidence.status",
        message="frontier bundle status must be pass or fail",
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_claimability_status() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload.update({"claimabilityStatus": "diagnostic"}),
        code="frontier_bundle_claimability_status_malformed",
        path="frontierBundleEvidence.claimabilityStatus",
        message="frontier bundle claimabilityStatus must be claimable or blocked",
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_summary() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload.update({"summary": ["claimBlockerCount"]}),
        code="frontier_bundle_summary_malformed",
        path="frontierBundleEvidence.summary",
        message="frontier bundle summary must be an object",
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_summary_values() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload["summary"].update({"nested": {"claimBlockerCount": 1}}),
        code="frontier_bundle_summary_values_malformed",
        path="frontierBundleEvidence.summary",
        message="frontier bundle summary values must be scalar",
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_claim_blocker_summary() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload.update({"claimBlockerSummary": {"count": 1}}),
        code="frontier_bundle_claim_blocker_summary_malformed",
        path="frontierBundleEvidence.claimBlockerSummary",
        message="frontier bundle claimBlockerSummary must be a list",
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_claim_blocker_summary_items() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload.update(
            {
                "claimBlockerSummary": [
                    {
                        "code": "chromium_release_build_evidence",
                        "message": "browser release artifact bundle must be a release_candidate",
                        "count": 0,
                    }
                ]
            }
        ),
        code="frontier_bundle_claim_blocker_summary_items_malformed",
        path="frontierBundleEvidence.claimBlockerSummary",
        message=(
            "frontier bundle claimBlockerSummary entries must have code, "
            "message, and positive count"
        ),
    )


def test_browser_readiness_flags_runtime_frontier_bundle_missing_claim_blocker_summary() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload.pop("claimBlockerSummary"),
        code="frontier_bundle_claim_blocker_summary_missing",
        path="frontierBundleEvidence.claimBlockerSummary",
        message="browser runtime frontier bundle claimBlockerSummary is required",
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_failures() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload.update({"failures": {"code": "runtime_frontier_bundle"}}),
        code="frontier_bundle_failures_malformed",
        path="frontierBundleEvidence.failures",
        message="frontier bundle failures must be a list",
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_failure_items() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload.update(
            {
                "failures": [
                    {
                        "code": "runtime_frontier_bundle",
                        "path": "",
                        "message": "frontier bundle failure",
                    }
                ]
            }
        ),
        code="frontier_bundle_failures_items_malformed",
        path="frontierBundleEvidence.failures",
        message="frontier bundle failures entries must have code, path, and message",
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_component_receipts() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload.update({"componentReceipts": ["runtimeIdentity"]}),
        code="frontier_bundle_component_receipts_malformed",
        path="frontierBundleEvidence.componentReceipts",
        message="frontier bundle componentReceipts must be an object",
    )


def test_browser_readiness_flags_runtime_frontier_bundle_missing_component_receipt() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload["componentReceipts"].pop("releaseArtifactBundle"),
        code="frontier_bundle_component_receipt_missing",
        path="frontierBundleEvidence.componentReceipts.releaseArtifactBundle",
        message=(
            "browser runtime frontier bundle componentReceipts."
            "releaseArtifactBundle is required"
        ),
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_component_receipt() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload["componentReceipts"].update({"runtimeIdentity": "doe"}),
        code="frontier_bundle_component_receipt_malformed",
        path="frontierBundleEvidence.componentReceipts.runtimeIdentity",
        message=(
            "browser runtime frontier bundle componentReceipts."
            "runtimeIdentity must be an object"
        ),
    )


def test_browser_readiness_flags_runtime_frontier_bundle_missing_component_receipt_field() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload["componentReceipts"]["runtimeIdentity"].pop("status"),
        code="frontier_bundle_component_receipt_field_malformed",
        path="frontierBundleEvidence.componentReceipts.runtimeIdentity.status",
        message=(
            "browser runtime frontier bundle componentReceipts."
            "runtimeIdentity.status is required"
        ),
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_promotion_field() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload["componentReceipts"]["claimPromotionReceipt"].update(
            {"artifactCount": True}
        ),
        code="frontier_bundle_component_receipt_field_malformed",
        path="frontierBundleEvidence.componentReceipts.claimPromotionReceipt.artifactCount",
        message=(
            "browser runtime frontier bundle componentReceipts."
            "claimPromotionReceipt.artifactCount must be a non-negative integer"
        ),
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_release_field() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload["componentReceipts"]["releaseArtifactBundle"].update(
            {"claimReports": {}}
        ),
        code="frontier_bundle_component_receipt_field_malformed",
        path="frontierBundleEvidence.componentReceipts.releaseArtifactBundle.claimReports",
        message=(
            "browser runtime frontier bundle componentReceipts."
            "releaseArtifactBundle.claimReports must be a list"
        ),
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_release_verification() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload["componentReceipts"]["releaseArtifactBundle"][
            "artifactVerification"
        ].update({"requiredForClaimable": False}),
        code="frontier_bundle_component_receipt_field_malformed",
        path=(
            "frontierBundleEvidence.componentReceipts."
            "releaseArtifactBundle.artifactVerification.requiredForClaimable"
        ),
        message=(
            "browser runtime frontier bundle componentReceipts."
            "releaseArtifactBundle.artifactVerification.requiredForClaimable must be true"
        ),
    )


def test_browser_readiness_flags_runtime_frontier_bundle_malformed_release_claim_report() -> None:
    _assert_malformed_browser_frontier_field(
        lambda payload: payload["componentReceipts"]["releaseArtifactBundle"]["claimReports"][
            0
        ].update({"workloadCount": True}),
        code="frontier_bundle_component_receipt_field_malformed",
        path=(
            "frontierBundleEvidence.componentReceipts."
            "releaseArtifactBundle.claimReports[0].workloadCount"
        ),
        message=(
            "browser runtime frontier bundle componentReceipts."
            "releaseArtifactBundle.claimReports[0].workloadCount "
            "must be a non-negative integer"
        ),
    )


def test_browser_readiness_flags_runtime_frontier_promotion_path_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["claimabilityStatus"] = "claimable"
        payload["claimBlockers"] = []
        payload["claimBlockerSummary"] = []
        payload["summary"]["claimBlockerCount"] = 0
        release_summary = payload["componentReceipts"]["releaseArtifactBundle"]
        release_summary["releaseStatus"] = "release_candidate"
        promotion_summary = payload["componentReceipts"]["claimPromotionReceipt"]
        promotion_summary["path"] = "examples/browser-claim-promotion-receipt.other.json"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "runtime_frontier_bundle_promotion_mismatch",
        "path": "frontierBundleEvidence.componentReceipts.claimPromotionReceipt",
        "message": "claimable browser runtime frontier bundle must bind a release-bundled promotable claim-promotion component",
    } in consistency["failures"]


def test_browser_readiness_flags_runtime_frontier_empty_release_promotion_receipts() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["promotionReceipts"] = []
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["claimabilityStatus"] = "claimable"
        payload["claimBlockers"] = []
        payload["claimBlockerSummary"] = []
        payload["summary"]["claimBlockerCount"] = 0
        release_summary = payload["componentReceipts"]["releaseArtifactBundle"]
        release_summary["path"] = release_rel.as_posix()
        release_summary["releaseStatus"] = "release_candidate"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "runtime_frontier_bundle_promotion_mismatch",
        "path": "frontierBundleEvidence.componentReceipts.claimPromotionReceipt",
        "message": "claimable browser runtime frontier bundle must bind a release-bundled promotable claim-promotion component",
    } in consistency["failures"]


def test_browser_readiness_flags_release_runtime_frontier_bundle_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["runtimeFrontierBundle"]["sha256"] = "f" * 64
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        release_summary = payload["componentReceipts"]["releaseArtifactBundle"]
        release_summary["path"] = release_rel.as_posix()
        release_summary["sha256"] = report_builder.sha256_file(release_path)
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_runtime_frontier_bundle_mismatch",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.runtimeFrontierBundle",
        "message": "release artifact bundle runtimeFrontierBundle must match the readiness runtime frontier bundle path and hash",
    } in consistency["failures"]


def test_browser_readiness_flags_missing_release_artifact_bundle() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["componentReceipts"]["releaseArtifactBundle"]["path"] = (
            Path(tmpdir) / "missing-browser-release-artifact-bundle.json"
        ).relative_to(REPO_ROOT).as_posix()
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_artifact_bundle_missing",
        "path": "frontierBundleEvidence.componentReceipts.releaseArtifactBundle.path",
        "message": "runtime frontier bundle must identify a readable browser release artifact bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_release_artifact_bundle_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["artifactKind"] = "browser_release_artifact_bundle_preview"
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["componentReceipts"]["releaseArtifactBundle"]["path"] = release_rel.as_posix()
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "releaseSupportArtifacts" not in release_candidate
    assert consistency["status"] == "fail"
    assert {
        "code": "release_artifact_bundle_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.artifactKind",
        "message": "browser release artifact bundle artifactKind must be browser_release_artifact_bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_missing_release_support_policy_kind() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["policies"] = [
            policy
            for policy in release_payload["policies"]
            if policy.get("kind") != "browser_unsupported_reason_taxonomy"
        ]
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["componentReceipts"]["releaseArtifactBundle"]["path"] = release_rel.as_posix()
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "browser_unsupported_reason_taxonomy" not in release_candidate["releaseSupportArtifacts"]["policyKinds"]
    assert {
        "code": "release_support_policy_kind_missing",
        "path": "releaseCandidateEvidence.releaseSupportArtifacts.policies",
        "message": "release artifact bundle must include support artifact kind browser_unsupported_reason_taxonomy",
    } in consistency["failures"]


def test_browser_readiness_flags_release_support_artifact_hash_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["policies"][0]["sha256"] = "0" * 64
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["componentReceipts"]["releaseArtifactBundle"]["path"] = release_rel.as_posix()
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "release_support_artifact_hash_mismatch",
        "path": "releaseCandidateEvidence.releaseSupportArtifacts.policies[0].sha256",
        "message": "release support artifact sha256 must match referenced file bytes",
    } in consistency["failures"]


def test_browser_readiness_flags_release_support_artifact_path_unsafe() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir, tempfile.TemporaryDirectory() as outside_dir:
        outside_policy = Path(outside_dir) / "browser-claim-policy.json"
        outside_policy.write_bytes((REPO_ROOT / "config" / "browser-claim-policy.json").read_bytes())
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["policies"][0]["path"] = outside_policy.as_posix()
        release_payload["policies"][0]["sha256"] = report_builder.sha256_file(outside_policy)
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["componentReceipts"]["releaseArtifactBundle"]["path"] = release_rel.as_posix()
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "release_support_artifact_path_unsafe",
        "path": "releaseCandidateEvidence.releaseSupportArtifacts.policies[0].path",
        "message": "release support artifact path must be repository-relative",
    } in consistency["failures"]


def test_browser_readiness_flags_release_artifact_bundle_failure_codes() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["releaseStatus"] = "release_candidate"
        release_payload["failureCodes"] = ["release_bundle_not_claimable"]
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        release_summary = payload["componentReceipts"]["releaseArtifactBundle"]
        release_summary["path"] = release_rel.as_posix()
        release_summary["releaseStatus"] = "release_candidate"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "release_artifact_bundle_failures_present",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.failureCodes",
        "message": "release artifact bundle failureCodes must be empty for release-candidate evidence",
    } in consistency["failures"]


def test_browser_readiness_flags_release_artifact_bundle_product_id_invalid() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["browserProduct"]["productId"] = "other-browser"
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["componentReceipts"]["releaseArtifactBundle"]["path"] = release_rel.as_posix()
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "release_artifact_bundle_browser_product_id_invalid",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.browserProduct.productId",
        "message": "release artifact bundle browserProduct.productId must be doe-browser or fawn-doe",
    } in consistency["failures"]


def test_browser_readiness_flags_release_candidate_platform_not_macos_arm64() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["releaseStatus"] = "release_candidate"
        release_payload["browserProduct"]["channel"] = "release_candidate"
        release_payload["platform"]["arch"] = "x64"
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        release_summary = payload["componentReceipts"]["releaseArtifactBundle"]
        release_summary["path"] = release_rel.as_posix()
        release_summary["releaseStatus"] = "release_candidate"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "release_artifact_bundle_platform_not_macos_arm64",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.platform",
        "message": "initial release candidates must target macOS arm64 zip",
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_app_metadata_product_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        metadata = {
            "browserProduct": dict(release_payload["browserProduct"]),
            "platform": release_payload["platform"],
            "browserExecutableArchivePath": release_payload["browserExecutableArchivePath"],
            "doeRuntimeArchivePath": release_payload["doeRuntimeArchivePath"],
            "dawnFallbackRuntimeArchivePath": release_payload["dawnFallbackRuntimeArchivePath"],
        }
        metadata["browserProduct"]["displayName"] = "Other Browser"
        archive_path = _write_release_archive_with_member_data(
            tmpdir,
            release_payload["browserAppMetadataArchivePath"],
            json.dumps(metadata, sort_keys=True).encode("utf-8"),
        )
        archive_rel = archive_path.relative_to(REPO_ROOT)
        release_payload["releaseArchive"]["path"] = archive_rel.as_posix()
        release_payload["releaseArchive"]["sha256"] = report_builder.sha256_file(archive_path)
        report = _build_report_with_release_bundle_payload(Path(tmpdir), release_payload)

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "release_archive_app_metadata_product_mismatch",
        "path": "releaseCandidateEvidence.releaseArchiveAppMetadata.browserProduct",
        "message": "browser metadata browserProduct must match the release artifact bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_non_macos_release_archive_app_metadata_runtime_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["platform"] = {
            "os": "linux",
            "arch": "x64",
            "packageFormat": "zip",
        }
        release_payload["browserExecutableArchivePath"] = "Fawn-Doe-linux-x64/fawn-doe"
        release_payload["browserAppMetadataArchivePath"] = "Fawn-Doe-linux-x64/browser-metadata.json"
        release_payload["doeRuntimeArchivePath"] = "Fawn-Doe-linux-x64/libwebgpu_doe.so"
        release_payload["dawnFallbackRuntimeArchivePath"] = "Fawn-Doe-linux-x64/libwebgpu_dawn.so"
        metadata = {
            "browserProduct": release_payload["browserProduct"],
            "platform": release_payload["platform"],
            "browserExecutableArchivePath": release_payload["browserExecutableArchivePath"],
            "doeRuntimeArchivePath": "Fawn-Doe-linux-x64/libwebgpu_doe_stale.so",
            "dawnFallbackRuntimeArchivePath": release_payload["dawnFallbackRuntimeArchivePath"],
        }
        archive_path = _write_release_archive_with_browser_metadata(
            tmpdir,
            release_payload["browserAppMetadataArchivePath"],
            metadata,
        )
        archive_rel = archive_path.relative_to(REPO_ROOT)

        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload["releaseArchive"]["path"] = archive_rel.as_posix()
        release_payload["releaseArchive"]["sha256"] = report_builder.sha256_file(archive_path)
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        payload["componentReceipts"]["releaseArtifactBundle"]["path"] = release_rel.as_posix()
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "release_archive_app_metadata_doe_runtime_mismatch",
        "path": "releaseCandidateEvidence.releaseArchiveAppMetadata.doeRuntimeArchivePath",
        "message": "browser metadata doeRuntimeArchivePath must match the release artifact bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_non_macos_release_archive_app_metadata_path_with_current_segment() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        unsafe_path = "Fawn-Doe-linux-x64/./browser-metadata.json"
        release_bundle["platform"] = {
            "os": "linux",
            "arch": "x64",
            "packageFormat": "zip",
        }
        release_bundle["browserAppMetadataArchivePath"] = unsafe_path

        report = _build_report_with_release_bundle_payload(tmp_path, release_bundle)

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_app_metadata_path_unsafe",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
        "message": f"browser metadata archive path must be relative and safe: {unsafe_path}",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_check_status_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-candidate-finalizer-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-candidate-finalizer-check.sample.json")
        payload["finalizerStatus"] = "pass"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_finalizer_check_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "finalizer_check_status_mismatch",
        "path": "releaseCandidateEvidence.finalizerCheck.finalizerStatus",
        "message": "finalizer-check receipt finalizerStatus must match the finalizer report status",
    } in consistency["failures"]
    assert {
        item["code"] for item in consistency["failures"]
    }.issuperset({
        "release_artifact_bundle_not_release_candidate",
        "provenance_report_not_pass",
        "finalizer_report_not_pass",
        "finalizer_check_not_pass",
        "finalizer_check_status_mismatch",
        "package_inputs_not_release_candidate_eligible",
        "package_inputs_not_release_candidate",
        "package_inputs_blockers_present",
    })


def test_browser_readiness_flags_finalizer_check_report_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-candidate-finalizer-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-candidate-finalizer-check.sample.json")
        payload["finalizerReportSha256"] = "0" * 64
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_finalizer_check_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "finalizer_check_report_mismatch",
        "path": "releaseCandidateEvidence.finalizerCheck.finalizerReportPath",
        "message": "finalizer-check receipt must bind the same finalizer report path and hash as release-candidate evidence",
    } in consistency["failures"]


def test_browser_readiness_flags_failing_finalizer_check() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-candidate-finalizer-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-candidate-finalizer-check.sample.json")
        payload["status"] = "fail"
        payload["failures"] = [
            {
                "code": "finalizer_report_not_pass",
                "path": "status",
                "message": "browser release-candidate finalizer report must pass",
            }
        ]
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_finalizer_check_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "finalizer_check_not_pass",
        "path": "releaseCandidateEvidence.finalizerCheck.status",
        "message": "release-candidate finalizer check must pass",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_check_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-candidate-finalizer-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-candidate-finalizer-check.sample.json")
        payload["artifactKind"] = "browser_release_candidate_finalizer_check_preview"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_finalizer_check_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "finalizerCheck" not in release_candidate
    assert consistency["status"] == "fail"
    assert {
        "code": "finalizer_check_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.finalizerCheck.artifactKind",
        "message": "finalizer-check receipt artifactKind must be browser_release_candidate_finalizer_check",
    } in consistency["failures"]


def _write_passing_finalizer_pair(
    tmpdir: str,
    *,
    release_output_sha256: str | None = None,
    runtime_frontier_output_sha256: str | None = None,
    package_inputs_sha256: str | None = None,
    include_package_inputs: bool = True,
    provenance_report_sha256: str | None = None,
    include_provenance_report: bool = True,
    finalizer_failures: list[dict[str, str]] | None = None,
    finalizer_summary_claimability_status: str = "blocked",
    finalizer_summary_failure_count: int = 0,
    finalizer_check_failures: list[dict[str, str]] | None = None,
) -> tuple[Path, Path]:
    tmp_path = Path(tmpdir)
    finalizer_path = tmp_path / "browser-release-candidate-finalizer.json"
    finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
    release_bundle_path = Path("examples/browser-release-artifact-bundle.sample.json")
    runtime_frontier_path = Path("examples/browser-runtime-frontier-bundle.sample.json")
    package_inputs_path = Path("examples/browser-release-package-inputs-check.sample.json")
    provenance_report_path = Path("examples/browser-release-candidate-provenance.sample.json")
    release_bundle_payload = _load(REPO_ROOT / release_bundle_path)
    release_bundle_sha256 = report_builder.sha256_file(REPO_ROOT / release_bundle_path)
    runtime_frontier_sha256 = report_builder.sha256_file(REPO_ROOT / runtime_frontier_path)
    package_inputs_default_sha256 = report_builder.sha256_file(
        REPO_ROOT / package_inputs_path
    )
    provenance_report_default_sha256 = report_builder.sha256_file(
        REPO_ROOT / provenance_report_path
    )
    inputs = {}
    if include_package_inputs:
        inputs["packageInputs"] = {
            "path": package_inputs_path.as_posix(),
            "sha256": package_inputs_sha256 or package_inputs_default_sha256,
            "kind": "browser_release_package_inputs_check",
        }
    if include_provenance_report:
        inputs["provenanceReport"] = {
            "path": provenance_report_path.as_posix(),
            "sha256": provenance_report_sha256 or provenance_report_default_sha256,
            "kind": "browser_release_candidate_provenance_report",
        }
    payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_candidate_finalizer",
        "status": "pass",
        "outputs": {
            "releaseArtifactBundle": {
                "path": release_bundle_path.as_posix(),
                "sha256": release_output_sha256 or release_bundle_sha256,
                "kind": "browser_release_artifact_bundle",
            },
            "runtimeFrontierBundle": {
                "path": runtime_frontier_path.as_posix(),
                "sha256": runtime_frontier_output_sha256 or runtime_frontier_sha256,
                "kind": "browser_runtime_frontier_bundle",
            },
        },
        "inputs": inputs,
        "summary": {
            "claimabilityStatus": finalizer_summary_claimability_status,
            "releaseBundleIdentitySha256": report_builder.release_bundle_identity_sha256(
                release_bundle_payload
            ),
            "failureCount": finalizer_summary_failure_count,
        },
    }
    if finalizer_failures is not None:
        payload["failures"] = finalizer_failures
    finalizer_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    check_path = tmp_path / "browser-release-candidate-finalizer-check.json"
    if finalizer_check_failures is None:
        finalizer_check_failures = []
    check_payload = {
        "schemaVersion": 1,
        "artifactKind": "browser_release_candidate_finalizer_check",
        "status": "pass",
        "finalizerStatus": "pass",
        "finalizerReportPath": finalizer_rel.as_posix(),
        "finalizerReportSha256": report_builder.sha256_file(finalizer_path),
        "verifyFilesRootProvided": True,
        "requirePass": True,
        "outputs": payload["outputs"],
        "inputs": payload["inputs"],
        "failureCount": len(finalizer_check_failures),
        "failures": finalizer_check_failures,
    }
    check_path.write_text(json.dumps(check_payload, indent=2) + "\n", encoding="utf-8")
    return finalizer_path, check_path


def test_browser_readiness_summarizes_passing_finalizer_outputs() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(tmpdir)
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    finalizer = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["finalizerReport"]
    failure_codes = {
        item["code"]
        for item in browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]["failures"]
    }

    assert finalizer["status"] == "pass"
    assert finalizer["outputs"]["releaseArtifactBundle"] == {
        "path": "examples/browser-release-artifact-bundle.sample.json",
        "sha256": report_builder.sha256_file(
            REPO_ROOT / "examples/browser-release-artifact-bundle.sample.json"
        ),
        "kind": "browser_release_artifact_bundle",
    }
    assert finalizer["outputs"]["runtimeFrontierBundle"] == {
        "path": "examples/browser-runtime-frontier-bundle.sample.json",
        "sha256": report_builder.sha256_file(
            REPO_ROOT / "examples/browser-runtime-frontier-bundle.sample.json"
        ),
        "kind": "browser_runtime_frontier_bundle",
    }
    assert finalizer["inputs"]["packageInputs"] == {
        "path": "examples/browser-release-package-inputs-check.sample.json",
        "sha256": report_builder.sha256_file(
            REPO_ROOT / "examples/browser-release-package-inputs-check.sample.json"
        ),
        "kind": "browser_release_package_inputs_check",
    }
    assert finalizer["inputs"]["provenanceReport"] == {
        "path": "examples/browser-release-candidate-provenance.sample.json",
        "sha256": report_builder.sha256_file(
            REPO_ROOT / "examples/browser-release-candidate-provenance.sample.json"
        ),
        "kind": "browser_release_candidate_provenance_report",
    }
    assert "finalizer_release_output_mismatch" not in failure_codes
    assert "finalizer_runtime_frontier_output_mismatch" not in failure_codes
    assert "finalizer_package_inputs_mismatch" not in failure_codes
    assert "finalizer_provenance_report_mismatch" not in failure_codes


def test_browser_readiness_summarizes_passing_finalizer_check_bindings() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(tmpdir)
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    finalizer = release_candidate["finalizerReport"]
    finalizer_check = release_candidate["finalizerCheck"]
    failure_codes = {
        item["code"]
        for item in release_candidate["consistency"]["failures"]
    }

    assert finalizer_check["outputs"] == finalizer["outputs"]
    assert finalizer_check["inputs"] == finalizer["inputs"]
    assert "finalizer_check_outputs_missing" not in failure_codes
    assert "finalizer_check_inputs_missing" not in failure_codes
    assert "finalizer_check_release_output_mismatch" not in failure_codes
    assert "finalizer_check_package_inputs_mismatch" not in failure_codes


def test_browser_readiness_flags_finalizer_check_binding_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(tmpdir)
        finalizer_check_payload = _load(finalizer_check_path)
        finalizer_check_payload["outputs"]["releaseArtifactBundle"]["sha256"] = "0" * 64
        finalizer_check_payload["inputs"]["provenanceReport"]["sha256"] = "1" * 64
        finalizer_check_path.write_text(
            json.dumps(finalizer_check_payload, indent=2) + "\n",
            encoding="utf-8",
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_check_release_output_mismatch",
        "path": "releaseCandidateEvidence.finalizerCheck.outputs.releaseArtifactBundle",
        "message": "finalizer-check releaseArtifactBundle output must match finalizer report output",
    } in consistency["failures"]
    assert {
        "code": "finalizer_check_provenance_report_mismatch",
        "path": "releaseCandidateEvidence.finalizerCheck.inputs.provenanceReport",
        "message": "finalizer-check provenanceReport input must match finalizer report input",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_check_binding_missing() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(tmpdir)
        finalizer_check_payload = _load(finalizer_check_path)
        del finalizer_check_payload["outputs"]
        del finalizer_check_payload["inputs"]
        finalizer_check_path.write_text(
            json.dumps(finalizer_check_payload, indent=2) + "\n",
            encoding="utf-8",
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_check_outputs_missing",
        "path": "releaseCandidateEvidence.finalizerCheck.outputs",
        "message": "passing finalizer-check receipt must bind checked finalizer output artifacts",
    } in consistency["failures"]
    assert {
        "code": "finalizer_check_inputs_missing",
        "path": "releaseCandidateEvidence.finalizerCheck.inputs",
        "message": "passing finalizer-check receipt must bind checked finalizer input artifacts",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_output_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(
            tmpdir,
            release_output_sha256="0" * 64,
            runtime_frontier_output_sha256="1" * 64,
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_release_output_mismatch",
        "path": "releaseCandidateEvidence.finalizerReport.outputs.releaseArtifactBundle",
        "message": "finalizer releaseArtifactBundle output must match the runtime frontier release bundle path and hash",
    } in consistency["failures"]
    assert {
        "code": "finalizer_runtime_frontier_output_mismatch",
        "path": "releaseCandidateEvidence.finalizerReport.outputs.runtimeFrontierBundle",
        "message": "finalizer runtimeFrontierBundle output must match the readiness runtime frontier bundle path and hash",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_package_input_missing() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(
            tmpdir,
            include_package_inputs=False,
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_package_inputs_missing",
        "path": "releaseCandidateEvidence.finalizerReport.inputs.packageInputs",
        "message": "passing finalizer report must bind input package-input evidence",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_package_input_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(
            tmpdir,
            package_inputs_sha256="0" * 64,
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_package_inputs_mismatch",
        "path": "releaseCandidateEvidence.finalizerReport.inputs.packageInputs",
        "message": "finalizer packageInputs input must match release-candidate package-input evidence",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_provenance_report_missing() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(
            tmpdir,
            include_provenance_report=False,
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_provenance_report_missing",
        "path": "releaseCandidateEvidence.finalizerReport.inputs.provenanceReport",
        "message": "passing finalizer report must bind input provenance-report evidence",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_provenance_report_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(
            tmpdir,
            provenance_report_sha256="0" * 64,
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_provenance_report_mismatch",
        "path": "releaseCandidateEvidence.finalizerReport.inputs.provenanceReport",
        "message": "finalizer provenanceReport input must match release-candidate provenance evidence",
    } in consistency["failures"]


def test_browser_readiness_flags_passing_finalizer_report_failures() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(
            tmpdir,
            finalizer_failures=[
                {
                    "code": "release_bundle_not_claimable",
                    "path": "summary.claimabilityStatus",
                    "message": "release bundle must be claimable",
                }
            ],
            finalizer_summary_failure_count=1,
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_report_failures_present",
        "path": "releaseCandidateEvidence.finalizerReport.failureCount",
        "message": "passing finalizer report must carry no failures",
    } in consistency["failures"]
    assert {
        "code": "finalizer_summary_failure_count_not_zero",
        "path": "releaseCandidateEvidence.finalizerReport.summary.failureCount",
        "message": "passing finalizer report summary failureCount must be zero",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_report_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-candidate-finalizer.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-candidate-finalizer.sample.json")
        payload["artifactKind"] = "browser_release_candidate_finalizer_preview"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_finalizer_report_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "finalizerReport" not in release_candidate
    assert consistency["status"] == "fail"
    assert {
        "code": "finalizer_report_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.finalizerReport.artifactKind",
        "message": "finalizer report artifactKind must be browser_release_candidate_finalizer",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_summary_claimability_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(
            tmpdir,
            finalizer_summary_claimability_status="claimable",
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_summary_claimability_mismatch",
        "path": "releaseCandidateEvidence.finalizerReport.summary.claimabilityStatus",
        "message": "finalizer summary claimabilityStatus must match the runtime frontier bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_finalizer_summary_release_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(tmpdir)
        finalizer_payload = _load(finalizer_path)
        finalizer_payload["summary"]["releaseBundleIdentitySha256"] = "0" * 64
        finalizer_path.write_text(
            json.dumps(finalizer_payload, indent=2) + "\n",
            encoding="utf-8",
        )

        finalizer_check_payload = _load(finalizer_check_path)
        finalizer_check_payload["finalizerReportSha256"] = report_builder.sha256_file(
            finalizer_path
        )
        finalizer_check_path.write_text(
            json.dumps(finalizer_check_payload, indent=2) + "\n",
            encoding="utf-8",
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_summary_release_identity_mismatch",
        "path": "releaseCandidateEvidence.finalizerReport.summary.releaseBundleIdentitySha256",
        "message": "finalizer summary releaseBundleIdentitySha256 must match the release artifact bundle identity",
    } in consistency["failures"]


def test_browser_readiness_flags_passing_finalizer_check_failures() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        finalizer_path, finalizer_check_path = _write_passing_finalizer_pair(
            tmpdir,
            finalizer_check_failures=[
                {
                    "code": "missing_finalizer_inputs",
                    "path": "inputs",
                    "message": "passing finalizer reports must bind inputs",
                }
            ],
        )
        finalizer_rel = finalizer_path.relative_to(REPO_ROOT)
        finalizer_check_rel = finalizer_check_path.relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_finalizer_report_path=finalizer_rel,
                browser_finalizer_check_path=finalizer_check_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "finalizer_check_failures_present",
        "path": "releaseCandidateEvidence.finalizerCheck.failureCount",
        "message": "passing finalizer-check receipt must carry no failures",
    } in consistency["failures"]


def test_browser_readiness_schema_accepts_package_input_preflight_phase() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-candidate-finalizer.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-candidate-finalizer.sample.json")
        payload["phase"] = "package_inputs_preflight"
        payload["failures"] = [
            {
                "code": "package_inputs_not_release_candidate_eligible",
                "path": "packageInputs.releaseCandidateEligible",
                "message": "package inputs must be release-candidate eligible before final bundle assembly",
            }
        ]
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_finalizer_report_path=custom_rel),
        )

    jsonschema.validate(report, _load(READINESS_SCHEMA_PATH))
    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    finalizer = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["finalizerReport"]
    assert finalizer["phase"] == "package_inputs_preflight"


def test_browser_readiness_flags_package_input_runtime_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-package-inputs-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-package-inputs-check.sample.json")
        payload["inputs"]["doeRuntime"]["sha256"] = "0" * 64
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_package_inputs_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]
    failure_codes = {item["code"] for item in consistency["failures"]}

    assert consistency["status"] == "fail"
    assert "package_inputs_doe_runtime_mismatch" in failure_codes
    assert "package_inputs_doe_runtime_manifest_mismatch" in failure_codes


def test_browser_readiness_flags_package_input_manifest_source_path_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        manifest_path = tmp_path / "browser-release-archive-manifest.json"
        manifest_rel = manifest_path.relative_to(REPO_ROOT)
        manifest = _load(REPO_ROOT / "examples" / "browser-release-archive-manifest.sample.json")
        manifest["members"]["doeRuntime"]["sourcePath"] = "browser/chromium/src/out/fawn_release/libwebgpu_doe.so"
        for row in manifest["archiveMembers"]:
            if row["archivePath"] == manifest["members"]["doeRuntime"]["archivePath"]:
                row["sourcePath"] = manifest["members"]["doeRuntime"]["sourcePath"]
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["path"] = manifest_rel.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(manifest_path)
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "package_inputs_doe_runtime_manifest_source_mismatch",
        "path": "releaseCandidateEvidence.releaseArchiveManifest.members.doeRuntime.sourcePath",
        "message": "release archive manifest doeRuntime sourcePath must match package-input path",
    } in consistency["failures"]


def test_browser_readiness_flags_package_input_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-package-inputs-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-package-inputs-check.sample.json")
        payload["browserProduct"]["productId"] = "other-browser"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_package_inputs_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "package_inputs_identity_mismatch",
        "path": "releaseCandidateEvidence.packageInputs.browserProduct",
        "message": "package-input browserProduct must match the release artifact bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_release_bundle_package_inputs_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_payload["packageInputs"] = {
            "path": "examples/browser-release-package-inputs-check.sample.json",
            "sha256": "f" * 64,
            "kind": "browser_release_package_inputs_check",
        }
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        release_summary = payload["componentReceipts"]["releaseArtifactBundle"]
        release_summary["path"] = release_rel.as_posix()
        release_summary["sha256"] = report_builder.sha256_file(release_path)
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "package_inputs_release_bundle_mismatch",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.packageInputs",
        "message": "release artifact bundle packageInputs must match package-input evidence",
    } in consistency["failures"]


def test_browser_readiness_flags_runtime_frontier_release_component_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        release_summary = payload["componentReceipts"]["releaseArtifactBundle"]
        release_summary["path"] = release_rel.as_posix()
        release_summary["bundleId"] = "stale-browser-release-bundle"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "runtime_frontier_release_component_identity_mismatch",
        "path": "frontierBundleEvidence.componentReceipts.releaseArtifactBundle.bundleId",
        "message": "runtime frontier release artifact component bundleId must match the loaded release artifact bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_runtime_frontier_release_identity_hash_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        release_path = Path(tmpdir) / "browser-release-artifact-bundle.json"
        release_rel = release_path.relative_to(REPO_ROOT)
        release_payload = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_path.write_text(json.dumps(release_payload, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-runtime-frontier-bundle.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        release_summary = payload["componentReceipts"]["releaseArtifactBundle"]
        release_summary["path"] = release_rel.as_posix()
        release_summary["releaseBundleIdentitySha256"] = "0" * 64
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "runtime_frontier_release_component_identity_mismatch",
        "path": (
            "frontierBundleEvidence.componentReceipts.releaseArtifactBundle."
            "releaseBundleIdentitySha256"
        ),
        "message": (
            "runtime frontier release artifact component "
            "releaseBundleIdentitySha256 must match the loaded release artifact "
            "bundle identity"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_package_input_schema_version_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-package-inputs-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-package-inputs-check.sample.json")
        payload["schemaVersion"] = 2
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_package_inputs_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "package_inputs_schema_version_mismatch",
        "path": "releaseCandidateEvidence.packageInputs.schemaVersion",
        "message": "package-input report schemaVersion must be 1",
    } in consistency["failures"]


def test_browser_readiness_flags_package_input_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-package-inputs-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-package-inputs-check.sample.json")
        payload["artifactKind"] = "browser_release_package_inputs_check_preview"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_package_inputs_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "packageInputs" not in release_candidate
    assert consistency["status"] == "fail"
    assert {
        "code": "package_inputs_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.packageInputs.artifactKind",
        "message": "package-input report artifactKind must be browser_release_package_inputs_check",
    } in consistency["failures"]


def test_browser_readiness_flags_failing_package_input_preflight() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-package-inputs-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-package-inputs-check.sample.json")
        payload["status"] = "fail"
        payload["failures"] = [
            {
                "code": "non_executable_input_file",
                "path": "inputs.browserExecutable.executable",
                "message": "browserExecutable must be executable",
            }
        ]
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_package_inputs_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert release_candidate["packageInputs"]["status"] == "fail"
    assert release_candidate["packageInputs"]["failureCount"] == 1
    assert {
        "code": "package_inputs_not_pass",
        "path": "releaseCandidateEvidence.packageInputs.status",
        "message": "browser release package inputs preflight must pass",
    } in consistency["failures"]
    assert {
        "code": "package_inputs_not_release_candidate",
        "path": "releaseCandidateEvidence.packageInputs.evidenceMode",
        "message": "browser release package inputs evidenceMode must be release_candidate",
    } in consistency["failures"]


def test_browser_readiness_flags_dirty_passing_package_input_preflight() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-package-inputs-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-package-inputs-check.sample.json")
        payload["status"] = "pass"
        payload["evidenceMode"] = "release_candidate"
        payload["releaseCandidateEligible"] = True
        payload["releaseCandidateBlockers"] = [
            {
                "code": "initial_macos_arm64_release_required",
                "path": "platform",
                "message": "initial release candidate must be macOS arm64",
            }
        ]
        payload["failures"] = [
            {
                "code": "non_executable_input_file",
                "path": "inputs.browserExecutable.executable",
                "message": "browser executable must be executable",
            }
        ]
        payload["summary"]["packageable"] = False
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_package_inputs_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    package_inputs = release_candidate["packageInputs"]
    consistency = release_candidate["consistency"]

    assert package_inputs["status"] == "pass"
    assert package_inputs["evidenceMode"] == "release_candidate"
    assert package_inputs["releaseCandidateEligible"] is True
    assert package_inputs["failureCount"] == 1
    assert len(package_inputs["releaseCandidateBlockers"]) == 1
    assert package_inputs["summary"]["packageable"] is False
    assert {
        "code": "package_inputs_failures_present",
        "path": "releaseCandidateEvidence.packageInputs.failureCount",
        "message": "passing package-input preflight must carry no failures",
    } in consistency["failures"]
    assert {
        "code": "package_inputs_blockers_present",
        "path": "releaseCandidateEvidence.packageInputs.releaseCandidateBlockers",
        "message": "passing package-input preflight must carry no release-candidate blockers",
    } in consistency["failures"]
    assert {
        "code": "package_inputs_summary_not_packageable",
        "path": "releaseCandidateEvidence.packageInputs.summary.packageable",
        "message": "passing package-input preflight summary.packageable must be true",
    } in consistency["failures"]


def test_browser_readiness_flags_package_input_binary_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-package-inputs-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-package-inputs-check.sample.json")
        payload["browserProduct"]["channel"] = "release_candidate"
        payload["platform"] = {"os": "macos", "arch": "arm64", "packageFormat": "zip"}
        payload["status"] = "pass"
        payload["evidenceMode"] = "release_candidate"
        payload["releaseCandidateEligible"] = True
        payload["releaseCandidateBlockers"] = []
        payload["failures"] = []
        payload["summary"]["packageable"] = True
        payload["inputs"]["browserExecutable"]["detectedFormat"] = "script"
        payload["inputs"]["browserExecutable"]["detectedArchitectures"] = []
        payload["inputs"]["doeRuntime"]["detectedFormat"] = "elf"
        payload["inputs"]["doeRuntime"]["detectedArchitectures"] = ["x64"]
        payload["inputs"]["dawnFallbackRuntime"]["detectedFormat"] = "macho"
        payload["inputs"]["dawnFallbackRuntime"]["detectedArchitectures"] = ["x64"]
        payload["inputs"]["shaderCompiler"]["detectedFormat"] = "script"
        payload["inputs"]["shaderCompiler"]["detectedArchitectures"] = []
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_package_inputs_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "package_inputs_binary_platform_mismatch",
        "path": "releaseCandidateEvidence.packageInputs.inputs.browserExecutable.detectedFormat",
        "message": "package-input browserExecutable must be detected as Mach-O for macOS release-candidate evidence",
    } in consistency["failures"]
    assert {
        "code": "package_inputs_binary_arch_mismatch",
        "path": "releaseCandidateEvidence.packageInputs.inputs.doeRuntime.detectedArchitectures",
        "message": "package-input doeRuntime must include arm64 code for macOS release-candidate evidence",
    } in consistency["failures"]
    assert {
        "code": "package_inputs_binary_platform_mismatch",
        "path": "releaseCandidateEvidence.packageInputs.inputs.shaderCompiler.detectedFormat",
        "message": "package-input shaderCompiler must be detected as Mach-O for macOS release-candidate evidence",
    } in consistency["failures"]


def test_browser_readiness_flags_published_proof_surface_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["surfaceId"] = "other-browser-proof-surface"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]
    failure_codes = {item["code"] for item in consistency["failures"]}

    assert consistency["status"] == "fail"
    assert failure_codes.issuperset({
        "proof_surface_provenance_mismatch",
        "proof_surface_release_bundle_mismatch",
        "proof_surface_check_identity_mismatch",
    })


def test_browser_readiness_flags_published_proof_surface_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["artifactKind"] = "browser_published_proof_surface_preview"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "publishedProofSurface" not in release_candidate
    assert consistency["status"] == "fail"
    assert {
        "code": "published_proof_surface_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.publishedProofSurface.artifactKind",
        "message": "published proof surface artifactKind must be browser_published_proof_surface",
    } in consistency["failures"]


def test_browser_readiness_flags_published_proof_surface_release_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        release_provenance = payload["proofPage"]["releaseProvenance"]
        release_provenance["browserProduct"]["productId"] = "other-browser"
        release_provenance["releaseArchive"]["downloadUrl"] = "https://downloads.doe.dev/other.zip"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "proof_surface_identity_mismatch",
        "path": "releaseCandidateEvidence.publishedProofSurface.browserProduct",
        "message": "published proof surface browserProduct must match the release artifact bundle",
    } in consistency["failures"]
    assert {
        "code": "proof_surface_archive_identity_mismatch",
        "path": "releaseCandidateEvidence.publishedProofSurface.releaseArchive",
        "message": "published proof surface releaseArchive must match the release artifact bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_runtime_identity_hash_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        runtime_identity_path = Path(tmpdir) / "browser-runtime-identity.json"
        runtime_identity_rel = runtime_identity_path.relative_to(REPO_ROOT)
        runtime_identity = _load(REPO_ROOT / "examples" / "browser-runtime-identity.selector.sample.json")
        replacement_hash = "b" * 64
        runtime_identity["provider"]["artifactIdentity"]["doeLibSha256"] = replacement_hash
        runtime_identity["runtimeSelection"]["artifactIdentity"]["doeLibSha256"] = replacement_hash
        runtime_identity_path.write_text(json.dumps(runtime_identity, indent=2) + "\n", encoding="utf-8")

        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["runtimeIdentityPath"] = runtime_identity_rel.as_posix()
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "proof_surface_runtime_identity_release_mismatch",
        "path": "releaseCandidateEvidence.publishedProofSurface.runtimeIdentityPath",
        "message": "proof-surface runtime identity artifact hashes must match release bundle browser/runtime artifacts",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_compiler_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["proofPage"]["diagnostics"]["compilerPath"] = "runtime/zig/zig-out/bin/other-compiler"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "proof_surface_compiler_identity_mismatch",
        "path": "releaseCandidateEvidence.publishedProofSurface.proofPage.diagnostics.compilerPath",
        "message": "published proof surface compilerPath must match release artifact bundle shaderCompiler.path",
    } in consistency["failures"]


def test_browser_readiness_flags_non_concrete_proof_diagnostics() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["proofPage"]["diagnostics"]["tsirStatus"] = "diagnostic"
        payload["proofPage"]["diagnostics"]["hostPlanStatus"] = "diagnostic"
        payload["proofPage"]["diagnostics"]["cslStatus"] = "diagnostic"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_non_release_diagnostic_status",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser proof surfaces require concrete tsirStatus diagnostics",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_missing_recent_receipts() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["proofPage"]["recentReceiptIds"] = []
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_without_proof_page",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser proof surfaces require recent receipt IDs",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_duplicate_recent_receipts() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["proofPage"]["recentReceiptIds"].append(
            payload["proofPage"]["recentReceiptIds"][0]
        )
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_recent_receipts_duplicate",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "proof-page recentReceiptIds must uniquely identify exposed execution receipts",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_duplicate_receipt_payload_links() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["proofPage"]["receiptPayloads"].append(payload["proofPage"]["receiptPayloads"][0])
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_receipt_payload_duplicate",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "proof-page receiptPayloads must uniquely identify execution receipt artifacts",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_duplicate_gallery_artifacts() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["galleryPages"].append(payload["galleryPages"][0])
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_gallery_identity_duplicate",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser gallery artifact paths must be unique",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_duplicate_gallery_urls() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["galleryPages"][1]["url"] = payload["galleryPages"][0]["url"]
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_gallery_url_duplicate",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser gallery URLs must be unique",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_duplicate_gallery_receipt_artifacts() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        row = payload["galleryPages"][0]
        row["receiptIds"].append(row["receiptIds"][0])
        row["receiptArtifacts"].append(row["receiptArtifacts"][0])
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_gallery_receipt_duplicate",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "gallery receipt IDs and artifact paths must uniquely identify execution receipts",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_malformed_extra_comparison_row() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["comparisonReceipts"].append(
            {
                "comparisonId": "browser-extra-dawn-vs-doe",
                "workloadId": "browser-extra-compute",
            }
        )
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_comparison_incomplete",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": (
            "claim-indexed Chromium browser comparison entries require comparisonId, "
            "workloadId, runner, comparisonPolicy, comparisonArtifact, Dawn receipt, "
            "and Doe receipt"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_duplicate_comparison_id() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["comparisonReceipts"].append(payload["comparisonReceipts"][0])
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_comparison_identity_duplicate",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser comparison IDs must be unique",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_duplicate_comparison_evidence() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        duplicate = dict(payload["comparisonReceipts"][0])
        duplicate["comparisonId"] = "browser-smoke-compute-dawn-vs-doe-copy"
        payload["comparisonReceipts"].append(duplicate)
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_comparison_artifact_duplicate",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser comparison artifact paths must be unique",
    } in consistency["failures"]
    assert {
        "code": "browser_release_proof_surface_comparison_receipt_pair_duplicate",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser comparison receipt pairs must be unique",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_unpaired_comparison_receipts() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["comparisonReceipts"][0]["doeReceipt"] = payload["comparisonReceipts"][0][
            "dawnReceipt"
        ]
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_comparison_receipt_duplicate",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser comparison rows must link distinct Dawn and Doe execution receipts",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_comparison_runner_off_gallery() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["comparisonReceipts"][0]["runner"][
            "pageArtifactPath"
        ] = "examples/browser-gallery-offsurface.sample.html"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_comparison_page_unpublished",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "claim-indexed Chromium browser comparison runner pages must be published gallery artifacts",
    } in consistency["failures"]


def test_browser_readiness_flags_execution_receipt_missing_timing() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        receipt_path = Path(tmpdir) / "browser-doe-execution-receipt.json"
        receipt_rel = receipt_path.relative_to(REPO_ROOT)
        receipt = _load(REPO_ROOT / "examples" / "browser-doe-execution-receipt.sample.json")
        receipt.pop("timing")
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        replacement_ref = {
            "receiptId": "browser-smoke-compute-doe",
            "path": receipt_rel.as_posix(),
            "sha256": receipt_sha,
            "kind": "browser_execution_receipt",
        }
        for row in payload["proofPage"]["receiptPayloads"]:
            if row.get("receiptId") == "browser-smoke-compute-doe":
                row.update(replacement_ref)
        for gallery in payload["galleryPages"]:
            for row in gallery.get("receiptArtifacts", []):
                if row.get("receiptId") == "browser-smoke-compute-doe":
                    row.update(replacement_ref)
        payload["comparisonReceipts"][0]["doeReceipt"] = replacement_ref
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_receipt_incomplete",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "execution receipt payload must include timing",
    } in consistency["failures"]


def test_browser_readiness_flags_comparison_receipt_output_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        receipt_path = Path(tmpdir) / "browser-doe-execution-receipt.json"
        receipt_rel = receipt_path.relative_to(REPO_ROOT)
        receipt = _load(REPO_ROOT / "examples" / "browser-doe-execution-receipt.sample.json")
        receipt["outputHash"] = "e" * 64
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        replacement_ref = {
            "receiptId": "browser-smoke-compute-doe",
            "path": receipt_rel.as_posix(),
            "sha256": receipt_sha,
            "kind": "browser_execution_receipt",
        }
        for row in payload["proofPage"]["receiptPayloads"]:
            if row.get("receiptId") == "browser-smoke-compute-doe":
                row.update(replacement_ref)
        for gallery in payload["galleryPages"]:
            for row in gallery.get("receiptArtifacts", []):
                if row.get("receiptId") == "browser-smoke-compute-doe":
                    row.update(replacement_ref)
        payload["comparisonReceipts"][0]["doeReceipt"] = replacement_ref
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_comparison_payload_mismatch",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "Dawn and Doe execution receipts must bind the same output or frame hash",
    } in consistency["failures"]


def test_browser_readiness_flags_comparison_artifact_mode_result_driver_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        comparison_path = Path(tmpdir) / "browser-smoke-report.json"
        comparison_rel = comparison_path.relative_to(REPO_ROOT)
        comparison = _load(REPO_ROOT / "examples" / "browser-smoke-report.sample.json")
        comparison["modeResults"][1]["runtimeSelection"]["profile"][
            "driver"
        ] = "sample-other-driver"
        _refresh_smoke_report_hashes(comparison)
        comparison_path.write_text(
            json.dumps(comparison, indent=2) + "\n",
            encoding="utf-8",
        )
        comparison_sha = hashlib.sha256(comparison_path.read_bytes()).hexdigest()

        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["comparisonReceipts"][0]["comparisonArtifact"] = {
            "path": comparison_rel.as_posix(),
            "sha256": comparison_sha,
            "kind": "chromium-webgpu-playwright-smoke",
        }
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_comparison_payload_mismatch",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": (
            "comparison artifact Doe modeResult runtimeSelection.profile.driver "
            "must match Doe execution receipt driver.driver"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_proof_page_receipt_diagnostics_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        receipt_path = Path(tmpdir) / "browser-proof-page-receipt.json"
        receipt_rel = receipt_path.relative_to(REPO_ROOT)
        receipt = _load(REPO_ROOT / "examples" / "browser-proof-page-receipt.sample.json")
        receipt["diagnostics"]["activeBackend"] = "webgpu-dawn"
        receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        custom_path = Path(tmpdir) / "browser-published-proof-surface.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json")
        payload["proofPage"]["diagnosticReceipt"] = {
            "path": receipt_rel.as_posix(),
            "sha256": receipt_sha,
            "kind": "browser_proof_page_receipt",
        }
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_release_proof_surface_proof_page_receipt_mismatch",
        "path": "releaseCandidateEvidence.browserRelease.proofSurfacePath",
        "message": "proof page receipt diagnostics must match proof page diagnostics",
    } in consistency["failures"]


def test_browser_readiness_flags_failing_proof_surface_check() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface-check.sample.json")
        payload["status"] = "fail"
        payload["failures"] = [
            {
                "code": "invalid_gallery_page_url",
                "path": "galleryPages[0].url",
                "message": "release proof gallery page URL must be public HTTPS",
            }
        ]
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_check_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "proof_surface_check_not_pass",
        "path": "releaseCandidateEvidence.proofSurfaceCheck.status",
        "message": "published proof-surface checker report must pass",
    } in consistency["failures"]
    assert {
        "code": "proof_surface_check_provenance_mismatch",
        "path": "releaseCandidateEvidence.proofSurfaceCheck",
        "message": "proof-surface checker report must match provenance report component artifact",
    } in consistency["failures"]
    assert {
        "code": "proof_surface_check_release_bundle_mismatch",
        "path": "releaseCandidateEvidence.proofSurfaceCheck",
        "message": "proof-surface checker report must match release artifact bundle proofSurfaceCheck",
    } in consistency["failures"]


def test_browser_readiness_flags_proof_surface_check_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface-check.sample.json")
        payload["artifactKind"] = "browser_published_proof_surface_check_preview"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_check_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "proofSurfaceCheck" not in release_candidate
    assert consistency["status"] == "fail"
    assert {
        "code": "proof_surface_check_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.proofSurfaceCheck.artifactKind",
        "message": "proof-surface checker report artifactKind must be browser_published_proof_surface_check",
    } in consistency["failures"]


def test_browser_readiness_flags_passing_proof_surface_check_failures() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-published-proof-surface-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-published-proof-surface-check.sample.json")
        payload["status"] = "pass"
        payload["failures"] = [
            {
                "code": "missing_gallery_public_receipt",
                "path": "galleryPages[0].publicReceipt",
                "message": "gallery page must bind a public receipt",
            }
        ]
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_proof_surface_check_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert release_candidate["proofSurfaceCheck"]["status"] == "pass"
    assert release_candidate["proofSurfaceCheck"]["failureCount"] == 1
    assert {
        "code": "proof_surface_check_failures_present",
        "path": "releaseCandidateEvidence.proofSurfaceCheck.failureCount",
        "message": "passing proof-surface checker report must carry no failures",
    } in consistency["failures"]


def test_browser_readiness_flags_chromium_source_checkout_without_runtime_selector() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "chromium-source-checkout-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "chromium-source-checkout-check.sample.json")
        payload["requireRuntimeSelector"] = False
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_chromium_source_checkout_path=custom_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "chromium_source_checkout_runtime_selector_not_required",
        "path": "releaseCandidateEvidence.chromiumSourceCheckout.requireRuntimeSelector",
        "message": "release-candidate Chromium source checkout must require runtime selector markers",
    } in consistency["failures"]


def test_browser_readiness_flags_blocked_chromium_source_checkout() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "chromium-source-checkout-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "chromium-source-checkout-check.sample.json")
        payload["status"] = "blocked"
        payload["missingRequired"] = ["selector:runtime_switch"]
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_chromium_source_checkout_path=custom_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert release_candidate["chromiumSourceCheckout"]["status"] == "blocked"
    assert release_candidate["chromiumSourceCheckout"]["missingRequired"] == [
        "selector:runtime_switch",
    ]
    assert {
        "code": "chromium_source_checkout_not_pass",
        "path": "releaseCandidateEvidence.chromiumSourceCheckout.status",
        "message": "release-candidate Chromium source checkout report must pass",
    } in consistency["failures"]
    assert {
        "code": "chromium_source_checkout_missing_required",
        "path": "releaseCandidateEvidence.chromiumSourceCheckout.missingRequired",
        "message": "release-candidate Chromium source checkout report must have no missing required checks",
    } in consistency["failures"]


def test_browser_readiness_flags_chromium_source_checkout_schema_version_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "chromium-source-checkout-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "chromium-source-checkout-check.sample.json")
        payload["schemaVersion"] = 2
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_chromium_source_checkout_path=custom_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "chromium_source_checkout_schema_version_mismatch",
        "path": "releaseCandidateEvidence.chromiumSourceCheckout.schemaVersion",
        "message": "Chromium source checkout report schemaVersion must be 1",
    } in consistency["failures"]


def test_browser_readiness_flags_chromium_source_checkout_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "chromium-source-checkout-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "chromium-source-checkout-check.sample.json")
        payload["artifactKind"] = "chromium_source_checkout_check_preview"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_chromium_source_checkout_path=custom_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "chromiumSourceCheckout" not in release_candidate
    assert consistency["status"] == "fail"
    assert {
        "code": "chromium_source_checkout_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.chromiumSourceCheckout.artifactKind",
        "message": "Chromium source checkout report artifactKind must be chromium_source_checkout_check",
    } in consistency["failures"]


def test_browser_readiness_flags_chromium_source_checkout_release_bundle_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "chromium-source-checkout-check.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "chromium-source-checkout-check.sample.json")
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(
                browser_chromium_source_checkout_path=custom_rel,
            ),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "chromium_source_checkout_release_bundle_mismatch",
        "path": "releaseCandidateEvidence.chromiumSourceCheckout",
        "message": "Chromium source checkout report must match release artifact bundle chromiumSourceCheckout",
    } in consistency["failures"]


def test_browser_readiness_flags_public_download_archive_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-public-download-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-public-download-receipt.sample.json")
        payload["contentSha256"] = "0" * 64
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_public_download_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "public_download_release_archive_mismatch",
        "path": "releaseCandidateEvidence.publicDownloadReceipt.releaseArchivePath",
        "message": "public download receipt must match release archive path, hash, and URL",
    } in consistency["failures"]


def test_browser_readiness_flags_incomplete_public_download_receipt() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-public-download-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-public-download-receipt.sample.json")
        payload["receiptId"] = ""
        payload["observedAt"] = ""
        payload["contentLengthBytes"] = 0
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_public_download_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "public_download_incomplete",
        "path": "releaseCandidateEvidence.publicDownloadReceipt.receiptId",
        "message": "public download receipt must include receiptId",
    } in consistency["failures"]
    assert {
        "code": "public_download_incomplete",
        "path": "releaseCandidateEvidence.publicDownloadReceipt.observedAt",
        "message": "public download receipt must include observedAt",
    } in consistency["failures"]
    assert {
        "code": "public_download_incomplete",
        "path": "releaseCandidateEvidence.publicDownloadReceipt.contentLengthBytes",
        "message": "public download receipt must include positive contentLengthBytes",
    } in consistency["failures"]


def test_browser_readiness_flags_public_download_schema_version_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-public-download-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-public-download-receipt.sample.json")
        payload["schemaVersion"] = 2
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_public_download_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "public_download_schema_version_mismatch",
        "path": "releaseCandidateEvidence.publicDownloadReceipt.schemaVersion",
        "message": "public download receipt schemaVersion must be 1",
    } in consistency["failures"]


def test_browser_readiness_flags_public_download_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-public-download-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-public-download-receipt.sample.json")
        payload["artifactKind"] = "browser_public_download_receipt_preview"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_public_download_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "publicDownloadReceipt" not in release_candidate
    assert consistency["status"] == "fail"
    assert {
        "code": "public_download_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.publicDownloadReceipt.artifactKind",
        "message": "public download receipt artifactKind must be browser_public_download_receipt",
    } in consistency["failures"]


def test_browser_readiness_flags_public_download_url_not_public() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-public-download-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-public-download-receipt.sample.json")
        payload["url"] = "http://localhost:8080/Fawn-Doe-macos-arm64.zip"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_public_download_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "public_download_url_not_public",
        "path": "releaseCandidateEvidence.publicDownloadReceipt.url",
        "message": "public download receipt URL must be public HTTPS",
    } in consistency["failures"]


def test_browser_readiness_flags_public_download_length_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-public-download-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-public-download-receipt.sample.json")
        payload["contentLengthBytes"] = 1
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_public_download_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "public_download_length_mismatch",
        "path": "releaseCandidateEvidence.publicDownloadReceipt.contentLengthBytes",
        "message": "public download receipt contentLengthBytes must match release archive bytes",
    } in consistency["failures"]


def test_browser_readiness_flags_public_download_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-public-download-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-public-download-receipt.sample.json")
        payload["platform"]["arch"] = "arm64"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_public_download_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "public_download_identity_mismatch",
        "path": "releaseCandidateEvidence.publicDownloadReceipt.platform",
        "message": "public download receipt platform must match the release artifact bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_non_public_release_archive_download_url() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchive"]["downloadUrl"] = "http://localhost/Fawn-Doe.zip"
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_download_url_not_public",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.downloadUrl",
        "message": "release archive download URL must be public HTTPS",
    } in consistency["failures"]


def test_browser_readiness_flags_invalid_release_archive_zip() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        archive_path = tmp_path / "browser-release-archive.zip"
        archive_rel = archive_path.relative_to(REPO_ROOT)
        archive_path.write_text("not a zip archive\n", encoding="utf-8")

        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchive"]["path"] = archive_rel.as_posix()
        release_bundle["releaseArchive"]["sha256"] = report_builder.sha256_file(archive_path)
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_zip_invalid",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.path",
        "message": "release archive must be a valid zip file",
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_member_hash_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        archive_path = _write_release_archive_with_member_data(
            tmpdir,
            "Fawn-Doe-linux-x64/libwebgpu_doe.so",
            b"stale Doe runtime bytes\n",
        )
        archive_rel = archive_path.relative_to(REPO_ROOT)

        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchive"]["path"] = archive_rel.as_posix()
        release_bundle["releaseArchive"]["sha256"] = report_builder.sha256_file(archive_path)
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_member_hash_mismatch",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.doeRuntime.sha256",
        "message": (
            "Doe runtime archive member hash must match "
            "release artifact bundle doeRuntime.sha256"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_binary_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseStatus"] = "release_candidate"
        release_bundle["browserProduct"]["channel"] = "release_candidate"
        release_bundle["platform"] = {"os": "macos", "arch": "arm64", "packageFormat": "zip"}

        report = _build_report_with_release_bundle_payload(tmp_path, release_bundle)

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "release_archive_binary_format_mismatch",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.browserExecutableArchivePath",
        "message": (
            "macOS browser executable archive member must be Mach-O: "
            "Fawn-Doe-linux-x64/chrome-wrapper"
        ),
    } in consistency["failures"]
    assert {
        "code": "release_archive_binary_arch_mismatch",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.doeRuntimeArchivePath",
        "message": (
            "macOS Doe runtime archive member must include arm64 code: "
            "Fawn-Doe-linux-x64/libwebgpu_doe.so"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_member_path_with_empty_segment() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["browserExecutableArchivePath"] = "Fawn.app//Contents/MacOS/Chromium"
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert {
        "code": "release_archive_member_path_unsafe",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.browserExecutableArchivePath",
        "message": "browser executable archive path must be relative and safe",
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_app_metadata_path_with_current_segment() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        unsafe_path = "Fawn.app/./Contents/Info.plist"
        release_bundle["browserAppMetadataArchivePath"] = unsafe_path

        report = _build_report_with_release_bundle_payload(tmp_path, release_bundle)

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_app_metadata_path_unsafe",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.browserAppMetadataArchivePath",
        "message": f"browser metadata archive path must be relative and safe: {unsafe_path}",
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_manifest_file_hash_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["sha256"] = "f" * 64
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_manifest_file_hash_mismatch",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.releaseArchiveManifest.sha256",
        "message": "release archive manifest sha256 must match release archive manifest file bytes",
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_path_unsafe() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir, tempfile.TemporaryDirectory() as outside_dir:
        outside_archive_path = Path(outside_dir) / "browser-release-archive.zip"
        outside_archive_path.write_bytes(
            (REPO_ROOT / "examples" / "browser-release-archive.sample.zip").read_bytes()
        )
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchive"]["path"] = outside_archive_path.as_posix()
        release_bundle["releaseArchive"]["sha256"] = report_builder.sha256_file(
            outside_archive_path
        )

        report = _build_report_with_release_bundle_payload(Path(tmpdir), release_bundle)

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_file_path_unsafe",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.path",
        "message": "release archive path must be repository-relative",
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_manifest_path_unsafe() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir, tempfile.TemporaryDirectory() as outside_dir:
        outside_manifest_path = Path(outside_dir) / "browser-release-archive-manifest.json"
        outside_manifest_path.write_bytes(
            (
                REPO_ROOT
                / "examples"
                / "browser-release-archive-manifest.sample.json"
            ).read_bytes()
        )
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["path"] = outside_manifest_path.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(
            outside_manifest_path
        )

        report = _build_report_with_release_bundle_payload(Path(tmpdir), release_bundle)

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_manifest_file_path_unsafe",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.releaseArchiveManifest.path",
        "message": "release archive manifest path must be repository-relative",
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_manifest_contract_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        manifest_path = tmp_path / "browser-release-archive-manifest.json"
        manifest_rel = manifest_path.relative_to(REPO_ROOT)
        manifest = _load(REPO_ROOT / "examples" / "browser-release-archive-manifest.sample.json")
        manifest["schemaVersion"] = 2
        manifest["artifactKind"] = "browser_release_archive_manifest_preview"
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["path"] = manifest_rel.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(manifest_path)
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_manifest_schema_version_mismatch",
        "path": "releaseCandidateEvidence.releaseArchiveManifest.schemaVersion",
        "message": "release archive manifest schemaVersion must be 1",
    } in consistency["failures"]
    assert {
        "code": "release_archive_manifest_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.releaseArchiveManifest.artifactKind",
        "message": "release archive manifest artifactKind must be browser_release_archive_manifest",
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_manifest_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        manifest_path = tmp_path / "browser-release-archive-manifest.json"
        manifest_rel = manifest_path.relative_to(REPO_ROOT)
        manifest = _load(REPO_ROOT / "examples" / "browser-release-archive-manifest.sample.json")
        manifest["browserProduct"]["productId"] = "other-browser"
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["path"] = manifest_rel.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(manifest_path)
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_manifest_identity_mismatch",
        "path": "releaseCandidateEvidence.releaseArchiveManifest.browserProduct",
        "message": "release archive manifest browserProduct must match the release artifact bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_manifest_archive_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        manifest_path = tmp_path / "browser-release-archive-manifest.json"
        manifest_rel = manifest_path.relative_to(REPO_ROOT)
        manifest = _load(REPO_ROOT / "examples" / "browser-release-archive-manifest.sample.json")
        manifest["archive"]["sha256"] = "0" * 64
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["path"] = manifest_rel.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(manifest_path)
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_manifest_archive_mismatch",
        "path": "releaseCandidateEvidence.releaseArchiveManifest.archive.sha256",
        "message": (
            "release archive manifest archive.sha256 must match "
            "release artifact bundle releaseArchive.sha256"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_manifest_member_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        manifest_path = tmp_path / "browser-release-archive-manifest.json"
        manifest_rel = manifest_path.relative_to(REPO_ROOT)
        manifest = _load(REPO_ROOT / "examples" / "browser-release-archive-manifest.sample.json")
        manifest["members"]["doeRuntime"]["sha256"] = "0" * 64
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["path"] = manifest_rel.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(manifest_path)
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_manifest_member_mismatch",
        "path": "releaseCandidateEvidence.releaseArchiveManifest.members.doeRuntime.sha256",
        "message": (
            "release archive manifest doeRuntime.sha256 must match "
            "release artifact bundle doeRuntime.sha256"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_manifest_archive_member_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        manifest_path = tmp_path / "browser-release-archive-manifest.json"
        manifest_rel = manifest_path.relative_to(REPO_ROOT)
        manifest = _load(REPO_ROOT / "examples" / "browser-release-archive-manifest.sample.json")
        manifest["archiveMembers"] = [
            row
            for row in manifest["archiveMembers"]
            if row["archivePath"] != "Fawn-Doe-linux-x64/libwebgpu_doe.so"
        ]
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["path"] = manifest_rel.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(manifest_path)
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_manifest_archive_member_mismatch",
        "path": "releaseCandidateEvidence.releaseArchiveManifest.archiveMembers",
        "message": "release archive manifest archiveMembers must include doeRuntime member",
    } in consistency["failures"]


def test_browser_readiness_flags_duplicate_release_bundle_member_paths() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["dawnFallbackRuntimeArchivePath"] = release_bundle[
            "doeRuntimeArchivePath"
        ]

        report = _build_report_with_release_bundle_payload(tmp_path, release_bundle)

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_member_path_duplicate",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.dawnFallbackRuntimeArchivePath",
        "message": (
            "Dawn fallback runtime archive path must not duplicate Doe runtime "
            "archive path from doeRuntimeArchivePath"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_duplicate_release_archive_manifest_member_paths() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        manifest_path = tmp_path / "browser-release-archive-manifest.json"
        manifest_rel = manifest_path.relative_to(REPO_ROOT)
        manifest = _load(REPO_ROOT / "examples" / "browser-release-archive-manifest.sample.json")
        manifest["archiveMembers"].append(dict(manifest["archiveMembers"][0]))
        duplicate_path = manifest["archiveMembers"][0]["archivePath"]
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["path"] = manifest_rel.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(manifest_path)

        report = _build_report_with_release_bundle_payload(tmp_path, release_bundle)

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_manifest_archive_member_duplicate",
        "path": "releaseCandidateEvidence.releaseArchiveManifest.archiveMembers",
        "message": (
            "release archive manifest archiveMembers must not repeat "
            f"member path: {duplicate_path}"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_unsafe_release_archive_manifest_archive_member_path() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        manifest_path = tmp_path / "browser-release-archive-manifest.json"
        manifest_rel = manifest_path.relative_to(REPO_ROOT)
        manifest = _load(REPO_ROOT / "examples" / "browser-release-archive-manifest.sample.json")
        unsafe_path = "Fawn.app//Contents/MacOS/Chromium"
        manifest["archiveMembers"][0]["archivePath"] = unsafe_path
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["path"] = manifest_rel.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(manifest_path)

        report = _build_report_with_release_bundle_payload(tmp_path, release_bundle)

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_manifest_archive_member_path_unsafe",
        "path": "releaseCandidateEvidence.releaseArchiveManifest.archiveMembers",
        "message": (
            "release archive manifest archiveMembers path must be "
            f"relative and safe: {unsafe_path}"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_duplicate_release_archive_zip_member_paths() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        archive_path = _write_release_archive_with_duplicate_member(tmp_path)
        archive_rel = archive_path.relative_to(REPO_ROOT)

        manifest_path = tmp_path / "browser-release-archive-manifest.json"
        manifest_rel = manifest_path.relative_to(REPO_ROOT)
        manifest = _load(REPO_ROOT / "examples" / "browser-release-archive-manifest.sample.json")
        manifest["archive"]["path"] = archive_rel.as_posix()
        manifest["archive"]["sha256"] = report_builder.sha256_file(archive_path)
        manifest["archive"]["byteLength"] = archive_path.stat().st_size
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchive"]["path"] = archive_rel.as_posix()
        release_bundle["releaseArchive"]["sha256"] = report_builder.sha256_file(archive_path)
        release_bundle["releaseArchiveManifest"]["path"] = manifest_rel.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(manifest_path)

        report = _build_report_with_release_bundle_payload(tmp_path, release_bundle)

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_zip_member_duplicate",
        "path": "releaseCandidateEvidence.releaseArtifactBundle.releaseArchive.path",
        "message": "release archive zip must not repeat member path: Fawn-Doe-linux-x64/browser-product.json",
    } in consistency["failures"]


def test_browser_readiness_flags_release_archive_manifest_zip_member_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        tmp_path = Path(tmpdir)
        manifest_path = tmp_path / "browser-release-archive-manifest.json"
        manifest_rel = manifest_path.relative_to(REPO_ROOT)
        manifest = _load(REPO_ROOT / "examples" / "browser-release-archive-manifest.sample.json")
        manifest["members"]["doeRuntime"]["byteLength"] = 1
        for row in manifest["archiveMembers"]:
            if row["archivePath"] == "Fawn-Doe-linux-x64/libwebgpu_doe.so":
                row["byteLength"] = 1
        manifest_path.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        release_bundle_path = tmp_path / "browser-release-artifact-bundle.json"
        release_bundle_rel = release_bundle_path.relative_to(REPO_ROOT)
        release_bundle = _load(REPO_ROOT / "examples" / "browser-release-artifact-bundle.sample.json")
        release_bundle["releaseArchiveManifest"]["path"] = manifest_rel.as_posix()
        release_bundle["releaseArchiveManifest"]["sha256"] = report_builder.sha256_file(manifest_path)
        release_bundle_path.write_text(
            json.dumps(release_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        frontier_bundle_path = tmp_path / "browser-runtime-frontier-bundle.json"
        frontier_bundle_rel = frontier_bundle_path.relative_to(REPO_ROOT)
        frontier_bundle = _load(REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json")
        frontier_release_ref = frontier_bundle["componentReceipts"]["releaseArtifactBundle"]
        frontier_release_ref["path"] = release_bundle_rel.as_posix()
        frontier_release_ref["sha256"] = report_builder.sha256_file(release_bundle_path)
        frontier_bundle_path.write_text(
            json.dumps(frontier_bundle, indent=2) + "\n",
            encoding="utf-8",
        )

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_bundle_path=frontier_bundle_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "release_archive_manifest_zip_mismatch",
        "path": "releaseCandidateEvidence.releaseArchiveManifest.archiveMembers",
        "message": (
            "release archive manifest member metadata must match zip member: "
            "Fawn-Doe-linux-x64/libwebgpu_doe.so"
        ),
    } in consistency["failures"]


def test_browser_readiness_flags_launch_runtime_state_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["activeRuntime"] = "dawn"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_runtime_state_mismatch",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.activeRuntime",
        "message": "browser launch receipt must prove a release-archive Doe WebGPU launch with hidden fallback disabled",
    } in consistency["failures"]


def test_browser_readiness_flags_launch_hidden_fallback_used() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["hiddenFallbackUsed"] = True
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_runtime_state_mismatch",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.activeRuntime",
        "message": "browser launch receipt must prove a release-archive Doe WebGPU launch with hidden fallback disabled",
    } in consistency["failures"]


def test_browser_readiness_flags_launch_receipt_missing_identity() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["receiptId"] = ""
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_incomplete",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.receiptId",
        "message": "browser launch receipt must include receiptId",
    } in consistency["failures"]


def test_browser_readiness_flags_launch_schema_version_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["schemaVersion"] = 2
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_schema_version_mismatch",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.schemaVersion",
        "message": "browser launch receipt schemaVersion must be 1",
    } in consistency["failures"]


def test_browser_readiness_flags_launch_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["browserProduct"]["productId"] = "other-browser"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_identity_mismatch",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.browserProduct",
        "message": "browser launch receipt browserProduct must match the release artifact bundle",
    } in consistency["failures"]


def test_browser_readiness_flags_non_public_launch_gallery_url() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["galleryPage"]["url"] = "http://localhost:8080/doe/compute.html"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_gallery_url_not_public",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.galleryUrl",
        "message": "browser launch receipt gallery URL must be public HTTPS",
    } in consistency["failures"]


def test_browser_readiness_flags_duplicate_launch_observed_receipts() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["observedReceiptIds"].append(payload["observedReceiptIds"][0])
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_observed_receipts_duplicate",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.observedReceiptIds",
        "message": "browser launch observedReceiptIds must uniquely identify observed receipts",
    } in consistency["failures"]


def test_browser_readiness_flags_unlinked_launch_observed_receipts() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["observedReceiptIds"].append("browser-unlinked-receipt")
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_observed_receipts_unlinked",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.observedReceiptIds",
        "message": "browser launch observedReceiptIds must exactly match proof, gallery, Dawn, and Doe receipt IDs",
    } in consistency["failures"]


def test_browser_readiness_flags_unrecognized_launch_gallery_category() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["galleryPage"]["category"] = "local_debug"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_gallery_category_unrecognized",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.galleryCategory",
        "message": "browser launch receipt gallery category must be recognized",
    } in consistency["failures"]


def test_browser_readiness_flags_launch_comparison_page_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["comparisonReceipt"]["pageArtifactPath"] = "examples/browser-gallery-rendering.sample.html"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_comparison_page_mismatch",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.comparisonPageArtifactPath",
        "message": "browser launch comparison pageArtifactPath must match the loaded gallery artifactPath",
    } in consistency["failures"]


def test_browser_readiness_flags_launch_comparison_identity_missing() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["comparisonReceipt"]["comparisonId"] = ""
        payload["comparisonReceipt"]["workloadId"] = ""
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_comparison_identity_missing",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.comparisonId",
        "message": "browser launch receipt must identify comparisonId and workloadId",
    } in consistency["failures"]


def test_browser_readiness_flags_launch_comparison_artifact_missing() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["comparisonReceipt"]["comparisonArtifactPath"] = ""
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_comparison_artifact_missing",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.comparisonArtifactPath",
        "message": "browser launch receipt must identify the same-page comparison artifact",
    } in consistency["failures"]


def test_browser_readiness_flags_launch_comparison_artifact_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["comparisonReceipt"]["comparisonArtifactPath"] = "examples/browser-smoke-report.other.json"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_comparison_artifact_mismatch",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.comparisonArtifactPath",
        "message": "browser launch comparisonArtifactPath must match the published proof surface",
    } in consistency["failures"]


def test_browser_readiness_flags_launch_gallery_proof_surface_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["galleryPage"]["artifactPath"] = "examples/browser-gallery-unlisted.sample.html"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_proof_surface_field_mismatch",
        "path": "releaseCandidateEvidence.browserLaunchReceipt",
        "message": "launch gallery artifact must match a proof-surface gallery page",
    } in consistency["failures"]


def test_browser_readiness_flags_missing_launch_receipt() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_rel = (Path(tmpdir) / "missing-browser-release-launch-receipt.json").relative_to(REPO_ROOT)

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_receipt_missing",
        "path": "releaseCandidateEvidence.browserLaunchReceipt",
        "message": f"configured browser launch receipt is missing or has the wrong artifact kind: {custom_rel.as_posix()}",
    } in consistency["failures"]


def test_browser_readiness_flags_launch_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-launch-receipt.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-launch-receipt.sample.json")
        payload["artifactKind"] = "browser_release_launch_receipt_preview"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_launch_receipt_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "browserLaunchReceipt" not in release_candidate
    assert consistency["status"] == "fail"
    assert {
        "code": "browser_launch_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.browserLaunchReceipt.artifactKind",
        "message": "browser launch receipt artifactKind must be browser_release_launch_receipt",
    } in consistency["failures"]


def test_browser_readiness_flags_passing_provenance_report_failures() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-candidate-provenance.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-candidate-provenance.sample.json")
        payload["status"] = "pass"
        payload["failures"] = [
            {
                "code": "browser_launch_provenance_mismatch",
                "path": "browserLaunchReceipt.browserProduct",
                "message": "browser launch receipt must match provenance",
            }
        ]
        payload["summary"]["failureCount"] = 1
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_provenance_report_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    provenance_report = release_candidate["provenanceReport"]
    consistency = release_candidate["consistency"]

    assert provenance_report["status"] == "pass"
    assert provenance_report["failureCount"] == 1
    assert provenance_report["summary"]["failureCount"] == 1
    assert {
        "code": "provenance_report_failures_present",
        "path": "releaseCandidateEvidence.provenanceReport.failureCount",
        "message": "passing provenance report must carry no failures",
    } in consistency["failures"]
    assert {
        "code": "provenance_summary_failure_count_not_zero",
        "path": "releaseCandidateEvidence.provenanceReport.summary.failureCount",
        "message": "passing provenance report summary failureCount must be zero",
    } in consistency["failures"]


def test_browser_readiness_flags_provenance_report_artifact_kind_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-candidate-provenance.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-candidate-provenance.sample.json")
        payload["artifactKind"] = "browser_release_candidate_provenance_report_preview"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_provenance_report_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    release_candidate = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]
    consistency = release_candidate["consistency"]

    assert "provenanceReport" not in release_candidate
    assert consistency["status"] == "fail"
    assert {
        "code": "provenance_report_artifact_kind_mismatch",
        "path": "releaseCandidateEvidence.provenanceReport.artifactKind",
        "message": "provenance report artifactKind must be browser_release_candidate_provenance_report",
    } in consistency["failures"]


def test_browser_readiness_flags_provenance_identity_mismatch() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "browser-release-candidate-provenance.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        payload = _load(REPO_ROOT / "examples" / "browser-release-candidate-provenance.sample.json")
        payload["platform"]["arch"] = "arm64"
        custom_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(browser_provenance_report_path=custom_rel),
        )

    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    consistency = browser_row["frontierBundleEvidence"]["releaseCandidateEvidence"]["consistency"]

    assert consistency["status"] == "fail"
    assert {
        "code": "provenance_identity_mismatch",
        "path": "releaseCandidateEvidence.provenanceReport.platform",
        "message": "provenance report platform must match the release artifact bundle",
    } in consistency["failures"]


def test_browser_claimable_candidate_still_reports_claim_promotion_blocker() -> None:
    row = {
        "id": "browser-chromium-runtime",
        "claimAllowed": False,
    }
    evidence = {
        "status": "pass",
        "claimabilityStatus": "claimable",
        "releaseCandidateEvidence": {
            "consistency": {
                "status": "pass",
                "failures": [],
            }
        },
    }

    blocker_codes = report_builder.claim_allowance_blocker_codes(row, [], evidence)

    assert blocker_codes == ["browser_claim_index_promotion"]


def test_browser_claim_promotion_blocker_requires_passing_frontier_bundle() -> None:
    row = {
        "id": "browser-chromium-runtime",
        "claimAllowed": False,
    }
    evidence = {
        "status": "fail",
        "claimabilityStatus": "claimable",
        "releaseCandidateEvidence": {
            "consistency": {
                "status": "pass",
                "failures": [],
            }
        },
    }

    blocker_codes = report_builder.claim_allowance_blocker_codes(row, [], evidence)

    assert blocker_codes == ["chromium_release_build_evidence"]


def test_browser_claim_promotion_blocker_requires_clean_candidate_consistency() -> None:
    row = {
        "id": "browser-chromium-runtime",
        "claimAllowed": False,
    }
    evidence = {
        "status": "pass",
        "claimabilityStatus": "claimable",
        "releaseCandidateEvidence": {
            "consistency": {
                "status": "fail",
                "failures": [
                    {
                        "code": "provenance_report_not_pass",
                        "path": "releaseCandidateEvidence.provenanceReport.status",
                        "message": "release-candidate provenance report must pass",
                    }
                ],
            }
        },
    }

    blocker_codes = report_builder.claim_allowance_blocker_codes(row, [], evidence)

    assert blocker_codes == ["chromium_release_build_evidence"]
