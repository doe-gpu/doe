#!/usr/bin/env python3
"""Tests for browser proof page receipt building."""

from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path

import jsonschema

from bench.tools import build_browser_proof_page_receipt as builder


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = REPO_ROOT / "config" / "browser-proof-page-receipt.schema.json"
DEFAULT_PRODUCT = {
    "productId": "fawn-doe",
    "displayName": "Fawn Doe",
    "version": "0.0.0-test",
    "channel": "release_candidate",
}
DEFAULT_PLATFORM = {"os": "macos", "arch": "arm64", "packageFormat": "zip"}
DEFAULT_DIAGNOSTICS = {
    "activeRuntime": "doe",
    "activeBackend": "webgpu",
    "webgpuAvailable": True,
    "compilerPath": "runtime/zig/zig-out/bin/doe-zig-runtime",
    "tsirStatus": "available",
    "hostPlanStatus": "not_applicable",
    "cslStatus": "not_applicable",
    "fallbackPolicyState": "hidden_fallback_disabled",
}
RECENT_RECEIPT_IDS = ["dawn-receipt", "doe-receipt"]


def _write_inputs(root: Path) -> dict[str, Path]:
    paths = {
        "proof_artifact": root / "proof.html",
        "release_archive": root / "Fawn-Doe-macos-arm64.zip",
        "release_archive_manifest": root / "Fawn-Doe-macos-arm64.manifest.json",
        "public_download_receipt": root / "browser-public-download-receipt.json",
    }
    paths["proof_artifact"].write_text("<!doctype html><main>about:doe</main>\n", encoding="utf-8")
    paths["release_archive"].write_bytes(b"browser archive\n")
    paths["release_archive_manifest"].write_text('{"artifactKind":"browser_release_archive_manifest"}\n', encoding="utf-8")
    paths["public_download_receipt"].write_text('{"artifactKind":"browser_public_download_receipt"}\n', encoding="utf-8")
    return paths


def _release_provenance(paths: dict[str, Path]) -> dict:
    return builder.build_release_provenance(
        release_archive=paths["release_archive"],
        release_archive_url="https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
        release_archive_manifest=paths["release_archive_manifest"],
        public_download_receipt=paths["public_download_receipt"],
        browser_product=DEFAULT_PRODUCT,
        platform=DEFAULT_PLATFORM,
        browser_executable_archive_path="Fawn.app/Contents/MacOS/Chromium",
        browser_app_metadata_archive_path="Fawn.app/Contents/Info.plist",
        doe_runtime_archive_path="Fawn.app/Contents/Frameworks/libwebgpu_doe.so",
        dawn_fallback_runtime_archive_path="Fawn.app/Contents/Frameworks/libdawn_native.so",
    )


def _proof_page_html(
    *,
    diagnostics: dict[str, object],
    release_provenance: dict,
    recent_receipt_ids: list[str],
) -> str:
    fragments: list[str] = ["<!doctype html><main>about:doe</main>"]
    for value in diagnostics.values():
        if isinstance(value, bool):
            fragments.append("true" if value else "false")
        elif isinstance(value, str):
            fragments.append(value)
    product = release_provenance["browserProduct"]
    fragments.extend([product["displayName"], product["version"], product["channel"]])
    platform = release_provenance["platform"]
    fragments.extend([platform["os"], platform["arch"], platform["packageFormat"]])
    for field in (
        "browserExecutableArchivePath",
        "browserAppMetadataArchivePath",
        "doeRuntimeArchivePath",
        "dawnFallbackRuntimeArchivePath",
    ):
        fragments.append(release_provenance[field])
    for field in ("releaseArchive", "releaseArchiveManifest", "publicDownloadReceipt"):
        artifact = release_provenance[field]
        for key in ("path", "sha256", "downloadUrl"):
            value = artifact.get(key)
            if isinstance(value, str):
                fragments.append(value)
    fragments.extend(recent_receipt_ids)
    return "\n".join(fragments) + "\n"


def _receipt_kwargs(root: Path, paths: dict[str, Path]) -> dict:
    release_provenance = _release_provenance(paths)
    paths["proof_artifact"].write_text(
        _proof_page_html(
            diagnostics=DEFAULT_DIAGNOSTICS,
            release_provenance=release_provenance,
            recent_receipt_ids=RECENT_RECEIPT_IDS,
        ),
        encoding="utf-8",
    )
    return {
        "receipt_id": "test-browser-proof-page",
        "url": "about:doe",
        "proof_artifact": paths["proof_artifact"],
        "proof_artifact_path": paths["proof_artifact"].relative_to(root).as_posix(),
        "runtime_identity_path": "runtime-identity.json",
        "diagnostics": DEFAULT_DIAGNOSTICS,
        "release_provenance": release_provenance,
        "recent_receipt_ids": RECENT_RECEIPT_IDS,
        "observed_at": "2026-06-30T00:00:00Z",
    }


class BrowserProofPageReceiptBuilderTests(unittest.TestCase):
    def test_build_receipt_hashes_captured_proof_page(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_inputs(root)
            kwargs = _receipt_kwargs(root, paths)
            expected_proof_page_bytes = paths["proof_artifact"].read_bytes()

            receipt = builder.build_receipt(**kwargs)

        jsonschema.validate(receipt, json.loads(SCHEMA.read_text(encoding="utf-8")))
        self.assertEqual(receipt["loadType"], "browser_internal_page")
        self.assertEqual(
            receipt["contentSha256"],
            hashlib.sha256(expected_proof_page_bytes).hexdigest(),
        )
        self.assertEqual(receipt["contentLengthBytes"], len(expected_proof_page_bytes))
        self.assertIs(receipt["diagnostics"]["webgpuAvailable"], True)

    def test_build_receipt_supports_file_url_load_type(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_inputs(root)
            kwargs = _receipt_kwargs(root, paths)
            kwargs["url"] = "file:///tmp/proof.html"

            receipt = builder.build_receipt(**kwargs)

        self.assertEqual(receipt["loadType"], "file")

    def test_build_receipt_rejects_non_doe_diagnostics(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_inputs(root)
            kwargs = _receipt_kwargs(root, paths)
            kwargs["diagnostics"] = {**DEFAULT_DIAGNOSTICS, "activeRuntime": "dawn"}

            with self.assertRaisesRegex(ValueError, "activeRuntime=doe"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_webgpu_unavailable_diagnostics(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_inputs(root)
            kwargs = _receipt_kwargs(root, paths)
            kwargs["diagnostics"] = {**DEFAULT_DIAGNOSTICS, "webgpuAvailable": False}
            paths["proof_artifact"].write_text(
                _proof_page_html(
                    diagnostics=kwargs["diagnostics"],
                    release_provenance=kwargs["release_provenance"],
                    recent_receipt_ids=RECENT_RECEIPT_IDS,
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "webgpuAvailable=true"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_diagnostic_release_statuses(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_inputs(root)
            kwargs = _receipt_kwargs(root, paths)
            kwargs["diagnostics"] = {**DEFAULT_DIAGNOSTICS, "tsirStatus": "diagnostic"}
            paths["proof_artifact"].write_text(
                _proof_page_html(
                    diagnostics=kwargs["diagnostics"],
                    release_provenance=kwargs["release_provenance"],
                    recent_receipt_ids=RECENT_RECEIPT_IDS,
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "tsirStatus must be concrete"):
                builder.build_receipt(**kwargs)

    def test_release_provenance_rejects_product_identity_mismatch(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            paths = _write_inputs(Path(temp_dir))

            with self.assertRaisesRegex(ValueError, "Doe Browser"):
                builder.build_release_provenance(
                    release_archive=paths["release_archive"],
                    release_archive_url="https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
                    release_archive_manifest=paths["release_archive_manifest"],
                    public_download_receipt=paths["public_download_receipt"],
                    browser_product={**DEFAULT_PRODUCT, "productId": "doe-browser"},
                    platform=DEFAULT_PLATFORM,
                    browser_executable_archive_path="Fawn.app/Contents/MacOS/Chromium",
                    browser_app_metadata_archive_path="Fawn.app/Contents/Info.plist",
                    doe_runtime_archive_path="Fawn.app/Contents/Frameworks/libwebgpu_doe.so",
                    dawn_fallback_runtime_archive_path="Fawn.app/Contents/Frameworks/libdawn_native.so",
                )

    def test_build_receipt_rejects_proof_page_without_compiler_path(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_inputs(root)
            kwargs = _receipt_kwargs(root, paths)
            paths["proof_artifact"].write_text(
                paths["proof_artifact"].read_text(encoding="utf-8").replace(
                    DEFAULT_DIAGNOSTICS["compilerPath"],
                    "",
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "diagnostic compilerPath"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_proof_page_without_release_archive_hash(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_inputs(root)
            kwargs = _receipt_kwargs(root, paths)
            release_archive_hash = kwargs["release_provenance"]["releaseArchive"]["sha256"]
            paths["proof_artifact"].write_text(
                paths["proof_artifact"].read_text(encoding="utf-8").replace(
                    release_archive_hash,
                    "",
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "release archive"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_proof_page_without_recent_receipt_id(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            paths = _write_inputs(root)
            kwargs = _receipt_kwargs(root, paths)
            paths["proof_artifact"].write_text(
                paths["proof_artifact"].read_text(encoding="utf-8").replace(
                    "doe-receipt",
                    "",
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "recent receipt ID"):
                builder.build_receipt(**kwargs)


if __name__ == "__main__":
    unittest.main()
