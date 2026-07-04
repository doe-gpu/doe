#!/usr/bin/env python3
"""Tests for browser public URL schema guards."""

from __future__ import annotations

import copy
import json
import unittest
from collections.abc import Callable
from pathlib import Path

import jsonschema


REPO_ROOT = Path(__file__).resolve().parents[2]


def _load_json(path: str) -> dict:
    return json.loads((REPO_ROOT / path).read_text(encoding="utf-8"))


def _set_public_gallery_receipt_url(payload: dict, value: str) -> None:
    payload["url"] = value


def _set_public_download_receipt_url(payload: dict, value: str) -> None:
    payload["url"] = value


def _set_proof_surface_gallery_url(payload: dict, value: str) -> None:
    payload["galleryPages"][0]["url"] = value


def _set_proof_surface_archive_url(payload: dict, value: str) -> None:
    payload["proofPage"]["releaseProvenance"]["releaseArchive"]["downloadUrl"] = value


def _set_proof_page_receipt_archive_url(payload: dict, value: str) -> None:
    payload["releaseProvenance"]["releaseArchive"]["downloadUrl"] = value


def _set_release_bundle_archive_url(payload: dict, value: str) -> None:
    payload["releaseArchive"]["downloadUrl"] = value


PUBLIC_URL_SCHEMA_CASES: tuple[tuple[str, str, Callable[[dict, str], None]], ...] = (
    (
        "config/browser-public-gallery-receipt.schema.json",
        "examples/browser-public-gallery-receipt.sample.json",
        _set_public_gallery_receipt_url,
    ),
    (
        "config/browser-public-download-receipt.schema.json",
        "examples/browser-public-download-receipt.sample.json",
        _set_public_download_receipt_url,
    ),
    (
        "config/browser-published-proof-surface.schema.json",
        "examples/browser-published-proof-surface.sample.json",
        _set_proof_surface_gallery_url,
    ),
    (
        "config/browser-published-proof-surface.schema.json",
        "examples/browser-published-proof-surface.sample.json",
        _set_proof_surface_archive_url,
    ),
    (
        "config/browser-proof-page-receipt.schema.json",
        "examples/browser-proof-page-receipt.sample.json",
        _set_proof_page_receipt_archive_url,
    ),
    (
        "config/browser-release-artifact-bundle.schema.json",
        "examples/browser-release-artifact-bundle.sample.json",
        _set_release_bundle_archive_url,
    ),
)


class BrowserPublicUrlSchemaTests(unittest.TestCase):
    def test_samples_pass_public_url_schema_guards(self) -> None:
        for schema_path, sample_path, _ in PUBLIC_URL_SCHEMA_CASES:
            with self.subTest(schema=schema_path, sample=sample_path):
                jsonschema.validate(_load_json(sample_path), _load_json(schema_path))

    def test_public_url_schema_guards_reject_non_public_urls(self) -> None:
        rejected_urls = (
            "http://downloads.doe.dev/Fawn-Doe-macos-arm64.zip",
            "https://localhost/Fawn-Doe-macos-arm64.zip",
            "https://127.0.0.1/Fawn-Doe-macos-arm64.zip",
            "https://example.invalid/Fawn-Doe-macos-arm64.zip",
            "https://example.com/Fawn-Doe-macos-arm64.zip",
        )
        for schema_path, sample_path, setter in PUBLIC_URL_SCHEMA_CASES:
            schema = _load_json(schema_path)
            sample = _load_json(sample_path)
            for url in rejected_urls:
                with self.subTest(schema=schema_path, sample=sample_path, url=url):
                    payload = copy.deepcopy(sample)
                    setter(payload, url)
                    with self.assertRaises(jsonschema.ValidationError):
                        jsonschema.validate(payload, schema)


if __name__ == "__main__":
    unittest.main()
