#!/usr/bin/env python3
"""Tests for Chromium fork maintenance policy checks."""

from __future__ import annotations

import json
from pathlib import Path

from bench.tools import check_chromium_fork_maintenance_policy as policy_check


REPO_ROOT = Path(__file__).resolve().parents[2]
POLICY_PATH = REPO_ROOT / "config" / "chromium-fork-maintenance-policy.json"


def _load() -> dict:
    return json.loads(POLICY_PATH.read_text(encoding="utf-8"))


def test_chromium_fork_maintenance_policy_passes_check() -> None:
    assert policy_check.check_policy(_load()) == []


def test_chromium_fork_maintenance_policy_rejects_local_volume_allowed_root() -> None:
    payload = _load()
    payload["patchIsolation"]["allowedPatchRoots"].append("browser/chromium_webgpu_lane/.local_volume/")

    assert {
        "code": "root_allowed_and_forbidden",
        "path": "patchIsolation",
        "message": "patch root 'browser/chromium_webgpu_lane/.local_volume/' is both allowed and forbidden",
    } in policy_check.check_policy(payload)


def test_chromium_fork_maintenance_policy_requires_dawn_fallback() -> None:
    payload = _load()
    payload["rollback"]["dawnFallbackAvailable"] = False

    assert {
        "code": "dawn_fallback_missing",
        "path": "rollback.dawnFallbackAvailable",
        "message": "release rollback requires Dawn fallback",
    } in policy_check.check_policy(payload)


def test_chromium_fork_maintenance_policy_requires_patch_manifest_path() -> None:
    payload = _load()
    payload["patchIsolation"].pop("patchManifestPath")

    assert {
        "code": "missing_patch_manifest_path",
        "path": "patchIsolation.patchManifestPath",
        "message": "patch manifest path must be declared",
    } in policy_check.check_policy(payload)


def test_chromium_fork_maintenance_policy_requires_existing_patch_manifest() -> None:
    payload = _load()
    payload["patchIsolation"]["patchManifestPath"] = "config/missing-chromium-patch-manifest.json"

    assert {
        "code": "missing_patch_manifest_file",
        "path": "patchIsolation.patchManifestPath",
        "message": "patch manifest file does not exist: config/missing-chromium-patch-manifest.json",
    } in policy_check.check_policy(payload)


def test_chromium_fork_maintenance_policy_requires_release_artifacts() -> None:
    payload = _load()
    payload["releaseArtifacts"]["compilerHashRequired"] = False

    assert {
        "code": "release_artifact_not_required",
        "path": "releaseArtifacts.compilerHashRequired",
        "message": "release requires compilerHashRequired",
    } in policy_check.check_policy(payload)


def test_chromium_fork_maintenance_policy_requires_release_archive_hash() -> None:
    payload = _load()
    payload["releaseArtifacts"]["releaseArchiveHashRequired"] = False

    assert {
        "code": "release_artifact_not_required",
        "path": "releaseArtifacts.releaseArchiveHashRequired",
        "message": "release requires releaseArchiveHashRequired",
    } in policy_check.check_policy(payload)


def test_chromium_fork_maintenance_policy_requires_dawn_fallback_runtime_hash() -> None:
    payload = _load()
    payload["releaseArtifacts"]["dawnFallbackRuntimeHashRequired"] = False

    assert {
        "code": "release_artifact_not_required",
        "path": "releaseArtifacts.dawnFallbackRuntimeHashRequired",
        "message": "release requires dawnFallbackRuntimeHashRequired",
    } in policy_check.check_policy(payload)
