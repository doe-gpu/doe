#!/usr/bin/env python3
"""Tests for composed browser runtime frontier bundle receipts."""

from __future__ import annotations

import hashlib
import json
import plistlib
import struct
import tempfile, unittest, zipfile
from pathlib import Path
from typing import Any

import jsonschema

from bench.browser.browser_gate import stable_hash
from bench.tools import check_browser_runtime_frontier_bundle as bundle
from bench.tools import check_browser_release_artifact_bundle as release_check


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "config" / "browser-runtime-frontier-bundle.schema.json"
SAMPLE_PATH = REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json"
DEFAULT_BROWSER_ARCHIVE_PATH, DEFAULT_APP_METADATA_ARCHIVE_PATH = "Fawn.app/Contents/MacOS/Chromium", "Fawn.app/Contents/Info.plist"
DEFAULT_DOE_RUNTIME_ARCHIVE_PATH, DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH = "Fawn.app/Contents/Frameworks/libwebgpu_doe.so", "Fawn.app/Contents/Frameworks/libdawn_native.so"
DEFAULT_BROWSER_PRODUCT = {"productId": "fawn-doe", "displayName": "Fawn Doe", "version": "0.0.0-test"}
CONCRETE_RELEASE_PROOF_DIAGNOSTICS = {
    "webgpuAvailable": True,
    "tsirStatus": "available",
    "hostPlanStatus": "not_applicable",
    "cslStatus": "not_applicable",
}
GALLERY_CATEGORIES = ("compute", "rendering", "tensor", "shader_edge", "benchmark_trace")

def _load_json(path: Path) -> dict: return json.loads(path.read_text(encoding="utf-8"))

def _without_hash_fields(payload: dict[str, Any], fields: tuple[str, ...]) -> dict[str, Any]:
    return {key: value for key, value in payload.items() if key not in fields}

class BrowserRuntimeFrontierBundleTests(unittest.TestCase):
    def test_sample_matches_checker_and_schema(self) -> None:
        report = bundle.build_report(
            runtime_identity_path="examples/browser-runtime-identity.selector.sample.json",
            claim_promotion_receipt_path="examples/browser-claim-promotion-receipt.sample.json",
            release_artifact_bundle_path="examples/browser-release-artifact-bundle.sample.json",
            root=REPO_ROOT,
        )

        jsonschema.validate(report, _load_json(SCHEMA_PATH))
        self.assertEqual(report, _load_json(SAMPLE_PATH))
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["claimabilityStatus"], "blocked")
        blocker_codes = {item["code"] for item in report["claimBlockers"]}
        self.assertIn("chromium_release_build_evidence", blocker_codes)
        self.assertNotIn("claim_grade_browser_runtime_identity", blocker_codes)
        self.assertNotIn("browser_structural_equivalence_receipts", blocker_codes)
        self.assertEqual(
            report["claimBlockerSummary"],
            [
                {
                    "code": "chromium_release_build_evidence",
                    "message": "browser release artifact bundle must be a release_candidate",
                    "count": 1,
                }
            ],
        )
        artifact_verification = report["componentReceipts"]["releaseArtifactBundle"][
            "artifactVerification"
        ]
        self.assertEqual(
            artifact_verification,
            {
                "requiredForClaimable": True,
                "verifyFilesRootProvided": False,
                "verified": False,
            },
        )

    def test_require_claimable_fails_for_sample(self) -> None:
        report = bundle.build_report(
            runtime_identity_path="examples/browser-runtime-identity.selector.sample.json",
            claim_promotion_receipt_path="examples/browser-claim-promotion-receipt.sample.json",
            release_artifact_bundle_path="examples/browser-release-artifact-bundle.sample.json",
            root=REPO_ROOT,
            require_claimable=True,
        )

        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["claimabilityStatus"], "blocked")
        self.assertEqual(report["failures"], report["claimBlockers"])

    def test_claim_grade_inputs_are_claimable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            identity_path = root / "runtime-identity.json"
            claim_report_path = root / "browser-claim-report.json"
            promotion_path = root / "promotion-receipt.json"
            release_path = root / "release-bundle.json"

            self._write_json(identity_path, self._claim_grade_identity())
            claim_report_hash = self._write_json(
                claim_report_path,
                self._claimable_claim_report(),
            )
            promotion_hash = self._write_json(
                promotion_path,
                self._promotion_receipt(claim_report_path.name, claim_report_hash),
            )
            self._write_json(
                release_path,
                self._verified_release_bundle(
                    root,
                    claim_report_path.name,
                    claim_report_hash,
                    promotion_path.name,
                    promotion_hash,
                    release_status="release_candidate",
                    failure_codes=[],
                ),
            )

            report = bundle.build_report(
                runtime_identity_path=identity_path.name,
                claim_promotion_receipt_path=promotion_path.name,
                release_artifact_bundle_path=release_path.name,
                root=root,
                verify_files_root=root,
            )

        jsonschema.validate(report, _load_json(SCHEMA_PATH))
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["claimabilityStatus"], "claimable")
        self.assertEqual(report["claimBlockers"], [])
        self.assertEqual(report["failures"], [])
        artifact_verification = report["componentReceipts"]["releaseArtifactBundle"][
            "artifactVerification"
        ]
        self.assertEqual(
            artifact_verification,
            {
                "requiredForClaimable": True,
                "verifyFilesRootProvided": True,
                "verified": True,
            },
        )
        bad_report = {**report, "claimBlockers": [{"code": "x", "path": "y", "message": "z"}]}
        with self.assertRaises(jsonschema.ValidationError): jsonschema.validate(bad_report, _load_json(SCHEMA_PATH))

    def test_claim_grade_builder_defers_runtime_frontier_self_check(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            identity_path = root / "runtime-identity.json"
            claim_report_path = root / "browser-claim-report.json"
            promotion_path = root / "promotion-receipt.json"
            release_path = root / "release-bundle.json"

            self._write_json(identity_path, self._claim_grade_identity())
            claim_report_hash = self._write_json(
                claim_report_path,
                self._claimable_claim_report(),
            )
            promotion_hash = self._write_json(
                promotion_path,
                self._promotion_receipt(claim_report_path.name, claim_report_hash),
            )
            release_payload = self._verified_release_bundle(
                root,
                claim_report_path.name,
                claim_report_hash,
                promotion_path.name,
                promotion_hash,
                release_status="release_candidate",
                failure_codes=[],
            )
            release_payload["runtimeFrontierBundle"] = {
                "path": "browser-runtime-frontier-bundle.future.json",
                "sha256": "0" * 64,
                "kind": "browser_runtime_frontier_bundle",
            }
            self._write_json(release_path, release_payload)

            report = bundle.build_report(
                runtime_identity_path=identity_path.name,
                claim_promotion_receipt_path=promotion_path.name,
                release_artifact_bundle_path=release_path.name,
                root=root,
                verify_files_root=root,
            )
            final_failures = release_check.check_bundle(
                release_payload,
                verify_files_root=root,
                require_release_candidate=True,
                bundle_path=release_path.name,
            )

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["claimabilityStatus"], "claimable")
        self.assertEqual(
            report["componentReceipts"]["releaseArtifactBundle"]["status"],
            "pass",
        )
        self.assertTrue(
            any(
                item["code"] == "artifact_file_missing"
                and item["path"] == "runtimeFrontierBundle.path"
                for item in final_failures
            ),
            final_failures,
        )

    def test_frontier_inputs_must_match_release_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir); identity_path = root / "runtime-identity.json"; other_identity_path = root / "other-runtime-identity.json"; claim_report_path = root / "browser-claim-report.json"; promotion_path = root / "promotion-receipt.json"; other_promotion_path = root / "other-promotion-receipt.json"; release_path = root / "release-bundle.json"
            self._write_json(identity_path, self._claim_grade_identity()); self._write_json(other_identity_path, self._claim_grade_identity())
            claim_report_hash = self._write_json(claim_report_path, self._claimable_claim_report())
            promotion_hash = self._write_json(promotion_path, self._promotion_receipt(claim_report_path.name, claim_report_hash)); self._write_json(other_promotion_path, self._promotion_receipt(claim_report_path.name, claim_report_hash))
            self._write_json(release_path, self._verified_release_bundle(root, claim_report_path.name, claim_report_hash, promotion_path.name, promotion_hash, release_status="release_candidate", failure_codes=[]))
            promotion_report = bundle.build_report(runtime_identity_path=identity_path.name, claim_promotion_receipt_path=other_promotion_path.name, release_artifact_bundle_path=release_path.name, root=root, verify_files_root=root)
            identity_report = bundle.build_report(runtime_identity_path=other_identity_path.name, claim_promotion_receipt_path=promotion_path.name, release_artifact_bundle_path=release_path.name, root=root, verify_files_root=root)
        self.assertEqual(promotion_report["status"], "fail"); self.assertTrue(any(item["message"] == "claim promotion receipt path must match release bundle promotionReceipts" for item in promotion_report["failures"]))
        self.assertEqual(identity_report["status"], "fail"); self.assertTrue(any(item["message"] == "runtime identity path must match proof surface runtimeIdentityPath" for item in identity_report["failures"]))

    def test_release_candidate_without_file_verification_blocks_claimability(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            identity_path = root / "runtime-identity.json"
            claim_report_path = root / "browser-claim-report.json"
            promotion_path = root / "promotion-receipt.json"
            release_path = root / "release-bundle.json"

            self._write_json(identity_path, self._claim_grade_identity())
            self._write_json(claim_report_path, self._claimable_claim_report())
            self._write_json(
                promotion_path,
                self._promotion_receipt(claim_report_path.name),
            )
            self._write_json(
                release_path,
                self._release_bundle(
                    claim_report_path.name,
                    promotion_path.name,
                    release_status="release_candidate",
                    failure_codes=[],
                ),
            )

            report = bundle.build_report(
                runtime_identity_path=identity_path.name,
                claim_promotion_receipt_path=promotion_path.name,
                release_artifact_bundle_path=release_path.name,
                root=root,
            )

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["claimabilityStatus"], "blocked")
        self.assertIn(
            {
                "code": "chromium_release_build_evidence",
                "path": "releaseBundle.artifactVerification.verified",
                "message": "browser release artifact bundle must verify files and hashes with --verify-files-root",
            },
            report["claimBlockers"],
        )
        self.assertIn(
            {
                "code": "chromium_release_build_evidence",
                "message": "browser release artifact bundle must verify files and hashes with --verify-files-root",
                "count": 1,
            },
            report["claimBlockerSummary"],
        )
        artifact_verification = report["componentReceipts"]["releaseArtifactBundle"][
            "artifactVerification"
        ]
        self.assertFalse(artifact_verification["verifyFilesRootProvided"])
        self.assertFalse(artifact_verification["verified"])

    def test_nonclaimable_claim_report_blocks_structural_equivalence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            identity_path = root / "runtime-identity.json"
            claim_report_path = root / "browser-claim-report.json"
            promotion_path = root / "promotion-receipt.json"
            release_path = root / "release-bundle.json"

            claim_report = self._claimable_claim_report()
            claim_report["comparisonStatus"] = "diagnostic"
            claim_report["claimStatus"] = "diagnostic"
            claim_report["workloads"][0]["comparisonStatus"] = "diagnostic"
            claim_report["workloads"][0]["claimability"]["claimable"] = False

            self._write_json(identity_path, self._claim_grade_identity())
            self._write_json(claim_report_path, claim_report)
            self._write_json(
                promotion_path,
                self._promotion_receipt(claim_report_path.name),
            )
            self._write_json(
                release_path,
                self._release_bundle(
                    claim_report_path.name,
                    promotion_path.name,
                    release_status="release_candidate",
                    failure_codes=[],
                ),
            )

            report = bundle.build_report(
                runtime_identity_path=identity_path.name,
                claim_promotion_receipt_path=promotion_path.name,
                release_artifact_bundle_path=release_path.name,
                root=root,
            )

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["claimabilityStatus"], "blocked")
        self.assertIn(
            "browser_structural_equivalence_receipts",
            {item["code"] for item in report["claimBlockers"]},
        )

    def test_missing_structural_receipts_blocks_structural_equivalence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            identity_path = root / "runtime-identity.json"
            claim_report_path = root / "browser-claim-report.json"
            promotion_path = root / "promotion-receipt.json"
            release_path = root / "release-bundle.json"

            claim_report = self._claimable_claim_report()
            del claim_report["structuralReceipts"]

            self._write_json(identity_path, self._claim_grade_identity())
            self._write_json(claim_report_path, claim_report)
            self._write_json(
                promotion_path,
                self._promotion_receipt(claim_report_path.name),
            )
            self._write_json(
                release_path,
                self._release_bundle(
                    claim_report_path.name,
                    promotion_path.name,
                    release_status="release_candidate",
                    failure_codes=[],
                ),
            )

            report = bundle.build_report(
                runtime_identity_path=identity_path.name,
                claim_promotion_receipt_path=promotion_path.name,
                release_artifact_bundle_path=release_path.name,
                root=root,
            )

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["claimabilityStatus"], "blocked")
        self.assertIn(
            {
                "code": "browser_structural_equivalence_receipts",
                "path": "claimReports[0].structuralReceipts",
                "message": "browser claim report must include structural receipt summary",
            },
            report["claimBlockers"],
        )

    def test_release_candidate_failure_codes_block_claimability(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            identity_path = root / "runtime-identity.json"
            claim_report_path = root / "browser-claim-report.json"
            promotion_path = root / "promotion-receipt.json"
            release_path = root / "release-bundle.json"

            self._write_json(identity_path, self._claim_grade_identity())
            self._write_json(claim_report_path, self._claimable_claim_report())
            self._write_json(
                promotion_path,
                self._promotion_receipt(claim_report_path.name),
            )
            self._write_json(
                release_path,
                self._release_bundle(
                    claim_report_path.name,
                    promotion_path.name,
                    release_status="diagnostic",
                    failure_codes=[
                        {
                            "code": "missing_release_build",
                            "path": "browserBinary",
                            "message": "release build evidence is absent",
                        }
                    ],
                ),
            )

            report = bundle.build_report(
                runtime_identity_path=identity_path.name,
                claim_promotion_receipt_path=promotion_path.name,
                release_artifact_bundle_path=release_path.name,
                root=root,
            )

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["claimabilityStatus"], "blocked")
        self.assertIn(
            "chromium_release_build_evidence",
            {item["code"] for item in report["claimBlockers"]},
        )

    def test_diagnostic_promotion_failures_block_claimability_without_failing_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            identity_path = root / "runtime-identity.json"
            claim_report_path = root / "browser-claim-report.json"
            promotion_path = root / "promotion-receipt.json"
            release_path = root / "release-bundle.json"

            self._write_json(identity_path, self._claim_grade_identity())
            claim_report_hash = self._write_json(
                claim_report_path,
                self._claimable_claim_report(),
            )
            promotion_hash = self._write_json(
                promotion_path,
                self._diagnostic_promotion_receipt(
                    claim_report_path.name,
                    claim_report_hash,
                ),
            )
            self._write_json(
                release_path,
                self._verified_release_bundle(
                    root,
                    claim_report_path.name,
                    claim_report_hash,
                    promotion_path.name,
                    promotion_hash,
                    release_status="diagnostic",
                    failure_codes=[],
                ),
            )

            report = bundle.build_report(
                runtime_identity_path=identity_path.name,
                claim_promotion_receipt_path=promotion_path.name,
                release_artifact_bundle_path=release_path.name,
                root=root,
                verify_files_root=root,
            )

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["claimabilityStatus"], "blocked")
        self.assertEqual(report["failures"], [])
        self.assertIn(
            "claim_grade_browser_runtime_identity",
            {item["code"] for item in report["claimBlockers"]},
        )
        self.assertEqual(
            report["componentReceipts"]["claimPromotionReceipt"]["promotionStatus"],
            "diagnostic",
        )

    def test_release_candidate_promotion_failures_remain_hard_failures(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            identity_path = root / "runtime-identity.json"
            claim_report_path = root / "browser-claim-report.json"
            promotion_path = root / "promotion-receipt.json"
            release_path = root / "release-bundle.json"

            self._write_json(identity_path, self._claim_grade_identity())
            claim_report_hash = self._write_json(
                claim_report_path,
                self._claimable_claim_report(),
            )
            promotion_hash = self._write_json(
                promotion_path,
                self._diagnostic_promotion_receipt(
                    claim_report_path.name,
                    claim_report_hash,
                ),
            )
            self._write_json(
                release_path,
                self._verified_release_bundle(
                    root,
                    claim_report_path.name,
                    claim_report_hash,
                    promotion_path.name,
                    promotion_hash,
                    release_status="release_candidate",
                    failure_codes=[],
                ),
            )

            report = bundle.build_report(
                runtime_identity_path=identity_path.name,
                claim_promotion_receipt_path=promotion_path.name,
                release_artifact_bundle_path=release_path.name,
                root=root,
                verify_files_root=root,
            )

        self.assertEqual(report["status"], "fail")
        self.assertIn(
            "claim_promotion_receipt_failure",
            {item["code"] for item in report["failures"]},
        )

    def _claim_grade_identity(self) -> dict:
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_runtime_identity",
            "surface": "doe-gpu/browser",
            "evidenceSource": "runtime_selection_artifact",
            "selectedRuntime": "doe",
            "executionOwner": "chromium_runtime_selector",
            "doeRuntimeActive": True,
            "webgpuAvailable": True,
            "provider": {"source": "test"},
            "runtimeSelection": {
                "selectedRuntime": "doe",
                "fallbackApplied": False,
                "fallbackReasonCode": "",
                "hiddenFallbackAllowed": False,
                "selectorVersion": "browser-runtime-selector-v1",
            },
        }

    def _claimable_claim_report(self) -> dict:
        return {
            "schemaVersion": 1,
            "reportKind": "browser-claim-report",
            "comparisonStatus": "comparable",
            "claimStatus": "claimable",
            "structuralReceipts": self._structural_receipts(),
            "workloads": [
                {
                    "id": "browser_claim_sample",
                    "comparisonStatus": "comparable",
                    "claimability": {"claimable": True, "reasons": []},
                }
            ],
            "failures": [],
        }

    def _structural_receipts(self) -> dict:
        return {
            "status": "pass",
            "workloadCount": 1,
            "sourceKernelDispatchWorkloadCount": 1,
            "sourceCommandIdentity": {
                "verified": True,
                "commandsPathCount": 1,
                "kernelPathCount": 1,
                "hashesBound": True,
            },
            "dispatchShapeParity": {
                "verified": True,
                "dispatchShapeWorkloadCount": 1,
                "runtimeModeCount": 2,
            },
            "checkerReports": [
                {
                    "path": "browser-check.json",
                    "status": "pass",
                    "errorCount": 0,
                }
            ],
            "failureCodes": [],
        }

    def _promotion_receipt(
        self,
        claim_report_path: str,
        claim_report_sha256: str = "a" * 64,
    ) -> dict:
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_claim_promotion_receipt",
            "receiptId": "test-browser-claim-promotion",
            "claimPolicyPath": "config/browser-claim-policy.json",
            "promotionStatus": "promotable",
            "artifacts": [
                {
                    "path": claim_report_path,
                    "sha256": claim_report_sha256,
                    "mode": "doe",
                    "forcedDoe": True,
                    "hiddenFallbackUsed": False,
                    "claimPolicyPassed": True,
                }
            ],
            "hiddenFallbackCheck": {"required": True, "passed": True},
            "failureCodes": [],
        }

    def _diagnostic_promotion_receipt(
        self,
        claim_report_path: str,
        claim_report_sha256: str,
    ) -> dict:
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_claim_promotion_receipt",
            "receiptId": "test-browser-claim-promotion-diagnostic",
            "claimPolicyPath": "config/browser-claim-policy.json",
            "promotionStatus": "diagnostic",
            "artifacts": [
                {
                    "path": claim_report_path,
                    "sha256": claim_report_sha256,
                    "mode": "doe",
                    "forcedDoe": False,
                    "hiddenFallbackUsed": False,
                    "claimPolicyPassed": False,
                }
            ],
            "hiddenFallbackCheck": {"required": True, "passed": False},
            "failureCodes": [],
        }

    def _release_bundle(
        self,
        claim_report_path: str,
        promotion_receipt_path: str,
        *,
        release_status: str,
        failure_codes: list[dict[str, str]],
    ) -> dict:
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_release_artifact_bundle",
            "bundleId": "test-browser-runtime-frontier",
            "releaseStatus": release_status,
            "browserProduct": {
                **DEFAULT_BROWSER_PRODUCT,
                "channel": release_status,
            },
            "releaseArchive": {
                **self._artifact(
                    "Fawn-Doe-macos-arm64.zip",
                    "browser_release_archive",
                ),
                "downloadUrl": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
            },
            "releaseArchiveManifest": self._artifact(
                "browser-release-archive-manifest.json",
                "browser_release_archive_manifest",
            ),
            "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"},
            "packageInputs": self._artifact(
                "browser-release-package-inputs-check.json",
                "browser_release_package_inputs_check",
            ),
            "browserExecutableArchivePath": DEFAULT_BROWSER_ARCHIVE_PATH,
            "browserAppMetadataArchivePath": DEFAULT_APP_METADATA_ARCHIVE_PATH,
            "doeRuntimeArchivePath": DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
            "dawnFallbackRuntimeArchivePath": DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
            "browserBinary": self._artifact("chrome", "browser_binary"),
            "doeRuntime": self._artifact("libwebgpu_doe.so", "doe_runtime"),
            "dawnFallbackRuntime": self._artifact("libdawn_native.so", "dawn_fallback_runtime"),
            "shaderCompiler": self._artifact("doe-zig-runtime", "shader_compiler"),
            "proofSurface": self._artifact(
                "browser-published-proof-surface.json",
                "browser_published_proof_surface",
            ),
            "proofSurfaceCheck": self._artifact(
                "browser-published-proof-surface-check.json",
                "browser_published_proof_surface_check",
            ),
            "publicDownloadReceipt": self._artifact(
                "browser-public-download-receipt.json",
                "browser_public_download_receipt",
            ),
            "browserLaunchReceipt": self._artifact(
                "browser-release-launch-receipt.json",
                "browser_release_launch_receipt",
            ),
            "chromiumSourceCheckout": self._artifact(
                "chromium-source-checkout-check.json",
                "chromium_source_checkout_check",
            ),
            "runtimeFrontierBundle": self._artifact("browser-runtime-frontier-bundle.json", "browser_runtime_frontier_bundle"),
            "contracts": [self._artifact("contract.md", "contract")],
            "claimReports": [self._artifact(claim_report_path, "browser_claim_report")],
            "promotionReceipts": [
                self._artifact(
                    promotion_receipt_path,
                    "browser_claim_promotion_receipt",
                )
            ],
            "policies": [
                self._artifact(f"{kind}.json", kind)
                for kind in sorted(release_check.REQUIRED_POLICY_KINDS)
            ],
            "failureCodes": failure_codes,
        }

    def _verified_release_bundle(
        self,
        root: Path,
        claim_report_path: str,
        claim_report_sha256: str,
        promotion_receipt_path: str,
        promotion_receipt_sha256: str,
        *,
        release_status: str,
        failure_codes: list[dict[str, str]],
    ) -> dict:
        release_archive = self._write_artifact_zip(root, "Fawn-Doe-macos-arm64.zip", "browser_release_archive", DEFAULT_BROWSER_ARCHIVE_PATH, self._macho_payload())
        release_archive = {**release_archive, "downloadUrl": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip"}
        browser_binary = self._write_artifact_file(root, "chrome", "browser_binary", self._macho_payload())
        doe_runtime = self._write_artifact_file(root, "libwebgpu_doe.so", "doe_runtime", self._macho_payload())
        dawn_runtime = self._write_artifact_file(root, "libdawn_native.so", "dawn_fallback_runtime", self._macho_payload())
        shader_compiler = self._write_artifact_file(root, "doe-zig-runtime", "shader_compiler", self._macho_payload())
        package_inputs = self._write_artifact_json(
            root,
            "browser-release-package-inputs-check.json",
            "browser_release_package_inputs_check",
            self._package_inputs_payload(
                browser_binary,
                doe_runtime,
                dawn_runtime,
                shader_compiler,
                release_status,
            ),
        )
        release_archive_manifest = self._write_release_archive_manifest_artifact(
            root,
            "browser-release-archive-manifest.json",
            "Fawn-Doe-macos-arm64.zip",
            release_status,
            package_inputs,
        )
        public_download_receipt = self._write_artifact_json(
            root, "browser-public-download-receipt.json", "browser_public_download_receipt",
            self._public_download_receipt_payload(
                root,
                "Fawn-Doe-macos-arm64.zip",
                release_archive_manifest,
                release_status,
            ),
        )
        runtime_frontier_bundle = self._write_artifact_json(
            root, "browser-runtime-frontier-bundle.json", "browser_runtime_frontier_bundle",
            {"schemaVersion": 1, "artifactKind": "browser_runtime_frontier_bundle", "status": "pass", "claimabilityStatus": "claimable", "claimBlockers": [], "claimBlockerSummary": [], "failures": [], "summary": {"claimBlockerCount": 0, "failureCount": 0}, "componentReceipts": {"runtimeIdentity": {"path": "runtime-identity.json", "status": "pass"}, "claimPromotionReceipt": {"path": promotion_receipt_path, "status": "pass", "promotionStatus": "promotable"}, "releaseArtifactBundle": {"path": "release-bundle.json", "status": "pass", "bundleId": "test-browser-runtime-frontier", "releaseStatus": release_status, "artifactVerification": {"verified": True}}}},
        )
        chromium_source_checkout = self._write_chromium_source_checkout_artifact(
            root,
            "chromium-source-checkout-check.json",
        )
        proof_surface = self._write_proof_surface_artifact(
            root,
            release_archive,
            release_archive_manifest,
            public_download_receipt,
            browser_binary,
            doe_runtime,
            dawn_runtime,
            release_status,
        )
        browser_launch_receipt = self._write_browser_launch_receipt_artifact(
            root,
            "browser-release-launch-receipt.json",
            release_archive,
            release_archive_manifest,
            proof_surface,
            release_status,
        )
        proof_surface_check = self._write_artifact_json(
            root,
            "browser-published-proof-surface-check.json",
            "browser_published_proof_surface_check",
            {
                "schemaVersion": 1,
                "artifactKind": "browser_published_proof_surface_check",
                "surfacePath": proof_surface["path"],
                "surfaceSha256": proof_surface["sha256"],
                "status": "pass",
                "verifyFilesRootProvided": True,
                "requirePublicUrls": True,
                "failures": [],
            },
        )
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_release_artifact_bundle",
            "bundleId": "test-browser-runtime-frontier",
            "releaseStatus": release_status,
            "browserProduct": {**DEFAULT_BROWSER_PRODUCT, "channel": release_status},
            "releaseArchive": release_archive,
            "releaseArchiveManifest": release_archive_manifest,
            "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"},
            "packageInputs": package_inputs,
            "browserExecutableArchivePath": DEFAULT_BROWSER_ARCHIVE_PATH,
            "browserAppMetadataArchivePath": DEFAULT_APP_METADATA_ARCHIVE_PATH,
            "doeRuntimeArchivePath": DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
            "dawnFallbackRuntimeArchivePath": DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
            "browserBinary": browser_binary,
            "doeRuntime": doe_runtime,
            "dawnFallbackRuntime": dawn_runtime,
            "shaderCompiler": shader_compiler,
            "proofSurface": proof_surface,
            "proofSurfaceCheck": proof_surface_check,
            "publicDownloadReceipt": public_download_receipt,
            "browserLaunchReceipt": browser_launch_receipt,
            "chromiumSourceCheckout": chromium_source_checkout,
            "runtimeFrontierBundle": runtime_frontier_bundle,
            "contracts": [self._write_artifact_file(root, "contract.md", "contract", "contract\n")],
            "claimReports": [{"path": claim_report_path, "sha256": claim_report_sha256, "kind": "browser_claim_report"}],
            "promotionReceipts": [{"path": promotion_receipt_path, "sha256": promotion_receipt_sha256, "kind": "browser_claim_promotion_receipt"}],
            "policies": [
                self._write_artifact_json(
                    root,
                    f"{kind}.json",
                    kind,
                    {"schemaVersion": 1, "kind": kind},
                )
                for kind in sorted(release_check.REQUIRED_POLICY_KINDS)
            ],
            "failureCodes": failure_codes,
        }

    def _public_download_receipt_payload(
        self,
        root: Path,
        archive_path: str,
        release_archive_manifest: dict[str, str],
        release_status: str,
    ) -> dict:
        path = root / archive_path
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_public_download_receipt",
            "receiptId": "test-browser-public-download",
            "url": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
            "method": "GET",
            "statusCode": 200,
            "contentSha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "contentLengthBytes": path.stat().st_size,
            "releaseArchivePath": archive_path,
            "releaseArchiveManifestPath": release_archive_manifest["path"],
            "releaseArchiveManifestSha256": release_archive_manifest["sha256"],
            "browserProduct": {
                **DEFAULT_BROWSER_PRODUCT,
                "channel": release_status,
            },
            "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"},
            "browserExecutableArchivePath": DEFAULT_BROWSER_ARCHIVE_PATH,
            "browserAppMetadataArchivePath": DEFAULT_APP_METADATA_ARCHIVE_PATH,
            "doeRuntimeArchivePath": DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
            "dawnFallbackRuntimeArchivePath": DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
            "observedAt": "2026-06-30T00:00:00Z",
        }

    def _package_inputs_payload(
        self,
        browser_binary: dict[str, str],
        doe_runtime: dict[str, str],
        dawn_runtime: dict[str, str],
        shader_compiler: dict[str, str],
        release_status: str,
    ) -> dict:
        candidate = release_status == "release_candidate"
        metadata_bytes = self._app_metadata_bytes()
        macho_length = len(self._macho_payload())
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_release_package_inputs_check",
            "status": "pass",
            "packageDir": {"path": "Fawn.app", "exists": True},
            "packageRootName": "Fawn.app",
            "browserProduct": {**DEFAULT_BROWSER_PRODUCT, "channel": release_status},
            "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"},
            "evidenceMode": "release_candidate" if candidate else "diagnostic",
            "releaseCandidateEligible": candidate,
            "releaseCandidateBlockers": [] if candidate else [
                {
                    "code": "release_candidate_channel_required",
                    "path": "browserProduct.channel",
                    "message": "initial browser release artifact must use release_candidate channel",
                }
            ],
            "inputs": {
                "browserExecutable": {
                    **browser_binary,
                    "archivePath": DEFAULT_BROWSER_ARCHIVE_PATH,
                    "exists": True,
                    "generated": False,
                    "byteLength": macho_length,
                    "executable": True,
                    "detectedFormat": "macho",
                    "detectedArchitectures": ["arm64"],
                },
                "appMetadata": {
                    "kind": "browser_app_metadata",
                    "path": "Info.plist",
                    "archivePath": DEFAULT_APP_METADATA_ARCHIVE_PATH,
                    "sha256": hashlib.sha256(metadata_bytes).hexdigest(),
                    "exists": True,
                    "generated": False,
                    "byteLength": len(metadata_bytes),
                    "executable": False,
                    "detectedFormat": "plist",
                    "detectedArchitectures": [],
                },
                "doeRuntime": {
                    **doe_runtime,
                    "archivePath": DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
                    "exists": True,
                    "generated": False,
                    "byteLength": macho_length,
                    "executable": True,
                    "detectedFormat": "macho",
                    "detectedArchitectures": ["arm64"],
                },
                "dawnFallbackRuntime": {
                    **dawn_runtime,
                    "archivePath": DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
                    "exists": True,
                    "generated": False,
                    "byteLength": macho_length,
                    "executable": True,
                    "detectedFormat": "macho",
                    "detectedArchitectures": ["arm64"],
                },
                "shaderCompiler": {
                    **shader_compiler,
                    "exists": True,
                    "generated": False,
                    "byteLength": macho_length,
                    "executable": True,
                    "detectedFormat": "macho",
                    "detectedArchitectures": ["arm64"],
                },
            },
            "overwrittenPackageMembers": [],
            "failures": [],
            "summary": {
                "packageable": True,
                "metadataSource": "package",
                "requiredArchiveMemberCount": 4,
                "runtimeReplacementCount": 0,
            },
        }

    def _write_chromium_source_checkout_artifact(
        self,
        root: Path,
        path: str,
    ) -> dict[str, str]:
        return self._write_artifact_json(
            root,
            path,
            "chromium_source_checkout_check",
            {
                "schemaVersion": 1,
                "artifactKind": "chromium_source_checkout_check",
                "sourceRoot": "browser/chromium/src",
                "requireReady": True,
                "requireRuntimeSelector": True,
                "status": "pass",
                "checks": [
                    {
                        "checkId": "source_root",
                        "status": "pass",
                        "required": True,
                        "path": "browser/chromium/src",
                        "message": "Chromium source root exists",
                    }
                ],
                "missingRequired": [],
            },
        )

    def _write_browser_launch_receipt_artifact(
        self,
        root: Path,
        path: str,
        release_archive: dict[str, str],
        release_archive_manifest: dict[str, str],
        proof_surface: dict[str, str],
        release_status: str,
    ) -> dict[str, str]:
        return self._write_artifact_json(
            root,
            path,
            "browser_release_launch_receipt",
            {
                "schemaVersion": 1,
                "artifactKind": "browser_release_launch_receipt",
                "receiptId": "test-browser-release-launch",
                "observedAt": "2026-06-30T00:00:00Z",
                "launchSource": "release_archive",
                "browserProduct": {
                    **DEFAULT_BROWSER_PRODUCT,
                    "channel": release_status,
                },
                "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"},
                "releaseArchive": release_archive,
                "releaseArchiveManifest": release_archive_manifest,
                "proofSurface": proof_surface,
                "browserExecutableArchivePath": DEFAULT_BROWSER_ARCHIVE_PATH,
                "browserAppMetadataArchivePath": DEFAULT_APP_METADATA_ARCHIVE_PATH,
                "doeRuntimeArchivePath": DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
                "dawnFallbackRuntimeArchivePath": DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
                "runtimeMode": "doe",
                "activeRuntime": "doe",
                "activeBackend": "webgpu-doe",
                "hiddenFallbackAllowed": False,
                "hiddenFallbackUsed": False,
                "webgpuAvailable": True,
                "proofPage": {
                    "url": "about:doe",
                    "loaded": True,
                    "artifactPath": "proof-page.html",
                    "receiptId": "test-browser-proof-page",
                },
                "galleryPage": {
                    "url": "https://gallery.doe.dev/doe/compute.html",
                    "loaded": True,
                    "category": "compute",
                    "artifactPath": "compute.html",
                    "receiptId": "browser-public-gallery-compute",
                },
                "comparisonReceipt": {
                    "comparisonId": "test-comparison",
                    "workloadId": "test-workload",
                    "pageArtifactPath": "compute.html",
                    "loaded": True,
                    "executionScope": "same_page",
                    "modes": ["dawn", "doe"],
                    "emitsSideBySideReceipts": True,
                    "comparisonArtifactPath": "comparison.json",
                    "dawnReceiptId": "dawn-receipt",
                    "doeReceiptId": "doe-receipt",
                },
                "observedReceiptIds": [
                    "test-browser-proof-page",
                    "browser-public-gallery-compute",
                    "dawn-receipt",
                    "doe-receipt",
                ],
            },
        )

    def _artifact(self, path: str, kind: str) -> dict[str, str]:
        return {"path": path, "sha256": "b" * 64, "kind": kind}

    def _write_proof_surface_artifact(
        self,
        root: Path,
        release_archive: dict[str, str],
        release_archive_manifest: dict[str, str],
        public_download_receipt: dict[str, str],
        browser_binary: dict[str, str],
        doe_runtime: dict[str, str],
        dawn_runtime: dict[str, str],
        release_status: str,
    ) -> dict[str, str]:
        release_provenance = self._release_provenance(
            release_archive,
            release_archive_manifest,
            public_download_receipt,
            release_status,
        )
        self._write_artifact_json(root, "browser-capture-policy.json", "browser_capture_policy", self._capture_policy_payload())
        self._write_artifact_json(
            root,
            "runtime-identity.json",
            "browser_runtime_identity",
            self._runtime_identity_payload(browser_binary, doe_runtime, dawn_runtime),
        )
        proof_page = self._write_artifact_file(
            root,
            "proof-page.html",
            "browser_proof_page",
            "\n".join(
                [
                    "<!doctype html>",
                    "<title>proof</title>",
                    "<main>",
                    "<p>doe</p>",
                    "<p>webgpu-doe</p>",
                    "<p>doe-zig-runtime</p>",
                    "<p>webgpuAvailable</p>",
                    "<p>true</p>",
                    "<p>available</p>",
                    "<p>not_applicable</p>",
                    "<p>hidden_fallback_disabled</p>",
                    "<p>Fawn Doe</p>",
                    "<p>0.0.0-test</p>",
                    f"<p>{release_status}</p>",
                    "<p>macos arm64 zip</p>",
                    f"<p>{release_archive['path']}</p>",
                    f"<p>{release_archive['sha256']}</p>",
                    f"<p>{release_archive['downloadUrl']}</p>",
                    f"<p>{release_archive_manifest['path']}</p>",
                    f"<p>{release_archive_manifest['sha256']}</p>",
                    f"<p>{public_download_receipt['path']}</p>",
                    f"<p>{public_download_receipt['sha256']}</p>",
                    f"<p>{DEFAULT_BROWSER_ARCHIVE_PATH}</p>",
                    f"<p>{DEFAULT_APP_METADATA_ARCHIVE_PATH}</p>",
                    f"<p>{DEFAULT_DOE_RUNTIME_ARCHIVE_PATH}</p>",
                    f"<p>{DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH}</p>",
                    "<p>compute.html</p>",
                    "<p>same_page</p>",
                    "<p>dawn doe</p>",
                    "<p>side_by_side_receipts</p>",
                    '<a href="comparison.json">test-comparison</a>',
                    "<p>test-workload</p>",
                    '<a href="dawn-receipt.json">dawn-receipt</a>',
                    '<a href="doe-receipt.json">doe-receipt</a>',
                    "</main>",
                    "",
                ]
            ),
        )
        proof_page_receipt = self._write_artifact_json(
            root,
            "proof-page-receipt.json",
            "browser_proof_page_receipt",
            self._proof_page_receipt_payload(root, "proof-page.html", release_provenance),
        )
        dawn_payload = self._execution_receipt_payload("dawn")
        doe_payload = self._execution_receipt_payload("doe")
        comparison_artifact = self._write_artifact_json(
            root,
            "comparison.json",
            "chromium-webgpu-playwright-smoke",
            self._comparison_artifact_payload(dawn_payload, doe_payload),
        )
        dawn_receipt = self._write_artifact_json(
            root,
            "dawn-receipt.json",
            "browser_execution_receipt",
            dawn_payload,
        )
        doe_receipt = self._write_artifact_json(
            root,
            "doe-receipt.json",
            "browser_execution_receipt",
            doe_payload,
        )
        self._write_artifact_file(root, "contract.md", "contract", "contract\n")
        gallery_artifacts = {
            category: self._write_artifact_file(
                root,
                f"{category}.html",
                "browser_gallery_page",
                "\n".join(
                    [
                        "<!doctype html>",
                        f"<title>{category}</title>",
                        "<main>",
                        f"<h1>{category}</h1>",
                        '<a href="contract.md">contract.md</a>',
                        "<p>compute.html</p>",
                        "<p>same_page</p>",
                        "<p>dawn doe</p>",
                        "<p>side_by_side_receipts</p>",
                        '<a href="comparison.json">test-comparison</a>',
                        "<p>test-workload</p>",
                        "<p>workload: test-workload</p>",
                        '<a href="dawn-receipt.json">dawn-receipt</a>',
                        '<a href="doe-receipt.json">doe-receipt</a>',
                        *self._gallery_receipt_fact_lines(dawn_payload),
                        *self._gallery_receipt_fact_lines(doe_payload),
                        "</main>",
                        "",
                    ]
                ),
            )
            for category in GALLERY_CATEGORIES
        }
        gallery_public_receipts = {
            category: self._write_artifact_json(
                root,
                f"{category}.public-gallery-receipt.json",
                "browser_public_gallery_receipt",
                self._public_gallery_receipt_payload(
                    root,
                    category,
                    f"{category}.html",
                    "contract.md",
                    ["test-workload"],
                ),
            )
            for category in GALLERY_CATEGORIES
        }
        return self._write_artifact_json(
            root,
            "browser-published-proof-surface.json",
            "browser_published_proof_surface",
            self._proof_surface_payload(
                proof_page,
                proof_page_receipt,
                comparison_artifact,
                dawn_receipt,
                doe_receipt,
                gallery_artifacts,
                gallery_public_receipts,
                release_provenance,
            ),
        )

    def _release_provenance(
        self,
        release_archive: dict[str, str],
        release_archive_manifest: dict[str, str],
        public_download_receipt: dict[str, str],
        release_status: str,
    ) -> dict:
        return {
            "browserProduct": {**DEFAULT_BROWSER_PRODUCT, "channel": release_status},
            "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"},
            "releaseArchive": release_archive,
            "releaseArchiveManifest": release_archive_manifest,
            "publicDownloadReceipt": public_download_receipt,
            "browserExecutableArchivePath": DEFAULT_BROWSER_ARCHIVE_PATH,
            "browserAppMetadataArchivePath": DEFAULT_APP_METADATA_ARCHIVE_PATH,
            "doeRuntimeArchivePath": DEFAULT_DOE_RUNTIME_ARCHIVE_PATH,
            "dawnFallbackRuntimeArchivePath": DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH,
        }

    def _capture_policy_payload(self) -> dict:
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_capture_policy",
            "policyId": "test-browser-capture-policy",
            "surfaces": [
                {
                    "surfaceId": "gpu_flight_recorder",
                    "originScoped": True,
                    "permissionGate": "secure_context_devtools_opt_in",
                    "rawPageDataPolicy": "hash",
                    "artifactDataPolicy": "hashes_and_redacted_metadata",
                    "replayAllowed": True,
                    "developerVisible": True,
                },
                {
                    "surfaceId": "flight_replay",
                    "originScoped": True,
                    "permissionGate": "secure_context_devtools_opt_in",
                    "rawPageDataPolicy": "forbid",
                    "artifactDataPolicy": "metadata_only",
                    "replayAllowed": True,
                    "developerVisible": True,
                },
                {
                    "surfaceId": "shader_links",
                    "originScoped": True,
                    "permissionGate": "devtools_opt_in",
                    "rawPageDataPolicy": "redact",
                    "artifactDataPolicy": "hashes_and_redacted_metadata",
                    "replayAllowed": False,
                    "developerVisible": True,
                    "reasonCode": "source_link_only",
                },
                {
                    "surfaceId": "media_path_probe",
                    "originScoped": True,
                    "permissionGate": "secure_context_devtools_opt_in",
                    "rawPageDataPolicy": "hash",
                    "artifactDataPolicy": "hashes_and_redacted_metadata",
                    "replayAllowed": False,
                    "developerVisible": True,
                    "reasonCode": "media_probe_digest_only",
                },
                {
                    "surfaceId": "pipeline_cache_receipts",
                    "originScoped": True,
                    "permissionGate": "devtools_opt_in",
                    "rawPageDataPolicy": "forbid",
                    "artifactDataPolicy": "metadata_only",
                    "replayAllowed": False,
                    "developerVisible": True,
                    "reasonCode": "receipt_only",
                },
                {
                    "surfaceId": "published_proof_surface",
                    "originScoped": True,
                    "permissionGate": "secure_context_devtools_opt_in",
                    "rawPageDataPolicy": "forbid",
                    "artifactDataPolicy": "hashes_and_redacted_metadata",
                    "replayAllowed": False,
                    "developerVisible": True,
                    "reasonCode": "published_browser_proof",
                },
                {
                    "surfaceId": "unsupported_explanations",
                    "originScoped": True,
                    "permissionGate": "devtools_opt_in",
                    "rawPageDataPolicy": "forbid",
                    "artifactDataPolicy": "metadata_only",
                    "replayAllowed": False,
                    "developerVisible": True,
                    "reasonCode": "diagnostic_only",
                },
            ],
        }

    def _runtime_identity_payload(
        self,
        browser_binary: dict[str, str],
        doe_runtime: dict[str, str],
        dawn_runtime: dict[str, str],
    ) -> dict:
        artifact_identity = {
            "browserExecutablePath": browser_binary["path"],
            "browserExecutableSha256": browser_binary["sha256"],
            "dawnRuntimePath": dawn_runtime["path"],
            "dawnRuntimeSha256": dawn_runtime["sha256"],
            "doeLibPath": doe_runtime["path"],
            "doeLibSha256": doe_runtime["sha256"],
        }
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_runtime_identity",
            "surface": "doe-gpu/browser",
            "evidenceSource": "runtime_selection_artifact",
            "selectedRuntime": "doe",
            "executionOwner": "chromium_runtime_selector",
            "doeRuntimeActive": True,
            "webgpuAvailable": True,
            "provider": {
                "artifactIdentity": artifact_identity,
            },
            "runtimeSelection": {
                "selectedRuntime": "doe",
                "fallbackApplied": False,
                "fallbackReasonCode": "",
                "hiddenFallbackAllowed": False,
                "selectorVersion": "browser-runtime-selector-v1",
                "artifactIdentity": artifact_identity,
            },
        }

    def _execution_receipt_payload(self, selected_runtime: str) -> dict:
        source = "@compute @workgroup_size(1) fn main() {}"
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_execution_receipt",
            "receiptId": f"{selected_runtime}-receipt",
            "workloadId": "test-workload",
            "selectedRuntime": selected_runtime,
            "sourceShader": {
                "language": "wgsl",
                "source": source,
                "sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
            },
            "loweringPath": ["wgsl", selected_runtime],
            "backend": f"webgpu-{selected_runtime}",
            "driver": {
                "vendor": "test",
                "api": "webgpu",
                "driver": "test-driver",
                "deviceFamily": "test-adapter-family",
                "profileId": "test-webgpu-adapter",
            },
            "device": {
                "adapterInfoSha256": "a" * 64,
                "featureCount": 1,
                "adapter": "test-adapter",
                "device": "test-device",
            },
            "commandGraph": {
                "graphSha256": "e" * 64,
                "artifactPath": "comparison.json",
            },
            "commandCoverage": {
                "commandCount": 1,
                "successCount": 1,
                "dispatchCount": 1,
            },
            "outputHash": "d" * 64,
            "runtimeSelectorState": {
                "selectionMode": selected_runtime,
                "selectedRuntime": selected_runtime,
                "forcedMode": selected_runtime,
                "fallbackApplied": False,
                "hiddenFallbackAllowed": False,
                "fallbackReasonCode": "",
                "selectorVersion": "browser-runtime-selector-v1",
            },
            "fallbackState": {
                "fallbackApplied": False,
                "hiddenFallbackAllowed": False,
                "reasonCode": "",
            },
            "timing": {
                "timingClass": "browser-operation-proxy",
                "phases": {
                    "setupNs": 1,
                    "encodeNs": 1,
                    "submitWaitNs": 1,
                },
            },
        }

    def _proof_surface_payload(
        self,
        proof_page: dict[str, str],
        proof_page_receipt: dict[str, str],
        comparison_artifact: dict[str, str],
        dawn_receipt: dict[str, str],
        doe_receipt: dict[str, str],
        gallery_artifacts: dict[str, dict[str, str]],
        gallery_public_receipts: dict[str, dict[str, str]],
        release_provenance: dict,
    ) -> dict:
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_published_proof_surface",
            "surfaceId": "test-browser-proof-surface",
            "capturePolicyPath": "browser-capture-policy.json",
            "runtimeIdentityPath": "runtime-identity.json",
            "proofPage": {
                "artifact": proof_page,
                "url": "about:doe",
                "diagnosticReceipt": proof_page_receipt,
                "diagnostics": {
                    "activeRuntime": "doe",
                    "activeBackend": "webgpu-doe",
                    "compilerPath": "doe-zig-runtime",
                    **CONCRETE_RELEASE_PROOF_DIAGNOSTICS,
                    "fallbackPolicyState": "hidden_fallback_disabled",
                },
                "releaseProvenance": release_provenance,
                "recentReceiptIds": ["dawn-receipt", "doe-receipt"],
                "receiptPayloads": [
                    {
                        "receiptId": "dawn-receipt",
                        **dawn_receipt,
                    },
                    {
                        "receiptId": "doe-receipt",
                        **doe_receipt,
                    }
                ],
            },
            "galleryPages": [
                {
                    "category": category,
                    "url": f"https://gallery.doe.dev/doe/{category}.html",
                    "artifact": gallery_artifacts[category],
                    "publicReceipt": gallery_public_receipts[category],
                    "workloadContractPath": "contract.md",
                    "workloadIds": ["test-workload"],
                    "receiptIds": ["dawn-receipt", "doe-receipt"],
                    "receiptArtifacts": [
                        {
                            "receiptId": "dawn-receipt",
                            **dawn_receipt,
                        },
                        {
                            "receiptId": "doe-receipt",
                            **doe_receipt,
                        }
                    ],
                }
                for category in GALLERY_CATEGORIES
            ],
            "comparisonReceipts": [
                {
                    "comparisonId": "test-comparison",
                    "workloadId": "test-workload",
                    "runner": {
                        "pageArtifactPath": "compute.html",
                        "executionScope": "same_page",
                        "modes": ["dawn", "doe"],
                        "emitsSideBySideReceipts": True,
                    },
                    "comparisonPolicy": {
                        "workloadIdentity": "same_workload_id",
                        "sourceShaderIdentity": "same_source_shader_identity",
                        "adapterDeviceIdentity": "same_device_identity",
                        "timingScope": "browser-operation-proxy",
                        "commandCoverage": "exact_match",
                        "outputIdentity": "same_output_hash",
                        "fallbackPolicy": "no_hidden_fallback",
                    },
                    "comparisonArtifact": comparison_artifact,
                    "dawnReceipt": {
                        "receiptId": "dawn-receipt",
                        **dawn_receipt,
                    },
                    "doeReceipt": {
                        "receiptId": "doe-receipt",
                        **doe_receipt,
                    },
                }
            ],
        }

    def _gallery_receipt_fact_lines(self, receipt: dict[str, Any]) -> list[str]:
        source_shader = receipt["sourceShader"]
        driver = receipt["driver"]
        device = receipt["device"]
        timing = receipt["timing"]
        phases = timing["phases"]
        return [
            f"<p>{receipt['backend']}</p>",
            f"<p>{source_shader['language']}</p>",
            f"<p>{source_shader['source']}</p>",
            f"<p>{source_shader['sha256']}</p>",
            f"<p>{' > '.join(receipt['loweringPath'])}</p>",
            f"<p>{driver['api']}</p>",
            f"<p>{driver['driver']}</p>",
            f"<p>{driver['deviceFamily']}</p>",
            f"<p>{driver['profileId']}</p>",
            f"<p>{device['adapter']}</p>",
            f"<p>{device['adapterInfoSha256']}</p>",
            f"<p>featureCount={device['featureCount']}</p>",
            f"<p>{receipt['outputHash']}</p>",
            f"<p>{timing['timingClass']}</p>",
            f"<p>setupNs={phases['setupNs']}</p>",
            f"<p>encodeNs={phases['encodeNs']}</p>",
            f"<p>submitWaitNs={phases['submitWaitNs']}</p>",
        ]

    def _comparison_artifact_payload(
        self,
        dawn_payload: dict[str, Any],
        doe_payload: dict[str, Any],
    ) -> dict[str, Any]:
        payload = _load_json(REPO_ROOT / "examples" / "browser-smoke-report.sample.json")
        receipts = {"dawn": dawn_payload, "doe": doe_payload}
        for row in payload["modeResults"]:
            mode = row["mode"]
            receipt = receipts[mode]
            selector = receipt["runtimeSelectorState"]
            selection = row["runtimeSelection"]
            for field in (
                "selectionMode",
                "selectedRuntime",
                "forcedMode",
                "fallbackApplied",
                "hiddenFallbackAllowed",
                "fallbackReasonCode",
                "selectorVersion",
            ):
                selection[field] = selector[field]
            driver = receipt["driver"]
            selection["profile"] = {
                field: driver[field]
                for field in ("profileId", "vendor", "api", "deviceFamily", "driver")
            }
            device = receipt["device"]
            row["adapterIdentity"] = {
                "adapterInfoSha256": device["adapterInfoSha256"],
                "featureCount": device["featureCount"],
                "adapter": device["adapter"],
                "device": device["device"],
            }

        previous_hash = None
        for row in payload["modeResults"]:
            row["previousHash"] = previous_hash
            row["hash"] = stable_hash(
                {
                    "previousHash": previous_hash,
                    "entry": _without_hash_fields(row, ("previousHash", "hash")),
                }
            )
            previous_hash = row["hash"]
        payload["reportHash"] = stable_hash(
            _without_hash_fields(payload, ("reportHash",))
        )
        return payload

    def _proof_page_receipt_payload(
        self,
        root: Path,
        artifact_path: str,
        release_provenance: dict,
    ) -> dict:
        path = root / artifact_path
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_proof_page_receipt",
            "receiptId": "test-browser-proof-page",
            "url": "about:doe",
            "loadType": "browser_internal_page",
            "status": "loaded",
            "contentSha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "contentLengthBytes": path.stat().st_size,
            "proofArtifactPath": artifact_path,
            "runtimeIdentityPath": "runtime-identity.json",
            "diagnostics": {
                "activeRuntime": "doe",
                "activeBackend": "webgpu-doe",
                "compilerPath": "doe-zig-runtime",
                **CONCRETE_RELEASE_PROOF_DIAGNOSTICS,
                "fallbackPolicyState": "hidden_fallback_disabled",
            },
            "releaseProvenance": release_provenance,
            "recentReceiptIds": ["dawn-receipt", "doe-receipt"],
            "observedAt": "2026-06-30T00:00:00Z",
        }

    def _public_gallery_receipt_payload(
        self,
        root: Path,
        category: str,
        artifact_path: str,
        workload_contract_path: str,
        workload_ids: list[str],
    ) -> dict:
        path = root / artifact_path
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_public_gallery_receipt",
            "receiptId": f"browser-public-gallery-{category}",
            "category": category,
            "url": f"https://gallery.doe.dev/doe/{category}.html",
            "method": "GET",
            "statusCode": 200,
            "contentSha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "contentLengthBytes": path.stat().st_size,
            "galleryArtifactPath": artifact_path,
            "workloadContractPath": workload_contract_path,
            "workloadIds": workload_ids,
            "receiptIds": ["dawn-receipt", "doe-receipt"],
            "receiptArtifactPaths": ["dawn-receipt.json", "doe-receipt.json"],
            "observedAt": "2026-06-30T00:00:00Z",
        }

    def _macho_payload(self) -> bytes:
        return struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)

    def _write_artifact_file(
        self,
        root: Path,
        relative_path: str,
        kind: str,
        contents: str | bytes,
    ) -> dict[str, str]:
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(contents, bytes):
            path.write_bytes(contents)
        else:
            path.write_text(contents, encoding="utf-8")
        return self._artifact_for_path(root, relative_path, kind)

    def _write_artifact_json(
        self,
        root: Path,
        relative_path: str,
        kind: str,
        payload: dict,
    ) -> dict[str, str]:
        self._write_json(root / relative_path, payload)
        return self._artifact_for_path(root, relative_path, kind)

    def _write_artifact_zip(
        self,
        root: Path,
        relative_path: str,
        kind: str,
        browser_member_path: str,
        browser_member_contents: str | bytes,
    ) -> dict[str, str]:
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        info = zipfile.ZipInfo("README.txt", (1980, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_STORED
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(info, "browser release archive fixture\n")
            browser_info = zipfile.ZipInfo(browser_member_path, (1980, 1, 1, 0, 0, 0))
            browser_info.compress_type = zipfile.ZIP_STORED
            browser_info.external_attr = 0o755 << 16
            archive.writestr(browser_info, browser_member_contents)
            for member_path, contents, executable in (
                (DEFAULT_APP_METADATA_ARCHIVE_PATH, self._app_metadata_bytes(), False),
                (DEFAULT_DOE_RUNTIME_ARCHIVE_PATH, self._macho_payload(), True),
                (DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH, self._macho_payload(), True),
            ):
                member_info = zipfile.ZipInfo(member_path, (1980, 1, 1, 0, 0, 0))
                member_info.compress_type = zipfile.ZIP_STORED
                if executable:
                    member_info.external_attr = 0o755 << 16
                archive.writestr(member_info, contents)
        return self._artifact_for_path(root, relative_path, kind)

    def _app_metadata_bytes(self) -> bytes:
        return plistlib.dumps({
            "CFBundleDisplayName": "Fawn Doe",
            "CFBundleExecutable": "Chromium",
            "CFBundleIdentifier": "dev.doe.fawn-doe",
            "CFBundleName": "Fawn Doe",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.0.0-test",
            "CFBundleVersion": "0.0.0-test",
        })

    def _write_release_archive_manifest_artifact(
        self,
        root: Path,
        relative_path: str,
        archive_path: str,
        release_status: str,
        source_package_inputs: dict[str, str] | None = None,
    ) -> dict[str, str]:
        archive_file = root / archive_path
        with zipfile.ZipFile(archive_file) as archive:
            def member(name: str) -> dict:
                info = archive.getinfo(name); data = archive.read(name); mode = (info.external_attr >> 16) & 0o777
                return {"archivePath": name, "sha256": hashlib.sha256(data).hexdigest(), "byteLength": len(data), "executable": bool(mode & 0o100)}
            names = sorted(info.filename for info in archive.infolist() if info.filename.startswith("Fawn.app/") and not info.is_dir())
            payload = {"schemaVersion": 1, "artifactKind": "browser_release_archive_manifest", "archive": {"path": archive_path, "sha256": hashlib.sha256(archive_file.read_bytes()).hexdigest(), "byteLength": archive_file.stat().st_size, "kind": "browser_release_archive"}, "browserProduct": {**DEFAULT_BROWSER_PRODUCT, "channel": release_status}, "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"}, "appBundleName": "Fawn.app", "members": {"browserExecutable": member(DEFAULT_BROWSER_ARCHIVE_PATH), "appMetadata": member(DEFAULT_APP_METADATA_ARCHIVE_PATH), "doeRuntime": member(DEFAULT_DOE_RUNTIME_ARCHIVE_PATH), "dawnFallbackRuntime": member(DEFAULT_DAWN_RUNTIME_ARCHIVE_PATH)}, "archiveMembers": [member(name) for name in names]}
        if source_package_inputs is not None:
            payload["sourcePackageInputs"] = source_package_inputs
            package_inputs = _load_json(root / source_package_inputs["path"])
            for role, row in package_inputs["inputs"].items():
                if role in payload["members"] and isinstance(row, dict):
                    payload["members"][role]["sourcePath"] = row["path"]
            payload["archiveMembers"] = [
                payload["members"][role]
                for role in (
                    "appMetadata",
                    "browserExecutable",
                    "dawnFallbackRuntime",
                    "doeRuntime",
                )
            ]
        return self._write_artifact_json(root, relative_path, "browser_release_archive_manifest", payload)

    def _artifact_for_path(
        self,
        root: Path,
        relative_path: str,
        kind: str,
    ) -> dict[str, str]:
        path = root / relative_path
        return {"path": relative_path, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "kind": kind}

    def _write_json(self, path: Path, payload: dict) -> str:
        path.parent.mkdir(parents=True, exist_ok=True)
        contents = json.dumps(payload, indent=2) + "\n"
        path.write_text(contents, encoding="utf-8")
        return hashlib.sha256(contents.encode("utf-8")).hexdigest()

if __name__ == "__main__":
    unittest.main()
