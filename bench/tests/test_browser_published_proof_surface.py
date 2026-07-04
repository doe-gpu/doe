#!/usr/bin/env python3
"""Tests for published browser proof surface checks."""

from __future__ import annotations

import copy
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

import jsonschema

from bench.browser.browser_gate import stable_hash
from bench.tools import check_browser_published_proof_surface as proof_check


REPO_ROOT = Path(__file__).resolve().parents[2]
SAMPLE_PATH = REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json"
SCHEMA_PATH = REPO_ROOT / "config" / "browser-published-proof-surface.schema.json"
CHECK_SCHEMA_PATH = REPO_ROOT / "config" / "browser-published-proof-surface-check.schema.json"
EXECUTION_RECEIPT_SCHEMA_PATH = REPO_ROOT / "config" / "browser-execution-receipt.schema.json"
PROOF_PAGE_RECEIPT_SCHEMA_PATH = REPO_ROOT / "config" / "browser-proof-page-receipt.schema.json"
PUBLIC_GALLERY_SCHEMA_PATH = REPO_ROOT / "config" / "browser-public-gallery-receipt.schema.json"
PUBLIC_DOWNLOAD_SCHEMA_PATH = REPO_ROOT / "config" / "browser-public-download-receipt.schema.json"
DAWN_RECEIPT_SAMPLE_PATH = REPO_ROOT / "examples" / "browser-dawn-execution-receipt.sample.json"
DOE_RECEIPT_SAMPLE_PATH = REPO_ROOT / "examples" / "browser-doe-execution-receipt.sample.json"


def _load() -> dict:
    return json.loads(SAMPLE_PATH.read_text(encoding="utf-8"))


def _load_doe_receipt() -> dict:
    return json.loads(DOE_RECEIPT_SAMPLE_PATH.read_text(encoding="utf-8"))


def _artifact(path: Path, receipt_id: str) -> dict:
    return {
        "receiptId": receipt_id,
        "path": path.name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "kind": "browser_execution_receipt",
    }


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


class BrowserPublishedProofSurfaceTests(unittest.TestCase):
    def test_sample_passes_check(self) -> None:
        jsonschema.validate(_load(), json.loads(SCHEMA_PATH.read_text(encoding="utf-8")))
        self.assertEqual(
            proof_check.check_surface(
                _load(),
                verify_files_root=REPO_ROOT,
                root=REPO_ROOT,
            ),
            [],
        )

    def test_sample_passes_public_release_surface_check(self) -> None:
        self.assertEqual(
            proof_check.check_surface(
                _load(),
                verify_files_root=REPO_ROOT,
                root=REPO_ROOT,
                require_public_urls=True,
            ),
            [],
        )

    def test_checker_cli_writes_schema_backed_report(self) -> None:
        with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
            out_path = Path(tmpdir) / "browser-published-proof-surface-check.json"
            old_argv = sys.argv
            try:
                sys.argv = [
                    "check_browser_published_proof_surface.py",
                    "--surface",
                    str(SAMPLE_PATH),
                    "--verify-files-root",
                    str(REPO_ROOT),
                    "--require-public-urls",
                    "--out",
                    str(out_path),
                ]
                self.assertEqual(proof_check.main(), 0)
            finally:
                sys.argv = old_argv

            report = json.loads(out_path.read_text(encoding="utf-8"))
            jsonschema.validate(
                report,
                json.loads(CHECK_SCHEMA_PATH.read_text(encoding="utf-8")),
            )
            self.assertEqual(report["artifactKind"], "browser_published_proof_surface_check")
            self.assertEqual(report["surfaceSha256"], hashlib.sha256(SAMPLE_PATH.read_bytes()).hexdigest())
            self.assertTrue(report["verifyFilesRootProvided"])
            self.assertTrue(report["requirePublicUrls"])
            self.assertEqual(report["status"], "pass")
            self.assertEqual(report["failures"], [])

    def test_checker_report_schema_requires_failures_on_fail(self) -> None:
        schema = json.loads(CHECK_SCHEMA_PATH.read_text(encoding="utf-8"))
        report = {
            "schemaVersion": 1,
            "artifactKind": "browser_published_proof_surface_check",
            "surfacePath": "examples/browser-published-proof-surface.sample.json",
            "surfaceSha256": "0" * 64,
            "verifyFilesRootProvided": True,
            "requirePublicUrls": True,
            "status": "fail",
            "failures": [],
        }
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(report, schema)

    def test_schema_requires_published_receipt_surface(self) -> None:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        missing_proof_receipt = copy.deepcopy(_load()); del missing_proof_receipt["proofPage"]["diagnosticReceipt"]
        missing_gallery_receipt = copy.deepcopy(_load()); del missing_gallery_receipt["galleryPages"][0]["publicReceipt"]
        missing_comparison_policy = copy.deepcopy(_load()); del missing_comparison_policy["comparisonReceipts"][0]["comparisonPolicy"]
        missing_gallery_workload_ids = copy.deepcopy(_load()); del missing_gallery_workload_ids["galleryPages"][0]["workloadIds"]
        with self.assertRaises(jsonschema.ValidationError): jsonschema.validate(missing_proof_receipt, schema)
        with self.assertRaises(jsonschema.ValidationError): jsonschema.validate(missing_gallery_receipt, schema)
        with self.assertRaises(jsonschema.ValidationError): jsonschema.validate(missing_comparison_policy, schema)
        with self.assertRaises(jsonschema.ValidationError): jsonschema.validate(missing_gallery_workload_ids, schema)
        bad_gallery_url = copy.deepcopy(_load()); bad_gallery_url["galleryPages"][0]["url"] = "http://gallery.doe.dev/doe/compute.html"
        with self.assertRaises(jsonschema.ValidationError): jsonschema.validate(bad_gallery_url, schema)

    def test_schema_requires_gallery_category_coverage(self) -> None:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        payload = copy.deepcopy(_load())
        payload["galleryPages"] = [
            row for row in payload["galleryPages"] if row["category"] != "tensor"
        ]
        payload["galleryPages"].append(copy.deepcopy(payload["galleryPages"][0]))

        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(payload, schema)

    def test_schema_requires_active_doe_diagnostics(self) -> None:
        schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        payload = copy.deepcopy(_load())
        payload["proofPage"]["diagnostics"]["activeRuntime"] = "dawn"
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(payload, schema)

        payload = copy.deepcopy(_load())
        payload["proofPage"]["diagnostics"]["fallbackPolicyState"] = "fallback_allowed"
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(payload, schema)

        payload = copy.deepcopy(_load())
        payload["proofPage"]["diagnostics"]["webgpuAvailable"] = False
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(payload, schema)

        schema = json.loads(PROOF_PAGE_RECEIPT_SCHEMA_PATH.read_text(encoding="utf-8"))
        receipt = json.loads(
            (REPO_ROOT / "examples" / "browser-proof-page-receipt.sample.json").read_text(
                encoding="utf-8"
            )
        )
        jsonschema.validate(receipt, schema)
        receipt["diagnostics"]["activeRuntime"] = "dawn"
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(receipt, schema)

        receipt = json.loads(
            (REPO_ROOT / "examples" / "browser-proof-page-receipt.sample.json").read_text(
                encoding="utf-8"
            )
        )
        receipt["diagnostics"]["fallbackPolicyState"] = "fallback_allowed"
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(receipt, schema)

        receipt = json.loads(
            (REPO_ROOT / "examples" / "browser-proof-page-receipt.sample.json").read_text(
                encoding="utf-8"
            )
        )
        receipt["diagnostics"]["webgpuAvailable"] = False
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(receipt, schema)

    def test_public_receipt_schemas_require_https(self) -> None:
        schema = json.loads(PUBLIC_GALLERY_SCHEMA_PATH.read_text(encoding="utf-8"))
        receipt = json.loads((REPO_ROOT / "examples" / "browser-public-gallery-receipt.sample.json").read_text(encoding="utf-8"))
        jsonschema.validate(receipt, schema); receipt["url"] = "http://gallery.doe.dev/doe/compute.html"
        with self.assertRaises(jsonschema.ValidationError): jsonschema.validate(receipt, schema)
        schema = json.loads(PUBLIC_DOWNLOAD_SCHEMA_PATH.read_text(encoding="utf-8"))
        receipt = json.loads((REPO_ROOT / "examples" / "browser-public-download-receipt.sample.json").read_text(encoding="utf-8"))
        jsonschema.validate(receipt, schema); receipt["url"] = "http://downloads.doe.dev/Fawn-Doe-macos-arm64.zip"
        with self.assertRaises(jsonschema.ValidationError): jsonschema.validate(receipt, schema)

    def test_execution_receipt_schema_binds_selector_runtime(self) -> None:
        schema = json.loads(EXECUTION_RECEIPT_SCHEMA_PATH.read_text(encoding="utf-8"))
        receipt = _load_doe_receipt()
        jsonschema.validate(receipt, schema)

        receipt["runtimeSelectorState"]["selectedRuntime"] = "dawn"
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(receipt, schema)

        receipt = _load_doe_receipt()
        receipt["runtimeSelectorState"]["fallbackReasonCode"] = "fallback"
        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(receipt, schema)

    def test_public_gallery_urls_are_required_when_requested(self) -> None:
        payload = copy.deepcopy(_load())
        del payload["galleryPages"][0]["url"]

        self.assertIn(
            {
                "code": "missing_gallery_page_url",
                "path": "galleryPages[0].url",
                "message": "release proof gallery pages must include a hosted HTTPS URL",
            },
            proof_check.check_surface(
                payload,
                verify_files_root=REPO_ROOT,
                root=REPO_ROOT,
                require_public_urls=True,
            ),
        )

    def test_public_gallery_urls_must_be_https(self) -> None:
        payload = copy.deepcopy(_load())
        for row in payload["galleryPages"]:
            row["url"] = f"https://gallery.doe.dev/doe/{row['category']}.html"
        payload["galleryPages"][0]["url"] = "http://localhost/compute.html"

        self.assertIn(
            {
                "code": "invalid_gallery_page_url",
                "path": "galleryPages[0].url",
                "message": "release proof gallery page URL must be public HTTPS",
            },
            proof_check.check_surface(
                payload,
                verify_files_root=REPO_ROOT,
                root=REPO_ROOT,
                require_public_urls=True,
            ),
        )

    def test_public_gallery_urls_reject_reserved_hosts(self) -> None:
        payload = copy.deepcopy(_load())
        for row in payload["galleryPages"]:
            row["url"] = f"https://gallery.doe.dev/doe/{row['category']}.html"
        payload["galleryPages"][0]["url"] = "https://example.invalid/compute.html"

        self.assertIn(
            {
                "code": "invalid_gallery_page_url",
                "path": "galleryPages[0].url",
                "message": "release proof gallery page URL must be public HTTPS",
            },
            proof_check.check_surface(
                payload,
                verify_files_root=REPO_ROOT,
                root=REPO_ROOT,
                require_public_urls=True,
            ),
        )

    def test_public_gallery_receipts_are_required_when_public_urls_are_required(self) -> None:
        payload = copy.deepcopy(_load())
        for row in payload["galleryPages"]:
            row["url"] = f"https://gallery.doe.dev/doe/{row['category']}.html"
        del payload["galleryPages"][0]["publicReceipt"]

        self.assertIn(
            {
                "code": "missing_gallery_public_receipt",
                "path": "galleryPages[0].publicReceipt",
                "message": "release proof gallery pages must link a public gallery receipt",
            },
            proof_check.check_surface(
                payload,
                verify_files_root=REPO_ROOT,
                root=REPO_ROOT,
                require_public_urls=True,
            ),
        )

    def test_public_gallery_receipt_hash_must_match_artifact(self) -> None:
        failures = proof_check.check_public_gallery_receipt_payload(
            {
                "schemaVersion": 1,
                "artifactKind": "browser_public_gallery_receipt",
                "receiptId": "receipt",
                "category": "compute",
                "url": "https://gallery.doe.dev/doe/compute.html",
                "method": "GET",
                "statusCode": 200,
                "contentSha256": "0" * 64,
                "contentLengthBytes": 1,
                "galleryArtifactPath": "compute.html",
                "workloadContractPath": "contract.md",
                "workloadIds": ["browser-smoke-compute"],
                "receiptIds": ["browser-smoke-compute-doe"],
                "receiptArtifactPaths": ["receipt.json"],
                "observedAt": "2026-06-30T00:00:00Z",
            },
            {
                "category": "compute",
                "url": "https://gallery.doe.dev/doe/compute.html",
                "artifact": {
                    "path": "compute.html",
                    "sha256": "f" * 64,
                    "kind": "browser_gallery_page",
                },
                "workloadContractPath": "contract.md",
                "workloadIds": ["browser-smoke-compute"],
                "receiptIds": ["browser-smoke-compute-doe"],
                "receiptArtifacts": [{"path": "receipt.json"}],
            },
            "galleryPages[0]",
            None,
        )

        self.assertIn(
            {
                "code": "gallery_public_receipt_hash_mismatch",
                "path": "galleryPages[0].publicReceipt.contentSha256",
                "message": "gallery public receipt contentSha256 must match gallery artifact sha256",
            },
            failures,
        )

    def test_public_gallery_receipt_workload_ids_must_match(self) -> None:
        failures = proof_check.check_public_gallery_receipt_payload(
            {
                "schemaVersion": 1,
                "artifactKind": "browser_public_gallery_receipt",
                "receiptId": "receipt",
                "category": "compute",
                "url": "https://gallery.doe.dev/doe/compute.html",
                "method": "GET",
                "statusCode": 200,
                "contentSha256": "f" * 64,
                "contentLengthBytes": 1,
                "galleryArtifactPath": "compute.html",
                "workloadContractPath": "contract.md",
                "workloadIds": ["other-workload"],
                "receiptIds": ["browser-smoke-compute-doe"],
                "receiptArtifactPaths": ["receipt.json"],
                "observedAt": "2026-06-30T00:00:00Z",
            },
            {
                "category": "compute",
                "url": "https://gallery.doe.dev/doe/compute.html",
                "artifact": {
                    "path": "compute.html",
                    "sha256": "f" * 64,
                    "kind": "browser_gallery_page",
                },
                "workloadContractPath": "contract.md",
                "workloadIds": ["browser-smoke-compute"],
                "receiptIds": ["browser-smoke-compute-doe"],
                "receiptArtifacts": [{"path": "receipt.json"}],
            },
            "galleryPages[0]",
            None,
        )

    def test_public_gallery_receipt_artifact_paths_must_match(self) -> None:
        failures = proof_check.check_public_gallery_receipt_payload(
            {
                "schemaVersion": 1,
                "artifactKind": "browser_public_gallery_receipt",
                "receiptId": "receipt",
                "category": "compute",
                "url": "https://gallery.doe.dev/doe/compute.html",
                "method": "GET",
                "statusCode": 200,
                "contentSha256": "f" * 64,
                "contentLengthBytes": 1,
                "galleryArtifactPath": "compute.html",
                "workloadContractPath": "contract.md",
                "workloadIds": ["browser-smoke-compute"],
                "receiptIds": ["browser-smoke-compute-doe"],
                "receiptArtifactPaths": ["other-receipt.json"],
                "observedAt": "2026-06-30T00:00:00Z",
            },
            {
                "category": "compute",
                "url": "https://gallery.doe.dev/doe/compute.html",
                "artifact": {
                    "path": "compute.html",
                    "sha256": "f" * 64,
                    "kind": "browser_gallery_page",
                },
                "workloadContractPath": "contract.md",
                "workloadIds": ["browser-smoke-compute"],
                "receiptIds": ["browser-smoke-compute-doe"],
                "receiptArtifacts": [{"path": "receipt.json"}],
            },
            "galleryPages[0]",
            None,
        )

        self.assertIn(
            {
                "code": "gallery_public_receipt_artifact_paths_mismatch",
                "path": "galleryPages[0].publicReceipt.receiptArtifactPaths",
                "message": (
                    "gallery public receipt receiptArtifactPaths must match gallery "
                    "receipt artifacts"
                ),
            },
            failures,
        )

    def test_proof_page_diagnostic_receipt_is_required_when_public_urls_are_required(self) -> None:
        payload = copy.deepcopy(_load())
        del payload["proofPage"]["diagnosticReceipt"]

        self.assertIn(
            {
                "code": "missing_proof_page_diagnostic_receipt",
                "path": "proofPage.diagnosticReceipt",
                "message": "release proof page must link a diagnostic page receipt",
            },
            proof_check.check_surface(
                payload,
                verify_files_root=REPO_ROOT,
                root=REPO_ROOT,
                require_public_urls=True,
            ),
        )

    def test_proof_page_diagnostic_receipt_hash_must_match_artifact(self) -> None:
        failures = proof_check.check_proof_page_receipt_payload(
            {
                "schemaVersion": 1,
                "artifactKind": "browser_proof_page_receipt",
                "receiptId": "receipt",
                "url": "about:doe",
                "loadType": "browser_internal_page",
                "status": "loaded",
                "contentSha256": "0" * 64,
                "contentLengthBytes": 1,
                "proofArtifactPath": "proof.html",
                "runtimeIdentityPath": "runtime.json",
                "diagnostics": {
                    "activeRuntime": "doe",
                    "activeBackend": "webgpu",
                    "webgpuAvailable": True,
                    "compilerPath": "compiler",
                    "tsirStatus": "diagnostic",
                    "hostPlanStatus": "diagnostic",
                    "cslStatus": "diagnostic",
                    "fallbackPolicyState": "hidden_fallback_disabled",
                },
                "recentReceiptIds": ["receipt"],
                "observedAt": "2026-06-30T00:00:00Z",
            },
            {
                "artifact": {
                    "path": "proof.html",
                    "sha256": "f" * 64,
                    "kind": "browser_proof_page",
                },
                "url": "about:doe",
                "diagnostics": {
                    "activeRuntime": "doe",
                    "activeBackend": "webgpu",
                    "webgpuAvailable": True,
                    "compilerPath": "compiler",
                    "tsirStatus": "diagnostic",
                    "hostPlanStatus": "diagnostic",
                    "cslStatus": "diagnostic",
                    "fallbackPolicyState": "hidden_fallback_disabled",
                },
                "recentReceiptIds": ["receipt"],
            },
            "runtime.json",
            None,
        )

        self.assertIn(
            {
                "code": "proof_page_receipt_hash_mismatch",
                "path": "proofPage.diagnosticReceipt.contentSha256",
                "message": "proof page receipt contentSha256 must match proof page artifact sha256",
            },
            failures,
        )

    def test_proof_page_requires_release_provenance(self) -> None:
        payload = copy.deepcopy(_load())
        del payload["proofPage"]["releaseProvenance"]

        self.assertIn(
            {
                "code": "missing_release_provenance",
                "path": "proofPage.releaseProvenance",
                "message": "proof page must bind release provenance",
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_proof_page_content_must_link_recent_gallery_receipts(self) -> None:
        payload = copy.deepcopy(_load())
        html = (REPO_ROOT / "examples" / "browser-proof-page.sample.html").read_text(
            encoding="utf-8"
        )
        html = html.replace("examples/browser-tensor-execution-receipt.sample.json", "")
        with tempfile.TemporaryDirectory() as tmpdir:
            proof_path = Path(tmpdir) / "proof.html"
            proof_path.write_text(html, encoding="utf-8")
            payload["proofPage"]["artifact"]["path"] = "proof.html"

            self.assertIn(
                {
                    "code": "proof_page_missing_receipt_link",
                    "path": "galleryPages[2].receiptArtifacts[0].path",
                    "message": (
                        "proof page artifact must link receipt payload: "
                        "examples/browser-tensor-execution-receipt.sample.json"
                    ),
                },
                proof_check.check_proof_page_content(
                    payload["proofPage"],
                    Path(tmpdir),
                    payload,
                ),
            )

    def test_proof_page_receipt_release_provenance_must_match(self) -> None:
        payload = copy.deepcopy(_load())
        receipt = json.loads(
            (REPO_ROOT / "examples" / "browser-proof-page-receipt.sample.json").read_text(
                encoding="utf-8"
            )
        )
        receipt["releaseProvenance"]["releaseArchive"]["sha256"] = "0" * 64

        self.assertIn(
            {
                "code": "proof_page_receipt_release_provenance_mismatch",
                "path": "proofPage.diagnosticReceipt.releaseProvenance",
                "message": (
                    "proof page receipt releaseProvenance must match proof page "
                    "releaseProvenance"
                ),
            },
            proof_check.check_proof_page_receipt_payload(
                receipt,
                payload["proofPage"],
                payload["runtimeIdentityPath"],
                REPO_ROOT,
            ),
        )

    def test_proof_page_must_expose_comparison_artifact_link(self) -> None:
        payload = _load()
        row = payload["comparisonReceipts"][0]
        terms = [
            fragment
            for _, _, _, fragment in proof_check.comparison_visibility_requirements(
                row,
                "comparisonReceipts[0]",
            )
        ]
        comparison_artifact_path = row["comparisonArtifact"]["path"]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "proof.html").write_text(
                "\n".join(term for term in terms if term != comparison_artifact_path),
                encoding="utf-8",
            )
            (root / "gallery.html").write_text("\n".join(terms), encoding="utf-8")

            self.assertIn(
                {
                    "code": "proof_page_missing_comparison_artifact_link",
                    "path": "comparisonReceipts[0].comparisonArtifact.path",
                    "message": (
                        "proof page artifact must expose comparison artifact: "
                        f"{comparison_artifact_path}"
                    ),
                },
                proof_check.check_comparison_surface_visibility(
                    {
                        "artifact": {
                            "path": "proof.html",
                            "sha256": "0" * 64,
                            "kind": "browser_proof_page",
                        }
                    },
                    [
                        {
                            "artifact": {
                                "path": "gallery.html",
                                "sha256": "0" * 64,
                                "kind": "browser_gallery_page",
                            }
                        }
                    ],
                    [row],
                    root,
                ),
            )

    def test_gallery_must_expose_whole_comparison_on_one_page(self) -> None:
        payload = _load()
        row = payload["comparisonReceipts"][0]
        terms = [
            fragment
            for _, _, _, fragment in proof_check.comparison_visibility_requirements(
                row,
                "comparisonReceipts[0]",
            )
        ]
        split_at = len(terms) // 2
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "proof.html").write_text("\n".join(terms), encoding="utf-8")
            (root / "gallery-a.html").write_text("\n".join(terms[:split_at]), encoding="utf-8")
            (root / "gallery-b.html").write_text("\n".join(terms[split_at:]), encoding="utf-8")

            self.assertIn(
                {
                    "code": "gallery_page_missing_comparison_mode",
                    "path": "comparisonReceipts[0]",
                    "message": (
                        "at least one gallery page artifact must expose the comparison ID, "
                        "workload ID, comparison artifact, and both Dawn/Doe receipt links"
                    ),
                },
                proof_check.check_comparison_surface_visibility(
                    {
                        "artifact": {
                            "path": "proof.html",
                            "sha256": "0" * 64,
                            "kind": "browser_proof_page",
                        }
                    },
                    [
                        {
                            "artifact": {
                                "path": "gallery-a.html",
                                "sha256": "0" * 64,
                                "kind": "browser_gallery_page",
                            }
                        },
                        {
                            "artifact": {
                                "path": "gallery-b.html",
                                "sha256": "0" * 64,
                                "kind": "browser_gallery_page",
                            }
                        },
                    ],
                    [row],
                    root,
                ),
            )

    def test_comparison_receipt_requires_same_page_runner(self) -> None:
        payload = copy.deepcopy(_load())
        del payload["comparisonReceipts"][0]["runner"]

        self.assertIn(
            {
                "code": "missing_comparison_runner",
                "path": "comparisonReceipts[0].runner",
                "message": "comparison receipt must bind a same-page Dawn/Doe runner",
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_comparison_runner_page_must_be_gallery_artifact(self) -> None:
        payload = copy.deepcopy(_load())
        payload["comparisonReceipts"][0]["runner"]["pageArtifactPath"] = "examples/missing.html"

        self.assertIn(
            {
                "code": "comparison_runner_page_not_gallery",
                "path": "comparisonReceipts[0].runner.pageArtifactPath",
                "message": "comparison runner pageArtifactPath must match a gallery page artifact",
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_public_url_predicate_rejects_non_public_hosts(self) -> None:
        self.assertTrue(proof_check.is_public_https_url("https://gallery.doe.dev/compute.html"))
        self.assertFalse(proof_check.is_public_https_url("https://192.168.0.1/compute.html"))
        self.assertFalse(proof_check.is_public_https_url("https://release/compute.html"))
        self.assertFalse(proof_check.is_public_https_url("https://gallery.test/compute.html"))
        self.assertFalse(proof_check.is_public_https_url("https://downloads.example.com/browser.zip"))

    def test_missing_gallery_category_fails(self) -> None:
        payload = copy.deepcopy(_load())
        payload["galleryPages"] = [
            row for row in payload["galleryPages"] if row["category"] != "tensor"
        ]

        self.assertIn(
            {
                "code": "missing_gallery_category",
                "path": "galleryPages",
                "message": "missing required gallery category: tensor",
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_missing_proof_diagnostic_field_fails(self) -> None:
        payload = copy.deepcopy(_load())
        del payload["proofPage"]["diagnostics"]["activeBackend"]

        self.assertIn(
            {
                "code": "missing_proof_diagnostic_field",
                "path": "proofPage.diagnostics.activeBackend",
                "message": "proof page diagnostic field is required: activeBackend",
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_unavailable_webgpu_proof_diagnostic_fails(self) -> None:
        payload = copy.deepcopy(_load())
        payload["proofPage"]["diagnostics"]["webgpuAvailable"] = False

        self.assertIn(
            {
                "code": "missing_proof_diagnostic_field",
                "path": "proofPage.diagnostics.webgpuAvailable",
                "message": "proof page diagnostic field is required: webgpuAvailable",
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_release_proof_page_rejects_diagnostic_status_values(self) -> None:
        payload = copy.deepcopy(_load())
        payload["proofPage"]["releaseProvenance"]["browserProduct"]["channel"] = (
            "release_candidate"
        )
        payload["proofPage"]["diagnostics"]["tsirStatus"] = "diagnostic"

        self.assertIn(
            {
                "code": "non_release_proof_diagnostic_status",
                "path": "proofPage.diagnostics.tsirStatus",
                "message": (
                    "release proof page diagnostic status must be concrete: "
                    "tsirStatus"
                ),
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_proof_page_active_backend_must_match_doe_receipt_backend(self) -> None:
        payload = copy.deepcopy(_load())
        payload["proofPage"]["diagnostics"]["activeBackend"] = "webgpu"

        self.assertIn(
            {
                "code": "proof_page_active_backend_mismatch",
                "path": "proofPage.diagnostics.activeBackend",
                "message": (
                    "proof page activeBackend must match a linked Doe execution "
                    "receipt backend"
                ),
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_artifact_hash_mismatch_fails(self) -> None:
        payload = copy.deepcopy(_load())
        payload["proofPage"]["artifact"]["sha256"] = "0" * 64

        failures = proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT)

        self.assertTrue(any(item["code"] == "artifact_hash_mismatch" for item in failures))

    def test_unlinked_gallery_receipt_id_fails(self) -> None:
        payload = copy.deepcopy(_load())
        payload["galleryPages"][0]["receiptIds"] = ["missing-receipt"]

        self.assertIn(
            {
                "code": "unlinked_gallery_receipt_id",
                "path": "galleryPages[0].receiptIds[0]",
                "message": "gallery receipt ID has no linked artifact: missing-receipt",
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_comparison_requires_distinct_dawn_and_doe_receipts(self) -> None:
        payload = copy.deepcopy(_load())
        payload["comparisonReceipts"][0]["doeReceipt"] = copy.deepcopy(
            payload["comparisonReceipts"][0]["dawnReceipt"]
        )

        failures = proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT)

        self.assertTrue(
            any(item["code"] == "unpaired_comparison_receipt_ids" for item in failures)
        )
        self.assertTrue(
            any(item["code"] == "unpaired_comparison_receipt_paths" for item in failures)
        )

    def test_capture_policy_reference_must_pass_capture_policy_gate(self) -> None:
        payload = copy.deepcopy(_load())
        payload["capturePolicyPath"] = "examples/browser-dawn-execution-receipt.sample.json"

        failures = proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT)

        self.assertTrue(
            any(
                item["code"] == "missing_surface"
                and item["path"] == "capturePolicyPath.surfaces"
                and item["message"] == "missing capture policy surface published_proof_surface"
                for item in failures
            )
        )

    def test_runtime_identity_reference_must_bind_active_doe(self) -> None:
        payload = copy.deepcopy(_load())
        payload["runtimeIdentityPath"] = "examples/browser-runtime-identity.sample.json"

        failures = proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT)

        self.assertTrue(
            any(item["code"] == "proof_surface_runtime_not_doe" for item in failures)
        )
        self.assertTrue(
            any(item["code"] == "proof_surface_doe_runtime_inactive" for item in failures)
        )

    def test_execution_receipt_requires_command_evidence(self) -> None:
        payload = _load_doe_receipt()
        del payload["commandGraph"]

        self.assertIn(
            {
                "code": "missing_receipt_command_evidence",
                "path": "receipt.path",
                "message": "receipt payload must include commandGraph or flightRecorderRef identity",
            },
            proof_check.check_execution_receipt_payload(
                payload,
                "receipt",
                "browser-smoke-compute-doe",
                "doe",
            ),
        )

    def test_release_execution_receipt_requires_source_text(self) -> None:
        payload = _load_doe_receipt()
        del payload["sourceShader"]["source"]

        self.assertIn(
            {
                "code": "missing_receipt_source_text",
                "path": "receipt.path",
                "message": "receipt payload sourceShader.source is required",
            },
            proof_check.check_execution_receipt_payload(
                payload,
                "receipt",
                "browser-smoke-compute-doe",
                "doe",
            ),
        )

    def test_execution_receipt_requires_source_hash(self) -> None:
        payload = _load_doe_receipt()
        del payload["sourceShader"]["sha256"]

        self.assertIn(
            {
                "code": "missing_receipt_source_hash",
                "path": "receipt.path",
                "message": "receipt payload sourceShader.sha256 is required",
            },
            proof_check.check_execution_receipt_payload(
                payload,
                "receipt",
                "browser-smoke-compute-doe",
                "doe",
            ),
        )

    def test_execution_receipt_rejects_source_hash_mismatch(self) -> None:
        payload = _load_doe_receipt()
        payload["sourceShader"]["sha256"] = "0" * 64

        self.assertIn(
            {
                "code": "receipt_source_hash_mismatch",
                "path": "receipt.sourceShader.sha256",
                "message": "sourceShader.sha256 must match sha256(sourceShader.source)",
            },
            proof_check.check_execution_receipt_payload(
                payload,
                "receipt",
                "browser-smoke-compute-doe",
                "doe",
            ),
        )

    def test_execution_receipt_requires_complete_command_coverage(self) -> None:
        payload = _load_doe_receipt()
        payload["commandCoverage"]["successCount"] = 0
        payload["commandCoverage"]["dispatchCount"] = 2

        failures = proof_check.check_execution_receipt_payload(
            payload,
            "receipt",
            "browser-smoke-compute-doe",
            "doe",
        )

        self.assertIn(
            {
                "code": "incomplete_receipt_command_coverage",
                "path": "receipt.path",
                "message": "receipt payload commandCoverage.successCount must equal commandCount",
            },
            failures,
        )
        self.assertIn(
            {
                "code": "invalid_receipt_dispatch_count",
                "path": "receipt.path",
                "message": "receipt payload commandCoverage.dispatchCount cannot exceed commandCount",
            },
            failures,
        )

    def test_execution_receipt_rejects_selector_fallback_drift(self) -> None:
        payload = _load_doe_receipt()
        payload["runtimeSelectorState"]["fallbackApplied"] = True
        payload["runtimeSelectorState"]["fallbackReasonCode"] = "fallback"

        failures = proof_check.check_execution_receipt_payload(
            payload,
            "receipt",
            "browser-smoke-compute-doe",
            "doe",
        )

        self.assertIn(
            {
                "code": "receipt_selector_fallback_applied",
                "path": "receipt.path",
                "message": "runtimeSelectorState.fallbackApplied must be false",
            },
            failures,
        )

    def test_comparison_receipts_require_matching_work_evidence(self) -> None:
        dawn_payload = json.loads(DAWN_RECEIPT_SAMPLE_PATH.read_text(encoding="utf-8"))
        doe_payload = json.loads(DOE_RECEIPT_SAMPLE_PATH.read_text(encoding="utf-8"))
        doe_payload["outputHash"] = "f" * 64
        doe_payload["commandCoverage"]["successCount"] = 0
        doe_payload["driver"]["driver"] = "other-driver"

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            dawn_path = root / "dawn.json"
            doe_path = root / "doe.json"
            comparison_path = root / "comparison.json"
            dawn_path.write_text(json.dumps(dawn_payload), encoding="utf-8")
            doe_path.write_text(json.dumps(doe_payload), encoding="utf-8")
            comparison_path.write_text("{}", encoding="utf-8")

            failures = proof_check.check_comparison_receipts(
                [
                    {
                        "comparisonId": "comparison",
                        "workloadId": "browser-smoke-compute",
                        "comparisonArtifact": {
                            "path": "comparison.json",
                            "sha256": hashlib.sha256(comparison_path.read_bytes()).hexdigest(),
                            "kind": "chromium-webgpu-playwright-smoke",
                        },
                        "dawnReceipt": _artifact(dawn_path, "browser-smoke-compute-dawn"),
                        "doeReceipt": _artifact(doe_path, "browser-smoke-compute-doe"),
                    }
                ],
                root,
            )

        self.assertTrue(any(item["code"] == "comparison_output_identity_mismatch" for item in failures))
        self.assertTrue(any(item["code"] == "comparison_command_coverage_mismatch" for item in failures))
        self.assertTrue(any(item["code"] == "comparison_driver_identity_mismatch" for item in failures))

    def test_comparison_receipts_require_policy(self) -> None:
        payload = copy.deepcopy(_load())
        del payload["comparisonReceipts"][0]["comparisonPolicy"]

        self.assertIn(
            {
                "code": "missing_comparison_policy",
                "path": "comparisonReceipts[0].comparisonPolicy",
                "message": "comparison receipt must declare the paired evidence policy",
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_comparison_policy_must_match_receipt_output_identity_kind(self) -> None:
        payload = copy.deepcopy(_load())
        payload["comparisonReceipts"][0]["comparisonPolicy"]["outputIdentity"] = "same_frame_hash"

        self.assertIn(
            {
                "code": "comparison_policy_output_identity_mismatch",
                "path": "comparisonReceipts[0].comparisonPolicy.outputIdentity",
                "message": (
                    "comparison policy outputIdentity must match both receipt output "
                    "identity kinds"
                ),
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_comparison_artifact_must_be_smoke_report(self) -> None:
        payload = copy.deepcopy(_load())
        payload["comparisonReceipts"][0]["comparisonArtifact"]["kind"] = "browser_claim_report"

        self.assertIn(
            {
                "code": "unsupported_comparison_artifact_kind",
                "path": "comparisonReceipts[0].comparisonArtifact.kind",
                "message": "comparisonArtifact.kind must be chromium-webgpu-playwright-smoke",
            },
            proof_check.check_surface(payload, verify_files_root=REPO_ROOT, root=REPO_ROOT),
        )

    def test_comparison_artifact_mode_result_must_match_receipt_identity(self) -> None:
        payload = copy.deepcopy(_load())
        row = payload["comparisonReceipts"][0]
        smoke_path = REPO_ROOT / row["comparisonArtifact"]["path"]
        with tempfile.TemporaryDirectory(dir=REPO_ROOT) as temp_dir:
            root = Path(temp_dir)
            comparison_path = root / "browser-smoke-report.json"
            comparison_rel = comparison_path.relative_to(REPO_ROOT)
            comparison = json.loads(smoke_path.read_text(encoding="utf-8"))
            comparison["modeResults"][1]["runtimeSelection"]["profile"][
                "driver"
            ] = "sample-other-driver"
            _refresh_smoke_report_hashes(comparison)
            comparison_path.write_text(
                json.dumps(comparison, indent=2) + "\n",
                encoding="utf-8",
            )
            row["comparisonArtifact"] = {
                "path": comparison_rel.as_posix(),
                "sha256": hashlib.sha256(comparison_path.read_bytes()).hexdigest(),
                "kind": "chromium-webgpu-playwright-smoke",
            }

            failures = proof_check.check_comparison_receipts(
                [row],
                REPO_ROOT,
            )

        self.assertIn(
            {
                "code": "comparison_artifact_receipt_identity_mismatch",
                "path": "comparisonReceipts[0]",
                "message": (
                    "comparison artifact Doe modeResult "
                    "runtimeSelection.profile.driver must match Doe execution "
                    "receipt driver.driver"
                ),
            },
            failures,
        )

    def test_proof_page_artifact_must_show_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            proof_path = root / "proof.html"
            proof_path.write_text("<!doctype html><p>doe</p>\n", encoding="utf-8")
            failures = proof_check.check_proof_page_content(
                {
                    "artifact": {"path": "proof.html"},
                    "diagnostics": {
                        "activeRuntime": "doe",
                        "activeBackend": "webgpu",
                        "webgpuAvailable": True,
                    },
                    "recentReceiptIds": [],
                    "receiptPayloads": [],
                },
                root,
            )

        self.assertIn(
            {
                "code": "proof_page_missing_diagnostic_text",
                "path": "proofPage.artifact.activeBackend",
                "message": "proof page artifact must show diagnostic value: activeBackend",
            },
            failures,
        )

    def test_proof_page_artifact_must_show_webgpu_available(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            proof_path = root / "proof.html"
            proof_path.write_text("<!doctype html><p>doe webgpu</p>\n", encoding="utf-8")
            failures = proof_check.check_proof_page_content(
                {
                    "artifact": {"path": "proof.html"},
                    "diagnostics": {
                        "activeRuntime": "doe",
                        "activeBackend": "webgpu",
                        "webgpuAvailable": True,
                    },
                    "recentReceiptIds": [],
                    "receiptPayloads": [],
                },
                root,
            )

        self.assertIn(
            {
                "code": "proof_page_missing_diagnostic_text",
                "path": "proofPage.artifact.webgpuAvailable",
                "message": "proof page artifact must show diagnostic value: webgpuAvailable",
            },
            failures,
        )

    def test_proof_page_artifact_must_show_release_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            proof_path = root / "proof.html"
            proof_path.write_text("<!doctype html><p>Fawn Doe</p>\n", encoding="utf-8")
            failures = proof_check.check_proof_page_content(
                {
                    "artifact": {"path": "proof.html"},
                    "diagnostics": {},
                    "releaseProvenance": {
                        "browserProduct": {
                            "displayName": "Fawn Doe",
                            "version": "0.0.0-sample",
                            "channel": "diagnostic",
                        },
                        "platform": {"os": "macos", "arch": "arm64", "packageFormat": "zip"},
                        "releaseArchive": {
                            "path": "browser.zip",
                            "sha256": "f" * 64,
                            "downloadUrl": "https://downloads.doe.dev/Fawn-Doe.zip",
                        },
                        "releaseArchiveManifest": {
                            "path": "browser-release-archive-manifest.json",
                            "sha256": "d" * 64,
                        },
                        "publicDownloadReceipt": {
                            "path": "download.json",
                            "sha256": "e" * 64,
                        },
                    },
                    "recentReceiptIds": [],
                    "receiptPayloads": [],
                },
                root,
            )

        self.assertIn(
            {
                "code": "proof_page_missing_release_provenance_text",
                "path": "proofPage.releaseProvenance.browserProduct.version",
                "message": "proof page artifact must show browser version: 0.0.0-sample",
            },
            failures,
        )

    def test_gallery_page_artifact_must_link_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery_path = root / "gallery.html"
            gallery_path.write_text(
                '<!doctype html><h1>compute</h1><a href="receipt.json">receipt</a>\n',
                encoding="utf-8",
            )
            failures = proof_check.check_gallery_page_content(
                {
                    "category": "compute",
                    "artifact": {"path": "gallery.html"},
                    "workloadContractPath": "contract.md",
                    "receiptIds": ["receipt"],
                    "receiptArtifacts": [{"path": "receipt.json"}],
                },
                "galleryPages[0]",
                root,
            )

        self.assertIn(
            {
                "code": "gallery_page_missing_contract_link",
                "path": "galleryPages[0].workloadContractPath",
                "message": "gallery page artifact must link workload contract: contract.md",
            },
            failures,
        )

    def test_gallery_page_artifact_must_show_receipt_backend_facts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt_path = root / "receipt.json"
            receipt_payload = _load_doe_receipt()
            receipt_path.write_text(
                json.dumps(receipt_payload, indent=2) + "\n",
                encoding="utf-8",
            )
            visible_facts = [
                fragment
                for label, fragment in proof_check.receipt_visibility_fragments(receipt_payload)
                if label != "backend"
            ]
            gallery_path = root / "gallery.html"
            gallery_path.write_text(
                (
                    '<!doctype html><h1>compute</h1>'
                    '<a href="contract.md">contract.md</a>'
                    '<a href="receipt.json">receipt.json</a>'
                    + "".join(f"<p>{fragment}</p>" for fragment in visible_facts)
                    + "\n"
                ),
                encoding="utf-8",
            )
            failures = proof_check.check_gallery_page_content(
                {
                    "category": "compute",
                    "artifact": {"path": "gallery.html"},
                    "workloadContractPath": "contract.md",
                    "workloadIds": ["browser-smoke-compute"],
                    "receiptIds": ["browser-smoke-compute-doe"],
                    "receiptArtifacts": [_artifact(receipt_path, "browser-smoke-compute-doe")],
                },
                "galleryPages[0]",
                root,
            )

        self.assertIn(
            {
                "code": "gallery_page_missing_receipt_fact_text",
                "path": "galleryPages[0].receiptArtifacts[0]",
                "message": "gallery page artifact must show receipt backend: webgpu-doe",
            },
            failures,
        )


if __name__ == "__main__":
    unittest.main()
