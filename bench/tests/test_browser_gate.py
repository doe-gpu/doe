#!/usr/bin/env python3
"""Tests for browser gate runtime-selection evidence."""

from __future__ import annotations

import json
from pathlib import Path
import hashlib
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from bench.browser.browser_gate import (
    stable_hash,
    validate_active_runtime_proof,
    validate_adapter_identity,
    validate_cts_subset,
    validate_flight_recorder_replay,
    validate_json_checker,
    validate_pipeline_cache_receipts,
    validate_recovery_parity,
    validate_smoke_report,
    validate_runtime_selection,
    validate_shader_compiler_identity,
    validate_trace_hash_fields,
    validate_workload_identity,
)


SHA256 = "a" * 64


def test_stable_hash_matches_javascript_float_canonicalization() -> None:
    payload = {"delta": -5.960466609168032e-05, "whole": 1.0, "tiny": 1e-07}
    canonical = b'{"delta":-0.00005960466609168032,"tiny":1e-7,"whole":1}'

    assert stable_hash(payload) == hashlib.sha256(canonical).hexdigest()


def _runtime_selection(mode: str = "dawn") -> dict:
    return {
        "selectionMode": mode,
        "selectedRuntime": mode,
        "forcedMode": mode,
        "fallbackApplied": False,
        "fallbackReasonCode": "",
        "hiddenFallbackAllowed": False,
        "profile": {
            "profileId": "",
            "vendor": "unknown",
            "api": "unknown",
            "deviceFamily": "unknown",
            "driver": "unknown",
        },
        "selectorVersion": "browser-runtime-selector-v1",
        "launchArgsHash": SHA256,
        "artifactIdentity": {
            "browserExecutablePath": "/tmp/chrome",
            "browserExecutableSha256": SHA256,
            "dawnRuntimePath": "/tmp/chrome",
            "dawnRuntimeSha256": SHA256,
            "doeLibPath": "/tmp/libwebgpu_doe.dylib" if mode == "doe" else None,
            "doeLibSha256": SHA256 if mode == "doe" else None,
        },
    }


def test_runtime_selection_requires_browser_executable_hash() -> None:
    payload = _runtime_selection("dawn")
    payload["artifactIdentity"].pop("browserExecutableSha256")

    errors = validate_runtime_selection(payload, "dawn", "smoke dawn")

    assert "smoke dawn artifactIdentity.browserExecutableSha256 must be sha256 hex" in errors


def test_runtime_selection_accepts_browser_executable_hash_for_dawn() -> None:
    assert validate_runtime_selection(_runtime_selection("dawn"), "dawn", "smoke dawn") == []


def test_runtime_selection_accepts_browser_executable_hash_for_doe() -> None:
    assert validate_runtime_selection(_runtime_selection("doe"), "doe", "smoke doe") == []


def test_runtime_selection_requires_dawn_runtime_hash() -> None:
    payload = _runtime_selection("doe")
    payload["artifactIdentity"].pop("dawnRuntimeSha256")

    errors = validate_runtime_selection(payload, "doe", "smoke doe")

    assert "smoke doe artifactIdentity.dawnRuntimeSha256 must be sha256 hex" in errors


def test_runtime_selection_requires_profile_fields() -> None:
    payload = _runtime_selection("dawn")
    payload.pop("profile")

    errors = validate_runtime_selection(payload, "dawn", "smoke dawn")

    assert "smoke dawn profile must be object" in errors


def test_runtime_selection_requires_denylist_detail_for_profile_denylist() -> None:
    payload = _runtime_selection("dawn")
    payload["fallbackReasonCode"] = "profile_denylisted"

    errors = validate_runtime_selection(payload, "dawn", "smoke dawn")

    assert "smoke dawn fallbackReasonCode must be empty" in errors
    assert "smoke dawn adapterDenylist must be present for profile_denylisted" in errors


def test_runtime_selection_accepts_denylist_detail_shape() -> None:
    payload = _runtime_selection("dawn")
    payload["adapterDenylist"] = {
        "matched": False,
        "reasonCode": "",
        "profileId": "",
        "vendor": "",
        "api": "",
        "deviceFamily": "",
        "driverPattern": "",
    }

    assert validate_runtime_selection(payload, "dawn", "smoke dawn") == []


def test_adapter_identity_requires_adapter_info_hash() -> None:
    errors = validate_adapter_identity({"featureCount": 0}, "smoke mode dawn")

    assert "smoke mode dawn adapterIdentity.adapterInfoSha256 must be sha256 hex" in errors


def test_adapter_identity_accepts_digest_and_feature_count() -> None:
    payload = {"adapterInfoSha256": SHA256, "featureCount": 0}

    assert validate_adapter_identity(payload, "smoke mode dawn") == []


def _active_runtime_proof_v2(mode: str, adapter_info: dict) -> dict:
    selection = _runtime_selection(mode)
    artifact_hash = (
        selection["artifactIdentity"]["doeLibSha256"]
        if mode == "doe"
        else selection["artifactIdentity"]["dawnRuntimeSha256"]
    )
    return {
        "schemaVersion": 2,
        "providerIdentitySource": "runtimeSelector",
        "hardwareIdentitySource": "wgpuAdapterGetInfo",
        "selectedRuntime": mode,
        "expected": {
            "provider": mode,
            "fallbackApplied": False,
            "hiddenFallbackAllowed": False,
            "hardwareVendorMustBeNonEmpty": True,
            "hardwareArchitectureMustBeNonEmpty": True,
        },
        "provider": {
            "selectionMode": mode,
            "selectedRuntime": mode,
            "forcedMode": mode,
            "fallbackApplied": False,
            "hiddenFallbackAllowed": False,
            "runtimeArtifactSha256": artifact_hash,
            "launchArgsHash": SHA256,
        },
        "hardware": {
            field: adapter_info.get(field, "")
            for field in ("vendor", "architecture", "device", "description")
        },
        "matched": True,
    }


def test_active_runtime_proof_accepts_real_amd_identity_for_doe() -> None:
    adapter_info = {
        "vendor": "AMD",
        "architecture": "vulkan",
        "device": "Radeon 8060S Graphics",
        "description": "RADV",
    }

    assert validate_active_runtime_proof(
        _active_runtime_proof_v2("doe", adapter_info),
        _runtime_selection("doe"),
        adapter_info,
        "doe",
        "smoke mode doe",
    ) == []


def test_active_runtime_proof_rejects_provider_selection_drift() -> None:
    adapter_info = {
        "vendor": "AMD",
        "architecture": "vulkan",
        "device": "Radeon 8060S Graphics",
        "description": "RADV",
    }
    proof = _active_runtime_proof_v2("doe", adapter_info)
    proof["provider"]["selectedRuntime"] = "dawn"

    errors = validate_active_runtime_proof(
        proof,
        _runtime_selection("doe"),
        adapter_info,
        "doe",
        "smoke mode doe",
    )

    assert "smoke mode doe activeRuntimeProof.provider must match runtimeSelection" in errors


def test_shader_compiler_identity_requires_compiler_hash() -> None:
    payload = {
        "compilerSurface": "dawn_runtime_embedded_shader_compiler",
        "compilerArtifactPath": "/tmp/chrome",
        "identitySource": "runtime_artifact_identity",
    }

    errors = validate_shader_compiler_identity(payload, "dawn", "smoke dawn")

    assert "smoke dawn shaderCompilerIdentity.compilerArtifactSha256 must be sha256 hex" in errors


def test_shader_compiler_identity_accepts_mode_surface() -> None:
    payload = {
        "compilerSurface": "doe_runtime_embedded_shader_compiler",
        "compilerArtifactPath": "/tmp/libwebgpu_doe.dylib",
        "compilerArtifactSha256": SHA256,
        "identitySource": "runtime_artifact_identity",
    }

    assert validate_shader_compiler_identity(payload, "doe", "smoke doe") == []


def test_trace_hash_fields_require_row_hash() -> None:
    errors = validate_trace_hash_fields({"previousHash": None}, "smoke mode dawn")

    assert "smoke mode dawn hash must be sha256 hex" in errors


def test_trace_hash_fields_accept_null_previous_hash() -> None:
    payload = {"hash": SHA256, "previousHash": None}

    assert validate_trace_hash_fields(payload, "smoke mode dawn") == []


def test_workload_identity_requires_digest() -> None:
    errors = validate_workload_identity({"kind": "browser_smoke_suite"}, "smoke report")

    assert "smoke report workloadIdentity must include a sha256 workload digest" in errors


def test_workload_identity_accepts_source_digest() -> None:
    payload = {"kind": "browser_layered_superset", "sourceWorkloadsSha256": SHA256}

    assert validate_workload_identity(payload, "layered report") == []


def test_validate_smoke_report_accepts_sample() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))

    assert validate_smoke_report(payload) == []


def test_validate_smoke_report_rejects_report_hash_drift() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload["modeResults"][0]["webgpuAvailable"] = False

    errors = validate_smoke_report(payload)

    assert "smoke reportHash mismatch" in errors


def test_validate_smoke_report_rejects_hidden_fallback() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload["modeResults"][1]["runtimeSelection"]["fallbackApplied"] = True

    errors = validate_smoke_report(payload, require_hash_chain=False)

    assert "smoke doe fallbackApplied must be false" in errors


def test_validate_smoke_report_requires_render_bundle_smoke() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload["modeResults"][0]["smoke"].pop("renderBundle")

    errors = validate_smoke_report(payload, require_hash_chain=False)

    assert "smoke mode dawn renderBundle pass must be true" in errors


def test_validate_smoke_report_requires_render_indirect_smoke() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload["modeResults"][1]["smoke"]["renderIndirect"]["pass"] = False

    errors = validate_smoke_report(payload, require_hash_chain=False)

    assert "smoke mode doe renderIndirect pass must be true" in errors


def test_validate_smoke_report_requires_external_texture_smoke() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload["modeResults"][1]["smoke"]["importExternalTexture"]["pass"] = False

    errors = validate_smoke_report(payload, require_hash_chain=False)

    assert "smoke mode doe importExternalTexture pass must be true" in errors


def test_validate_smoke_report_requires_timestamp_query_smoke() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload["modeResults"][0]["smoke"]["timestampQuery"]["pass"] = False

    errors = validate_smoke_report(payload, require_hash_chain=False)

    assert "smoke mode dawn timestampQuery pass must be true" in errors


def test_validate_smoke_report_rejects_failed_browser_close_when_recorded() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload["modeResults"][1]["browserClose"] = {
        "attempted": True,
        "pass": False,
        "elapsedMs": 10000,
        "error": "doe browser close timed out",
    }

    errors = validate_smoke_report(payload, require_hash_chain=False)

    assert "smoke mode doe browserClose pass must be true" in errors


def test_validate_smoke_report_requires_bundle_comparison() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload["comparison"]["bothRenderBundleSmokePass"] = False

    errors = validate_smoke_report(payload, require_hash_chain=False)

    assert "smoke bothRenderBundleSmokePass must be true" in errors


def test_validate_smoke_report_requires_timestamp_query_comparison() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload["comparison"]["bothTimestampQuerySmokePass"] = False

    errors = validate_smoke_report(payload, require_hash_chain=False)

    assert "smoke bothTimestampQuerySmokePass must be true" in errors


def test_validate_smoke_report_requires_runtime_selections() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload.pop("runtimeSelections")

    errors = validate_smoke_report(payload, require_hash_chain=False)

    assert "smoke runtimeSelections must be list" in errors


def test_validate_smoke_report_rejects_unknown_runtime_selection_mode() -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-smoke-report.sample.json").read_text(encoding="utf-8"))
    payload["runtimeSelections"][0]["selectionMode"] = "auto"

    errors = validate_smoke_report(payload, require_hash_chain=False)

    assert "smoke runtimeSelections[0] selectionMode must be dawn or doe" in errors


def test_validate_cts_subset_accepts_sample() -> None:
    errors = validate_cts_subset(
        Path("examples/browser-cts-subset.sample.json"),
        Path(__file__).resolve().parents[2],
    )

    assert errors == []


def test_validate_cts_subset_reports_structural_failures(tmp_path: Path) -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-cts-subset.sample.json").read_text(encoding="utf-8"))
    payload["browserArtifacts"]["forcedDoeArtifactPath"] = ""
    subset = tmp_path / "browser-cts-subset.json"
    subset.write_text(json.dumps(payload) + "\n", encoding="utf-8")

    errors = validate_cts_subset(subset, root)

    assert any("cts-subset:missing_browser_lane" in error for error in errors)


def test_validate_recovery_parity_accepts_sample() -> None:
    errors = validate_recovery_parity(
        Path("examples/browser-recovery-parity.sample.json"),
        Path(__file__).resolve().parents[2],
    )

    assert errors == []


def test_validate_recovery_parity_reports_structural_failures(tmp_path: Path) -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-recovery-parity.sample.json").read_text(encoding="utf-8"))
    payload["cases"] = [
        row
        for row in payload["cases"]
        if row["caseKind"] != "device_loss"
    ]
    parity = tmp_path / "browser-recovery-parity.json"
    parity.write_text(json.dumps(payload) + "\n", encoding="utf-8")

    errors = validate_recovery_parity(parity, root)

    assert any("recovery-parity:missing_case_kind" in error for error in errors)


def test_validate_json_checker_accepts_canvas_fusion_sample() -> None:
    root = Path(__file__).resolve().parents[2]
    errors = validate_json_checker(
        label="canvas-webgpu-fusion",
        root=root,
        checker=root / "browser/chromium/scripts/check-browser-canvas-webgpu-fusion.py",
        path_flag="--probe",
        artifact_path=root / "examples/browser-canvas-webgpu-fusion.sample.json",
    )

    assert errors == []


def test_validate_json_checker_accepts_shader_links_sample() -> None:
    root = Path(__file__).resolve().parents[2]
    errors = validate_json_checker(
        label="shader-links",
        root=root,
        checker=root / "browser/chromium/scripts/check-browser-shader-links.py",
        path_flag="--links",
        artifact_path=root / "examples/browser-shader-links.sample.json",
    )

    assert errors == []


def test_validate_flight_recorder_replay_accepts_sample(tmp_path: Path) -> None:
    root = Path(__file__).resolve().parents[2]
    replay = tmp_path / "browser-gpu-flight-replay.json"

    errors = validate_flight_recorder_replay(
        root=root,
        flight_recorder_path=root / "examples/browser-gpu-flight-recorder.sample.json",
        replay_report_path=replay,
        capture_policy_path=root / "config/browser-capture-policy.json",
    )

    assert errors == []
    assert replay.exists()


def test_validate_flight_recorder_replay_reports_structural_failure(tmp_path: Path) -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-gpu-flight-recorder.sample.json").read_text(encoding="utf-8"))
    payload["commandGraph"]["edges"][0]["toNodeId"] = "node:missing"
    recorder = tmp_path / "browser-gpu-flight-recorder.json"
    recorder.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    replay = tmp_path / "browser-gpu-flight-replay.json"

    errors = validate_flight_recorder_replay(
        root=root,
        flight_recorder_path=recorder,
        replay_report_path=replay,
        capture_policy_path=root / "config/browser-capture-policy.json",
    )

    assert any("flight-recorder-replay:missing_edge_node" in error for error in errors)


def test_validate_pipeline_cache_receipts_accepts_sample() -> None:
    root = Path(__file__).resolve().parents[2]

    assert validate_pipeline_cache_receipts(root / "examples/browser-pipeline-cache-receipts.sample.json") == []


def test_validate_pipeline_cache_receipts_reports_failure(tmp_path: Path) -> None:
    root = Path(__file__).resolve().parents[2]
    payload = json.loads((root / "examples/browser-pipeline-cache-receipts.sample.json").read_text(encoding="utf-8"))
    payload["receiptStatus"] = "fail"
    payload["failureCodes"] = [
        {
            "code": "missing_cache_receipt_field",
            "path": "receipts[0].cacheKey",
            "message": "missing cache receipt field cacheKey",
        }
    ]
    receipts = tmp_path / "browser-pipeline-cache-receipts.json"
    receipts.write_text(json.dumps(payload) + "\n", encoding="utf-8")

    errors = validate_pipeline_cache_receipts(receipts)

    assert any("pipeline-cache-receipts:missing_cache_receipt_field" in error for error in errors)
