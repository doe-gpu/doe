#!/usr/bin/env python3
"""Execution-receipt identity and fallback-state checks for browser claims."""

from __future__ import annotations

import hashlib
from typing import Any

TIMING_PHASE_FIELDS = ("setupNs", "encodeNs", "submitWaitNs")
EXPECTED_BACKEND_BY_RUNTIME = {
    "dawn": "webgpu-dawn",
    "doe": "webgpu-doe",
}
DAWN_LOWERING_MARKERS = ("wgsl", "tint", "dawn-native")
DOE_FORBIDDEN_LOWERING_MARKERS = ("tint", "dawn-native")


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def non_bool_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def strict_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(char in "0123456789abcdef" for char in value)
    )


def recent_receipt_artifact_paths(proof_surface: dict[str, Any]) -> list[str]:
    proof_page = proof_surface.get("proofPage")
    if not isinstance(proof_page, dict):
        return []
    recent_ids = {
        item for item in proof_page.get("recentReceiptIds", []) if isinstance(item, str)
    }
    paths: list[str] = []

    def collect(artifact: Any) -> None:
        if not isinstance(artifact, dict):
            return
        if artifact.get("receiptId") not in recent_ids:
            return
        path = artifact.get("path")
        if isinstance(path, str) and path and path not in paths:
            paths.append(path)

    for artifact in proof_page.get("receiptPayloads", []) or []:
        collect(artifact)
    for row in proof_surface.get("galleryPages", []) or []:
        if isinstance(row, dict):
            for artifact in row.get("receiptArtifacts", []) or []:
                collect(artifact)
    for item in proof_surface.get("comparisonReceipts", []) or []:
        if isinstance(item, dict):
            collect(item.get("dawnReceipt"))
            collect(item.get("doeReceipt"))
    return paths


def validate_output_identity_payload(
    payload: dict[str, Any],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    output_values = [
        payload.get(field)
        for field in ("outputHash", "frameHash")
        if payload.get(field) is not None
    ]
    if not any(isinstance(value, str) and value for value in output_values):
        return [
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload must include outputHash or frameHash",
            )
        ]
    if len(output_values) == 1 and strict_sha256(output_values[0]):
        return []
    return [
        failure(
            "browser_release_proof_surface_receipt_incomplete",
            proof_surface_path,
            "execution receipt outputHash or frameHash must be one lowercase SHA-256 string",
        )
    ]


def validate_source_shader_metadata_payload(
    payload: dict[str, Any],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    source_shader = payload.get("sourceShader")
    if not isinstance(source_shader, dict):
        return []
    failures: list[dict[str, str]] = []
    if source_shader.get("language") != "wgsl":
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_source_mismatch",
                proof_surface_path,
                "execution receipt sourceShader.language must be wgsl",
            )
        )
    if not isinstance(source_shader.get("entryPoint"), str) or not source_shader.get("entryPoint"):
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_source_mismatch",
                proof_surface_path,
                "execution receipt sourceShader.entryPoint must be a non-empty string",
            )
        )
    return failures


def validate_source_shader_hash_alias_payload(
    payload: dict[str, Any],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    source_shader = payload.get("sourceShader")
    if not isinstance(source_shader, dict):
        return []
    source_sha = source_shader.get("sourceSha256")
    if source_sha is None:
        return []
    if not strict_sha256(source_sha):
        return [
            failure(
                "browser_release_proof_surface_receipt_source_mismatch",
                proof_surface_path,
                "execution receipt sourceShader.sourceSha256 must be a lowercase SHA-256 string",
            )
        ]
    source = source_shader.get("source")
    if not isinstance(source, str) or not source:
        return []
    actual_source_sha = hashlib.sha256(source.encode("utf-8")).hexdigest()
    if source_sha == actual_source_sha:
        return []
    return [
        failure(
            "browser_release_proof_surface_receipt_source_mismatch",
            proof_surface_path,
            "execution receipt sourceShader.sourceSha256 must match sourceShader.source",
        )
    ]


def source_shader_identity(payload: dict[str, Any]) -> tuple[Any, Any, Any] | None:
    source_shader = payload.get("sourceShader")
    if not isinstance(source_shader, dict):
        return None
    value = source_shader.get("sha256")
    if not isinstance(value, str) or not value:
        value = source_shader.get("source")
    if not isinstance(value, str) or not value:
        return None
    return (
        source_shader.get("language"),
        source_shader.get("entryPoint"),
        value,
    )


def validate_backend_runtime_binding_payload(
    payload: dict[str, Any],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    selected_runtime = payload.get("selectedRuntime")
    expected_backend = EXPECTED_BACKEND_BY_RUNTIME.get(selected_runtime)
    backend = payload.get("backend")
    if expected_backend is None or backend == expected_backend:
        return []
    return [
        failure(
            "browser_release_proof_surface_receipt_backend_mismatch",
            proof_surface_path,
            "execution receipt backend must match selectedRuntime",
        )
    ]


def validate_lowering_path_runtime_binding_payload(
    payload: dict[str, Any],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    selected_runtime = payload.get("selectedRuntime")
    lowering_path = payload.get("loweringPath")
    if not isinstance(lowering_path, list) or not all(
        isinstance(item, str) and item for item in lowering_path
    ):
        return []

    if selected_runtime == "dawn":
        if list(lowering_path) == list(DAWN_LOWERING_MARKERS):
            return []
        return [
            failure(
                "browser_release_proof_surface_receipt_lowering_mismatch",
                proof_surface_path,
                "Dawn execution receipt loweringPath must use the WGSL/Tint/Dawn route",
            )
        ]

    if selected_runtime != "doe":
        return []

    if (
        lowering_path[0] == "wgsl"
        and "doe-wgsl" in lowering_path
        and lowering_path[-1] == "webgpu"
        and not any(item in DOE_FORBIDDEN_LOWERING_MARKERS for item in lowering_path)
    ):
        return []
    return [
        failure(
            "browser_release_proof_surface_receipt_lowering_mismatch",
            proof_surface_path,
            "Doe execution receipt loweringPath must use the WGSL/Doe/WebGPU route",
        )
    ]


def execution_receipt_reference_identity(
    artifact: dict[str, Any],
    expected_runtime: str | None,
) -> tuple[Any, Any, Any, Any, str | None]:
    return (
        artifact.get("receiptId"),
        artifact.get("path"),
        artifact.get("sha256"),
        artifact.get("kind"),
        expected_runtime,
    )


def validate_execution_receipt_reference_consistency(
    refs: list[tuple[dict[str, Any], str | None]],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    refs_by_path_runtime: dict[
        tuple[str, str | None],
        tuple[Any, Any, Any, Any, str | None],
    ] = {}
    paths_by_receipt_id: dict[Any, Any] = {}
    for artifact, expected_runtime in refs:
        identity = execution_receipt_reference_identity(artifact, expected_runtime)
        rel_path = artifact.get("path")
        if isinstance(rel_path, str):
            path_key = (rel_path, expected_runtime)
            previous_identity = refs_by_path_runtime.get(path_key)
            if previous_identity is None:
                refs_by_path_runtime[path_key] = identity
            elif previous_identity != identity:
                failures.append(
                    failure(
                        "browser_release_proof_surface_receipt_reference_mismatch",
                        proof_surface_path,
                        "duplicate execution receipt path/runtime references must agree on ID, hash, and kind",
                    )
                )

        receipt_id = artifact.get("receiptId")
        if isinstance(receipt_id, str) and isinstance(rel_path, str):
            previous_path = paths_by_receipt_id.get(receipt_id)
            if previous_path is None:
                paths_by_receipt_id[receipt_id] = rel_path
            elif previous_path != rel_path:
                failures.append(
                    failure(
                        "browser_release_proof_surface_receipt_reference_mismatch",
                        proof_surface_path,
                        "execution receipt IDs must not reference multiple artifact paths",
                    )
                )
    return failures


def validate_timing_payload(
    payload: dict[str, Any],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    timing = payload.get("timing")
    if not isinstance(timing, dict):
        return [
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload must include timing",
            )
        ]

    failures: list[dict[str, str]] = []
    if not isinstance(timing.get("timingClass"), str) or not timing.get("timingClass"):
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt timing must include timingClass",
            )
        )
    phases = timing.get("phases")
    if not isinstance(phases, dict) or not phases:
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt timing must include phase timings",
            )
        )
    else:
        for field in TIMING_PHASE_FIELDS:
            value = phases.get(field)
            if not non_bool_int(value) or value < 0:
                failures.append(
                    failure(
                        "browser_release_proof_surface_receipt_incomplete",
                        proof_surface_path,
                        f"execution receipt timing.phases.{field} must be non-negative integer nanoseconds",
                    )
                )
    return failures


def validate_no_hidden_fallback_payload(
    payload: dict[str, Any],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    selected_runtime = payload.get("selectedRuntime")
    failures: list[dict[str, str]] = []
    runtime_selector_state = payload.get("runtimeSelectorState")
    if not isinstance(runtime_selector_state, dict):
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_hidden_fallback",
                proof_surface_path,
                "execution receipt payload must include runtimeSelectorState",
            )
        )
    else:
        if runtime_selector_state.get("selectedRuntime") != selected_runtime:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_hidden_fallback",
                    proof_surface_path,
                    "execution receipt runtimeSelectorState.selectedRuntime must match selectedRuntime",
                )
            )
        if runtime_selector_state.get("fallbackApplied") is not False:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_hidden_fallback",
                    proof_surface_path,
                    "execution receipt runtimeSelectorState.fallbackApplied must be false",
                )
            )
        if runtime_selector_state.get("hiddenFallbackAllowed") is not False:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_hidden_fallback",
                    proof_surface_path,
                    "execution receipt runtimeSelectorState.hiddenFallbackAllowed must be false",
                )
            )
        selector_fallback_reason = runtime_selector_state.get("fallbackReasonCode")
        if not isinstance(selector_fallback_reason, str):
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_hidden_fallback",
                    proof_surface_path,
                    "execution receipt runtimeSelectorState.fallbackReasonCode must be a string",
                )
            )
        elif selector_fallback_reason:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_hidden_fallback",
                    proof_surface_path,
                    "execution receipt runtimeSelectorState.fallbackReasonCode must be empty",
                )
            )

    fallback_state = payload.get("fallbackState")
    if not isinstance(fallback_state, dict):
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_hidden_fallback",
                proof_surface_path,
                "execution receipt payload must include fallbackState",
            )
        )
    else:
        if fallback_state.get("fallbackApplied") is not False:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_hidden_fallback",
                    proof_surface_path,
                    "execution receipt fallbackState.fallbackApplied must be false",
                )
            )
        if fallback_state.get("hiddenFallbackAllowed") is not False:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_hidden_fallback",
                    proof_surface_path,
                    "execution receipt fallbackState.hiddenFallbackAllowed must be false",
                )
            )
        reason_code = fallback_state.get("reasonCode")
        if not isinstance(reason_code, str):
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_hidden_fallback",
                    proof_surface_path,
                    "execution receipt fallbackState.reasonCode must be a string",
                )
            )
        elif reason_code:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_hidden_fallback",
                    proof_surface_path,
                    "execution receipt fallbackState.reasonCode must be empty",
                )
            )
    return failures


def _command_coverage_identity(payload: dict[str, Any]) -> tuple[Any, Any, Any] | None:
    coverage = payload.get("commandCoverage")
    if not isinstance(coverage, dict):
        return None
    return (
        coverage.get("commandCount"),
        coverage.get("successCount"),
        coverage.get("dispatchCount"),
    )


def _timing_class(payload: dict[str, Any]) -> str | None:
    timing = payload.get("timing")
    if not isinstance(timing, dict):
        return None
    value = timing.get("timingClass")
    return value if isinstance(value, str) and value else None


def _output_identity_policy_value(payload: dict[str, Any]) -> str | None:
    if isinstance(payload.get("outputHash"), str) and payload.get("outputHash"):
        return "same_output_hash"
    if isinstance(payload.get("frameHash"), str) and payload.get("frameHash"):
        return "same_frame_hash"
    return None


def validate_comparison_policy_payload_binding(
    policy: dict[str, Any],
    dawn_payload: dict[str, Any],
    doe_payload: dict[str, Any],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    dawn_workload_id = dawn_payload.get("workloadId")
    doe_workload_id = doe_payload.get("workloadId")
    workload_policy = (
        "same_workload_id"
        if isinstance(dawn_workload_id, str)
        and dawn_workload_id
        and dawn_workload_id == doe_workload_id
        else None
    )
    source_policy = (
        "same_source_shader_identity"
        if source_shader_identity(dawn_payload) is not None
        and source_shader_identity(dawn_payload) == source_shader_identity(doe_payload)
        else None
    )
    device_policy = (
        "same_device_identity"
        if dawn_payload.get("driver") is not None
        and dawn_payload.get("device") is not None
        and dawn_payload.get("driver") == doe_payload.get("driver")
        and dawn_payload.get("device") == doe_payload.get("device")
        else None
    )
    dawn_timing_class = _timing_class(dawn_payload)
    timing_policy = (
        dawn_timing_class
        if dawn_timing_class is not None and dawn_timing_class == _timing_class(doe_payload)
        else None
    )
    command_policy = (
        "exact_match"
        if _command_coverage_identity(dawn_payload) is not None
        and _command_coverage_identity(dawn_payload) == _command_coverage_identity(doe_payload)
        else None
    )
    dawn_output_policy = _output_identity_policy_value(dawn_payload)
    output_policy = (
        dawn_output_policy
        if dawn_output_policy is not None
        and dawn_output_policy == _output_identity_policy_value(doe_payload)
        else None
    )
    fallback_policy = (
        "no_hidden_fallback"
        if not validate_no_hidden_fallback_payload(
            dawn_payload,
            proof_surface_path=proof_surface_path,
        )
        and not validate_no_hidden_fallback_payload(
            doe_payload,
            proof_surface_path=proof_surface_path,
        )
        else None
    )

    failures: list[dict[str, str]] = []
    checks = (
        (
            policy.get("workloadIdentity"),
            workload_policy,
            "comparison policy workloadIdentity must match both execution receipt workload IDs",
        ),
        (
            policy.get("sourceShaderIdentity"),
            source_policy,
            "comparison policy sourceShaderIdentity must match both execution receipt source identities",
        ),
        (
            policy.get("adapterDeviceIdentity"),
            device_policy,
            "comparison policy adapterDeviceIdentity must match both execution receipt driver/device identities",
        ),
        (
            policy.get("timingScope"),
            timing_policy,
            "comparison policy timingScope must match both execution receipt timing classes",
        ),
        (
            policy.get("commandCoverage"),
            command_policy,
            "comparison policy commandCoverage must match both execution receipt command coverage",
        ),
        (
            policy.get("outputIdentity"),
            output_policy,
            "comparison policy outputIdentity must match both execution receipt output identity kinds",
        ),
        (
            policy.get("fallbackPolicy"),
            fallback_policy,
            "comparison policy fallbackPolicy must match both execution receipt fallback states",
        ),
    )
    for declared, derived, message in checks:
        if derived is not None and declared == derived:
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_comparison_payload_mismatch",
                proof_surface_path,
                message,
            )
        )
    return failures
