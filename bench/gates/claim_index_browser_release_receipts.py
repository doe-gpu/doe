#!/usr/bin/env python3
"""Execution-receipt checks for Chromium claim-index browser releases."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from bench.browser.browser_gate import validate_smoke_report
from bench.gates.claim_index_browser_release_receipt_state import (
    recent_receipt_artifact_paths,
    source_shader_identity,
    strict_sha256,
    validate_backend_runtime_binding_payload,
    validate_comparison_policy_payload_binding,
    validate_execution_receipt_reference_consistency,
    validate_lowering_path_runtime_binding_payload,
    validate_no_hidden_fallback_payload,
    validate_output_identity_payload,
    validate_source_shader_hash_alias_payload,
    validate_source_shader_metadata_payload,
    validate_timing_payload,
)


BROWSER_EXECUTION_RECEIPT_KIND = "browser_execution_receipt"
BROWSER_PROOF_PAGE_RECEIPT_KIND = "browser_proof_page_receipt"
BROWSER_COMPARISON_ARTIFACT_KIND = "chromium-webgpu-playwright-smoke"
COMMAND_EVIDENCE_HASH_FIELDS = ("sha256", "hash", "graphSha256", "artifactSha256")
PROOF_PAGE_VISIBLE_DIAGNOSTIC_FIELDS = (
    "activeRuntime",
    "activeBackend",
    "compilerPath",
    "tsirStatus",
    "hostPlanStatus",
    "cslStatus",
    "fallbackPolicyState",
)


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def nested_value(value: Any, path: tuple[str, ...]) -> Any:
    current = value
    for key in path:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def unsafe_receipt_path_reason(path: Any) -> str:
    if not isinstance(path, str) or not path:
        return "receipt path must be a non-empty string"
    if "\\" in path:
        return "receipt path must use forward slashes"
    if path.startswith("/"):
        return "receipt path must be repository-relative"
    if not path.endswith(".json"):
        return "receipt path must end in .json"
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return "receipt path must not contain empty, current, or parent segments"
    return ""


def unsafe_repo_path_reason(path: Any) -> str:
    if not isinstance(path, str) or not path:
        return "artifact path must be a non-empty string"
    if "\\" in path:
        return "artifact path must use forward slashes"
    if path.startswith("/"):
        return "artifact path must be repository-relative"
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return "artifact path must not contain empty, current, or parent segments"
    return ""


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def output_identity(payload: dict[str, Any]) -> str | None:
    for field in ("outputHash", "frameHash"):
        value = payload.get(field)
        if isinstance(value, str) and value:
            return value
    return None


def output_identity_kind(payload: dict[str, Any]) -> str | None:
    for field in ("outputHash", "frameHash"):
        value = payload.get(field)
        if isinstance(value, str) and value:
            return field
    return None


def timing_class(payload: dict[str, Any]) -> str | None:
    timing = payload.get("timing")
    if not isinstance(timing, dict):
        return None
    value = timing.get("timingClass")
    return value if isinstance(value, str) and value else None


def command_coverage_identity(payload: dict[str, Any]) -> tuple[Any, Any, Any] | None:
    coverage = payload.get("commandCoverage")
    if not isinstance(coverage, dict):
        return None
    return (
        coverage.get("commandCount"),
        coverage.get("successCount"),
        coverage.get("dispatchCount"),
    )


def command_evidence_identity(payload: dict[str, Any]) -> str | None:
    for field in ("commandGraph", "flightRecorderRef"):
        evidence = payload.get(field)
        if not isinstance(evidence, dict):
            continue
        for hash_field in COMMAND_EVIDENCE_HASH_FIELDS:
            value = evidence.get(hash_field)
            if strict_sha256(value):
                return value
    return None


def command_evidence_hashes(payload: dict[str, Any]) -> set[str]:
    hashes: set[str] = set()
    for field in ("commandGraph", "flightRecorderRef"):
        evidence = payload.get(field)
        if not isinstance(evidence, dict):
            continue
        for hash_field in COMMAND_EVIDENCE_HASH_FIELDS:
            value = evidence.get(hash_field)
            if strict_sha256(value):
                hashes.add(value)
    return hashes


def command_evidence_artifact_paths(payload: dict[str, Any]) -> list[str]:
    paths: list[str] = []
    for field in ("commandGraph", "flightRecorderRef"):
        evidence = payload.get(field)
        if not isinstance(evidence, dict):
            continue
        artifact_path = evidence.get("artifactPath")
        if isinstance(artifact_path, str) and artifact_path and artifact_path not in paths:
            paths.append(artifact_path)
    return paths


def non_bool_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def validate_command_coverage_payload(
    payload: dict[str, Any],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    coverage = payload.get("commandCoverage")
    if not isinstance(coverage, dict) or not coverage:
        return [
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload must include commandCoverage",
            )
        ]

    failures: list[dict[str, str]] = []
    command_count = coverage.get("commandCount")
    success_count = coverage.get("successCount")
    dispatch_count = coverage.get("dispatchCount")
    if not non_bool_int(command_count) or command_count <= 0:
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt commandCoverage.commandCount must be positive",
            )
        )
    if not non_bool_int(success_count) or success_count < 0:
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt commandCoverage.successCount must be non-negative",
            )
        )
    elif non_bool_int(command_count):
        if success_count > command_count:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_incomplete",
                    proof_surface_path,
                    "execution receipt commandCoverage.successCount cannot exceed commandCount",
                )
            )
        elif command_count > 0 and success_count != command_count:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_incomplete",
                    proof_surface_path,
                    "execution receipt commandCoverage.successCount must equal commandCount",
                )
            )
    if dispatch_count is not None:
        if not non_bool_int(dispatch_count) or dispatch_count < 0:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_incomplete",
                    proof_surface_path,
                    "execution receipt commandCoverage.dispatchCount must be non-negative",
                )
            )
        elif non_bool_int(command_count) and command_count > 0 and dispatch_count > command_count:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_incomplete",
                    proof_surface_path,
                    "execution receipt commandCoverage.dispatchCount cannot exceed commandCount",
                )
            )
    return failures


def command_evidence_has_hash(evidence: dict[str, Any]) -> bool:
    return any(strict_sha256(evidence.get(field)) for field in COMMAND_EVIDENCE_HASH_FIELDS)


def validate_command_evidence_payload(
    payload: dict[str, Any],
    *,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    command_graph = payload.get("commandGraph")
    flight_recorder_ref = payload.get("flightRecorderRef")
    evidence_items = [
        evidence
        for evidence in (command_graph, flight_recorder_ref)
        if isinstance(evidence, dict) and evidence
    ]
    if not evidence_items:
        return [
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload must include commandGraph or flightRecorderRef evidence",
            )
        ]

    failures: list[dict[str, str]] = []
    for evidence in evidence_items:
        if command_evidence_has_hash(evidence):
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt command evidence must include a lowercase SHA-256 identity",
            )
        )
    return failures


def validate_execution_receipt_payload(
    payload: dict[str, Any],
    *,
    artifact: dict[str, Any],
    expected_runtime: str | None,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("artifactKind") != BROWSER_EXECUTION_RECEIPT_KIND:
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "claim-indexed Chromium proof surfaces require browser execution receipt payloads",
            )
        )
    if payload.get("schemaVersion") != 1:
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload schemaVersion must be 1",
            )
        )
    if payload.get("receiptId") != artifact.get("receiptId"):
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload receiptId must match the proof-surface artifact reference",
            )
        )
    if not isinstance(payload.get("workloadId"), str) or not payload.get("workloadId"):
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload must include workloadId",
            )
        )
    selected_runtime = payload.get("selectedRuntime")
    if expected_runtime is not None and selected_runtime != expected_runtime:
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                f"comparison execution receipt must select {expected_runtime}",
            )
        )
    elif expected_runtime is None and selected_runtime not in ("dawn", "doe"):
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload must identify the selected runtime",
            )
        )

    source_shader = payload.get("sourceShader")
    if not isinstance(source_shader, dict):
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload must include sourceShader",
            )
        )
    else:
        source = source_shader.get("source")
        source_sha = source_shader.get("sha256")
        if not isinstance(source, str) or not source:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_incomplete",
                    proof_surface_path,
                    "execution receipt payload must include sourceShader.source",
                )
            )
        if not isinstance(source_sha, str) or not source_sha:
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_incomplete",
                    proof_surface_path,
                    "execution receipt payload must include sourceShader.sha256",
                )
            )
        if isinstance(source, str) and isinstance(source_sha, str):
            actual_source_sha = hashlib.sha256(source.encode("utf-8")).hexdigest()
            if source_sha != actual_source_sha:
                failures.append(
                    failure(
                        "browser_release_proof_surface_receipt_incomplete",
                        proof_surface_path,
                        "execution receipt sourceShader.sha256 must match sourceShader.source",
                    )
                )
        failures.extend(
            validate_source_shader_metadata_payload(
                payload,
                proof_surface_path=proof_surface_path,
            )
        )
        failures.extend(
            validate_source_shader_hash_alias_payload(
                payload,
                proof_surface_path=proof_surface_path,
            )
        )

    lowering_path = payload.get("loweringPath")
    if not isinstance(lowering_path, list) or not lowering_path:
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload must include loweringPath",
            )
        )
    elif not all(isinstance(item, str) and item for item in lowering_path):
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt loweringPath entries must be non-empty strings",
            )
        )
    failures.extend(
        validate_lowering_path_runtime_binding_payload(
            payload,
            proof_surface_path=proof_surface_path,
        )
    )

    for field in ("backend",):
        if not isinstance(payload.get(field), str) or not payload.get(field):
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_incomplete",
                    proof_surface_path,
                    f"execution receipt payload must include {field}",
                )
            )
    for field in ("driver", "device"):
        if not isinstance(payload.get(field), dict) or not payload.get(field):
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_incomplete",
                    proof_surface_path,
                    f"execution receipt payload must include {field}",
                )
            )

    failures.extend(
        validate_backend_runtime_binding_payload(
            payload,
            proof_surface_path=proof_surface_path,
        )
    )
    failures.extend(
        validate_output_identity_payload(
            payload,
            proof_surface_path=proof_surface_path,
        )
    )
    failures.extend(
        validate_command_evidence_payload(
            payload,
            proof_surface_path=proof_surface_path,
        )
    )
    failures.extend(
        validate_command_coverage_payload(
            payload,
            proof_surface_path=proof_surface_path,
        )
    )
    failures.extend(
        validate_no_hidden_fallback_payload(
            payload,
            proof_surface_path=proof_surface_path,
        )
    )
    failures.extend(
        validate_timing_payload(
            payload,
            proof_surface_path=proof_surface_path,
        )
    )

    return failures


def load_execution_receipt_payload(root: Path, artifact: Any) -> dict[str, Any] | None:
    if not isinstance(artifact, dict):
        return None
    rel_path = artifact.get("path")
    if unsafe_receipt_path_reason(rel_path):
        return None
    try:
        payload = json.loads((root / rel_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def validate_execution_receipt_artifact(
    *,
    root: Path,
    artifact: Any,
    expected_runtime: str | None,
    entry_path: str,
) -> list[dict[str, str]]:
    proof_surface_path = f"{entry_path}.browserRelease.proofSurfacePath"
    if not isinstance(artifact, dict):
        return [
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "proof-surface execution receipt references must be objects",
            )
        ]

    for field in ("receiptId", "path", "sha256", "kind"):
        if not isinstance(artifact.get(field), str) or not artifact.get(field):
            return [
                failure(
                    "browser_release_proof_surface_receipt_incomplete",
                    proof_surface_path,
                    f"proof-surface execution receipt references require {field}",
                )
            ]
    if artifact.get("kind") != BROWSER_EXECUTION_RECEIPT_KIND:
        return [
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "proof-surface receipt references must name browser_execution_receipt artifacts",
            )
        ]

    rel_path = artifact["path"]
    reason = unsafe_receipt_path_reason(rel_path)
    if reason:
        return [
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                reason,
            )
        ]
    artifact_path = root / rel_path
    if not artifact_path.exists():
        return [
            failure(
                "browser_release_proof_surface_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: missing_required",
            )
        ]

    failures: list[dict[str, str]] = []
    try:
        actual_sha = sha256_file(artifact_path)
    except OSError as exc:
        return [
            failure(
                "browser_release_proof_surface_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: hash_failed: {exc}",
            )
        ]
    if actual_sha != artifact.get("sha256"):
        failures.append(
            failure(
                "browser_release_proof_surface_receipt_hash_mismatch",
                proof_surface_path,
                (
                    f"execution receipt artifact {rel_path} must hash to "
                    f"{actual_sha}, got {artifact.get('sha256')!r}"
                ),
            )
        )

    try:
        payload = json.loads(artifact_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return failures + [
            failure(
                "browser_release_proof_surface_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: parse_failed: {exc}",
            )
        ]
    if not isinstance(payload, dict):
        return failures + [
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                proof_surface_path,
                "execution receipt payload must be a JSON object",
            )
        ]

    failures.extend(
        validate_execution_receipt_payload(
            payload,
            artifact=artifact,
            expected_runtime=expected_runtime,
            proof_surface_path=proof_surface_path,
        )
    )
    return failures


def proof_surface_execution_receipt_artifacts(
    proof_surface: dict[str, Any],
) -> list[tuple[dict[str, Any], str | None]]:
    refs: list[tuple[dict[str, Any], str | None]] = []
    proof_payloads = nested_value(proof_surface, ("proofPage", "receiptPayloads"))
    if isinstance(proof_payloads, list):
        refs.extend((item, None) for item in proof_payloads if isinstance(item, dict))

    gallery_pages = proof_surface.get("galleryPages")
    if isinstance(gallery_pages, list):
        for item in gallery_pages:
            if not isinstance(item, dict):
                continue
            artifacts = item.get("receiptArtifacts")
            if isinstance(artifacts, list):
                refs.extend((artifact, None) for artifact in artifacts if isinstance(artifact, dict))

    comparison_receipts = proof_surface.get("comparisonReceipts")
    if isinstance(comparison_receipts, list):
        for item in comparison_receipts:
            if not isinstance(item, dict):
                continue
            dawn = item.get("dawnReceipt")
            doe = item.get("doeReceipt")
            if isinstance(dawn, dict):
                refs.append((dawn, "dawn"))
            if isinstance(doe, dict):
                refs.append((doe, "doe"))

    return refs


def release_bundle_artifact_sha256(
    release_bundle: dict[str, Any] | None,
    artifact_field: str,
) -> str | None:
    if not isinstance(release_bundle, dict):
        return None
    artifact = release_bundle.get(artifact_field)
    if not isinstance(artifact, dict):
        return None
    value = artifact.get("sha256")
    return value if strict_sha256(value) else None


def validate_runtime_selection_release_identity(
    selection: Any,
    *,
    release_bundle: dict[str, Any] | None,
    label: str,
    proof_surface_path: str,
    expected_mode: str | None = None,
) -> list[dict[str, str]]:
    if not isinstance(release_bundle, dict) or not isinstance(selection, dict):
        return []
    artifact_identity = selection.get("artifactIdentity")
    if not isinstance(artifact_identity, dict):
        return []
    mode = expected_mode or selection.get("selectedRuntime") or selection.get("selectionMode")
    checks = (
        ("browserExecutableSha256", "browserBinary"),
        ("dawnRuntimeSha256", "dawnFallbackRuntime"),
    )
    if mode == "doe":
        checks += (("doeLibSha256", "doeRuntime"),)

    failures: list[dict[str, str]] = []
    for identity_field, bundle_field in checks:
        expected_sha = release_bundle_artifact_sha256(release_bundle, bundle_field)
        if expected_sha is not None and artifact_identity.get(identity_field) == expected_sha:
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_comparison_artifact_release_mismatch",
                proof_surface_path,
                (
                    f"comparison artifact {label}.artifactIdentity.{identity_field} "
                    f"must match releaseArtifactBundlePath.{bundle_field}.sha256"
                ),
            )
        )
    return failures


def validate_comparison_artifact_release_identity(
    payload: dict[str, Any],
    *,
    release_bundle: dict[str, Any] | None,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    if not isinstance(release_bundle, dict):
        return []
    failures: list[dict[str, str]] = []
    runtime_selections = payload.get("runtimeSelections")
    if isinstance(runtime_selections, list):
        for index, selection in enumerate(runtime_selections):
            failures.extend(
                validate_runtime_selection_release_identity(
                    selection,
                    release_bundle=release_bundle,
                    label=f"runtimeSelections[{index}]",
                    proof_surface_path=proof_surface_path,
                )
            )
    mode_results = payload.get("modeResults")
    if isinstance(mode_results, list):
        for index, result in enumerate(mode_results):
            if not isinstance(result, dict):
                continue
            mode = result.get("mode")
            failures.extend(
                validate_runtime_selection_release_identity(
                    result.get("runtimeSelection"),
                    release_bundle=release_bundle,
                    label=f"modeResults[{index}].runtimeSelection",
                    proof_surface_path=proof_surface_path,
                    expected_mode=mode if isinstance(mode, str) else None,
                )
            )
    return failures


def validate_comparison_artifact_payload_fields(
    payload: dict[str, Any],
    *,
    row: dict[str, Any],
    proof_surface_path: str,
    release_bundle: dict[str, Any] | None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for message in validate_smoke_report(
        payload,
        required_modes=("dawn", "doe"),
        require_strict=True,
        require_hash_chain=True,
    ):
        failures.append(
            failure(
                "browser_release_proof_surface_comparison_artifact_mismatch",
                proof_surface_path,
                f"comparison artifact {message}",
            )
        )
    failures.extend(
        validate_comparison_artifact_release_identity(
            payload,
            release_bundle=release_bundle,
            proof_surface_path=proof_surface_path,
        )
    )

    runner = row.get("runner")
    policy = row.get("comparisonPolicy")
    expected_modes = runner.get("modes") if isinstance(runner, dict) else ["dawn", "doe"]
    expected_timing_class = policy.get("timingScope") if isinstance(policy, dict) else None

    checks: tuple[tuple[Any, Any, str], ...] = (
        (
            payload.get("reportKind"),
            BROWSER_COMPARISON_ARTIFACT_KIND,
            "comparison artifact reportKind must identify the strict browser smoke report",
        ),
        (payload.get("mode"), "both", "comparison artifact mode must run both runtimes"),
        (
            payload.get("timingClass"),
            expected_timing_class,
            "comparison artifact timingClass must match the comparison policy",
        ),
    )
    for actual, expected, message in checks:
        if actual == expected:
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_comparison_artifact_mismatch",
                proof_surface_path,
                message,
            )
        )

    mode_results = payload.get("modeResults")
    if not isinstance(mode_results, list) or not mode_results:
        return failures + [
            failure(
                "browser_release_proof_surface_comparison_artifact_incomplete",
                proof_surface_path,
                "comparison artifact must include Dawn and Doe mode results",
            )
        ]

    modes = [
        item.get("mode")
        for item in mode_results
        if isinstance(item, dict) and isinstance(item.get("mode"), str)
    ]
    if modes != expected_modes:
        failures.append(
            failure(
                "browser_release_proof_surface_comparison_artifact_mismatch",
                proof_surface_path,
                "comparison artifact modeResults must match the same-page runner modes",
            )
        )

    for mode in ("dawn", "doe"):
        result = next(
            (
                item
                for item in mode_results
                if isinstance(item, dict) and item.get("mode") == mode
            ),
            None,
        )
        if not isinstance(result, dict):
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_artifact_incomplete",
                    proof_surface_path,
                    f"comparison artifact must include a {mode} mode result",
                )
            )
            continue
        runtime_selection = result.get("runtimeSelection")
        if not isinstance(runtime_selection, dict):
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_artifact_incomplete",
                    proof_surface_path,
                    f"comparison artifact {mode} result must include runtimeSelection",
                )
            )
            continue
        for actual, expected, message in (
            (
                runtime_selection.get("selectedRuntime"),
                mode,
                f"comparison artifact {mode} result selectedRuntime must match mode",
            ),
            (
                runtime_selection.get("fallbackApplied"),
                False,
                f"comparison artifact {mode} result must not apply fallback",
            ),
            (
                runtime_selection.get("hiddenFallbackAllowed"),
                False,
                f"comparison artifact {mode} result must disable hidden fallback",
            ),
            (
                result.get("webgpuAvailable"),
                True,
                f"comparison artifact {mode} result must have WebGPU available",
            ),
            (
                result.get("adapterAvailable"),
                True,
                f"comparison artifact {mode} result must have an adapter available",
            ),
            (
                result.get("errors"),
                [],
                f"comparison artifact {mode} result must have no errors",
            ),
        ):
            if actual == expected:
                continue
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_artifact_mismatch",
                    proof_surface_path,
                    message,
                )
            )
    return failures


def comparison_mode_result(
    payload: dict[str, Any],
    mode: str,
) -> dict[str, Any] | None:
    rows = payload.get("modeResults")
    if not isinstance(rows, list):
        return None
    for row in rows:
        if isinstance(row, dict) and row.get("mode") == mode:
            return row
    return None


def expected_device_adapter_label(adapter_identity: dict[str, Any]) -> tuple[str, str] | None:
    for field in ("adapter", "device", "name"):
        value = adapter_identity.get(field)
        if isinstance(value, str) and value:
            return field, value
    return None


def validate_comparison_mode_result_receipt_binding(
    *,
    mode_result: dict[str, Any],
    receipt_payload: dict[str, Any],
    mode: str,
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    label = "Dawn" if mode == "dawn" else "Doe"
    selection = mode_result.get("runtimeSelection")
    selector_state = receipt_payload.get("runtimeSelectorState")
    if isinstance(selection, dict) and isinstance(selector_state, dict):
        for field in (
            "selectionMode",
            "selectedRuntime",
            "forcedMode",
            "fallbackApplied",
            "hiddenFallbackAllowed",
            "fallbackReasonCode",
            "selectorVersion",
        ):
            if selector_state.get(field) == selection.get(field):
                continue
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_payload_mismatch",
                    proof_surface_path,
                    (
                        f"comparison artifact {label} modeResult runtimeSelection.{field} "
                        f"must match {label} execution receipt runtimeSelectorState.{field}"
                    ),
                )
            )

        profile = selection.get("profile")
        driver = receipt_payload.get("driver")
        if isinstance(profile, dict) and isinstance(driver, dict):
            for field in ("vendor", "api", "driver", "deviceFamily", "profileId"):
                expected = profile.get(field)
                if expected is None:
                    continue
                if driver.get(field) == expected:
                    continue
                failures.append(
                    failure(
                        "browser_release_proof_surface_comparison_payload_mismatch",
                        proof_surface_path,
                        (
                            f"comparison artifact {label} modeResult "
                            f"runtimeSelection.profile.{field} must match {label} "
                            f"execution receipt driver.{field}"
                        ),
                    )
                )

    adapter_identity = mode_result.get("adapterIdentity")
    device = receipt_payload.get("device")
    if isinstance(adapter_identity, dict) and isinstance(device, dict):
        expected_device_fields: dict[str, tuple[str, Any]] = {}
        for field in ("adapterInfoSha256", "featureCount"):
            if adapter_identity.get(field) is not None:
                expected_device_fields[field] = (field, adapter_identity.get(field))
        adapter_label = expected_device_adapter_label(adapter_identity)
        if adapter_label is not None:
            source_field, expected = adapter_label
            expected_device_fields["adapter"] = (source_field, expected)
        for field, (source_field, expected) in expected_device_fields.items():
            if device.get(field) == expected:
                continue
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_payload_mismatch",
                    proof_surface_path,
                    (
                        f"comparison artifact {label} modeResult adapterIdentity.{source_field} "
                        f"must match {label} execution receipt device.{field}"
                    ),
                )
            )
    return failures


def validate_comparison_artifact_receipt_bindings(
    *,
    comparison_payload: dict[str, Any],
    dawn_payload: dict[str, Any],
    doe_payload: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for mode, receipt_payload in (("dawn", dawn_payload), ("doe", doe_payload)):
        mode_result = comparison_mode_result(comparison_payload, mode)
        if not isinstance(mode_result, dict):
            continue
        failures.extend(
            validate_comparison_mode_result_receipt_binding(
                mode_result=mode_result,
                receipt_payload=receipt_payload,
                mode=mode,
                proof_surface_path=proof_surface_path,
            )
        )
    return failures


def validate_comparison_artifact_file(
    *,
    root: Path,
    row: dict[str, Any],
    proof_surface_path: str,
    release_bundle: dict[str, Any] | None,
) -> list[dict[str, str]]:
    artifact = row.get("comparisonArtifact")
    if not isinstance(artifact, dict):
        return [
            failure(
                "browser_release_proof_surface_comparison_artifact_incomplete",
                proof_surface_path,
                "same-page comparison entries require comparisonArtifact objects",
            )
        ]

    for field in ("path", "sha256", "kind"):
        if not isinstance(artifact.get(field), str) or not artifact.get(field):
            return [
                failure(
                    "browser_release_proof_surface_comparison_artifact_incomplete",
                    proof_surface_path,
                    f"comparisonArtifact references require {field}",
                )
            ]
    if artifact.get("kind") != BROWSER_COMPARISON_ARTIFACT_KIND:
        return [
            failure(
                "browser_release_proof_surface_comparison_artifact_mismatch",
                proof_surface_path,
                "comparisonArtifact.kind must name the strict browser smoke report",
            )
        ]

    rel_path = artifact["path"]
    reason = unsafe_repo_path_reason(rel_path)
    if reason:
        return [
            failure(
                "browser_release_proof_surface_comparison_artifact_incomplete",
                proof_surface_path,
                reason,
            )
        ]
    artifact_path = root / rel_path
    if not artifact_path.exists():
        return [
            failure(
                "browser_release_proof_surface_comparison_artifact_unavailable",
                proof_surface_path,
                f"{rel_path}: missing_required",
            )
        ]

    failures: list[dict[str, str]] = []
    try:
        actual_sha = sha256_file(artifact_path)
    except OSError as exc:
        return [
            failure(
                "browser_release_proof_surface_comparison_artifact_unavailable",
                proof_surface_path,
                f"{rel_path}: hash_failed: {exc}",
            )
        ]
    if actual_sha != artifact.get("sha256"):
        failures.append(
            failure(
                "browser_release_proof_surface_comparison_artifact_hash_mismatch",
                proof_surface_path,
                (
                    f"comparison artifact {rel_path} must hash to "
                    f"{actual_sha}, got {artifact.get('sha256')!r}"
                ),
            )
        )

    try:
        payload = json.loads(artifact_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return failures + [
            failure(
                "browser_release_proof_surface_comparison_artifact_unavailable",
                proof_surface_path,
                f"{rel_path}: parse_failed: {exc}",
            )
        ]
    if not isinstance(payload, dict):
        return failures + [
            failure(
                "browser_release_proof_surface_comparison_artifact_incomplete",
                proof_surface_path,
                "comparison artifact payload must be a JSON object",
            )
        ]

    failures.extend(
        validate_comparison_artifact_payload_fields(
            payload,
            row=row,
            proof_surface_path=proof_surface_path,
            release_bundle=release_bundle,
        )
    )
    return failures


def load_comparison_artifact_payload(
    root: Path,
    artifact: Any,
) -> dict[str, Any] | None:
    if not isinstance(artifact, dict):
        return None
    rel_path = artifact.get("path")
    if unsafe_repo_path_reason(rel_path):
        return None
    try:
        payload = json.loads((root / rel_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def comparison_artifact_identity_hashes(
    root: Path,
    artifact: Any,
) -> set[str]:
    if not isinstance(artifact, dict):
        return set()
    hashes = {
        value for value in (artifact.get("sha256"),) if strict_sha256(value)
    }
    rel_path = artifact.get("path")
    if unsafe_repo_path_reason(rel_path):
        return hashes
    try:
        payload = json.loads((root / rel_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return hashes
    if isinstance(payload, dict) and strict_sha256(payload.get("reportHash")):
        hashes.add(payload["reportHash"])
    return hashes


def validate_command_evidence_comparison_artifact_hash_binding(
    *,
    receipt_payload: dict[str, Any],
    label: str,
    comparison_artifact_hashes: set[str],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    if command_evidence_hashes(receipt_payload) & comparison_artifact_hashes:
        return []
    return [
        failure(
            "browser_release_proof_surface_comparison_payload_mismatch",
            proof_surface_path,
            (
                f"{label} execution receipt command evidence must hash-bind "
                "the comparison artifact"
            ),
        )
    ]


def validate_claim_indexed_proof_surface_comparison_payloads(
    root: Path,
    proof_surface: dict[str, Any],
    entry_path: str,
    release_bundle: dict[str, Any] | None,
) -> list[dict[str, str]]:
    path = f"{entry_path}.browserRelease.proofSurfacePath"
    comparison_receipts = proof_surface.get("comparisonReceipts")
    if not isinstance(comparison_receipts, list):
        return []

    failures: list[dict[str, str]] = []
    for item in comparison_receipts:
        if not isinstance(item, dict):
            continue
        failures.extend(
            validate_comparison_artifact_file(
                root=root,
                row=item,
                proof_surface_path=path,
                release_bundle=release_bundle,
            )
        )
        policy = item.get("comparisonPolicy")
        dawn_payload = load_execution_receipt_payload(root, item.get("dawnReceipt"))
        doe_payload = load_execution_receipt_payload(root, item.get("doeReceipt"))
        if not isinstance(policy, dict) or dawn_payload is None or doe_payload is None:
            continue

        comparison_artifact = item.get("comparisonArtifact")
        comparison_artifact_path = (
            comparison_artifact.get("path")
            if isinstance(comparison_artifact, dict)
            else None
        )
        comparison_artifact_hashes = comparison_artifact_identity_hashes(
            root,
            comparison_artifact,
        )
        comparison_payload = load_comparison_artifact_payload(root, comparison_artifact)
        if comparison_payload is not None:
            failures.extend(
                validate_comparison_artifact_receipt_bindings(
                    comparison_payload=comparison_payload,
                    dawn_payload=dawn_payload,
                    doe_payload=doe_payload,
                    proof_surface_path=path,
                )
            )
        if isinstance(comparison_artifact_path, str) and comparison_artifact_path:
            for label, payload in (("Dawn", dawn_payload), ("Doe", doe_payload)):
                if comparison_artifact_path in command_evidence_artifact_paths(payload):
                    failures.extend(
                        validate_command_evidence_comparison_artifact_hash_binding(
                            receipt_payload=payload,
                            label=label,
                            comparison_artifact_hashes=comparison_artifact_hashes,
                            proof_surface_path=path,
                        )
                    )
                    continue
                failures.append(
                    failure(
                        "browser_release_proof_surface_comparison_payload_mismatch",
                        path,
                        (
                            f"{label} execution receipt command evidence must bind "
                            "the comparison artifact path"
                        ),
                    )
                )

        parity_checks = (
            (
                dawn_payload.get("workloadId"),
                doe_payload.get("workloadId"),
                "Dawn and Doe execution receipts must bind the same workload ID",
            ),
            (
                source_shader_identity(dawn_payload),
                source_shader_identity(doe_payload),
                "Dawn and Doe execution receipts must bind the same source shader",
            ),
            (
                dawn_payload.get("device"),
                doe_payload.get("device"),
                "Dawn and Doe execution receipts must bind the same device identity",
            ),
            (
                dawn_payload.get("driver"),
                doe_payload.get("driver"),
                "Dawn and Doe execution receipts must bind the same driver identity",
            ),
            (
                output_identity(dawn_payload),
                output_identity(doe_payload),
                "Dawn and Doe execution receipts must bind the same output or frame hash",
            ),
            (
                output_identity_kind(dawn_payload),
                output_identity_kind(doe_payload),
                "Dawn and Doe execution receipts must use the same output identity kind",
            ),
            (
                command_coverage_identity(dawn_payload),
                command_coverage_identity(doe_payload),
                "Dawn and Doe execution receipts must bind the same command coverage",
            ),
            (
                command_evidence_identity(dawn_payload),
                command_evidence_identity(doe_payload),
                "Dawn and Doe execution receipts must bind the same command evidence",
            ),
            (
                timing_class(dawn_payload),
                timing_class(doe_payload),
                "Dawn and Doe execution receipts must use the same timing class",
            ),
        )
        for left, right, message in parity_checks:
            if left is not None and left == right:
                continue
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_payload_mismatch",
                    path,
                    message,
                )
            )

        workload_id = item.get("workloadId")
        if isinstance(workload_id, str) and workload_id:
            if (
                dawn_payload.get("workloadId") != workload_id
                or doe_payload.get("workloadId") != workload_id
            ):
                failures.append(
                    failure(
                        "browser_release_proof_surface_comparison_payload_mismatch",
                        path,
                        "comparison workload ID must match both execution receipts",
                    )
                )

        failures.extend(
            validate_comparison_policy_payload_binding(
                policy,
                dawn_payload,
                doe_payload,
                proof_surface_path=path,
            )
        )

    return failures


def validate_claim_indexed_proof_surface_execution_receipts(
    root: Path,
    proof_surface: dict[str, Any],
    entry_path: str,
    release_bundle: dict[str, Any] | None,
) -> list[dict[str, str]]:
    refs = proof_surface_execution_receipt_artifacts(proof_surface)
    if not refs:
        return [
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                f"{entry_path}.browserRelease.proofSurfacePath",
                "claim-indexed Chromium proof surfaces require execution receipt artifacts",
            )
        ]

    failures: list[dict[str, str]] = []
    failures.extend(
        validate_execution_receipt_reference_consistency(
            refs,
            proof_surface_path=f"{entry_path}.browserRelease.proofSurfacePath",
        )
    )
    seen: set[tuple[str, str | None]] = set()
    for artifact, expected_runtime in refs:
        key = (artifact.get("path", ""), expected_runtime)
        if key in seen:
            continue
        seen.add(key)
        failures.extend(
            validate_execution_receipt_artifact(
                root=root,
                artifact=artifact,
                expected_runtime=expected_runtime,
                entry_path=entry_path,
            )
        )
    failures.extend(
        validate_claim_indexed_proof_surface_comparison_payloads(
            root,
            proof_surface,
            entry_path,
            release_bundle,
        )
    )
    return failures


def validate_json_receipt_artifact_file(
    *,
    root: Path,
    artifact: dict[str, Any],
    failure_prefix: str,
    proof_surface_path: str,
    label: str,
) -> tuple[dict[str, Any] | None, list[dict[str, str]]]:
    rel_path = artifact.get("path")
    reason = unsafe_receipt_path_reason(rel_path)
    if reason:
        return None, [
            failure(
                f"{failure_prefix}_incomplete",
                proof_surface_path,
                reason,
            )
        ]
    path = root / rel_path
    if not path.exists():
        return None, [
            failure(
                f"{failure_prefix}_unavailable",
                proof_surface_path,
                f"{rel_path}: missing_required",
            )
        ]

    failures: list[dict[str, str]] = []
    try:
        actual_sha = sha256_file(path)
    except OSError as exc:
        return None, [
            failure(
                f"{failure_prefix}_unavailable",
                proof_surface_path,
                f"{rel_path}: hash_failed: {exc}",
            )
        ]
    if actual_sha != artifact.get("sha256"):
        failures.append(
            failure(
                f"{failure_prefix}_hash_mismatch",
                proof_surface_path,
                (
                    f"{label} artifact {rel_path} must hash to "
                    f"{actual_sha}, got {artifact.get('sha256')!r}"
                ),
            )
        )

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        failures.append(
            failure(
                f"{failure_prefix}_unavailable",
                proof_surface_path,
                f"{rel_path}: parse_failed: {exc}",
            )
        )
        return None, failures
    if not isinstance(payload, dict):
        failures.append(
            failure(
                f"{failure_prefix}_incomplete",
                proof_surface_path,
                f"{label} payload must be a JSON object",
            )
        )
        return None, failures
    return payload, failures


def proof_page_load_type(url: Any) -> str:
    if isinstance(url, str) and url.startswith("file:"):
        return "file"
    return "browser_internal_page"


def validate_proof_page_receipt_payload(
    *,
    payload: dict[str, Any],
    proof_surface: dict[str, Any],
    proof_page: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    artifact = proof_page.get("artifact")
    artifact_path = artifact.get("path") if isinstance(artifact, dict) else None
    artifact_sha = artifact.get("sha256") if isinstance(artifact, dict) else None
    field_checks: tuple[tuple[Any, Any, str], ...] = (
        (payload.get("schemaVersion"), 1, "schemaVersion must be 1"),
        (
            payload.get("artifactKind"),
            BROWSER_PROOF_PAGE_RECEIPT_KIND,
            "artifactKind must be browser_proof_page_receipt",
        ),
        (payload.get("url"), proof_page.get("url"), "URL must match proof page"),
        (
            payload.get("loadType"),
            proof_page_load_type(proof_page.get("url")),
            "loadType must match proof page URL",
        ),
        (payload.get("status"), "loaded", "status must be loaded"),
        (
            payload.get("contentSha256"),
            artifact_sha,
            "contentSha256 must match proof page artifact sha256",
        ),
        (
            payload.get("proofArtifactPath"),
            artifact_path,
            "proofArtifactPath must match proof page artifact path",
        ),
        (
            payload.get("runtimeIdentityPath"),
            proof_surface.get("runtimeIdentityPath"),
            "runtimeIdentityPath must match proof surface",
        ),
        (
            payload.get("diagnostics"),
            proof_page.get("diagnostics"),
            "diagnostics must match proof page diagnostics",
        ),
        (
            payload.get("recentReceiptIds"),
            proof_page.get("recentReceiptIds"),
            "recentReceiptIds must match proof page recentReceiptIds",
        ),
        (
            payload.get("releaseProvenance"),
            proof_page.get("releaseProvenance"),
            "releaseProvenance must match proof page releaseProvenance",
        ),
    )
    for actual, expected, message in field_checks:
        if actual == expected:
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_proof_page_receipt_mismatch",
                proof_surface_path,
                f"proof page receipt {message}",
            )
        )

    for field in ("receiptId", "observedAt"):
        if not isinstance(payload.get(field), str) or not payload.get(field):
            failures.append(
                failure(
                    "browser_release_proof_surface_proof_page_receipt_incomplete",
                    proof_surface_path,
                    f"proof page receipt requires {field}",
                )
            )
    if not isinstance(payload.get("contentLengthBytes"), int) or payload.get(
        "contentLengthBytes"
    ) <= 0:
        failures.append(
            failure(
                "browser_release_proof_surface_proof_page_receipt_incomplete",
                proof_surface_path,
                "proof page receipt requires positive contentLengthBytes",
            )
        )
    return failures


def validate_proof_page_content_file(
    *,
    root: Path,
    proof_surface: dict[str, Any],
    proof_page: dict[str, Any],
    payload: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    artifact = proof_page.get("artifact")
    if not isinstance(artifact, dict):
        return []
    rel_path = artifact.get("path")
    reason = unsafe_repo_path_reason(rel_path)
    if reason:
        return [
            failure(
                "browser_release_proof_surface_proof_page_receipt_incomplete",
                proof_surface_path,
                reason,
            )
        ]
    artifact_path = root / rel_path
    if not artifact_path.exists():
        return [
            failure(
                "browser_release_proof_surface_proof_page_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: proof_page_artifact_missing",
            )
        ]
    failures: list[dict[str, str]] = []
    try:
        actual_sha = sha256_file(artifact_path)
        actual_size = artifact_path.stat().st_size
    except OSError as exc:
        return [
            failure(
                "browser_release_proof_surface_proof_page_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: proof_page_artifact_read_failed: {exc}",
            )
        ]
    if actual_sha != artifact.get("sha256"):
        failures.append(
            failure(
                "browser_release_proof_surface_proof_page_receipt_hash_mismatch",
                proof_surface_path,
                f"proof page artifact {rel_path} hash must match proof-surface artifact ref",
            )
        )
    if payload.get("contentLengthBytes") != actual_size:
        failures.append(
            failure(
                "browser_release_proof_surface_proof_page_receipt_mismatch",
                proof_surface_path,
                "proof page receipt contentLengthBytes must match proof page artifact size",
            )
        )
    try:
        text = artifact_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return failures + [
            failure(
                "browser_release_proof_surface_proof_page_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: proof_page_artifact_text_failed: {exc}",
            )
        ]
    failures.extend(
        validate_proof_page_visible_text(
            text=text,
            proof_surface=proof_surface,
            proof_page=proof_page,
            proof_surface_path=proof_surface_path,
        )
    )
    return failures


def validate_proof_page_visible_text(
    *,
    text: str,
    proof_surface: dict[str, Any],
    proof_page: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    diagnostics = proof_page.get("diagnostics")
    if isinstance(diagnostics, dict):
        for field in PROOF_PAGE_VISIBLE_DIAGNOSTIC_FIELDS:
            value = diagnostics.get(field)
            if isinstance(value, str) and value and value not in text:
                failures.append(
                    failure(
                        "browser_release_proof_surface_proof_page_content_incomplete",
                        proof_surface_path,
                        f"proof page artifact must show diagnostic value: {field}",
                    )
                )
    for field_path, label, fragment in release_provenance_visible_fragments(
        proof_page.get("releaseProvenance")
    ):
        if fragment in text:
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_proof_page_content_incomplete",
                proof_surface_path,
                f"proof page artifact must show {label}: {field_path}",
            )
        )
    recent_receipt_ids = proof_page.get("recentReceiptIds")
    if isinstance(recent_receipt_ids, list):
        for receipt_id in recent_receipt_ids:
            if isinstance(receipt_id, str) and receipt_id and receipt_id not in text:
                failures.append(
                    failure(
                        "browser_release_proof_surface_proof_page_content_incomplete",
                        proof_surface_path,
                        "proof page artifact must show recent receipt IDs",
                    )
                )
    for path in recent_receipt_artifact_paths(proof_surface):
        if path not in text:
            failures.append(
                failure(
                    "browser_release_proof_surface_proof_page_content_incomplete",
                    proof_surface_path,
                    "proof page artifact must link recent receipt payload paths",
                )
            )
    return failures


def release_provenance_visible_fragments(
    provenance: Any,
) -> list[tuple[str, str, str]]:
    if not isinstance(provenance, dict):
        return []
    fragments: list[tuple[str, str, str]] = []
    product = provenance.get("browserProduct")
    if isinstance(product, dict):
        for field, label in (
            ("displayName", "browser product"),
            ("version", "browser version"),
            ("channel", "release channel"),
        ):
            value = product.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"browserProduct.{field}", label, value))
    platform = provenance.get("platform")
    if isinstance(platform, dict):
        for field, label in (
            ("os", "platform OS"),
            ("arch", "platform architecture"),
            ("packageFormat", "package format"),
        ):
            value = platform.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"platform.{field}", label, value))
    for field, label in (
        ("browserExecutableArchivePath", "browser executable member"),
        ("browserAppMetadataArchivePath", "app metadata member"),
        ("doeRuntimeArchivePath", "Doe runtime member"),
        ("dawnFallbackRuntimeArchivePath", "Dawn fallback runtime member"),
    ):
        value = provenance.get(field)
        if isinstance(value, str) and value:
            fragments.append((field, label, value))
    for field, label in (
        ("releaseArchive", "release archive"),
        ("releaseArchiveManifest", "release archive manifest"),
        ("publicDownloadReceipt", "public download receipt"),
    ):
        artifact = provenance.get(field)
        if not isinstance(artifact, dict):
            continue
        for key in ("path", "sha256", "downloadUrl"):
            value = artifact.get(key)
            if isinstance(value, str) and value:
                fragments.append((f"{field}.{key}", label, value))
    return fragments


def validate_claim_indexed_proof_surface_proof_page_receipt(
    root: Path,
    proof_surface: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    proof_surface_path = f"{entry_path}.browserRelease.proofSurfacePath"
    proof_page = proof_surface.get("proofPage")
    if not isinstance(proof_page, dict):
        return []
    artifact = proof_page.get("diagnosticReceipt")
    if not isinstance(artifact, dict):
        return [
            failure(
                "browser_release_proof_surface_proof_page_receipt_incomplete",
                proof_surface_path,
                "proof page requires a diagnosticReceipt artifact object",
            )
        ]
    for field in ("path", "sha256", "kind"):
        if not isinstance(artifact.get(field), str) or not artifact.get(field):
            return [
                failure(
                    "browser_release_proof_surface_proof_page_receipt_incomplete",
                    proof_surface_path,
                    f"proof page diagnosticReceipt references require {field}",
                )
            ]
    if artifact.get("kind") != BROWSER_PROOF_PAGE_RECEIPT_KIND:
        return [
            failure(
                "browser_release_proof_surface_proof_page_receipt_incomplete",
                proof_surface_path,
                "proof page diagnosticReceipt must name browser_proof_page_receipt artifacts",
            )
        ]

    payload, failures = validate_json_receipt_artifact_file(
        root=root,
        artifact=artifact,
        failure_prefix="browser_release_proof_surface_proof_page_receipt",
        proof_surface_path=proof_surface_path,
        label="proof page receipt",
    )
    if payload is None:
        return failures
    failures.extend(
        validate_proof_page_receipt_payload(
            payload=payload,
            proof_surface=proof_surface,
            proof_page=proof_page,
            proof_surface_path=proof_surface_path,
        )
    )
    failures.extend(
        validate_proof_page_content_file(
            root=root,
            proof_surface=proof_surface,
            proof_page=proof_page,
            payload=payload,
            proof_surface_path=proof_surface_path,
        )
    )
    return failures


def validate_claim_indexed_proof_surface_receipts(
    root: Path,
    proof_surface: dict[str, Any],
    entry_path: str,
    *,
    release_bundle: dict[str, Any] | None = None,
) -> list[dict[str, str]]:
    from bench.gates.claim_index_browser_release_gallery import (
        validate_claim_indexed_proof_surface_public_gallery_receipts,
    )

    failures: list[dict[str, str]] = []
    failures.extend(
        validate_claim_indexed_proof_surface_execution_receipts(
            root,
            proof_surface,
            entry_path,
            release_bundle,
        )
    )
    failures.extend(
        validate_claim_indexed_proof_surface_public_gallery_receipts(
            root,
            proof_surface,
            entry_path,
        )
    )
    failures.extend(
        validate_claim_indexed_proof_surface_proof_page_receipt(
            root,
            proof_surface,
            entry_path,
        )
    )
    return failures
