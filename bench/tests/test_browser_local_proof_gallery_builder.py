#!/usr/bin/env python3
"""Tests for local browser proof-gallery generation."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bench.tools import build_browser_local_proof_gallery as builder


REPO_ROOT = Path(__file__).resolve().parents[2]


class BrowserLocalProofGalleryBuilderTests(unittest.TestCase):
    def test_builds_page_with_public_gallery_visible_fragments(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "gallery.html"
            builder.write_page(
                title="Local Browser Proof Gallery",
                category="compute",
                workload_contract_path="browser/chromium/contracts/browser-published-release.contract.md",
                receipt_paths=[
                    REPO_ROOT / "examples/browser-dawn-execution-receipt.sample.json",
                    REPO_ROOT / "examples/browser-doe-execution-receipt.sample.json",
                ],
                comparison_artifact_path=REPO_ROOT / "examples/browser-smoke-report.sample.json",
                release_archive_manifest_path=REPO_ROOT / "examples/browser-release-archive-manifest.sample.json",
                package_inputs_path=REPO_ROOT / "examples/browser-release-package-inputs-check.sample.json",
                out_path=out,
            )

            html = out.read_text(encoding="utf-8")

        self.assertIn("browser-smoke-compute-dawn", html)
        self.assertIn("browser-smoke-compute-doe", html)
        self.assertIn("webgpu-dawn", html)
        self.assertIn("webgpu-doe", html)
        self.assertIn("wgsl &gt; doe-wgsl &gt; tsir &gt; hostplan &gt; webgpu", html)
        self.assertIn("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", html)


if __name__ == "__main__":
    unittest.main()
