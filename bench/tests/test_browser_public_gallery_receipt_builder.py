#!/usr/bin/env python3
"""Tests for browser public gallery receipt building."""

from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path

import jsonschema

from bench.tools import build_browser_public_gallery_receipt as builder


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA = REPO_ROOT / "config" / "browser-public-gallery-receipt.schema.json"
WORKLOAD_CONTRACT = "browser/chromium/contracts/browser-benchmark-superset.contract.md"
DOE_RECEIPT_PATH = REPO_ROOT / "examples/browser-doe-execution-receipt.sample.json"
DOE_RECEIPT_PAYLOAD = json.loads(DOE_RECEIPT_PATH.read_text(encoding="utf-8"))
DOE_RECEIPT_VISIBLE_FACTS = builder.receipt_visibility_fragments(DOE_RECEIPT_PAYLOAD)
GALLERY_HTML = (
    "<!doctype html><h1>compute</h1>"
    f"<p>{WORKLOAD_CONTRACT}</p>"
    "<p>browser-smoke-compute</p>"
    "<p>browser-smoke-compute-doe</p>"
    "<a href=\"examples/browser-doe-execution-receipt.sample.json\">"
    "examples/browser-doe-execution-receipt.sample.json</a>"
    + "".join(f"<p>{fragment}</p>" for _, fragment in DOE_RECEIPT_VISIBLE_FACTS)
    + "\n"
)


def _receipt_kwargs(root: Path, gallery: Path) -> dict:
    return {
        "receipt_id": "test-browser-public-gallery-compute",
        "category": "compute",
        "url": "https://gallery.doe.dev/doe/compute.html",
        "download": builder.DownloadResult(status_code=200, content=gallery.read_bytes()),
        "gallery_artifact_path": gallery.relative_to(root).as_posix(),
        "workload_contract_path": WORKLOAD_CONTRACT,
        "workload_ids": ["browser-smoke-compute"],
        "receipt_ids": ["browser-smoke-compute-doe"],
        "receipt_artifact_paths": ["examples/browser-doe-execution-receipt.sample.json"],
        "receipt_visible_fragments": DOE_RECEIPT_VISIBLE_FACTS,
        "observed_at": "2026-06-30T00:00:00Z",
        "expected_artifact": gallery,
    }


class BrowserPublicGalleryReceiptBuilderTests(unittest.TestCase):
    def test_build_receipt_hashes_hosted_gallery_bytes(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML, encoding="utf-8")

            receipt = builder.build_receipt(**_receipt_kwargs(root, gallery))

        jsonschema.validate(receipt, json.loads(SCHEMA.read_text(encoding="utf-8")))
        self.assertEqual(receipt["method"], "GET")
        self.assertEqual(receipt["statusCode"], 200)
        self.assertEqual(
            receipt["contentSha256"],
            hashlib.sha256(GALLERY_HTML.encode("utf-8")).hexdigest(),
        )
        self.assertEqual(receipt["contentLengthBytes"], len(GALLERY_HTML.encode("utf-8")))
        self.assertEqual(receipt["workloadIds"], ["browser-smoke-compute"])
        self.assertEqual(receipt["receiptIds"], ["browser-smoke-compute-doe"])
        self.assertEqual(
            receipt["receiptArtifactPaths"],
            ["examples/browser-doe-execution-receipt.sample.json"],
        )

    def test_build_receipt_rejects_non_public_url(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML, encoding="utf-8")
            kwargs = _receipt_kwargs(root, gallery)
            kwargs["url"] = "https://localhost/doe/compute.html"

            with self.assertRaisesRegex(ValueError, "public HTTPS"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_local_gallery_hash_mismatch(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML, encoding="utf-8")
            kwargs = _receipt_kwargs(root, gallery)
            kwargs["download"] = builder.DownloadResult(
                status_code=200,
                content=b"served gallery bytes\n",
            )

            with self.assertRaisesRegex(ValueError, "does not match"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_unsupported_category(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML, encoding="utf-8")
            kwargs = _receipt_kwargs(root, gallery)
            kwargs["category"] = "other"

            with self.assertRaisesRegex(ValueError, "unsupported gallery category"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_missing_workload_ids(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML, encoding="utf-8")
            kwargs = _receipt_kwargs(root, gallery)
            kwargs["workload_ids"] = []

            with self.assertRaisesRegex(ValueError, "workload ID"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_missing_receipt_id(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML, encoding="utf-8")
            kwargs = _receipt_kwargs(root, gallery)
            kwargs["receipt_id"] = ""

            with self.assertRaisesRegex(ValueError, "receipt ID"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_missing_observed_at(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML, encoding="utf-8")
            kwargs = _receipt_kwargs(root, gallery)
            kwargs["observed_at"] = ""

            with self.assertRaisesRegex(ValueError, "observedAt"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_missing_gallery_artifact_path(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML, encoding="utf-8")
            kwargs = _receipt_kwargs(root, gallery)
            kwargs["gallery_artifact_path"] = ""

            with self.assertRaisesRegex(ValueError, "gallery artifact path"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_missing_workload_contract_path(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML, encoding="utf-8")
            kwargs = _receipt_kwargs(root, gallery)
            kwargs["workload_contract_path"] = ""

            with self.assertRaisesRegex(ValueError, "workload contract path"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_gallery_content_without_workload_id(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML.replace("browser-smoke-compute", ""), encoding="utf-8")
            kwargs = _receipt_kwargs(root, gallery)

            with self.assertRaisesRegex(ValueError, "workload ID"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_gallery_content_without_receipt_artifact_path(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(
                GALLERY_HTML.replace("examples/browser-doe-execution-receipt.sample.json", ""),
                encoding="utf-8",
            )
            kwargs = _receipt_kwargs(root, gallery)

            with self.assertRaisesRegex(ValueError, "receipt artifact path"):
                builder.build_receipt(**kwargs)

    def test_build_receipt_rejects_gallery_content_without_receipt_fact(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            gallery = root / "compute.html"
            gallery.write_text(GALLERY_HTML.replace("webgpu-doe", ""), encoding="utf-8")
            kwargs = _receipt_kwargs(root, gallery)

            with self.assertRaisesRegex(ValueError, "receipt backend"):
                builder.build_receipt(**kwargs)

    def test_receipt_payload_evidence_derives_gallery_identity(self) -> None:
        (
            receipt_ids,
            receipt_artifact_paths,
            workload_ids,
            receipt_visible_fragments,
        ) = builder.receipt_payload_evidence(
            [DOE_RECEIPT_PATH]
        )

        self.assertEqual(receipt_ids, ["browser-smoke-compute-doe"])
        self.assertEqual(
            receipt_artifact_paths,
            ["examples/browser-doe-execution-receipt.sample.json"],
        )
        self.assertEqual(workload_ids, ["browser-smoke-compute"])
        self.assertIn(("backend", "webgpu-doe"), receipt_visible_fragments)


if __name__ == "__main__":
    unittest.main()
