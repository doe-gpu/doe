#!/usr/bin/env python3
"""Tests for repository-owned structural documentation claims."""

from __future__ import annotations

from pipeline.tools import validate_doc_claims


def test_structural_doc_claims_resolve_inside_the_repository() -> None:
    assert validate_doc_claims.validate() == 0


def test_chromium_claims_use_tracked_contracts_not_external_checkout_files() -> None:
    paths = {path for path, _label in validate_doc_claims.STRUCTURAL_CLAIMS}

    assert not any(path.startswith("browser/chromium/src/") for path in paths)
    assert {
        "bench/tools/check_chromium_source_checkout.py",
        "config/webgpu-integration-chromium.json",
        "config/doe-chromium-proc-surface.json",
        "config/chromium-patch-manifest.json",
    }.issubset(paths)
