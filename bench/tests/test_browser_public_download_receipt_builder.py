#!/usr/bin/env python3
"""Tests for browser public download receipt building."""

from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path

import jsonschema

from bench.tools import build_browser_public_download_receipt as builder


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = REPO_ROOT / "config" / "browser-public-download-receipt.schema.json"
DEFAULT_PRODUCT = {
    "productId": "fawn-doe",
    "displayName": "Fawn Doe",
    "version": "0.0.0-test",
    "channel": "release_candidate",
}
DEFAULT_PLATFORM = {"os": "macos", "arch": "arm64", "packageFormat": "zip"}
MACOS_BROWSER_EXECUTABLE = "Fawn.app/Contents/MacOS/Chromium"
MACOS_APP_METADATA = "Fawn.app/Contents/Info.plist"
MACOS_DOE_RUNTIME = "Fawn.app/Contents/Frameworks/libwebgpu_doe.so"
MACOS_DAWN_RUNTIME = "Fawn.app/Contents/Frameworks/libdawn_native.so"


def _write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _write_manifest(manifest: Path, archive: Path) -> None:
    members = {
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
        manifest,
        {
            "schemaVersion": 1,
            "artifactKind": "browser_release_archive_manifest",
            "archive": {
                "path": archive.name,
                "sha256": builder.sha256_file(archive),
                "byteLength": archive.stat().st_size,
                "kind": "browser_release_archive",
            },
            "browserProduct": DEFAULT_PRODUCT,
            "platform": DEFAULT_PLATFORM,
            "appBundleName": "Fawn.app",
            "members": members,
            "archiveMembers": list(members.values()),
        },
    )


def _mutate_manifest(manifest: Path, mutator) -> None:
    payload = json.loads(manifest.read_text(encoding="utf-8"))
    mutator(payload)
    _write_json(manifest, payload)


def _receipt_kwargs(root: Path, archive: Path, manifest: Path) -> dict:
    return {
        "receipt_id": "test-browser-public-download",
        "url": "https://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
        "download": builder.DownloadResult(status_code=200, content=archive.read_bytes()),
        "release_archive_path": archive.relative_to(root).as_posix(),
        "release_archive_manifest_path": manifest.relative_to(root).as_posix(),
        "release_archive_manifest_sha256": builder.sha256_file(manifest),
        "browser_product": DEFAULT_PRODUCT,
        "platform": DEFAULT_PLATFORM,
        "browser_executable_archive_path": MACOS_BROWSER_EXECUTABLE,
        "browser_app_metadata_archive_path": MACOS_APP_METADATA,
        "doe_runtime_archive_path": MACOS_DOE_RUNTIME,
        "dawn_fallback_runtime_archive_path": MACOS_DAWN_RUNTIME,
        "observed_at": "2026-06-30T00:00:00Z",
        "expected_archive": archive,
        "release_archive_manifest": manifest,
    }


class BrowserPublicDownloadReceiptBuilderTests(unittest.TestCase):
    def test_build_receipt_hashes_served_archive_bytes(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            expected_manifest_sha = builder.sha256_file(manifest)

            receipt = builder.build_receipt(**_receipt_kwargs(root, archive, manifest))

        jsonschema.validate(receipt, json.loads(SCHEMA.read_text(encoding="utf-8")))
        self.assertEqual(receipt["method"], "GET")
        self.assertEqual(receipt["statusCode"], 200)
        self.assertEqual(
            receipt["contentSha256"],
            hashlib.sha256(b"browser archive bytes\n").hexdigest(),
        )
        self.assertEqual(receipt["contentLengthBytes"], len(b"browser archive bytes\n"))
        self.assertEqual(receipt["releaseArchiveManifestPath"], manifest.name)
        self.assertEqual(
            receipt["releaseArchiveManifestSha256"],
            expected_manifest_sha,
        )

    def test_build_receipt_rejects_non_public_url(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            kwargs["url"] = "https://localhost/Fawn-Doe-macos-arm64.zip"

            with self.assertRaisesRegex(ValueError, "public HTTPS"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_local_archive_hash_mismatch(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"local archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            kwargs["download"] = builder.DownloadResult(
                status_code=200,
                content=b"served archive bytes\n",
            )

            with self.assertRaisesRegex(ValueError, "does not match"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_product_identity_mismatch(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            kwargs["browser_product"] = {
                **DEFAULT_PRODUCT,
                "productId": "doe-browser",
            }

            with self.assertRaisesRegex(ValueError, "Doe Browser"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_missing_receipt_id(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            kwargs["receipt_id"] = ""

            with self.assertRaisesRegex(ValueError, "receipt ID"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_missing_observed_at(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            kwargs["observed_at"] = ""

            with self.assertRaisesRegex(ValueError, "observedAt"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_invalid_manifest_hash(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            kwargs["release_archive_manifest_sha256"] = "not-a-sha256"

            with self.assertRaisesRegex(ValueError, "release archive manifest sha256"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_missing_product_version(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            kwargs["browser_product"] = {
                **DEFAULT_PRODUCT,
                "version": "",
            }

            with self.assertRaisesRegex(ValueError, "browser product version"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_invalid_platform_identity(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            kwargs["platform"] = {
                **DEFAULT_PLATFORM,
                "arch": "",
            }

            with self.assertRaisesRegex(ValueError, "platform arch"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_missing_archive_member_path(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            kwargs["doe_runtime_archive_path"] = ""

            with self.assertRaisesRegex(ValueError, "Doe runtime archive path"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_release_archive_manifest_archive_drift(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            _mutate_manifest(
                manifest,
                lambda payload: payload["archive"].__setitem__("sha256", "0" * 64),
            )
            kwargs["release_archive_manifest_sha256"] = builder.sha256_file(manifest)

            with self.assertRaisesRegex(ValueError, "archive.sha256"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_release_archive_manifest_member_drift(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            archive = root / "Fawn-Doe-macos-arm64.zip"
            manifest = root / "Fawn-Doe-macos-arm64.manifest.json"
            archive.write_bytes(b"browser archive bytes\n")
            _write_manifest(manifest, archive)
            kwargs = _receipt_kwargs(root, archive, manifest)
            _mutate_manifest(
                manifest,
                lambda payload: payload["members"]["doeRuntime"].__setitem__(
                    "archivePath",
                    "Fawn.app/Contents/Frameworks/other-libwebgpu-doe.so",
                ),
            )
            kwargs["release_archive_manifest_sha256"] = builder.sha256_file(manifest)

            with self.assertRaisesRegex(ValueError, "Doe runtime archive path"):
                builder.build_receipt(**kwargs)


if __name__ == "__main__":
    unittest.main()
