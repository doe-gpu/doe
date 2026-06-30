#!/usr/bin/env python3
"""Tests for composed browser runtime frontier bundle receipts."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import jsonschema

from bench.tools import check_browser_runtime_frontier_bundle as bundle
from bench.tools import check_browser_release_artifact_bundle as release_check


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "config" / "browser-runtime-frontier-bundle.schema.json"
SAMPLE_PATH = REPO_ROOT / "examples" / "browser-runtime-frontier-bundle.sample.json"


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class BrowserRuntimeFrontierBundleTests(unittest.TestCase):
    def test_sample_matches_checker_and_schema(self) -> None:
        report = bundle.build_report(
            runtime_identity_path="examples/browser-runtime-identity.selector.sample.json",
            claim_promotion_receipt_path="examples/browser-claim-promotion-receipt.sample.json",
            release_artifact_bundle_path="examples/browser-release-artifact-bundle.sample.json",
            root=REPO_ROOT,
            verify_files_root=REPO_ROOT,
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
                "verifyFilesRootProvided": True,
                "verified": True,
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
            "browserBinary": self._artifact("chrome", "browser_binary"),
            "doeRuntime": self._artifact("libwebgpu_doe.so", "doe_runtime"),
            "shaderCompiler": self._artifact("doe-zig-runtime", "shader_compiler"),
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
        return {
            "schemaVersion": 1,
            "artifactKind": "browser_release_artifact_bundle",
            "bundleId": "test-browser-runtime-frontier",
            "releaseStatus": release_status,
            "browserBinary": self._write_artifact_file(
                root,
                "chrome",
                "browser_binary",
                "browser binary\n",
            ),
            "doeRuntime": self._write_artifact_file(
                root,
                "libwebgpu_doe.so",
                "doe_runtime",
                "doe runtime\n",
            ),
            "shaderCompiler": self._write_artifact_file(
                root,
                "doe-zig-runtime",
                "shader_compiler",
                "shader compiler\n",
            ),
            "contracts": [
                self._write_artifact_file(root, "contract.md", "contract", "contract\n")
            ],
            "claimReports": [
                {
                    "path": claim_report_path,
                    "sha256": claim_report_sha256,
                    "kind": "browser_claim_report",
                }
            ],
            "promotionReceipts": [
                {
                    "path": promotion_receipt_path,
                    "sha256": promotion_receipt_sha256,
                    "kind": "browser_claim_promotion_receipt",
                }
            ],
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

    def _artifact(self, path: str, kind: str) -> dict[str, str]:
        return {"path": path, "sha256": "b" * 64, "kind": kind}

    def _write_artifact_file(
        self,
        root: Path,
        relative_path: str,
        kind: str,
        contents: str,
    ) -> dict[str, str]:
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
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

    def _artifact_for_path(
        self,
        root: Path,
        relative_path: str,
        kind: str,
    ) -> dict[str, str]:
        path = root / relative_path
        return {
            "path": relative_path,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "kind": kind,
        }

    def _write_json(self, path: Path, payload: dict) -> str:
        path.parent.mkdir(parents=True, exist_ok=True)
        contents = json.dumps(payload, indent=2) + "\n"
        path.write_text(contents, encoding="utf-8")
        return hashlib.sha256(contents.encode("utf-8")).hexdigest()


if __name__ == "__main__":
    unittest.main()
