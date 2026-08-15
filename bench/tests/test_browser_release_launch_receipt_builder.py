#!/usr/bin/env python3
"""Tests for browser release launch receipt building."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

import jsonschema

from bench.tools import build_browser_release_launch_receipt as builder


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = REPO_ROOT / "config" / "browser-release-launch-receipt.schema.json"
DEFAULT_PRODUCT = {
    "productId": "fawn-doe",
    "displayName": "Fawn Doe",
    "version": "0.0.0-test",
    "channel": "release_candidate",
}
DEFAULT_PLATFORM = {"os": "macos", "arch": "arm64", "packageFormat": "zip"}
PROOF_PAGE_ARTIFACT_PATH = "examples/browser-proof-page.sample.html"
PROOF_PAGE_RECEIPT_ID = "browser-proof-page-sample"
GALLERY_URL = "https://gallery.doe.dev/doe/compute.html"
GALLERY_CATEGORY = "compute"
GALLERY_ARTIFACT_PATH = "examples/browser-gallery-compute.sample.html"
GALLERY_RECEIPT_ID = "browser-public-gallery-compute"
COMPARISON_ID = "browser-smoke-compute-dawn-vs-doe"
COMPARISON_WORKLOAD_ID = "browser-smoke-compute"
COMPARISON_ARTIFACT_PATH = "examples/browser-smoke-report.sample.json"
COMPARISON_DAWN_RECEIPT_ID = "browser-smoke-compute-dawn"
COMPARISON_DOE_RECEIPT_ID = "browser-smoke-compute-doe"
MACOS_BROWSER_EXECUTABLE = "Fawn.app/Contents/MacOS/Chromium"
MACOS_APP_METADATA = "Fawn.app/Contents/Info.plist"
MACOS_DOE_RUNTIME = "Fawn.app/Contents/Frameworks/libwebgpu_doe.so"
MACOS_DAWN_RUNTIME = "Fawn.app/Contents/Frameworks/libdawn_native.so"


def _write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _write_inputs(root: Path) -> dict[str, Path]:
    release_archive = root / "Fawn-Doe-macos-arm64.zip"
    release_archive_manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
    proof_surface = root / "browser-published-proof-surface.json"
    proof_page_receipt = root / "browser-proof-page-receipt.json"
    gallery_receipt = root / "browser-public-gallery-receipt.json"
    clean_install_check = root / "browser-release-clean-install-check.json"
    clean_install_verifier = root / "clean-install-verifier.py"
    smoke_script = root / "webgpu-smoke.mjs"
    smoke_report = root / "webgpu-smoke.json"
    clean_install_verifier.write_text("# fixture verifier\n", encoding="utf-8")
    smoke_script.write_text("// fixture smoke\n", encoding="utf-8")
    _write_json(smoke_report, {"reportKind": "chromium-webgpu-playwright-smoke"})
    release_archive.write_bytes(b"browser archive bytes\n")
    manifest_members = {
        "browserExecutable": {
            "archivePath": MACOS_BROWSER_EXECUTABLE,
            "sha256": "1" * 64,
            "byteLength": 16,
            "executable": True,
        },
        "appMetadata": {
            "archivePath": MACOS_APP_METADATA,
            "sha256": "2" * 64,
            "byteLength": 16,
            "executable": False,
        },
        "doeRuntime": {
            "archivePath": MACOS_DOE_RUNTIME,
            "sha256": "3" * 64,
            "byteLength": 16,
            "executable": True,
        },
        "dawnFallbackRuntime": {
            "archivePath": MACOS_DAWN_RUNTIME,
            "sha256": "4" * 64,
            "byteLength": 16,
            "executable": True,
        },
    }
    _write_json(
        release_archive_manifest,
        {
            "schemaVersion": 1,
            "artifactKind": "browser_release_archive_manifest",
            "archive": {
                "path": str(release_archive),
                "sha256": builder.sha256_file(release_archive),
                "byteLength": release_archive.stat().st_size,
                "kind": "browser_release_archive",
            },
            "browserProduct": DEFAULT_PRODUCT,
            "platform": DEFAULT_PLATFORM,
            "appBundleName": "Fawn.app",
            "members": manifest_members,
            "archiveMembers": list(manifest_members.values()),
        },
    )
    _write_json(proof_page_receipt, {"receiptId": PROOF_PAGE_RECEIPT_ID})
    _write_json(gallery_receipt, {"receiptId": GALLERY_RECEIPT_ID})
    _write_json(
        proof_surface,
        {
            "schemaVersion": 1,
            "artifactKind": "browser_published_proof_surface",
            "surfaceId": "test-browser-proof-surface",
            "capturePolicyPath": "config/browser-capture-policy.json",
            "runtimeIdentityPath": "examples/browser-runtime-identity.selector.sample.json",
            "proofPage": {
                "artifact": {"path": PROOF_PAGE_ARTIFACT_PATH, "sha256": "0" * 64, "kind": "browser_proof_page"},
                "url": "about:doe",
                "diagnosticReceipt": {
                    "path": str(proof_page_receipt),
                    "sha256": builder.sha256_file(proof_page_receipt),
                    "kind": "browser_proof_page_receipt",
                },
                "diagnostics": {
                    "activeRuntime": "doe",
                    "activeBackend": "webgpu-doe",
                    "compilerPath": "runtime/zig/zig-out/bin/doe-zig-runtime",
                    "tsirStatus": "diagnostic",
                    "hostPlanStatus": "diagnostic",
                    "cslStatus": "diagnostic",
                    "fallbackPolicyState": "hidden_fallback_disabled",
                },
                "releaseProvenance": {
                    "browserProduct": DEFAULT_PRODUCT,
                    "platform": DEFAULT_PLATFORM,
                    "releaseArchive": {
                        "path": str(release_archive),
                        "sha256": builder.sha256_file(release_archive),
                        "kind": "browser_release_archive",
                        "downloadUrl": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
                    },
                    "releaseArchiveManifest": {
                        "path": str(release_archive_manifest),
                        "sha256": builder.sha256_file(release_archive_manifest),
                        "kind": "browser_release_archive_manifest",
                    },
                    "browserExecutableArchivePath": MACOS_BROWSER_EXECUTABLE,
                    "browserAppMetadataArchivePath": MACOS_APP_METADATA,
                    "doeRuntimeArchivePath": MACOS_DOE_RUNTIME,
                    "dawnFallbackRuntimeArchivePath": MACOS_DAWN_RUNTIME,
                },
                "recentReceiptIds": [COMPARISON_DAWN_RECEIPT_ID, COMPARISON_DOE_RECEIPT_ID],
                "receiptPayloads": [],
            },
            "galleryPages": [
                {
                    "category": GALLERY_CATEGORY,
                    "url": GALLERY_URL,
                    "artifact": {"path": GALLERY_ARTIFACT_PATH, "sha256": "0" * 64, "kind": "browser_gallery_page"},
                    "publicReceipt": {
                        "path": str(gallery_receipt),
                        "sha256": builder.sha256_file(gallery_receipt),
                        "kind": "browser_public_gallery_receipt",
                    },
                    "workloadContractPath": "browser/chromium/contracts/browser-benchmark-superset.contract.md",
                    "workloadIds": [COMPARISON_WORKLOAD_ID],
                    "receiptIds": [COMPARISON_DAWN_RECEIPT_ID, COMPARISON_DOE_RECEIPT_ID],
                    "receiptArtifacts": [],
                }
            ],
            "comparisonReceipts": [
                {
                    "comparisonId": COMPARISON_ID,
                    "workloadId": COMPARISON_WORKLOAD_ID,
                    "runner": {
                        "pageArtifactPath": GALLERY_ARTIFACT_PATH,
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
                    "comparisonArtifact": {
                        "path": COMPARISON_ARTIFACT_PATH,
                        "sha256": "0" * 64,
                        "kind": "chromium-webgpu-playwright-smoke",
                    },
                    "dawnReceipt": {
                        "receiptId": COMPARISON_DAWN_RECEIPT_ID,
                        "path": "examples/browser-dawn-execution-receipt.sample.json",
                        "sha256": "0" * 64,
                        "kind": "browser_execution_receipt",
                    },
                    "doeReceipt": {
                        "receiptId": COMPARISON_DOE_RECEIPT_ID,
                        "path": "examples/browser-doe-execution-receipt.sample.json",
                        "sha256": "0" * 64,
                        "kind": "browser_execution_receipt",
                    },
                }
            ],
        },
    )
    _write_json(
        clean_install_check,
        {
            "schemaVersion": 1,
            "artifactKind": "browser_release_clean_install_check",
            "observedAt": "2026-08-11T00:00:00Z",
            "verificationLevel": "webgpu_smoke",
            "sourceMode": "release_archive",
            "verifier": {
                "path": str(clean_install_verifier),
                "sha256": builder.sha256_file(clean_install_verifier),
                "kind": "browser_release_clean_install_verifier",
            },
            "releaseArchive": {
                "path": str(release_archive),
                "sha256": builder.sha256_file(release_archive),
                "byteLength": release_archive.stat().st_size,
                "kind": "browser_release_archive",
            },
            "releaseArchiveManifest": {
                "path": str(release_archive_manifest),
                "sha256": builder.sha256_file(release_archive_manifest),
                "byteLength": release_archive_manifest.stat().st_size,
                "kind": "browser_release_archive_manifest",
            },
            "browserProduct": DEFAULT_PRODUCT,
            "platform": DEFAULT_PLATFORM,
            "extraction": {
                "isolation": "fresh_temporary_directory",
                "archiveMemberCount": 4,
                "extractedMemberCount": 4,
                "borrowedMemberCount": 0,
            },
            "launchProbe": {"attempted": True, "exitCode": 0, "timedOut": False},
            "webgpuSmoke": {
                "required": True,
                "modes": ["dawn", "doe"],
                "script": {
                    "path": str(smoke_script),
                    "sha256": builder.sha256_file(smoke_script),
                    "kind": "browser_webgpu_smoke_runner",
                },
                "report": {
                    "path": str(smoke_report),
                    "sha256": builder.sha256_file(smoke_report),
                    "kind": "chromium-webgpu-playwright-smoke",
                },
                "process": {"attempted": True, "exitCode": 0, "timedOut": False},
            },
            "releaseCandidateEligible": True,
            "status": "pass",
            "failures": [],
        },
    )
    return {
        "release_archive": release_archive,
        "release_archive_manifest": release_archive_manifest,
        "proof_surface": proof_surface,
        "clean_install_check": clean_install_check,
    }


def _receipt_kwargs(root: Path) -> dict:
    paths = _write_inputs(root)
    return {
        "receipt_id": "test-browser-release-launch",
        "observed_at": "2026-06-30T00:00:00Z",
        "release_archive": paths["release_archive"],
        "release_archive_url": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
        "release_archive_manifest": paths["release_archive_manifest"],
        "proof_surface": paths["proof_surface"],
        "clean_install_check": paths["clean_install_check"],
        "browser_product": DEFAULT_PRODUCT,
        "platform": DEFAULT_PLATFORM,
        "browser_executable_archive_path": MACOS_BROWSER_EXECUTABLE,
        "browser_app_metadata_archive_path": MACOS_APP_METADATA,
        "doe_runtime_archive_path": MACOS_DOE_RUNTIME,
        "dawn_fallback_runtime_archive_path": MACOS_DAWN_RUNTIME,
        "active_backend": "webgpu-doe",
        "proof_page_url": "about:doe",
        "proof_page_artifact_path": PROOF_PAGE_ARTIFACT_PATH,
        "proof_page_receipt_id": PROOF_PAGE_RECEIPT_ID,
        "gallery_url": GALLERY_URL,
        "gallery_category": GALLERY_CATEGORY,
        "gallery_artifact_path": GALLERY_ARTIFACT_PATH,
        "gallery_receipt_id": GALLERY_RECEIPT_ID,
        "comparison_id": COMPARISON_ID,
        "comparison_workload_id": COMPARISON_WORKLOAD_ID,
        "comparison_page_artifact_path": GALLERY_ARTIFACT_PATH,
        "comparison_artifact_path": COMPARISON_ARTIFACT_PATH,
        "comparison_dawn_receipt_id": COMPARISON_DAWN_RECEIPT_ID,
        "comparison_doe_receipt_id": COMPARISON_DOE_RECEIPT_ID,
        "observed_receipt_ids": [
            PROOF_PAGE_RECEIPT_ID,
            GALLERY_RECEIPT_ID,
            COMPARISON_DAWN_RECEIPT_ID,
            COMPARISON_DOE_RECEIPT_ID,
        ],
    }


def _mutate_proof_surface(proof_surface: Path, mutator) -> None:
    payload = json.loads(proof_surface.read_text(encoding="utf-8"))
    mutator(payload)
    _write_json(proof_surface, payload)


def _mutate_manifest(manifest: Path, mutator) -> None:
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    mutator(payload)
    _write_json(manifest, payload)


class BrowserReleaseLaunchReceiptBuilderTests(unittest.TestCase):
    def test_build_receipt_hashes_launch_inputs(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt = builder.build_receipt(**_receipt_kwargs(root))

        jsonschema.validate(receipt, json.loads(SCHEMA.read_text(encoding="utf-8")))
        self.assertEqual(receipt["artifactKind"], "browser_release_launch_receipt")
        self.assertEqual(receipt["launchSource"], "release_archive")
        self.assertEqual(receipt["runtimeMode"], "doe")
        self.assertEqual(receipt["activeRuntime"], "doe")
        self.assertEqual(receipt["hiddenFallbackAllowed"], False)
        self.assertEqual(receipt["hiddenFallbackUsed"], False)
        self.assertEqual(receipt["webgpuAvailable"], True)
        self.assertEqual(receipt["proofPage"]["receiptId"], "browser-proof-page-sample")
        self.assertEqual(receipt["galleryPage"]["receiptId"], "browser-public-gallery-compute")
        self.assertEqual(receipt["comparisonReceipt"]["comparisonId"], "browser-smoke-compute-dawn-vs-doe")
        self.assertEqual(receipt["comparisonReceipt"]["modes"], ["dawn", "doe"])

    def test_release_candidate_requires_observational_clean_install_check(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            kwargs["clean_install_check"] = None

            with self.assertRaisesRegex(ValueError, "clean install check is required"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_non_public_gallery_url(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            kwargs["gallery_url"] = "https://localhost/doe/compute.html"

            with self.assertRaisesRegex(ValueError, "gallery URL"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_requires_observed_proof_page_receipt(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            kwargs["observed_receipt_ids"] = ["browser-public-gallery-compute"]

            with self.assertRaisesRegex(ValueError, "proof page receipt ID"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_requires_observed_comparison_receipts(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            kwargs["observed_receipt_ids"] = [
                "browser-proof-page-sample",
                "browser-public-gallery-compute",
                "browser-smoke-compute-dawn",
            ]

            with self.assertRaisesRegex(ValueError, "comparison Doe receipt ID"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_duplicate_observed_receipts(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            kwargs["observed_receipt_ids"].append(kwargs["observed_receipt_ids"][0])

            with self.assertRaisesRegex(ValueError, "observed receipt IDs must be unique"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_unlinked_observed_receipts(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            kwargs["observed_receipt_ids"].append("browser-unlinked-receipt")

            with self.assertRaisesRegex(ValueError, "exactly match proof page"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_requires_comparison_on_loaded_gallery_page(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            kwargs["comparison_page_artifact_path"] = "examples/browser-gallery-rendering.sample.html"

            with self.assertRaisesRegex(ValueError, "loaded gallery artifact path"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_proof_surface_backend_drift(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            _mutate_proof_surface(
                kwargs["proof_surface"],
                lambda payload: payload["proofPage"]["diagnostics"].__setitem__("activeBackend", "dawn-native"),
            )

            with self.assertRaisesRegex(ValueError, "active backend"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_proof_surface_comparison_drift(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            _mutate_proof_surface(
                kwargs["proof_surface"],
                lambda payload: payload["comparisonReceipts"][0]["doeReceipt"].__setitem__("receiptId", "other-doe-receipt"),
            )

            with self.assertRaisesRegex(ValueError, "Doe receiptId"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_product_identity_mismatch(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            kwargs["browser_product"] = {**DEFAULT_PRODUCT, "productId": "doe-browser"}

            with self.assertRaisesRegex(ValueError, "Doe Browser"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_release_archive_manifest_archive_drift(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            _mutate_manifest(
                kwargs["release_archive_manifest"],
                lambda payload: payload["archive"].__setitem__("sha256", "0" * 64),
            )

            with self.assertRaisesRegex(ValueError, "archive.sha256"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_release_archive_manifest_member_drift(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            kwargs = _receipt_kwargs(Path(temp_dir))
            _mutate_manifest(
                kwargs["release_archive_manifest"],
                lambda payload: payload["members"]["doeRuntime"].__setitem__(
                    "archivePath",
                    "Fawn.app/Contents/Frameworks/other-libwebgpu-doe.so",
                ),
            )

            with self.assertRaisesRegex(ValueError, "Doe runtime archive path"):
                builder.build_receipt(**kwargs)


if __name__ == "__main__":
    unittest.main()
