#!/usr/bin/env python3
"""Build browser published proof-surface manifests from concrete artifacts."""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import sys
from pathlib import Path
from typing import Any

try:
    from bench.tools._public_url import is_public_https_url
except ModuleNotFoundError:
    from _public_url import is_public_https_url

try:
    from bench.browser.browser_gate import validate_smoke_report
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from bench.browser.browser_gate import validate_smoke_report


REPO_ROOT = Path(__file__).resolve().parents[2]
GALLERY_CATEGORIES = {
    "compute",
    "rendering",
    "tensor",
    "shader_edge",
    "benchmark_trace",
}
REQUIRED_DRIVER_FIELDS = ("vendor", "api", "driver", "deviceFamily")
REQUIRED_TIMING_PHASES = ("setupNs", "encodeNs", "submitWaitNs")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--surface-id", required=True)
    parser.add_argument("--capture-policy-path", required=True)
    parser.add_argument("--runtime-identity-path", required=True)
    parser.add_argument("--proof-page-artifact", required=True)
    parser.add_argument("--proof-page-receipt", required=True)
    parser.add_argument("--proof-receipt-payload", action="append", required=True)
    parser.add_argument(
        "--gallery-entry",
        action="append",
        required=True,
        help=(
            "JSON object with category, url, artifact, publicReceipt, "
            "workloadContractPath, and receiptPayloads."
        ),
    )
    parser.add_argument(
        "--comparison-entry",
        action="append",
        required=True,
        help=(
            "JSON object with comparisonId, workloadId, pageArtifactPath, "
            "comparisonArtifact, dawnReceipt, and doeReceipt."
        ),
    )
    parser.add_argument("--out", required=True)
    return parser.parse_args()


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def require_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"{label} must be an existing file: {path}")


def repo_relative(path: Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def path_from_text(path_text: str, *, label: str) -> Path:
    if not isinstance(path_text, str) or not path_text:
        raise ValueError(f"{label} path is required")
    return Path(path_text)


def artifact(path: Path, kind: str, label: str) -> dict[str, str]:
    require_file(path, label)
    return {
        "path": repo_relative(path),
        "sha256": sha256_file(path),
        "kind": kind,
    }


def execution_receipt_artifact(path: Path) -> dict[str, str]:
    payload = load_json(path)
    if not isinstance(payload, dict):
        raise ValueError(f"execution receipt must be a JSON object: {path}")
    validate_execution_receipt_payload(payload, path=path)
    receipt_id = payload["receiptId"]
    return {
        "receiptId": receipt_id,
        **artifact(path, "browser_execution_receipt", "execution receipt"),
    }


def execution_receipt_workload_id(path: Path) -> str:
    payload = load_json(path)
    if not isinstance(payload, dict):
        raise ValueError(f"execution receipt must be a JSON object: {path}")
    workload_id = payload.get("workloadId")
    if not isinstance(workload_id, str) or not workload_id:
        raise ValueError(f"execution receipt workloadId is required: {path}")
    return workload_id


def unique_workload_ids(paths: list[Path]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for path in paths:
        workload_id = execution_receipt_workload_id(path)
        if workload_id in seen:
            continue
        seen.add(workload_id)
        result.append(workload_id)
    return result


def output_identity_policy(payload: dict[str, Any], *, path: Path) -> str:
    has_output_hash = isinstance(payload.get("outputHash"), str) and bool(payload["outputHash"])
    has_frame_hash = isinstance(payload.get("frameHash"), str) and bool(payload["frameHash"])
    if has_output_hash == has_frame_hash:
        raise ValueError(f"execution receipt must carry exactly one output identity: {path}")
    return "same_output_hash" if has_output_hash else "same_frame_hash"


def source_shader_identity(payload: dict[str, Any], *, path: Path) -> str:
    source_shader = payload.get("sourceShader")
    if not isinstance(source_shader, dict):
        raise ValueError(f"execution receipt sourceShader must be an object: {path}")
    source = source_shader.get("source")
    if not isinstance(source, str) or not source:
        raise ValueError(f"execution receipt sourceShader.source is required: {path}")
    source_hash = hashlib.sha256(source.encode("utf-8")).hexdigest()
    for key in ("sha256", "sourceSha256"):
        value = source_shader.get(key)
        if isinstance(value, str) and value != source_hash:
            raise ValueError(f"execution receipt sourceShader.{key} must match sourceShader.source: {path}")
    return source_hash


def driver_device_identity(payload: dict[str, Any], *, path: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    driver = payload.get("driver")
    if not isinstance(driver, dict) or not driver:
        raise ValueError(f"execution receipt driver must be a non-empty object: {path}")
    for field in REQUIRED_DRIVER_FIELDS:
        require_concrete_text(driver.get(field), label=f"driver.{field}", path=path)
    device = payload.get("device")
    if not isinstance(device, dict) or not device:
        raise ValueError(f"execution receipt device must be a non-empty object: {path}")
    require_hash(device.get("adapterInfoSha256"), label="device.adapterInfoSha256", path=path)
    if not nonnegative_int(device.get("featureCount")):
        raise ValueError(f"execution receipt device.featureCount must be non-negative: {path}")
    require_concrete_text(device.get("adapter"), label="device.adapter", path=path)
    return driver, device


def selected_runtime(payload: dict[str, Any], *, path: Path, expected_runtime: str) -> str:
    runtime = payload.get("selectedRuntime")
    if runtime != expected_runtime:
        raise ValueError(f"execution receipt selectedRuntime must be {expected_runtime}: {path}")
    return expected_runtime


def workload_identity(payload: dict[str, Any], *, path: Path) -> str:
    workload_id = payload.get("workloadId")
    if not isinstance(workload_id, str) or not workload_id:
        raise ValueError(f"execution receipt workloadId is required: {path}")
    return workload_id


def command_coverage_identity(payload: dict[str, Any], *, path: Path) -> dict[str, Any]:
    coverage = payload.get("commandCoverage")
    if not isinstance(coverage, dict) or not coverage:
        raise ValueError(f"execution receipt commandCoverage must be a non-empty object: {path}")
    return coverage


def positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def nonnegative_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def require_concrete_text(value: Any, *, label: str, path: Path) -> str:
    if not isinstance(value, str) or not value or value == "unknown":
        raise ValueError(f"execution receipt {label} must be concrete: {path}")
    return value


def require_hash(value: Any, *, label: str, path: Path) -> str:
    if not (
        isinstance(value, str)
        and len(value) == 64
        and all(char in "0123456789abcdef" for char in value)
    ):
        raise ValueError(f"execution receipt {label} must be lowercase SHA-256: {path}")
    return value


def complete_command_coverage_identity(payload: dict[str, Any], *, path: Path) -> dict[str, Any]:
    coverage = command_coverage_identity(payload, path=path)
    command_count = coverage.get("commandCount")
    if not positive_int(command_count):
        raise ValueError(f"execution receipt commandCoverage.commandCount must be positive: {path}")
    success_count = coverage.get("successCount")
    if not nonnegative_int(success_count):
        raise ValueError(f"execution receipt commandCoverage.successCount must be non-negative: {path}")
    if success_count > command_count:
        raise ValueError(f"execution receipt commandCoverage.successCount cannot exceed commandCount: {path}")
    if success_count != command_count:
        raise ValueError(f"execution receipt commandCoverage.successCount must equal commandCount: {path}")
    dispatch_count = coverage.get("dispatchCount")
    if dispatch_count is not None:
        if not nonnegative_int(dispatch_count):
            raise ValueError(f"execution receipt commandCoverage.dispatchCount must be non-negative: {path}")
        if dispatch_count > command_count:
            raise ValueError(f"execution receipt commandCoverage.dispatchCount cannot exceed commandCount: {path}")
    return coverage


def lowering_path_identity(payload: dict[str, Any], *, path: Path) -> list[str]:
    lowering_path = payload.get("loweringPath")
    if not isinstance(lowering_path, list) or not lowering_path:
        raise ValueError(f"execution receipt loweringPath must be a non-empty array: {path}")
    if not all(isinstance(item, str) and item for item in lowering_path):
        raise ValueError(f"execution receipt loweringPath entries must be non-empty strings: {path}")
    return lowering_path


def command_evidence_identity(payload: dict[str, Any], *, path: Path) -> str:
    for field in ("commandGraph", "flightRecorderRef"):
        evidence = payload.get(field)
        if not isinstance(evidence, dict) or not evidence:
            continue
        for key in ("sha256", "hash", "graphSha256", "artifactSha256"):
            value = evidence.get(key)
            if isinstance(value, str) and value:
                return value
    raise ValueError(f"execution receipt must include commandGraph or flightRecorderRef identity: {path}")


def receipt_runtime(payload: dict[str, Any], *, path: Path) -> str:
    runtime = payload.get("selectedRuntime")
    if runtime not in {"dawn", "doe"}:
        raise ValueError(f"execution receipt selectedRuntime must be dawn or doe: {path}")
    return runtime


def runtime_selector_identity(payload: dict[str, Any], *, path: Path, selected_runtime: str) -> dict[str, Any]:
    state = payload.get("runtimeSelectorState")
    if not isinstance(state, dict):
        raise ValueError(f"execution receipt runtimeSelectorState must be an object: {path}")
    if state.get("selectedRuntime") != selected_runtime:
        raise ValueError(f"execution receipt runtimeSelectorState.selectedRuntime must match selectedRuntime: {path}")
    if state.get("fallbackApplied") is not False:
        raise ValueError(f"execution receipt runtimeSelectorState.fallbackApplied must be false: {path}")
    if state.get("hiddenFallbackAllowed") is not False:
        raise ValueError(f"execution receipt runtimeSelectorState.hiddenFallbackAllowed must be false: {path}")
    fallback_reason = state.get("fallbackReasonCode")
    if not isinstance(fallback_reason, str):
        raise ValueError(f"execution receipt runtimeSelectorState.fallbackReasonCode must be a string: {path}")
    if fallback_reason:
        raise ValueError(f"execution receipt runtimeSelectorState.fallbackReasonCode must be empty: {path}")
    return state


def fallback_state_identity(payload: dict[str, Any], *, path: Path) -> dict[str, Any]:
    state = payload.get("fallbackState")
    if not isinstance(state, dict):
        raise ValueError(f"execution receipt fallbackState must be an object: {path}")
    if state.get("fallbackApplied") is not False:
        raise ValueError(f"execution receipt fallbackState.fallbackApplied must be false: {path}")
    if state.get("hiddenFallbackAllowed") is not False:
        raise ValueError(f"execution receipt fallbackState.hiddenFallbackAllowed must be false: {path}")
    reason = state.get("reasonCode")
    if not isinstance(reason, str):
        raise ValueError(f"execution receipt fallbackState.reasonCode must be a string: {path}")
    if reason:
        raise ValueError(f"execution receipt fallbackState.reasonCode must be empty: {path}")
    return state


def timing_class_identity(payload: dict[str, Any], *, path: Path) -> str:
    timing = payload.get("timing")
    if not isinstance(timing, dict):
        raise ValueError(f"execution receipt timing must be an object: {path}")
    timing_class = timing.get("timingClass")
    if not isinstance(timing_class, str) or not timing_class:
        raise ValueError(f"execution receipt timing.timingClass is required: {path}")
    phases = timing.get("phases")
    if not isinstance(phases, dict) or not phases:
        raise ValueError(f"execution receipt timing.phases must be a non-empty object: {path}")
    for field in REQUIRED_TIMING_PHASES:
        if not nonnegative_int(phases.get(field)):
            raise ValueError(f"execution receipt timing.phases.{field} must be non-negative: {path}")
    return timing_class


def validate_execution_receipt_payload(payload: dict[str, Any], *, path: Path) -> None:
    if payload.get("artifactKind") != "browser_execution_receipt":
        raise ValueError(f"execution receipt artifactKind must be browser_execution_receipt: {path}")
    receipt_id = payload.get("receiptId")
    if not isinstance(receipt_id, str) or not receipt_id:
        raise ValueError(f"execution receipt receiptId is required: {path}")
    selected = receipt_runtime(payload, path=path)
    workload_identity(payload, path=path)
    source_shader_identity(payload, path=path)
    lowering_path_identity(payload, path=path)
    if not isinstance(payload.get("backend"), str) or not payload["backend"]:
        raise ValueError(f"execution receipt backend must be a non-empty string: {path}")
    driver_device_identity(payload, path=path)
    command_evidence_identity(payload, path=path)
    complete_command_coverage_identity(payload, path=path)
    output_identity_policy(payload, path=path)
    runtime_selector_identity(payload, path=path, selected_runtime=selected)
    fallback_state_identity(payload, path=path)
    timing_class_identity(payload, path=path)


def comparison_policy(dawn_path: Path, doe_path: Path, *, workload_id: str | None = None) -> dict[str, str]:
    dawn_payload = load_json(dawn_path)
    doe_payload = load_json(doe_path)
    if not isinstance(dawn_payload, dict) or not isinstance(doe_payload, dict):
        raise ValueError("comparison receipts must be JSON objects")
    validate_execution_receipt_payload(dawn_payload, path=dawn_path)
    validate_execution_receipt_payload(doe_payload, path=doe_path)
    selected_runtime(dawn_payload, path=dawn_path, expected_runtime="dawn")
    selected_runtime(doe_payload, path=doe_path, expected_runtime="doe")
    dawn_workload_id = workload_identity(dawn_payload, path=dawn_path)
    doe_workload_id = workload_identity(doe_payload, path=doe_path)
    if dawn_workload_id != doe_workload_id:
        raise ValueError("comparison receipts must use the same workload identity")
    if workload_id is not None and dawn_workload_id != workload_id:
        raise ValueError("comparison entry workloadId must match receipt workloadId")
    if source_shader_identity(dawn_payload, path=dawn_path) != source_shader_identity(doe_payload, path=doe_path):
        raise ValueError("comparison receipts must use the same source shader identity")
    if command_coverage_identity(dawn_payload, path=dawn_path) != command_coverage_identity(doe_payload, path=doe_path):
        raise ValueError("comparison receipts must use the same command coverage")
    dawn_driver, dawn_device = driver_device_identity(dawn_payload, path=dawn_path)
    doe_driver, doe_device = driver_device_identity(doe_payload, path=doe_path)
    if dawn_driver != doe_driver:
        raise ValueError("comparison receipts must use the same driver identity")
    if dawn_device != doe_device:
        raise ValueError("comparison receipts must use the same device identity")
    dawn_output_policy = output_identity_policy(dawn_payload, path=dawn_path)
    doe_output_policy = output_identity_policy(doe_payload, path=doe_path)
    if dawn_output_policy != doe_output_policy:
        raise ValueError("comparison receipts must use the same output identity policy")
    timing = dawn_payload.get("timing")
    if not isinstance(timing, dict) or not isinstance(timing.get("timingClass"), str):
        raise ValueError(f"Dawn receipt timing.timingClass is required: {dawn_path}")
    doe_timing = doe_payload.get("timing")
    if (
        not isinstance(doe_timing, dict)
        or doe_timing.get("timingClass") != timing["timingClass"]
    ):
        raise ValueError("comparison receipts must use the same timing class")
    return {
        "workloadIdentity": "same_workload_id",
        "sourceShaderIdentity": "same_source_shader_identity",
        "adapterDeviceIdentity": "same_device_identity",
        "timingScope": timing["timingClass"],
        "commandCoverage": "exact_match",
        "outputIdentity": dawn_output_policy,
        "fallbackPolicy": "no_hidden_fallback",
    }


def comparison_artifact(path: Path) -> dict[str, str]:
    payload = load_json(path)
    if not isinstance(payload, dict):
        raise ValueError(f"comparison artifact must be a JSON object: {path}")
    errors = validate_smoke_report(
        payload,
        required_modes=("dawn", "doe"),
        require_strict=True,
        require_hash_chain=True,
    )
    if errors:
        raise ValueError(
            "comparison artifact must be a strict Dawn/Doe smoke report: "
            f"{path}: {'; '.join(errors)}"
        )
    return artifact(path, "chromium-webgpu-playwright-smoke", "comparison artifact")


def release_provenance_fragments(provenance: Any) -> list[str]:
    if not isinstance(provenance, dict):
        return []
    fragments: list[str] = []
    product = provenance.get("browserProduct")
    if isinstance(product, dict):
        for field in ("displayName", "version", "channel"):
            value = product.get(field)
            if isinstance(value, str) and value:
                fragments.append(value)
    platform = provenance.get("platform")
    if isinstance(platform, dict):
        for field in ("os", "arch", "packageFormat"):
            value = platform.get(field)
            if isinstance(value, str) and value:
                fragments.append(value)
    for field in (
        "browserExecutableArchivePath",
        "browserAppMetadataArchivePath",
        "doeRuntimeArchivePath",
        "dawnFallbackRuntimeArchivePath",
    ):
        value = provenance.get(field)
        if isinstance(value, str) and value:
            fragments.append(value)
    for field in ("releaseArchive", "releaseArchiveManifest", "publicDownloadReceipt"):
        artifact_value = provenance.get(field)
        if not isinstance(artifact_value, dict):
            continue
        for key in ("path", "sha256", "downloadUrl"):
            value = artifact_value.get(key)
            if isinstance(value, str) and value:
                fragments.append(value)
    return fragments


def require_text_fragments(text: str, fragments: list[str], *, label: str) -> None:
    for fragment in fragments:
        escaped = html.escape(fragment, quote=False)
        if fragment not in text and escaped not in text:
            raise ValueError(f"{label} must expose: {fragment}")


def receipt_visibility_fragments(payload: dict[str, Any]) -> list[str]:
    fragments: list[str] = []
    for field in ("receiptId", "workloadId", "backend"):
        value = payload.get(field)
        if isinstance(value, str) and value:
            fragments.append(value)
    source_shader = payload.get("sourceShader")
    if isinstance(source_shader, dict):
        for field in ("language", "entryPoint", "source", "sha256", "sourceSha256"):
            value = source_shader.get(field)
            if isinstance(value, str) and value:
                fragments.append(value)
    lowering_path = payload.get("loweringPath")
    if isinstance(lowering_path, list) and all(isinstance(item, str) and item for item in lowering_path):
        fragments.append(" > ".join(lowering_path))
    driver = payload.get("driver")
    if isinstance(driver, dict):
        for field in (*REQUIRED_DRIVER_FIELDS, "profileId"):
            value = driver.get(field)
            if isinstance(value, str) and value:
                fragments.append(value)
    device = payload.get("device")
    if isinstance(device, dict):
        for field in ("adapter", "adapterInfoSha256"):
            value = device.get(field)
            if isinstance(value, str) and value:
                fragments.append(value)
        feature_count = device.get("featureCount")
        if nonnegative_int(feature_count):
            fragments.append(f"featureCount={feature_count}")
    for field in ("outputHash", "frameHash"):
        value = payload.get(field)
        if isinstance(value, str) and value:
            fragments.append(value)
    timing = payload.get("timing")
    if isinstance(timing, dict):
        timing_class = timing.get("timingClass")
        if isinstance(timing_class, str) and timing_class:
            fragments.append(timing_class)
        phases = timing.get("phases")
        if isinstance(phases, dict):
            for field in REQUIRED_TIMING_PHASES:
                value = phases.get(field)
                if nonnegative_int(value):
                    fragments.append(f"{field}={value}")
    return fragments


def visible_diagnostic_fragments(diagnostics: dict[str, Any]) -> list[str]:
    fragments: list[str] = []
    for value in diagnostics.values():
        if isinstance(value, bool):
            fragments.append("true" if value else "false")
        elif isinstance(value, str) and value:
            fragments.append(value)
    return fragments


def validate_proof_page_content(
    *,
    proof_artifact: Path,
    proof_page: dict[str, Any],
) -> None:
    try:
        text = proof_artifact.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"proof page artifact must be UTF-8 text: {proof_artifact}") from exc
    diagnostics = proof_page.get("diagnostics")
    if isinstance(diagnostics, dict):
        require_text_fragments(
            text,
            visible_diagnostic_fragments(diagnostics),
            label="proof page artifact",
        )
    require_text_fragments(
        text,
        release_provenance_fragments(proof_page.get("releaseProvenance")),
        label="proof page artifact",
    )
    recent_receipt_ids = proof_page.get("recentReceiptIds")
    if isinstance(recent_receipt_ids, list):
        require_text_fragments(
            text,
            [
                receipt_id
                for receipt_id in recent_receipt_ids
                if isinstance(receipt_id, str) and receipt_id
            ],
            label="proof page artifact",
        )
    receipt_payloads = proof_page.get("receiptPayloads")
    if isinstance(receipt_payloads, list):
        require_text_fragments(
            text,
            [
                row["path"]
                for row in receipt_payloads
                if isinstance(row, dict) and isinstance(row.get("path"), str) and row["path"]
            ],
            label="proof page artifact",
        )


def comparison_visibility_fragments(row: dict[str, Any]) -> list[str]:
    fragments: list[str] = []
    for field in ("comparisonId", "workloadId"):
        value = row.get(field)
        if isinstance(value, str) and value:
            fragments.append(value)
    comparison_artifact_value = row.get("comparisonArtifact")
    if isinstance(comparison_artifact_value, dict):
        path = comparison_artifact_value.get("path")
        if isinstance(path, str) and path:
            fragments.append(path)
    runner = row.get("runner")
    if isinstance(runner, dict):
        for field in ("pageArtifactPath", "executionScope"):
            value = runner.get(field)
            if isinstance(value, str) and value:
                fragments.append(value)
        modes = runner.get("modes")
        if isinstance(modes, list):
            fragments.extend(
                mode
                for mode in modes
                if isinstance(mode, str) and mode
            )
        if runner.get("emitsSideBySideReceipts") is True:
            fragments.append("side_by_side_receipts")
    for field in ("dawnReceipt", "doeReceipt"):
        receipt = row.get(field)
        if not isinstance(receipt, dict):
            continue
        for key in ("receiptId", "path"):
            value = receipt.get(key)
            if isinstance(value, str) and value:
                fragments.append(value)
    return fragments


def validate_comparison_visibility(
    *,
    proof_artifact: Path,
    comparison_receipts: list[dict[str, Any]],
) -> None:
    try:
        text = proof_artifact.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"proof page artifact must be UTF-8 text: {proof_artifact}") from exc
    for row in comparison_receipts:
        require_text_fragments(
            text,
            comparison_visibility_fragments(row),
            label="proof page artifact",
        )


def validate_gallery_page_content(
    *,
    gallery_artifact: Path,
    gallery_page: dict[str, Any],
    receipt_payloads: list[dict[str, Any]] | None = None,
) -> None:
    try:
        text = gallery_artifact.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"gallery page artifact must be UTF-8 text: {gallery_artifact}") from exc
    fragments: list[str] = []
    for field in ("category", "workloadContractPath"):
        value = gallery_page.get(field)
        if isinstance(value, str) and value:
            fragments.append(value)
    for field in ("workloadIds", "receiptIds"):
        values = gallery_page.get(field)
        if isinstance(values, list):
            fragments.extend(
                value
                for value in values
                if isinstance(value, str) and value
            )
    receipt_artifacts = gallery_page.get("receiptArtifacts")
    if isinstance(receipt_artifacts, list):
        fragments.extend(
            row["path"]
            for row in receipt_artifacts
            if isinstance(row, dict) and isinstance(row.get("path"), str) and row["path"]
        )
    for payload in receipt_payloads or []:
        fragments.extend(receipt_visibility_fragments(payload))
    require_text_fragments(text, fragments, label="gallery page artifact")


def validate_proof_page_receipt(
    proof_receipt: dict[str, Any],
    *,
    proof_artifact: Path,
    proof_artifact_path: str,
    runtime_identity_path: str,
) -> None:
    if proof_receipt.get("schemaVersion") != 1:
        raise ValueError("proof page receipt schemaVersion must be 1")
    if proof_receipt.get("artifactKind") != "browser_proof_page_receipt":
        raise ValueError("proof page receipt artifactKind must be browser_proof_page_receipt")
    if not isinstance(proof_receipt.get("receiptId"), str) or not proof_receipt["receiptId"]:
        raise ValueError("proof page receipt receiptId is required")
    url = proof_receipt.get("url")
    if not isinstance(url, str) or not url:
        raise ValueError("proof page receipt URL is required")
    expected_load_type = "file" if url.startswith("file:") else "browser_internal_page"
    if proof_receipt.get("loadType") != expected_load_type:
        raise ValueError(f"proof page receipt loadType must be {expected_load_type}")
    if proof_receipt.get("status") != "loaded":
        raise ValueError("proof page receipt status must be loaded")
    if proof_receipt.get("contentSha256") != sha256_file(proof_artifact):
        raise ValueError("proof page receipt contentSha256 must match proof page artifact")
    if proof_receipt.get("contentLengthBytes") != proof_artifact.stat().st_size:
        raise ValueError("proof page receipt contentLengthBytes must match proof page artifact")
    if proof_receipt.get("proofArtifactPath") != proof_artifact_path:
        raise ValueError("proof page receipt proofArtifactPath must match proof page artifact")
    if proof_receipt.get("runtimeIdentityPath") != runtime_identity_path:
        raise ValueError("proof page receipt runtimeIdentityPath must match proof surface")
    recent_receipt_ids = proof_receipt.get("recentReceiptIds")
    if not isinstance(recent_receipt_ids, list) or not recent_receipt_ids:
        raise ValueError("proof page receipt recentReceiptIds is required")
    for receipt_id in recent_receipt_ids:
        if not isinstance(receipt_id, str) or not receipt_id:
            raise ValueError("proof page receipt recentReceiptIds entries must be non-empty strings")
    if not isinstance(proof_receipt.get("diagnostics"), dict):
        raise ValueError("proof page receipt diagnostics must be an object")
    if proof_receipt["diagnostics"].get("webgpuAvailable") is not True:
        raise ValueError("proof page receipt diagnostics.webgpuAvailable must be true")
    if not isinstance(proof_receipt.get("releaseProvenance"), dict):
        raise ValueError("proof page receipt releaseProvenance must be an object")
    if not isinstance(proof_receipt.get("observedAt"), str) or not proof_receipt["observedAt"]:
        raise ValueError("proof page receipt observedAt is required")


def doe_execution_receipt_backends(receipt_payloads: list[Path]) -> set[str]:
    backends: set[str] = set()
    for path in receipt_payloads:
        payload = load_json(path)
        if not isinstance(payload, dict):
            continue
        validate_execution_receipt_payload(payload, path=path)
        if payload.get("selectedRuntime") != "doe":
            continue
        backend = payload.get("backend")
        if isinstance(backend, str) and backend:
            backends.add(backend)
    return backends


def validate_proof_page_active_backend(
    proof_receipt: dict[str, Any],
    *,
    receipt_payloads: list[Path],
) -> None:
    diagnostics = proof_receipt.get("diagnostics")
    if not isinstance(diagnostics, dict):
        return
    active_backend = diagnostics.get("activeBackend")
    if not isinstance(active_backend, str) or not active_backend:
        raise ValueError("proof page receipt diagnostics.activeBackend is required")
    doe_backends = doe_execution_receipt_backends(receipt_payloads)
    if not doe_backends:
        raise ValueError("proof page must link at least one Doe execution receipt backend")
    if active_backend not in doe_backends:
        raise ValueError(
            "proof page receipt diagnostics.activeBackend must match a linked Doe execution receipt backend"
        )


def build_proof_page(
    *,
    proof_artifact: Path,
    proof_receipt: Path,
    runtime_identity_path: str,
    receipt_payloads: list[Path],
    additional_recent_receipt_ids: set[str] | None = None,
) -> dict[str, Any]:
    proof_artifact_entry = artifact(proof_artifact, "browser_proof_page", "proof page artifact")
    proof_receipt_payload = load_json(proof_receipt)
    if not isinstance(proof_receipt_payload, dict):
        raise ValueError("proof page receipt must be a JSON object")
    validate_proof_page_receipt(
        proof_receipt_payload,
        proof_artifact=proof_artifact,
        proof_artifact_path=proof_artifact_entry["path"],
        runtime_identity_path=runtime_identity_path,
    )
    validate_proof_page_active_backend(
        proof_receipt_payload,
        receipt_payloads=receipt_payloads,
    )
    receipt_artifacts = [
        execution_receipt_artifact(path)
        for path in receipt_payloads
    ]
    linked_receipt_ids = {
        row["receiptId"]
        for row in receipt_artifacts
    }
    recent_receipt_ids = set(proof_receipt_payload["recentReceiptIds"])
    if not linked_receipt_ids <= recent_receipt_ids:
        raise ValueError("proof page receipt recentReceiptIds must match linked receipt payloads")
    if additional_recent_receipt_ids is not None:
        allowed_receipt_ids = linked_receipt_ids | additional_recent_receipt_ids
        for receipt_id in proof_receipt_payload["recentReceiptIds"]:
            if receipt_id not in allowed_receipt_ids:
                raise ValueError("proof page receipt recentReceiptIds must match linked receipt payloads")
    proof_page = {
        "artifact": proof_artifact_entry,
        "url": proof_receipt_payload["url"],
        "diagnosticReceipt": artifact(
            proof_receipt,
            "browser_proof_page_receipt",
            "proof page receipt",
        ),
        "diagnostics": proof_receipt_payload["diagnostics"],
        "releaseProvenance": proof_receipt_payload["releaseProvenance"],
        "recentReceiptIds": proof_receipt_payload["recentReceiptIds"],
        "receiptPayloads": receipt_artifacts,
    }
    validate_proof_page_content(proof_artifact=proof_artifact, proof_page=proof_page)
    return proof_page


def load_entry(path: Path, label: str) -> dict[str, Any]:
    payload = load_json(path)
    if not isinstance(payload, dict):
        raise ValueError(f"{label} entry must be a JSON object: {path}")
    return payload


def validate_gallery_public_receipt(
    payload: dict[str, Any],
    *,
    category: str,
    url: str,
    artifact_entry: dict[str, str],
    workload_contract_path: str,
    workload_ids: list[str],
    receipt_ids: list[str],
    receipt_artifact_paths: list[str],
    artifact_path: Path,
) -> None:
    if payload.get("schemaVersion") != 1:
        raise ValueError("gallery public receipt schemaVersion must be 1")
    if payload.get("artifactKind") != "browser_public_gallery_receipt":
        raise ValueError("gallery public receipt artifactKind must be browser_public_gallery_receipt")
    if not isinstance(payload.get("receiptId"), str) or not payload["receiptId"]:
        raise ValueError("gallery public receipt receiptId is required")
    if payload.get("category") != category:
        raise ValueError("gallery public receipt category must match gallery entry")
    if payload.get("url") != url:
        raise ValueError("gallery public receipt URL must match gallery entry")
    if not is_public_https_url(payload.get("url")):
        raise ValueError("gallery public receipt URL must be public HTTPS")
    if payload.get("method") != "GET":
        raise ValueError("gallery public receipt method must be GET")
    if payload.get("statusCode") != 200:
        raise ValueError("gallery public receipt statusCode must be 200")
    if payload.get("contentSha256") != artifact_entry["sha256"]:
        raise ValueError("gallery public receipt contentSha256 must match gallery artifact")
    if payload.get("contentLengthBytes") != artifact_path.stat().st_size:
        raise ValueError("gallery public receipt contentLengthBytes must match gallery artifact")
    if payload.get("galleryArtifactPath") != artifact_entry["path"]:
        raise ValueError("gallery public receipt galleryArtifactPath must match gallery artifact")
    if payload.get("workloadContractPath") != workload_contract_path:
        raise ValueError("gallery public receipt workloadContractPath must match gallery entry")
    if payload.get("workloadIds") != workload_ids:
        raise ValueError("gallery public receipt workloadIds must match gallery entry")
    if payload.get("receiptIds") != receipt_ids:
        raise ValueError("gallery public receipt receiptIds must match gallery entry")
    if payload.get("receiptArtifactPaths") != receipt_artifact_paths:
        raise ValueError("gallery public receipt receiptArtifactPaths must match gallery entry")
    if not isinstance(payload.get("observedAt"), str) or not payload["observedAt"]:
        raise ValueError("gallery public receipt observedAt is required")


def build_gallery_page(entry: dict[str, Any]) -> dict[str, Any]:
    category = entry.get("category")
    if category not in GALLERY_CATEGORIES:
        raise ValueError(f"unsupported gallery category: {category}")
    url = entry.get("url")
    if not is_public_https_url(url):
        raise ValueError(f"gallery URL must be public HTTPS: {url}")
    artifact_path = path_from_text(entry.get("artifact"), label="gallery artifact")
    public_receipt_path = path_from_text(entry.get("publicReceipt"), label="gallery public receipt")
    workload_contract_path = entry.get("workloadContractPath")
    if not isinstance(workload_contract_path, str) or not workload_contract_path:
        raise ValueError("gallery workloadContractPath is required")
    receipt_payload_paths = entry.get("receiptPayloads")
    if not isinstance(receipt_payload_paths, list) or not receipt_payload_paths:
        raise ValueError("gallery receiptPayloads must be a non-empty array")
    receipt_paths = [
        path_from_text(path, label="gallery receipt payload")
        for path in receipt_payload_paths
    ]
    workload_ids = unique_workload_ids(receipt_paths)
    receipt_artifacts = [
        execution_receipt_artifact(path)
        for path in receipt_paths
    ]
    receipt_payloads = [load_json(path) for path in receipt_paths]
    receipt_ids = [row["receiptId"] for row in receipt_artifacts]
    receipt_artifact_paths = [row["path"] for row in receipt_artifacts]
    artifact_entry = artifact(artifact_path, "browser_gallery_page", "gallery page artifact")
    public_receipt_payload = load_json(public_receipt_path)
    if not isinstance(public_receipt_payload, dict):
        raise ValueError("gallery public receipt must be a JSON object")
    validate_gallery_public_receipt(
        public_receipt_payload,
        category=category,
        url=url,
        artifact_entry=artifact_entry,
        workload_contract_path=workload_contract_path,
        workload_ids=workload_ids,
        receipt_ids=receipt_ids,
        receipt_artifact_paths=receipt_artifact_paths,
        artifact_path=artifact_path,
    )
    gallery_page = {
        "category": category,
        "url": url,
        "artifact": artifact_entry,
        "publicReceipt": artifact(
            public_receipt_path,
            "browser_public_gallery_receipt",
            "gallery public receipt",
        ),
        "workloadContractPath": workload_contract_path,
        "workloadIds": workload_ids,
        "receiptIds": receipt_ids,
        "receiptArtifacts": receipt_artifacts,
    }
    validate_gallery_page_content(
        gallery_artifact=artifact_path,
        gallery_page=gallery_page,
        receipt_payloads=[
            payload
            for payload in receipt_payloads
            if isinstance(payload, dict)
        ],
    )
    return gallery_page


def build_comparison(
    entry: dict[str, Any],
    *,
    gallery_artifact_paths: set[str] | None = None,
) -> dict[str, Any]:
    comparison_id = entry.get("comparisonId")
    workload_id = entry.get("workloadId")
    page_artifact_path = entry.get("pageArtifactPath")
    if not isinstance(comparison_id, str) or not comparison_id:
        raise ValueError("comparisonId is required")
    if not isinstance(workload_id, str) or not workload_id:
        raise ValueError("workloadId is required")
    if not isinstance(page_artifact_path, str) or not page_artifact_path:
        raise ValueError("pageArtifactPath is required")
    if gallery_artifact_paths is not None and page_artifact_path not in gallery_artifact_paths:
        raise ValueError("comparison pageArtifactPath must match a gallery page artifact")
    dawn_receipt_path = path_from_text(entry.get("dawnReceipt"), label="Dawn execution receipt")
    doe_receipt_path = path_from_text(entry.get("doeReceipt"), label="Doe execution receipt")
    dawn_receipt = execution_receipt_artifact(dawn_receipt_path)
    doe_receipt = execution_receipt_artifact(doe_receipt_path)
    return {
        "comparisonId": comparison_id,
        "workloadId": workload_id,
        "runner": {
            "pageArtifactPath": page_artifact_path,
            "executionScope": "same_page",
            "modes": ["dawn", "doe"],
            "emitsSideBySideReceipts": True,
        },
        "comparisonPolicy": comparison_policy(dawn_receipt_path, doe_receipt_path, workload_id=workload_id),
        "comparisonArtifact": comparison_artifact(
            path_from_text(entry.get("comparisonArtifact"), label="comparison artifact")
        ),
        "dawnReceipt": dawn_receipt,
        "doeReceipt": doe_receipt,
    }


def build_surface(
    *,
    surface_id: str,
    capture_policy_path: str,
    runtime_identity_path: str,
    proof_artifact: Path,
    proof_receipt: Path,
    proof_receipt_payloads: list[Path],
    gallery_entries: list[dict[str, Any]],
    comparison_entries: list[dict[str, Any]],
) -> dict[str, Any]:
    if not surface_id:
        raise ValueError("surfaceId is required")
    require_file(path_from_text(capture_policy_path, label="capture policy"), "capture policy")
    require_file(path_from_text(runtime_identity_path, label="runtime identity"), "runtime identity")
    if not gallery_entries:
        raise ValueError("at least one gallery entry is required")
    if not comparison_entries:
        raise ValueError("at least one comparison entry is required")
    gallery_pages = [build_gallery_page(entry) for entry in gallery_entries]
    gallery_artifact_paths = {
        row["artifact"]["path"]
        for row in gallery_pages
    }
    comparison_receipts = [
        build_comparison(entry, gallery_artifact_paths=gallery_artifact_paths)
        for entry in comparison_entries
    ]
    surface_receipt_ids = {
        artifact["receiptId"]
        for row in gallery_pages
        for artifact in row.get("receiptArtifacts", [])
        if isinstance(artifact, dict) and isinstance(artifact.get("receiptId"), str)
    }
    for row in comparison_receipts:
        for field in ("dawnReceipt", "doeReceipt"):
            receipt = row.get(field)
            if isinstance(receipt, dict) and isinstance(receipt.get("receiptId"), str):
                surface_receipt_ids.add(receipt["receiptId"])
    proof_page = build_proof_page(
        proof_artifact=proof_artifact,
        proof_receipt=proof_receipt,
        runtime_identity_path=runtime_identity_path,
        receipt_payloads=proof_receipt_payloads,
        additional_recent_receipt_ids=surface_receipt_ids,
    )
    validate_comparison_visibility(
        proof_artifact=proof_artifact,
        comparison_receipts=comparison_receipts,
    )
    return {
        "schemaVersion": 1,
        "artifactKind": "browser_published_proof_surface",
        "surfaceId": surface_id,
        "capturePolicyPath": capture_policy_path,
        "runtimeIdentityPath": runtime_identity_path,
        "proofPage": proof_page,
        "galleryPages": gallery_pages,
        "comparisonReceipts": comparison_receipts,
    }


def main() -> int:
    args = parse_args()
    try:
        surface = build_surface(
            surface_id=args.surface_id,
            capture_policy_path=args.capture_policy_path,
            runtime_identity_path=args.runtime_identity_path,
            proof_artifact=Path(args.proof_page_artifact),
            proof_receipt=Path(args.proof_page_receipt),
            proof_receipt_payloads=[Path(path) for path in args.proof_receipt_payload],
            gallery_entries=[
                load_entry(Path(path), "gallery")
                for path in args.gallery_entry
            ],
            comparison_entries=[
                load_entry(Path(path), "comparison")
                for path in args.comparison_entry
            ],
        )
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(surface, indent=2) + "\n", encoding="utf-8")
    except Exception as exc:
        sys.stderr.write(f"build_browser_published_proof_surface: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
