#!/usr/bin/env python3
"""Tests for the Chromium WebGPU integration overlay checker."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from typing import Any

from bench.browser.browser_gate import stable_hash


REPO_ROOT = Path(__file__).resolve().parents[2]
OVERLAY_PATH = REPO_ROOT / "config" / "webgpu-integration-chromium.json"
CHECKER_PATH = REPO_ROOT / "bench" / "tools" / "check_webgpu_integration_chromium.py"
SMOKE_SAMPLE_PATH = REPO_ROOT / "examples" / "browser-smoke-report.sample.json"


def _load_overlay() -> dict[str, Any]:
    return json.loads(OVERLAY_PATH.read_text(encoding="utf-8"))


def _load_checker() -> Any:
    spec = importlib.util.spec_from_file_location("webgpu_integration_chromium", CHECKER_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _without_hash_fields(payload: dict[str, Any], fields: tuple[str, ...]) -> dict[str, Any]:
    return {key: value for key, value in payload.items() if key not in fields}


def _refresh_smoke_hashes(payload: dict[str, Any]) -> None:
    previous_hash = None
    for row in payload["modeResults"]:
        row.pop("hash", None)
        row["previousHash"] = previous_hash
        row["hash"] = stable_hash(
            {
                "previousHash": previous_hash,
                "entry": _without_hash_fields(row, ("previousHash", "hash")),
            }
        )
        previous_hash = row["hash"]
    payload.pop("reportHash", None)
    payload["reportHash"] = stable_hash(payload)


def _source_smoke_report(root: Path) -> dict[str, Any]:
    payload = json.loads(SMOKE_SAMPLE_PATH.read_text(encoding="utf-8"))
    chrome_path = str(root / "browser/chromium/src/out/fawn_release/Chromium")
    doe_lib_path = str(root / "runtime/zig/zig-out/lib/libwebgpu_doe.dylib")
    payload["chromePath"] = chrome_path
    for row in payload["modeResults"]:
        artifact = row["runtimeSelection"]["artifactIdentity"]
        artifact["browserExecutablePath"] = chrome_path
        artifact["dawnRuntimePath"] = chrome_path
        if row["mode"] == "doe":
            artifact["doeLibPath"] = doe_lib_path
    payload["runtimeSelections"] = [row["runtimeSelection"] for row in payload["modeResults"]]
    _refresh_smoke_hashes(payload)
    return payload


def _activated_overlay() -> dict[str, Any]:
    payload = _load_overlay()
    payload["integrationPhase"] = "chromium_runtime_active"
    payload["wireProtocolNotes"]["architecture"] = "WebGPUDecoderImpl source runtime active"
    for row in payload["coverage"]:
        row["status"] = "passing"
        row.pop("blockedBy", None)
    return payload


def test_webgpu_integration_chromium_overlay_passes_check() -> None:
    checker = _load_checker()

    assert checker.check_overlay(_load_overlay()) == []


def test_webgpu_integration_chromium_overlay_links_existing_smoke_artifact() -> None:
    checker = _load_checker()

    assert checker.check_overlay(
        _load_overlay(),
        verify_artifact_root=REPO_ROOT,
    ) == []


def test_webgpu_integration_chromium_requires_core_capability() -> None:
    checker = _load_checker()
    payload = _load_overlay()
    payload["coverage"] = [
        row for row in payload["coverage"]
        if row["capability"] != "requestAdapter"
    ]

    failures = checker.check_overlay(payload)

    assert {
        "code": "missing_required_capability",
        "path": "coverage",
        "message": "missing required capability requestAdapter",
    } in failures


def test_webgpu_integration_chromium_rejects_passing_blocked_row() -> None:
    checker = _load_checker()
    payload = _load_overlay()
    payload["integrationPhase"] = "chromium_runtime_active"
    payload["wireProtocolNotes"]["architecture"] = "WebGPUDecoderImpl source selector active"
    payload["coverage"][0]["status"] = "passing"
    payload["coverage"][0]["blockedBy"] = "unexpected-blocker"

    failures = checker.check_overlay(payload)

    assert {
        "code": "passing_row_blocked",
        "path": "coverage[0].blockedBy",
        "message": "passing rows must not carry blockedBy",
    } in failures


def test_webgpu_integration_chromium_rejects_passing_before_source_runtime_active() -> None:
    checker = _load_checker()
    payload = _load_overlay()
    payload["coverage"][0]["status"] = "passing"

    failures = checker.check_overlay(payload)

    assert {
        "code": "passing_before_source_runtime_active",
        "path": "coverage[0].status",
        "message": "passing Chromium rows require integrationPhase=chromium_runtime_active",
    } in failures


def test_webgpu_integration_chromium_accepts_active_source_runtime_rows() -> None:
    checker = _load_checker()

    assert checker.check_overlay(_activated_overlay()) == []


def test_webgpu_integration_chromium_rejects_abandoned_decoder_name() -> None:
    checker = _load_checker()
    payload = _activated_overlay()
    payload["wireProtocolNotes"]["architecture"] = "DoeCommandDecoder source runtime active"

    assert {
        "code": "missing_decoder_architecture",
        "path": "wireProtocolNotes.architecture",
        "message": "architecture note must name the patched WebGPUDecoderImpl seam",
    } in checker.check_overlay(payload)


def test_webgpu_integration_chromium_requires_render_bundle_for_active_runtime() -> None:
    checker = _load_checker()
    payload = _activated_overlay()
    for row in payload["coverage"]:
        if row["capability"] == "renderBundles":
            row["status"] = "diagnostic_wrapper_only"

    failures = checker.check_overlay(payload)

    assert {
        "code": "required_capability_not_passing",
        "path": "coverage[renderBundles].status",
        "message": "renderBundles must be passing in the Chromium overlay",
    } in failures


def test_webgpu_integration_chromium_requires_external_texture_for_active_runtime() -> None:
    checker = _load_checker()
    payload = _activated_overlay()
    for row in payload["coverage"]:
        if row["capability"] == "importExternalTexture":
            row["status"] = "diagnostic_wrapper_only"

    failures = checker.check_overlay(payload)

    assert {
        "code": "required_capability_not_passing",
        "path": "coverage[importExternalTexture].status",
        "message": "importExternalTexture must be passing in the Chromium overlay",
    } in failures


def test_webgpu_integration_chromium_verifies_smoke_artifact(tmp_path: Path) -> None:
    checker = _load_checker()
    payload = _load_overlay()
    payload["smokeTestArtifact"] = "artifacts/smoke.json"
    artifact_dir = tmp_path / "artifacts"
    artifact_dir.mkdir()
    (artifact_dir / "smoke.json").write_text(json.dumps(_source_smoke_report(tmp_path)), encoding="utf-8")

    assert checker.check_overlay(payload, verify_artifact_root=tmp_path) == []


def test_webgpu_integration_chromium_requires_source_binary_smoke_artifact(tmp_path: Path) -> None:
    checker = _load_checker()
    payload = _load_overlay()
    payload["smokeTestArtifact"] = "artifacts/smoke.json"
    artifact_dir = tmp_path / "artifacts"
    artifact_dir.mkdir()
    report = _source_smoke_report(tmp_path)
    report["chromePath"] = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    _refresh_smoke_hashes(report)
    (artifact_dir / "smoke.json").write_text(json.dumps(report), encoding="utf-8")

    failures = checker.check_overlay(payload, verify_artifact_root=tmp_path)

    assert {
        "code": "non_source_chromium_binary",
        "path": "smokeTestArtifact.chromePath",
        "message": "source runtime evidence must use a browser/chromium/src/out Chromium binary",
    } in failures


def test_webgpu_integration_chromium_requires_no_fallback_source_smoke(tmp_path: Path) -> None:
    checker = _load_checker()
    payload = _load_overlay()
    payload["smokeTestArtifact"] = "artifacts/smoke.json"
    artifact_dir = tmp_path / "artifacts"
    artifact_dir.mkdir()
    report = _source_smoke_report(tmp_path)
    report["modeResults"][1]["runtimeSelection"]["fallbackApplied"] = True
    report["runtimeSelections"] = [row["runtimeSelection"] for row in report["modeResults"]]
    _refresh_smoke_hashes(report)
    (artifact_dir / "smoke.json").write_text(json.dumps(report), encoding="utf-8")

    failures = checker.check_overlay(payload, verify_artifact_root=tmp_path)

    assert {
        "code": "invalid_source_smoke_report_contract",
        "path": "smokeTestArtifact",
        "message": "smoke doe fallbackApplied must be false",
    } in failures
    assert any(
        failure["code"] == "invalid_source_runtime_selection"
        and failure["path"] == "smokeTestArtifact.runtimeSelections[1]"
        and "fallbackApplied must be false" in failure["message"]
        for failure in failures
    )


def test_webgpu_integration_chromium_requires_top_level_runtime_selections(
    tmp_path: Path,
) -> None:
    checker = _load_checker()
    payload = _load_overlay()
    payload["smokeTestArtifact"] = "artifacts/smoke.json"
    artifact_dir = tmp_path / "artifacts"
    artifact_dir.mkdir()
    report = _source_smoke_report(tmp_path)
    report.pop("runtimeSelections")
    _refresh_smoke_hashes(report)
    (artifact_dir / "smoke.json").write_text(json.dumps(report), encoding="utf-8")

    failures = checker.check_overlay(payload, verify_artifact_root=tmp_path)

    assert {
        "code": "missing_source_runtime_selections",
        "path": "smokeTestArtifact.runtimeSelections",
        "message": "source runtime evidence must include top-level runtimeSelections",
    } in failures


def test_webgpu_integration_chromium_reports_missing_smoke_artifact(tmp_path: Path) -> None:
    checker = _load_checker()
    payload = _load_overlay()
    payload["smokeTestArtifact"] = "artifacts/missing.json"

    failures = checker.check_overlay(payload, verify_artifact_root=tmp_path)

    assert failures == [
        {
            "code": "missing_smoke_artifact_file",
            "path": "smokeTestArtifact",
            "message": f"missing smoke artifact {tmp_path / 'artifacts/missing.json'}",
        }
    ]


def test_webgpu_integration_chromium_rejects_unsafe_smoke_artifact_path(tmp_path: Path) -> None:
    checker = _load_checker()
    payload = _load_overlay()
    payload["smokeTestArtifact"] = "../smoke.json"

    failures = checker.check_overlay(payload, verify_artifact_root=tmp_path)

    assert failures == [
        {
            "code": "unsafe_smoke_artifact_path",
            "path": "smokeTestArtifact",
            "message": "smokeTestArtifact must be repo-relative",
        }
    ]
