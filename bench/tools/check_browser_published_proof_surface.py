#!/usr/bin/env python3
"""Check published browser proof page and gallery evidence."""

from __future__ import annotations

import argparse
import hashlib
import html
import importlib.util
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib.bench_utils import load_json_object as load_json
from bench.browser.browser_gate import validate_smoke_report
from bench.tools import check_browser_capture_policy as capture_policy_check

try:
    from bench.tools._public_url import is_public_https_url
except ModuleNotFoundError:
    from _public_url import is_public_https_url


RUNTIME_IDENTITY_PATH = (
    REPO_ROOT / "browser" / "chromium" / "scripts" / "check-browser-runtime-identity.py"
)
REQUIRED_GALLERY_CATEGORIES = {
    "compute",
    "rendering",
    "tensor",
    "shader_edge",
    "benchmark_trace",
}
SUPPORTED_COMPARISON_ARTIFACT_KINDS = {
    "chromium-webgpu-playwright-smoke",
}
REQUIRED_PROOF_DIAGNOSTICS = {
    "activeRuntime",
    "activeBackend",
    "webgpuAvailable",
    "compilerPath",
    "tsirStatus",
    "hostPlanStatus",
    "cslStatus",
    "fallbackPolicyState",
}
RELEASE_CHANNELS = {"release_candidate", "release"}
PROOF_DIAGNOSTIC_STATUS_FIELDS = ("tsirStatus", "hostPlanStatus", "cslStatus")
NON_RELEASE_DIAGNOSTIC_STATUS_VALUES = {
    "diagnostic",
    "placeholder",
    "sample",
    "tbd",
    "todo",
    "unknown",
}
REQUIRED_RELEASE_PROVENANCE_FIELDS = {
    "browserProduct",
    "platform",
    "releaseArchive",
    "releaseArchiveManifest",
    "publicDownloadReceipt",
    "browserExecutableArchivePath",
    "browserAppMetadataArchivePath",
    "doeRuntimeArchivePath",
    "dawnFallbackRuntimeArchivePath",
}
REQUIRED_BROWSER_PRODUCT_FIELDS = {"productId", "displayName", "version", "channel"}
REQUIRED_PLATFORM_FIELDS = {"os", "arch", "packageFormat"}
REQUIRED_EXECUTION_RECEIPT_FIELDS = {
    "backend",
    "commandCoverage",
    "device",
    "driver",
    "fallbackState",
    "loweringPath",
    "runtimeSelectorState",
    "sourceShader",
    "timing",
    "workloadId",
}
REQUIRED_COMPARISON_POLICY_FIELDS = {
    "adapterDeviceIdentity",
    "commandCoverage",
    "fallbackPolicy",
    "outputIdentity",
    "sourceShaderIdentity",
    "timingScope",
    "workloadIdentity",
}
REQUIRED_DRIVER_FIELDS = ("vendor", "api", "driver", "deviceFamily")
REQUIRED_TIMING_PHASES = ("setupNs", "encodeNs", "submitWaitNs")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--surface", required=True, help="browser_published_proof_surface JSON.")
    parser.add_argument(
        "--verify-files-root",
        default="",
        help="Resolve artifact paths under this root and verify hashes.",
    )
    parser.add_argument(
        "--require-public-urls",
        action="store_true",
        help="Require hosted HTTPS URLs for every public gallery page.",
    )
    parser.add_argument("--out", default="", help="Optional output path for the checker report.")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def concrete_text(value: Any) -> bool:
    return isinstance(value, str) and bool(value) and value != "unknown"


def lowercase_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(char in "0123456789abcdef" for char in value)
    )


def nonnegative_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def diagnostic_visible_fragment(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    return value if isinstance(value, str) else ""


def visible_fragment_present(text: str, fragment: str) -> bool:
    escaped = html.escape(fragment, quote=False)
    return fragment in text or escaped in text


def resolve_artifact_path(path_text: str, verify_files_root: Path) -> Path | None:
    root = verify_files_root.resolve()
    path = Path(path_text)
    candidate = path if path.is_absolute() else root.joinpath(*PurePosixPath(path_text).parts)
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        return None
    return resolved


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def repo_relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def artifact_file_path(artifact: Any, verify_files_root: Path | None) -> Path | None:
    if verify_files_root is None or not isinstance(artifact, dict):
        return None
    artifact_path = artifact.get("path")
    if not isinstance(artifact_path, str) or not artifact_path:
        return None
    resolved = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved is None or not resolved.is_file():
        return None
    return resolved


def artifact_text(artifact: Any, verify_files_root: Path | None) -> str | None:
    resolved = artifact_file_path(artifact, verify_files_root)
    if resolved is None:
        return None
    try:
        return resolved.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def load_runtime_identity_checker():
    spec = importlib.util.spec_from_file_location(
        "browser_runtime_identity_for_published_proof_surface",
        RUNTIME_IDENTITY_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load runtime identity checker: {RUNTIME_IDENTITY_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_artifact(
    artifact: Any,
    path: str,
    verify_files_root: Path | None,
    *,
    expected_kind: str | None = None,
) -> list[dict[str, str]]:
    if not isinstance(artifact, dict):
        return [failure("invalid_artifact", path, "artifact must be object")]
    failures: list[dict[str, str]] = []
    artifact_path = artifact.get("path")
    artifact_hash = artifact.get("sha256")
    if expected_kind is not None and artifact.get("kind") != expected_kind:
        failures.append(failure("wrong_artifact_kind", f"{path}.kind", f"expected {expected_kind}"))
    if not isinstance(artifact_path, str) or not artifact_path:
        failures.append(failure("missing_artifact_path", f"{path}.path", "artifact path is required"))
    if not isinstance(artifact_hash, str) or len(artifact_hash) != 64:
        failures.append(failure("missing_artifact_hash", f"{path}.sha256", "artifact sha256 is required"))
    if (
        verify_files_root is not None
        and isinstance(artifact_path, str)
        and isinstance(artifact_hash, str)
    ):
        resolved = resolve_artifact_path(artifact_path, verify_files_root)
        if resolved is None:
            failures.append(
                failure(
                    "unsafe_artifact_path",
                    f"{path}.path",
                    f"artifact path must resolve under verify-files-root: {artifact_path}",
                )
            )
            return failures
        if not resolved.is_file():
            failures.append(
                failure(
                    "artifact_file_missing",
                    f"{path}.path",
                    f"artifact file not found: {artifact_path}",
                )
            )
            return failures
        actual_hash = sha256_file(resolved)
        if actual_hash != artifact_hash:
            failures.append(
                failure(
                    "artifact_hash_mismatch",
                    f"{path}.sha256",
                    f"expected {actual_hash} for {artifact_path}",
                )
            )
    return failures


def check_receipt_artifact(
    artifact: Any,
    path: str,
    verify_files_root: Path | None,
    *,
    expected_runtime: str | None = None,
    require_source_text: bool = False,
) -> list[dict[str, str]]:
    failures = check_artifact(
        artifact,
        path,
        verify_files_root,
        expected_kind="browser_execution_receipt",
    )
    if not isinstance(artifact, dict):
        return failures
    receipt_id = artifact.get("receiptId")
    if not isinstance(receipt_id, str) or not receipt_id:
        failures.append(failure("missing_receipt_id", f"{path}.receiptId", "receiptId is required"))
    payload = load_artifact_payload(artifact, path, verify_files_root)
    if payload is not None:
        failures.extend(
            check_execution_receipt_payload(
                payload,
                path,
                receipt_id,
                expected_runtime,
                require_source_text=require_source_text,
            )
        )
    return failures


def load_artifact_payload(
    artifact: dict[str, Any],
    path: str,
    verify_files_root: Path | None,
) -> dict[str, Any] | None:
    if verify_files_root is None:
        return None
    artifact_path = artifact.get("path")
    artifact_hash = artifact.get("sha256")
    if not (
        isinstance(artifact_path, str)
        and artifact_path
        and isinstance(artifact_hash, str)
        and len(artifact_hash) == 64
    ):
        return None
    resolved = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved is None or not resolved.is_file():
        return None
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return {
            "_invalid_payload_error": failure(
                "invalid_receipt_payload",
                f"{path}.path",
                f"receipt payload is not valid JSON: {exc}",
            )
        }
    if not isinstance(payload, dict):
        return {
            "_invalid_payload_error": failure(
                "invalid_receipt_payload",
                f"{path}.path",
                "receipt payload must be a JSON object",
            )
        }
    return payload


def check_proof_page_active_backend_matches_doe_receipt(
    proof_page: dict[str, Any],
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    diagnostics = proof_page.get("diagnostics")
    receipt_payloads = proof_page.get("receiptPayloads")
    if (
        verify_files_root is None
        or not isinstance(diagnostics, dict)
        or not isinstance(receipt_payloads, list)
    ):
        return []
    active_backend = diagnostics.get("activeBackend")
    if not isinstance(active_backend, str) or not active_backend:
        return []
    doe_backends: set[str] = set()
    for index, artifact in enumerate(receipt_payloads):
        if not isinstance(artifact, dict):
            continue
        payload = load_artifact_payload(
            artifact,
            f"proofPage.receiptPayloads[{index}]",
            verify_files_root,
        )
        if not isinstance(payload, dict) or payload.get("_invalid_payload_error"):
            continue
        if payload.get("selectedRuntime") != "doe":
            continue
        backend = payload.get("backend")
        if isinstance(backend, str) and backend:
            doe_backends.add(backend)
    if not doe_backends:
        return [
            failure(
                "missing_doe_receipt_backend",
                "proofPage.receiptPayloads",
                "proof page must link at least one Doe execution receipt backend",
            )
        ]
    if active_backend not in doe_backends:
        return [
            failure(
                "proof_page_active_backend_mismatch",
                "proofPage.diagnostics.activeBackend",
                "proof page activeBackend must match a linked Doe execution receipt backend",
            )
        ]
    return []


def load_comparison_artifact_payload(
    artifact: dict[str, Any],
    path: str,
    verify_files_root: Path | None,
) -> dict[str, Any] | None:
    if verify_files_root is None:
        return None
    artifact_path = artifact.get("path")
    artifact_hash = artifact.get("sha256")
    if not (
        isinstance(artifact_path, str)
        and artifact_path
        and isinstance(artifact_hash, str)
        and len(artifact_hash) == 64
    ):
        return None
    resolved = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved is None or not resolved.is_file():
        return None
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return {
            "_invalid_payload_error": failure(
                "invalid_comparison_artifact_payload",
                f"{path}.path",
                f"comparison artifact payload is not valid JSON: {exc}",
            )
        }
    if not isinstance(payload, dict):
        return {
            "_invalid_payload_error": failure(
                "invalid_comparison_artifact_payload",
                f"{path}.path",
                "comparison artifact payload must be a JSON object",
            )
        }
    return payload


def check_execution_receipt_payload(
    payload: dict[str, Any],
    path: str,
    receipt_id: Any,
    expected_runtime: str | None,
    *,
    require_source_text: bool = False,
) -> list[dict[str, str]]:
    invalid_payload_error = payload.get("_invalid_payload_error")
    if isinstance(invalid_payload_error, dict):
        return [invalid_payload_error]
    failures: list[dict[str, str]] = []
    if payload.get("artifactKind") != "browser_execution_receipt":
        failures.append(
            failure(
                "invalid_receipt_artifact_kind",
                f"{path}.path",
                "receipt payload artifactKind must be browser_execution_receipt",
            )
        )
    if isinstance(receipt_id, str) and payload.get("receiptId") != receipt_id:
        failures.append(
            failure(
                "receipt_id_mismatch",
                f"{path}.receiptId",
                "manifest receiptId must match receipt payload receiptId",
            )
        )
    selected_runtime = payload.get("selectedRuntime")
    if not isinstance(selected_runtime, str) or not selected_runtime:
        failures.append(
            failure(
                "missing_receipt_runtime",
                f"{path}.path",
                "receipt payload selectedRuntime is required",
            )
        )
    elif expected_runtime is not None and selected_runtime != expected_runtime:
        failures.append(
            failure(
                "wrong_receipt_runtime",
                f"{path}.path",
                f"expected selectedRuntime={expected_runtime}",
            )
        )
    workload_id = payload.get("workloadId")
    if not isinstance(workload_id, str) or not workload_id:
        failures.append(
            failure(
                "missing_receipt_workload_id",
                f"{path}.path",
                "receipt payload workloadId must be a non-empty string",
            )
        )
    for field in sorted(REQUIRED_EXECUTION_RECEIPT_FIELDS):
        if field not in payload:
            failures.append(
                failure(
                    "missing_execution_receipt_field",
                    f"{path}.path",
                    f"receipt payload field is required: {field}",
                )
            )
    source_shader = payload.get("sourceShader")
    if not isinstance(source_shader, dict):
        failures.append(
            failure(
                "missing_receipt_source_shader",
                f"{path}.path",
                "receipt payload sourceShader must be an object",
            )
        )
    else:
        source = source_shader.get("source")
        source_hash_value = source_shader.get("sha256")
        if not isinstance(source, str) or not source:
            failures.append(
                failure(
                    "missing_receipt_source_text",
                    f"{path}.path",
                    "receipt payload sourceShader.source is required",
                )
            )
        if not isinstance(source_hash_value, str) or not source_hash_value:
            failures.append(
                failure(
                    "missing_receipt_source_hash",
                    f"{path}.path",
                    "receipt payload sourceShader.sha256 is required",
                )
            )
    if isinstance(source_shader, dict) and isinstance(source_shader.get("source"), str):
        source_hash = hashlib.sha256(source_shader["source"].encode("utf-8")).hexdigest()
        for key in ("sha256", "sourceSha256"):
            value = source_shader.get(key)
            if isinstance(value, str) and value != source_hash:
                failures.append(
                    failure(
                        "receipt_source_hash_mismatch",
                        f"{path}.sourceShader.{key}",
                        f"sourceShader.{key} must match sha256(sourceShader.source)",
                    )
                )
    if command_evidence_identity(payload) is None:
        failures.append(
            failure(
                "missing_receipt_command_evidence",
                f"{path}.path",
                "receipt payload must include commandGraph or flightRecorderRef identity",
            )
        )
    lowering_path = payload.get("loweringPath")
    if not isinstance(lowering_path, list) or not lowering_path:
        failures.append(
            failure(
                "missing_receipt_lowering_path",
                f"{path}.path",
                "receipt payload loweringPath must be non-empty",
            )
        )
    elif not all(isinstance(item, str) and item for item in lowering_path):
        failures.append(
            failure(
                "invalid_receipt_lowering_path",
                f"{path}.path",
                "receipt payload loweringPath entries must be non-empty strings",
            )
        )
    if not isinstance(payload.get("backend"), str) or not payload.get("backend"):
        failures.append(
            failure(
                "missing_receipt_backend",
                f"{path}.path",
                "receipt payload backend must be a non-empty string",
            )
        )
    driver = payload.get("driver")
    if not isinstance(driver, dict) or not driver:
        failures.append(
            failure(
                "missing_receipt_driver",
                f"{path}.path",
                "receipt payload driver must be a non-empty object",
            )
        )
    else:
        for field in REQUIRED_DRIVER_FIELDS:
            if not concrete_text(driver.get(field)):
                failures.append(
                    failure(
                        "invalid_receipt_driver_identity",
                        f"{path}.driver.{field}",
                        f"receipt payload driver.{field} must be concrete",
                    )
                )
    device = payload.get("device")
    if not isinstance(device, dict) or not device:
        failures.append(
            failure(
                "missing_receipt_device",
                f"{path}.path",
                "receipt payload device must be a non-empty object",
            )
        )
    else:
        if not lowercase_sha256(device.get("adapterInfoSha256")):
            failures.append(
                failure(
                    "invalid_receipt_device_identity",
                    f"{path}.device.adapterInfoSha256",
                    "receipt payload device.adapterInfoSha256 must be lowercase SHA-256",
                )
            )
        if not nonnegative_int(device.get("featureCount")):
            failures.append(
                failure(
                    "invalid_receipt_device_identity",
                    f"{path}.device.featureCount",
                    "receipt payload device.featureCount must be non-negative",
                )
            )
        if not concrete_text(device.get("adapter")):
            failures.append(
                failure(
                    "invalid_receipt_device_identity",
                    f"{path}.device.adapter",
                    "receipt payload device.adapter must be concrete",
                )
            )
    if output_identity(payload) is None:
        failures.append(
            failure(
                "missing_receipt_output_identity",
                f"{path}.path",
                "receipt payload outputHash or frameHash must be a non-empty string",
            )
        )
    command_coverage = payload.get("commandCoverage")
    if not isinstance(command_coverage, dict) or not command_coverage:
        failures.append(
            failure(
                "missing_receipt_command_coverage",
                f"{path}.path",
                "receipt payload commandCoverage must be a non-empty object",
            )
        )
    else:
        command_count = command_coverage.get("commandCount")
        success_count = command_coverage.get("successCount")
        dispatch_count = command_coverage.get("dispatchCount")
        if not isinstance(command_count, int) or command_count <= 0:
            failures.append(
                failure(
                    "invalid_receipt_command_count",
                    f"{path}.path",
                    "receipt payload commandCoverage.commandCount must be positive",
                )
            )
        if not isinstance(success_count, int) or success_count < 0:
            failures.append(
                failure(
                    "invalid_receipt_success_count",
                    f"{path}.path",
                    "receipt payload commandCoverage.successCount must be non-negative",
                )
            )
        elif isinstance(command_count, int) and success_count > command_count:
            failures.append(
                failure(
                    "invalid_receipt_success_count",
                    f"{path}.path",
                    "receipt payload commandCoverage.successCount cannot exceed commandCount",
                )
            )
        elif isinstance(command_count, int) and command_count > 0 and success_count != command_count:
            failures.append(
                failure(
                    "incomplete_receipt_command_coverage",
                    f"{path}.path",
                    "receipt payload commandCoverage.successCount must equal commandCount",
                )
            )
        if dispatch_count is not None:
            if not isinstance(dispatch_count, int) or dispatch_count < 0:
                failures.append(
                    failure(
                        "invalid_receipt_dispatch_count",
                        f"{path}.path",
                        "receipt payload commandCoverage.dispatchCount must be non-negative",
                    )
                )
            elif isinstance(command_count, int) and command_count > 0 and dispatch_count > command_count:
                failures.append(
                    failure(
                        "invalid_receipt_dispatch_count",
                        f"{path}.path",
                        "receipt payload commandCoverage.dispatchCount cannot exceed commandCount",
                    )
                )
    runtime_selector_state = payload.get("runtimeSelectorState")
    if not isinstance(runtime_selector_state, dict):
        failures.append(
            failure(
                "missing_receipt_runtime_selector_state",
                f"{path}.path",
                "receipt payload runtimeSelectorState must be an object",
            )
        )
    else:
        selector_runtime = runtime_selector_state.get("selectedRuntime")
        if selector_runtime != selected_runtime:
            failures.append(
                failure(
                    "receipt_runtime_selector_mismatch",
                    f"{path}.path",
                    "runtimeSelectorState.selectedRuntime must match selectedRuntime",
                )
            )
        selector_fallback_applied = runtime_selector_state.get("fallbackApplied")
        if selector_fallback_applied is not False:
            failures.append(
                failure(
                    "receipt_selector_fallback_applied",
                    f"{path}.path",
                    "runtimeSelectorState.fallbackApplied must be false",
                )
            )
        if runtime_selector_state.get("hiddenFallbackAllowed") is not False:
            failures.append(
                failure(
                    "receipt_hidden_fallback_not_disabled",
                    f"{path}.path",
                    "runtimeSelectorState.hiddenFallbackAllowed must be false",
                )
            )
        selector_fallback_reason = runtime_selector_state.get("fallbackReasonCode")
        if not isinstance(selector_fallback_reason, str):
            failures.append(
                failure(
                    "invalid_receipt_selector_fallback_reason",
                    f"{path}.path",
                    "runtimeSelectorState.fallbackReasonCode must be a string",
                )
            )
        elif selector_fallback_applied is False and selector_fallback_reason:
            failures.append(
                failure(
                    "unexpected_receipt_selector_fallback_reason",
                    f"{path}.path",
                    "non-fallback proof receipts must not carry a selector fallback reason",
                )
            )
    fallback_state = payload.get("fallbackState")
    if not isinstance(fallback_state, dict):
        failures.append(
            failure(
                "missing_receipt_fallback_state",
                f"{path}.path",
                "receipt payload fallbackState must be an object",
            )
        )
    else:
        if fallback_state.get("hiddenFallbackAllowed") is not False:
            failures.append(
                failure(
                    "receipt_hidden_fallback_not_disabled",
                    f"{path}.path",
                    "fallbackState.hiddenFallbackAllowed must be false",
                )
            )
        fallback_applied = fallback_state.get("fallbackApplied")
        if fallback_applied is not False:
            failures.append(
                failure(
                    "receipt_fallback_applied",
                    f"{path}.path",
                    "published proof receipts must not apply fallback",
                )
            )
        reason_code = fallback_state.get("reasonCode")
        if not isinstance(reason_code, str):
            failures.append(
                failure(
                    "invalid_receipt_fallback_reason",
                    f"{path}.path",
                    "fallbackState.reasonCode must be a string",
                )
            )
        elif fallback_applied is False and reason_code:
            failures.append(
                failure(
                    "unexpected_receipt_fallback_reason",
                    f"{path}.path",
                    "non-fallback proof receipts must not carry a fallback reason",
                )
            )
    timing = payload.get("timing")
    if not isinstance(timing, dict):
        failures.append(
            failure(
                "missing_receipt_timing",
                f"{path}.path",
                "receipt payload timing must be an object",
            )
        )
    elif not isinstance(timing.get("timingClass"), str) or not timing.get("timingClass"):
        failures.append(
            failure(
                "missing_receipt_timing_class",
                f"{path}.path",
                "receipt payload timing.timingClass is required",
            )
        )
    elif not isinstance(timing.get("phases"), dict) or not timing.get("phases"):
        failures.append(
            failure(
                "missing_receipt_timing_phases",
                f"{path}.path",
                "receipt payload timing.phases must be a non-empty object",
            )
        )
    else:
        phases = timing["phases"]
        for field in REQUIRED_TIMING_PHASES:
            if not nonnegative_int(phases.get(field)):
                failures.append(
                    failure(
                        "invalid_receipt_timing_phase",
                        f"{path}.timing.phases.{field}",
                        f"receipt payload timing.phases.{field} must be non-negative",
                    )
                )
    return failures


def source_shader_identity(payload: dict[str, Any]) -> str | None:
    source_shader = payload.get("sourceShader")
    if not isinstance(source_shader, dict):
        return None
    for key in ("sha256", "sourceSha256", "source"):
        value = source_shader.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def output_identity(payload: dict[str, Any]) -> str | None:
    for key in ("outputHash", "frameHash"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def receipt_visibility_fragments(payload: dict[str, Any]) -> list[tuple[str, str]]:
    fragments: list[tuple[str, str]] = []
    for field in ("receiptId", "workloadId", "backend"):
        value = payload.get(field)
        if isinstance(value, str) and value:
            fragments.append((field, value))
    source_shader = payload.get("sourceShader")
    if isinstance(source_shader, dict):
        for field in ("language", "entryPoint", "source", "sha256", "sourceSha256"):
            value = source_shader.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"sourceShader.{field}", value))
    lowering_path = payload.get("loweringPath")
    if isinstance(lowering_path, list) and all(isinstance(item, str) and item for item in lowering_path):
        fragments.append(("loweringPath", " > ".join(lowering_path)))
    driver = payload.get("driver")
    if isinstance(driver, dict):
        for field in (*REQUIRED_DRIVER_FIELDS, "profileId"):
            value = driver.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"driver.{field}", value))
    device = payload.get("device")
    if isinstance(device, dict):
        for field in ("adapter", "adapterInfoSha256"):
            value = device.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"device.{field}", value))
        feature_count = device.get("featureCount")
        if nonnegative_int(feature_count):
            fragments.append(("device.featureCount", f"featureCount={feature_count}"))
    for field in ("outputHash", "frameHash"):
        value = payload.get(field)
        if isinstance(value, str) and value:
            fragments.append((field, value))
    timing = payload.get("timing")
    if isinstance(timing, dict):
        timing_class = timing.get("timingClass")
        if isinstance(timing_class, str) and timing_class:
            fragments.append(("timing.timingClass", timing_class))
        phases = timing.get("phases")
        if isinstance(phases, dict):
            for field in REQUIRED_TIMING_PHASES:
                value = phases.get(field)
                if nonnegative_int(value):
                    fragments.append((f"timing.phases.{field}", f"{field}={value}"))
    return fragments


def output_identity_kind(payload: dict[str, Any]) -> str | None:
    has_output_hash = isinstance(payload.get("outputHash"), str) and bool(payload["outputHash"])
    has_frame_hash = isinstance(payload.get("frameHash"), str) and bool(payload["frameHash"])
    if has_output_hash == has_frame_hash:
        return None
    return "same_output_hash" if has_output_hash else "same_frame_hash"


def command_evidence_identity(payload: dict[str, Any]) -> str | None:
    for field in ("commandGraph", "flightRecorderRef"):
        evidence = payload.get(field)
        if not isinstance(evidence, dict) or not evidence:
            continue
        for key in ("sha256", "hash", "graphSha256", "artifactSha256"):
            value = evidence.get(key)
            if isinstance(value, str) and value:
                return value
    return None


def timing_class(payload: dict[str, Any]) -> str | None:
    timing = payload.get("timing")
    if not isinstance(timing, dict):
        return None
    value = timing.get("timingClass")
    return value if isinstance(value, str) and value else None


def valid_loaded_payload(payload: dict[str, Any] | None) -> bool:
    return isinstance(payload, dict) and not isinstance(payload.get("_invalid_payload_error"), dict)


def unique_ordered(values: list[str]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def check_comparison_artifact_payload(
    artifact: Any,
    path: str,
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    if not isinstance(artifact, dict):
        return []
    failures: list[dict[str, str]] = []
    artifact_kind = artifact.get("kind")
    if artifact_kind not in SUPPORTED_COMPARISON_ARTIFACT_KINDS:
        failures.append(
            failure(
                "unsupported_comparison_artifact_kind",
                f"{path}.kind",
                "comparisonArtifact.kind must be chromium-webgpu-playwright-smoke",
            )
        )
        return failures
    payload = load_comparison_artifact_payload(artifact, path, verify_files_root)
    if payload is None:
        return failures
    invalid_payload_error = payload.get("_invalid_payload_error")
    if isinstance(invalid_payload_error, dict):
        return failures + [invalid_payload_error]
    if artifact_kind == "chromium-webgpu-playwright-smoke":
        for message in validate_smoke_report(
            payload,
            required_modes=("dawn", "doe"),
            require_strict=True,
            require_hash_chain=True,
        ):
            failures.append(
                failure(
                    "comparison_smoke_report_failure",
                    path,
                    message,
                )
            )
    return failures


def check_reference(path_text: Any, path: str, root: Path) -> list[dict[str, str]]:
    if not isinstance(path_text, str) or not path_text:
        return [failure("missing_reference", path, "reference path is required")]
    if not safe_repo_path(path_text):
        return [failure("unsafe_reference", path, f"reference path must be repo-relative: {path_text}")]
    if not root.joinpath(*PurePosixPath(path_text).parts).exists():
        return [failure("missing_reference_file", path, f"missing referenced path: {path_text}")]
    return []


def resolve_reference(path_text: str, root: Path) -> Path | None:
    if not safe_repo_path(path_text):
        return None
    candidate = root.joinpath(*PurePosixPath(path_text).parts)
    try:
        resolved = candidate.resolve()
        resolved.relative_to(root.resolve())
    except (OSError, ValueError):
        return None
    return resolved


def load_reference_payload(path_text: Any, path: str, root: Path) -> tuple[list[dict[str, str]], dict[str, Any] | None]:
    failures = check_reference(path_text, path, root)
    if failures:
        return failures, None
    assert isinstance(path_text, str)
    resolved = resolve_reference(path_text, root)
    if resolved is None or not resolved.is_file():
        return [failure("missing_reference_file", path, f"missing referenced path: {path_text}")], None
    try:
        payload = load_json(resolved)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        return [
            failure(
                "invalid_reference_payload",
                path,
                f"referenced payload is not a JSON object: {exc}",
            )
        ], None
    return [], payload


def prefixed_failures(prefix: str, items: list[dict[str, str]]) -> list[dict[str, str]]:
    return [
        failure(
            item["code"],
            f"{prefix}.{item['path']}",
            item["message"],
        )
        for item in items
    ]


def check_capture_policy_reference(path_text: Any, root: Path) -> list[dict[str, str]]:
    failures, payload = load_reference_payload(path_text, "capturePolicyPath", root)
    if payload is None:
        return failures
    return failures + prefixed_failures(
        "capturePolicyPath",
        capture_policy_check.check_policy(payload),
    )


def check_runtime_identity_reference(path_text: Any, root: Path) -> tuple[list[dict[str, str]], dict[str, Any] | None]:
    failures, payload = load_reference_payload(path_text, "runtimeIdentityPath", root)
    if payload is None:
        return failures, None
    checker = load_runtime_identity_checker()
    return failures + prefixed_failures(
        "runtimeIdentityPath",
        checker.check_identity(payload),
    ), payload


def check_release_provenance(
    provenance: Any,
    path: str,
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    if not isinstance(provenance, dict):
        return [failure("missing_release_provenance", path, "proof page must bind release provenance")]
    failures: list[dict[str, str]] = []
    for field in sorted(REQUIRED_RELEASE_PROVENANCE_FIELDS):
        if field not in provenance:
            failures.append(
                failure(
                    "missing_release_provenance_field",
                    f"{path}.{field}",
                    f"release provenance field is required: {field}",
                )
            )
    product = provenance.get("browserProduct")
    if not isinstance(product, dict):
        failures.append(
            failure("invalid_release_browser_product", f"{path}.browserProduct", "browserProduct must be object")
        )
    else:
        for field in sorted(REQUIRED_BROWSER_PRODUCT_FIELDS):
            value = product.get(field)
            if not isinstance(value, str) or not value:
                failures.append(
                    failure(
                        "missing_release_browser_product_field",
                        f"{path}.browserProduct.{field}",
                        f"browserProduct field is required: {field}",
                    )
                )
    platform = provenance.get("platform")
    if not isinstance(platform, dict):
        failures.append(failure("invalid_release_platform", f"{path}.platform", "platform must be object"))
    else:
        for field in sorted(REQUIRED_PLATFORM_FIELDS):
            value = platform.get(field)
            if not isinstance(value, str) or not value:
                failures.append(
                    failure(
                        "missing_release_platform_field",
                        f"{path}.platform.{field}",
                        f"platform field is required: {field}",
                    )
                )
    failures.extend(
        check_artifact(
            provenance.get("releaseArchive"),
            f"{path}.releaseArchive",
            verify_files_root,
            expected_kind="browser_release_archive",
        )
    )
    release_archive = provenance.get("releaseArchive")
    if isinstance(release_archive, dict) and not is_public_https_url(release_archive.get("downloadUrl")):
        failures.append(
            failure(
                "invalid_release_archive_download_url",
                f"{path}.releaseArchive.downloadUrl",
                "releaseArchive downloadUrl must be public HTTPS",
            )
        )
    failures.extend(
        check_artifact(
            provenance.get("publicDownloadReceipt"),
            f"{path}.publicDownloadReceipt",
            verify_files_root,
            expected_kind="browser_public_download_receipt",
        )
    )
    failures.extend(
        check_artifact(
            provenance.get("releaseArchiveManifest"),
            f"{path}.releaseArchiveManifest",
            verify_files_root,
            expected_kind="browser_release_archive_manifest",
        )
    )
    for field in (
        "browserExecutableArchivePath",
        "browserAppMetadataArchivePath",
        "doeRuntimeArchivePath",
        "dawnFallbackRuntimeArchivePath",
    ):
        value = provenance.get(field)
        if not isinstance(value, str) or not value:
            failures.append(
                failure(
                    "missing_release_member_path",
                    f"{path}.{field}",
                    f"release provenance member path is required: {field}",
                )
            )
    return failures


def release_provenance_fragments(provenance: Any) -> list[tuple[str, str, str]]:
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
        for field, label in (("os", "platform OS"), ("arch", "platform architecture"), ("packageFormat", "package format")):
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


def check_proof_page(
    proof_page: Any,
    verify_files_root: Path | None,
    *,
    proof_surface: dict[str, Any] | None = None,
    runtime_identity_path: Any = None,
    require_diagnostic_receipt: bool = False,
    require_source_text: bool = False,
) -> list[dict[str, str]]:
    if not isinstance(proof_page, dict):
        return [failure("invalid_proof_page", "proofPage", "proofPage must be object")]
    failures: list[dict[str, str]] = []
    failures.extend(
        check_artifact(
            proof_page.get("artifact"),
            "proofPage.artifact",
            verify_files_root,
            expected_kind="browser_proof_page",
        )
    )
    url = proof_page.get("url")
    if not isinstance(url, str) or not url:
        failures.append(failure("missing_proof_page_url", "proofPage.url", "proof page URL is required"))
    elif not (url == "about:doe" or url.startswith("chrome://") or url.startswith("file:")):
        failures.append(
            failure(
                "invalid_proof_page_url",
                "proofPage.url",
                "proof page URL must be about:doe, chrome://, or file:",
            )
        )
    diagnostics = proof_page.get("diagnostics")
    if not isinstance(diagnostics, dict):
        failures.append(
            failure(
                "missing_proof_diagnostics",
                "proofPage.diagnostics",
                "proof page diagnostics are required",
            )
        )
    else:
        for field in sorted(REQUIRED_PROOF_DIAGNOSTICS):
            value = diagnostics.get(field)
            missing = (
                value is not True
                if field == "webgpuAvailable"
                else not isinstance(value, str) or not value
            )
            if missing:
                failures.append(
                    failure(
                        "missing_proof_diagnostic_field",
                        f"proofPage.diagnostics.{field}",
                        f"proof page diagnostic field is required: {field}",
                    )
                )
        product = proof_page.get("releaseProvenance", {}).get("browserProduct")
        channel = product.get("channel") if isinstance(product, dict) else None
        if channel in RELEASE_CHANNELS:
            for field in PROOF_DIAGNOSTIC_STATUS_FIELDS:
                value = diagnostics.get(field)
                if (
                    not isinstance(value, str)
                    or value.lower() in NON_RELEASE_DIAGNOSTIC_STATUS_VALUES
                ):
                    failures.append(
                        failure(
                            "non_release_proof_diagnostic_status",
                            f"proofPage.diagnostics.{field}",
                            f"release proof page diagnostic status must be concrete: {field}",
                        )
                    )
    receipt_ids = proof_page.get("recentReceiptIds")
    if not isinstance(receipt_ids, list) or not receipt_ids:
        failures.append(
            failure(
                "missing_recent_receipt_ids",
                "proofPage.recentReceiptIds",
                "proof page must expose recent receipt IDs",
            )
        )
    receipt_payloads = proof_page.get("receiptPayloads")
    linked_receipt_ids: set[str] = set()
    if not isinstance(receipt_payloads, list) or not receipt_payloads:
        failures.append(
            failure(
                "missing_receipt_payload_links",
                "proofPage.receiptPayloads",
                "proof page must link receipt payloads",
            )
        )
    else:
        for index, artifact in enumerate(receipt_payloads):
            failures.extend(
                check_receipt_artifact(
                    artifact,
                    f"proofPage.receiptPayloads[{index}]",
                    verify_files_root,
                    require_source_text=require_source_text,
                )
            )
            if isinstance(artifact, dict) and isinstance(artifact.get("receiptId"), str):
                linked_receipt_ids.add(artifact["receiptId"])
    gallery_pages = proof_surface.get("galleryPages") if isinstance(proof_surface, dict) else None
    if isinstance(gallery_pages, list):
        for row in gallery_pages:
            if not isinstance(row, dict):
                continue
            for artifact in row.get("receiptArtifacts") or []:
                if isinstance(artifact, dict) and isinstance(artifact.get("receiptId"), str):
                    linked_receipt_ids.add(artifact["receiptId"])
    comparison_receipts = (
        proof_surface.get("comparisonReceipts") if isinstance(proof_surface, dict) else None
    )
    if isinstance(comparison_receipts, list):
        for item in comparison_receipts:
            if not isinstance(item, dict):
                continue
            for field in ("dawnReceipt", "doeReceipt"):
                artifact = item.get(field)
                if isinstance(artifact, dict) and isinstance(artifact.get("receiptId"), str):
                    linked_receipt_ids.add(artifact["receiptId"])
    if isinstance(receipt_ids, list):
        for index, receipt_id in enumerate(receipt_ids):
            if not isinstance(receipt_id, str) or not receipt_id:
                failures.append(
                    failure(
                        "invalid_recent_receipt_id",
                        f"proofPage.recentReceiptIds[{index}]",
                        "recent receipt ID must be a non-empty string",
                    )
                )
            elif linked_receipt_ids and receipt_id not in linked_receipt_ids:
                failures.append(
                    failure(
                        "unlinked_recent_receipt_id",
                        f"proofPage.recentReceiptIds[{index}]",
                        f"recent receipt ID has no linked payload: {receipt_id}",
                    )
                )
    failures.extend(
        check_release_provenance(
            proof_page.get("releaseProvenance"),
            "proofPage.releaseProvenance",
            verify_files_root,
        )
    )
    failures.extend(
        check_proof_page_diagnostic_receipt(
            proof_page,
            verify_files_root,
            runtime_identity_path=runtime_identity_path,
            require_diagnostic_receipt=require_diagnostic_receipt,
        )
    )
    failures.extend(
        check_proof_page_active_backend_matches_doe_receipt(
            proof_page,
            verify_files_root,
        )
    )
    failures.extend(check_proof_page_content(proof_page, verify_files_root, proof_surface))
    return failures


def load_proof_page_receipt_payload(
    artifact: dict[str, Any],
    path: str,
    verify_files_root: Path | None,
) -> dict[str, Any] | None:
    if verify_files_root is None:
        return None
    artifact_path = artifact.get("path")
    artifact_hash = artifact.get("sha256")
    if not (
        isinstance(artifact_path, str)
        and artifact_path
        and isinstance(artifact_hash, str)
        and len(artifact_hash) == 64
    ):
        return None
    resolved = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved is None or not resolved.is_file():
        return None
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return {
            "_invalid_payload_error": failure(
                "invalid_proof_page_receipt_payload",
                f"{path}.path",
                f"proof page receipt payload is not valid JSON: {exc}",
            )
        }
    if not isinstance(payload, dict):
        return {
            "_invalid_payload_error": failure(
                "invalid_proof_page_receipt_payload",
                f"{path}.path",
                "proof page receipt payload must be a JSON object",
            )
        }
    return payload


def check_proof_page_diagnostic_receipt(
    proof_page: dict[str, Any],
    verify_files_root: Path | None,
    *,
    runtime_identity_path: Any,
    require_diagnostic_receipt: bool,
) -> list[dict[str, str]]:
    receipt_artifact = proof_page.get("diagnosticReceipt")
    if receipt_artifact is None:
        if not require_diagnostic_receipt:
            return []
        return [
            failure(
                "missing_proof_page_diagnostic_receipt",
                "proofPage.diagnosticReceipt",
                "release proof page must link a diagnostic page receipt",
            )
        ]
    failures = check_artifact(
        receipt_artifact,
        "proofPage.diagnosticReceipt",
        verify_files_root,
        expected_kind="browser_proof_page_receipt",
    )
    if not isinstance(receipt_artifact, dict):
        return failures
    payload = load_proof_page_receipt_payload(
        receipt_artifact,
        "proofPage.diagnosticReceipt",
        verify_files_root,
    )
    if payload is not None:
        failures.extend(
            check_proof_page_receipt_payload(
                payload,
                proof_page,
                runtime_identity_path,
                verify_files_root,
            )
        )
    return failures


def check_proof_page_receipt_payload(
    payload: dict[str, Any],
    proof_page: dict[str, Any],
    runtime_identity_path: Any,
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    invalid_payload_error = payload.get("_invalid_payload_error")
    if isinstance(invalid_payload_error, dict):
        return [invalid_payload_error]
    failures: list[dict[str, str]] = []
    artifact = proof_page.get("artifact")
    artifact_path = artifact.get("path") if isinstance(artifact, dict) else None
    artifact_sha = artifact.get("sha256") if isinstance(artifact, dict) else None
    if payload.get("schemaVersion") != 1:
        failures.append(
            failure(
                "invalid_proof_page_receipt_schema_version",
                "proofPage.diagnosticReceipt.path",
                "proof page receipt schemaVersion must be 1",
            )
        )
    if payload.get("artifactKind") != "browser_proof_page_receipt":
        failures.append(
            failure(
                "invalid_proof_page_receipt_artifact_kind",
                "proofPage.diagnosticReceipt.path",
                "proof page receipt artifactKind must be browser_proof_page_receipt",
            )
        )
    if not isinstance(payload.get("receiptId"), str) or not payload.get("receiptId"):
        failures.append(
            failure(
                "missing_proof_page_receipt_id",
                "proofPage.diagnosticReceipt.path",
                "proof page receiptId is required",
            )
        )
    if payload.get("url") != proof_page.get("url"):
        failures.append(
            failure(
                "proof_page_receipt_url_mismatch",
                "proofPage.diagnosticReceipt.url",
                "proof page receipt URL must match proofPage.url",
            )
        )
    load_type = payload.get("loadType")
    if proof_page.get("url") == "about:doe":
        expected_load_type = "browser_internal_page"
    else:
        expected_load_type = "file" if isinstance(proof_page.get("url"), str) and proof_page.get("url").startswith("file:") else "browser_internal_page"
    if load_type != expected_load_type:
        failures.append(
            failure(
                "proof_page_receipt_load_type_mismatch",
                "proofPage.diagnosticReceipt.loadType",
                f"proof page receipt loadType must be {expected_load_type}",
            )
        )
    if payload.get("status") != "loaded":
        failures.append(
            failure(
                "invalid_proof_page_receipt_status",
                "proofPage.diagnosticReceipt.status",
                "proof page receipt status must be loaded",
            )
        )
    if payload.get("contentSha256") != artifact_sha:
        failures.append(
            failure(
                "proof_page_receipt_hash_mismatch",
                "proofPage.diagnosticReceipt.contentSha256",
                "proof page receipt contentSha256 must match proof page artifact sha256",
            )
        )
    if not isinstance(payload.get("contentLengthBytes"), int) or payload.get("contentLengthBytes") <= 0:
        failures.append(
            failure(
                "invalid_proof_page_receipt_length",
                "proofPage.diagnosticReceipt.contentLengthBytes",
                "proof page receipt contentLengthBytes must be positive",
            )
        )
    if payload.get("proofArtifactPath") != artifact_path:
        failures.append(
            failure(
                "proof_page_receipt_artifact_path_mismatch",
                "proofPage.diagnosticReceipt.proofArtifactPath",
                "proof page receipt proofArtifactPath must match proof page artifact path",
            )
        )
    if payload.get("runtimeIdentityPath") != runtime_identity_path:
        failures.append(
            failure(
                "proof_page_receipt_runtime_identity_mismatch",
                "proofPage.diagnosticReceipt.runtimeIdentityPath",
                "proof page receipt runtimeIdentityPath must match proof surface runtimeIdentityPath",
            )
        )
    if payload.get("diagnostics") != proof_page.get("diagnostics"):
        failures.append(
            failure(
                "proof_page_receipt_diagnostics_mismatch",
                "proofPage.diagnosticReceipt.diagnostics",
                "proof page receipt diagnostics must match proof page diagnostics",
            )
        )
    if payload.get("recentReceiptIds") != proof_page.get("recentReceiptIds"):
        failures.append(
            failure(
                "proof_page_receipt_recent_ids_mismatch",
                "proofPage.diagnosticReceipt.recentReceiptIds",
                "proof page receipt recentReceiptIds must match proof page recentReceiptIds",
            )
        )
    if payload.get("releaseProvenance") != proof_page.get("releaseProvenance"):
        failures.append(
            failure(
                "proof_page_receipt_release_provenance_mismatch",
                "proofPage.diagnosticReceipt.releaseProvenance",
                "proof page receipt releaseProvenance must match proof page releaseProvenance",
            )
        )
    if not isinstance(payload.get("observedAt"), str) or not payload.get("observedAt"):
        failures.append(
            failure(
                "missing_proof_page_receipt_observed_at",
                "proofPage.diagnosticReceipt.observedAt",
                "proof page receipt observedAt is required",
            )
        )
    if verify_files_root is not None and isinstance(artifact_path, str):
        resolved_proof_page = resolve_artifact_path(artifact_path, verify_files_root)
        content_length = payload.get("contentLengthBytes")
        if (
            resolved_proof_page is not None
            and resolved_proof_page.is_file()
            and isinstance(content_length, int)
            and content_length != resolved_proof_page.stat().st_size
        ):
            failures.append(
                failure(
                    "proof_page_receipt_length_mismatch",
                    "proofPage.diagnosticReceipt.contentLengthBytes",
                    "proof page receipt contentLengthBytes must match proof page artifact size",
                )
            )
    return failures


def recent_receipt_artifact_paths(
    proof_page: dict[str, Any],
    proof_surface: dict[str, Any] | None,
) -> list[tuple[str, str]]:
    recent_ids = {
        item for item in proof_page.get("recentReceiptIds", []) if isinstance(item, str)
    }
    paths: list[tuple[str, str]] = []

    def collect(artifact: Any, label: str) -> None:
        if not isinstance(artifact, dict):
            return
        if artifact.get("receiptId") not in recent_ids:
            return
        path = artifact.get("path")
        if isinstance(path, str) and path and not any(path == item[0] for item in paths):
            paths.append((path, label))

    for index, artifact in enumerate(proof_page.get("receiptPayloads", []) or []):
        collect(artifact, f"proofPage.receiptPayloads[{index}].path")
    if isinstance(proof_surface, dict):
        for row_index, row in enumerate(proof_surface.get("galleryPages", []) or []):
            if not isinstance(row, dict):
                continue
            for artifact_index, artifact in enumerate(row.get("receiptArtifacts", []) or []):
                collect(
                    artifact,
                    f"galleryPages[{row_index}].receiptArtifacts[{artifact_index}].path",
                )
        for item_index, item in enumerate(proof_surface.get("comparisonReceipts", []) or []):
            if not isinstance(item, dict):
                continue
            collect(item.get("dawnReceipt"), f"comparisonReceipts[{item_index}].dawnReceipt.path")
            collect(item.get("doeReceipt"), f"comparisonReceipts[{item_index}].doeReceipt.path")
    return paths


def check_proof_page_content(
    proof_page: dict[str, Any],
    verify_files_root: Path | None,
    proof_surface: dict[str, Any] | None = None,
) -> list[dict[str, str]]:
    if verify_files_root is None:
        return []
    text = artifact_text(proof_page.get("artifact"), verify_files_root)
    if text is None:
        return []
    failures: list[dict[str, str]] = []
    diagnostics = proof_page.get("diagnostics")
    if isinstance(diagnostics, dict):
        for field in sorted(REQUIRED_PROOF_DIAGNOSTICS):
            fragment = diagnostic_visible_fragment(diagnostics.get(field))
            if fragment and fragment not in text:
                failures.append(
                    failure(
                        "proof_page_missing_diagnostic_text",
                        f"proofPage.artifact.{field}",
                        f"proof page artifact must show diagnostic value: {field}",
                    )
                )
    for field_path, label, fragment in release_provenance_fragments(
        proof_page.get("releaseProvenance")
    ):
        if fragment not in text:
            failures.append(
                failure(
                    "proof_page_missing_release_provenance_text",
                    f"proofPage.releaseProvenance.{field_path}",
                    f"proof page artifact must show {label}: {fragment}",
                )
            )
    recent_receipt_ids = proof_page.get("recentReceiptIds")
    if isinstance(recent_receipt_ids, list):
        for index, receipt_id in enumerate(recent_receipt_ids):
            if isinstance(receipt_id, str) and receipt_id and receipt_id not in text:
                failures.append(
                    failure(
                        "proof_page_missing_receipt_id_text",
                        f"proofPage.recentReceiptIds[{index}]",
                        f"proof page artifact must show recent receipt ID: {receipt_id}",
                    )
                )
    for path, path_label in recent_receipt_artifact_paths(proof_page, proof_surface):
        if path not in text:
            failures.append(
                failure(
                    "proof_page_missing_receipt_link",
                    path_label,
                    f"proof page artifact must link receipt payload: {path}",
                )
            )
    return failures


def check_gallery_pages(
    gallery_pages: Any,
    verify_files_root: Path | None,
    root: Path,
    *,
    require_public_urls: bool = False,
    require_source_text: bool = False,
) -> list[dict[str, str]]:
    if not isinstance(gallery_pages, list) or not gallery_pages:
        return [failure("missing_gallery_pages", "galleryPages", "galleryPages must be non-empty")]
    failures: list[dict[str, str]] = []
    categories = {
        row.get("category")
        for row in gallery_pages
        if isinstance(row, dict) and isinstance(row.get("category"), str)
    }
    for category in sorted(REQUIRED_GALLERY_CATEGORIES - categories):
        failures.append(
            failure(
                "missing_gallery_category",
                "galleryPages",
                f"missing required gallery category: {category}",
            )
        )
    for index, row in enumerate(gallery_pages):
        path = f"galleryPages[{index}]"
        if not isinstance(row, dict):
            failures.append(failure("invalid_gallery_page", path, "gallery page must be object"))
            continue
        category = row.get("category")
        if category not in REQUIRED_GALLERY_CATEGORIES:
            failures.append(
                failure(
                    "invalid_gallery_category",
                    f"{path}.category",
                    f"invalid gallery category: {category!r}",
                )
            )
        url = row.get("url")
        if require_public_urls:
            if not isinstance(url, str) or not url:
                failures.append(
                    failure(
                        "missing_gallery_page_url",
                        f"{path}.url",
                        "release proof gallery pages must include a hosted HTTPS URL",
                    )
                )
            elif not is_public_https_url(url):
                failures.append(
                    failure(
                        "invalid_gallery_page_url",
                        f"{path}.url",
                        "release proof gallery page URL must be public HTTPS",
                    )
                )
        failures.extend(
            check_artifact(
                row.get("artifact"),
                f"{path}.artifact",
                verify_files_root,
                expected_kind="browser_gallery_page",
            )
        )
        failures.extend(
            check_public_gallery_receipt(
                row,
                path,
                verify_files_root,
                require_public_receipt=require_public_urls,
            )
        )
        failures.extend(check_reference(row.get("workloadContractPath"), f"{path}.workloadContractPath", root))
        receipt_ids = row.get("receiptIds")
        linked_receipt_ids: set[str] = set()
        linked_workload_ids: list[str] = []
        if not isinstance(receipt_ids, list) or not receipt_ids:
            failures.append(
                failure(
                    "missing_gallery_receipt_ids",
                    f"{path}.receiptIds",
                    "gallery page must expose receipt IDs",
                )
            )
        receipt_artifacts = row.get("receiptArtifacts")
        if not isinstance(receipt_artifacts, list) or not receipt_artifacts:
            failures.append(
                failure(
                    "missing_gallery_receipt_artifacts",
                    f"{path}.receiptArtifacts",
                    "gallery page must link receipt artifacts",
                )
            )
        else:
            for artifact_index, artifact in enumerate(receipt_artifacts):
                failures.extend(
                    check_receipt_artifact(
                        artifact,
                        f"{path}.receiptArtifacts[{artifact_index}]",
                        verify_files_root,
                        require_source_text=require_source_text,
                    )
                )
                if isinstance(artifact, dict) and isinstance(artifact.get("receiptId"), str):
                    linked_receipt_ids.add(artifact["receiptId"])
                if isinstance(artifact, dict):
                    payload = load_artifact_payload(
                        artifact,
                        f"{path}.receiptArtifacts[{artifact_index}]",
                        verify_files_root,
                    )
                    if valid_loaded_payload(payload):
                        assert payload is not None
                        workload_id = payload.get("workloadId")
                        if isinstance(workload_id, str) and workload_id:
                            linked_workload_ids.append(workload_id)
        if isinstance(receipt_ids, list):
            for receipt_index, receipt_id in enumerate(receipt_ids):
                if not isinstance(receipt_id, str) or not receipt_id:
                    failures.append(
                        failure(
                            "invalid_gallery_receipt_id",
                            f"{path}.receiptIds[{receipt_index}]",
                            "gallery receipt ID must be a non-empty string",
                        )
                    )
                elif linked_receipt_ids and receipt_id not in linked_receipt_ids:
                    failures.append(
                        failure(
                            "unlinked_gallery_receipt_id",
                            f"{path}.receiptIds[{receipt_index}]",
                            f"gallery receipt ID has no linked artifact: {receipt_id}",
                        )
                    )
        workload_ids = row.get("workloadIds")
        if not isinstance(workload_ids, list) or not workload_ids:
            failures.append(
                failure(
                    "missing_gallery_workload_ids",
                    f"{path}.workloadIds",
                    "gallery page must expose workload IDs",
                )
            )
        else:
            for workload_index, workload_id in enumerate(workload_ids):
                if not isinstance(workload_id, str) or not workload_id:
                    failures.append(
                        failure(
                            "invalid_gallery_workload_id",
                            f"{path}.workloadIds[{workload_index}]",
                            "gallery workload ID must be a non-empty string",
                        )
                    )
            expected_workload_ids = unique_ordered(linked_workload_ids)
            if expected_workload_ids and workload_ids != expected_workload_ids:
                failures.append(
                    failure(
                        "gallery_workload_ids_mismatch",
                        f"{path}.workloadIds",
                        "gallery workloadIds must match linked receipt payload workloadIds",
                    )
                )
        failures.extend(check_gallery_page_content(row, path, verify_files_root))
    return failures


def load_public_gallery_receipt_payload(
    artifact: dict[str, Any],
    path: str,
    verify_files_root: Path | None,
) -> dict[str, Any] | None:
    if verify_files_root is None:
        return None
    artifact_path = artifact.get("path")
    artifact_hash = artifact.get("sha256")
    if not (
        isinstance(artifact_path, str)
        and artifact_path
        and isinstance(artifact_hash, str)
        and len(artifact_hash) == 64
    ):
        return None
    resolved = resolve_artifact_path(artifact_path, verify_files_root)
    if resolved is None or not resolved.is_file():
        return None
    try:
        payload = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        return {
            "_invalid_payload_error": failure(
                "invalid_gallery_public_receipt_payload",
                f"{path}.path",
                f"gallery public receipt payload is not valid JSON: {exc}",
            )
        }
    if not isinstance(payload, dict):
        return {
            "_invalid_payload_error": failure(
                "invalid_gallery_public_receipt_payload",
                f"{path}.path",
                "gallery public receipt payload must be a JSON object",
            )
        }
    return payload


def check_public_gallery_receipt(
    row: dict[str, Any],
    path: str,
    verify_files_root: Path | None,
    *,
    require_public_receipt: bool,
) -> list[dict[str, str]]:
    receipt_artifact = row.get("publicReceipt")
    if receipt_artifact is None:
        if not require_public_receipt:
            return []
        return [
            failure(
                "missing_gallery_public_receipt",
                f"{path}.publicReceipt",
                "release proof gallery pages must link a public gallery receipt",
            )
        ]
    failures = check_artifact(
        receipt_artifact,
        f"{path}.publicReceipt",
        verify_files_root,
        expected_kind="browser_public_gallery_receipt",
    )
    if not isinstance(receipt_artifact, dict):
        return failures
    payload = load_public_gallery_receipt_payload(
        receipt_artifact,
        f"{path}.publicReceipt",
        verify_files_root,
    )
    if payload is not None:
        failures.extend(check_public_gallery_receipt_payload(payload, row, path, verify_files_root))
    return failures


def check_public_gallery_receipt_payload(
    payload: dict[str, Any],
    row: dict[str, Any],
    path: str,
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    invalid_payload_error = payload.get("_invalid_payload_error")
    if isinstance(invalid_payload_error, dict):
        return [invalid_payload_error]
    failures: list[dict[str, str]] = []
    artifact = row.get("artifact")
    artifact_path = artifact.get("path") if isinstance(artifact, dict) else None
    artifact_sha = artifact.get("sha256") if isinstance(artifact, dict) else None
    if payload.get("schemaVersion") != 1:
        failures.append(
            failure(
                "invalid_gallery_public_receipt_schema_version",
                f"{path}.publicReceipt.path",
                "gallery public receipt schemaVersion must be 1",
            )
        )
    if payload.get("artifactKind") != "browser_public_gallery_receipt":
        failures.append(
            failure(
                "invalid_gallery_public_receipt_artifact_kind",
                f"{path}.publicReceipt.path",
                "gallery public receipt artifactKind must be browser_public_gallery_receipt",
            )
        )
    if not isinstance(payload.get("receiptId"), str) or not payload.get("receiptId"):
        failures.append(
            failure(
                "missing_gallery_public_receipt_id",
                f"{path}.publicReceipt.path",
                "gallery public receiptId is required",
            )
        )
    if payload.get("category") != row.get("category"):
        failures.append(
            failure(
                "gallery_public_receipt_category_mismatch",
                f"{path}.publicReceipt.category",
                "gallery public receipt category must match gallery page category",
            )
        )
    if payload.get("url") != row.get("url"):
        failures.append(
            failure(
                "gallery_public_receipt_url_mismatch",
                f"{path}.publicReceipt.url",
                "gallery public receipt URL must match gallery page URL",
            )
        )
    elif not is_public_https_url(payload.get("url")):
        failures.append(
            failure(
                "invalid_gallery_public_receipt_url",
                f"{path}.publicReceipt.url",
                "gallery public receipt URL must be public HTTPS",
            )
        )
    if payload.get("method") != "GET":
        failures.append(
            failure(
                "invalid_gallery_public_receipt_method",
                f"{path}.publicReceipt.method",
                "gallery public receipt method must be GET",
            )
        )
    if payload.get("statusCode") != 200:
        failures.append(
            failure(
                "invalid_gallery_public_receipt_status",
                f"{path}.publicReceipt.statusCode",
                "gallery public receipt statusCode must be 200",
            )
        )
    if payload.get("contentSha256") != artifact_sha:
        failures.append(
            failure(
                "gallery_public_receipt_hash_mismatch",
                f"{path}.publicReceipt.contentSha256",
                "gallery public receipt contentSha256 must match gallery artifact sha256",
            )
        )
    if not isinstance(payload.get("contentLengthBytes"), int) or payload.get("contentLengthBytes") <= 0:
        failures.append(
            failure(
                "invalid_gallery_public_receipt_length",
                f"{path}.publicReceipt.contentLengthBytes",
                "gallery public receipt contentLengthBytes must be positive",
            )
        )
    if payload.get("galleryArtifactPath") != artifact_path:
        failures.append(
            failure(
                "gallery_public_receipt_artifact_path_mismatch",
                f"{path}.publicReceipt.galleryArtifactPath",
                "gallery public receipt galleryArtifactPath must match gallery artifact path",
            )
        )
    if payload.get("workloadContractPath") != row.get("workloadContractPath"):
        failures.append(
            failure(
                "gallery_public_receipt_contract_mismatch",
                f"{path}.publicReceipt.workloadContractPath",
                "gallery public receipt workloadContractPath must match gallery page",
            )
        )
    if payload.get("workloadIds") != row.get("workloadIds"):
        failures.append(
            failure(
                "gallery_public_receipt_workload_ids_mismatch",
                f"{path}.publicReceipt.workloadIds",
                "gallery public receipt workloadIds must match gallery page",
            )
        )
    if payload.get("receiptIds") != row.get("receiptIds"):
        failures.append(
            failure(
                "gallery_public_receipt_ids_mismatch",
                f"{path}.publicReceipt.receiptIds",
                "gallery public receipt receiptIds must match gallery page",
            )
        )
    receipt_artifacts = row.get("receiptArtifacts")
    receipt_artifact_paths = [
        artifact.get("path")
        for artifact in receipt_artifacts
        if isinstance(artifact, dict) and isinstance(artifact.get("path"), str)
    ] if isinstance(receipt_artifacts, list) else []
    if payload.get("receiptArtifactPaths") != receipt_artifact_paths:
        failures.append(
            failure(
                "gallery_public_receipt_artifact_paths_mismatch",
                f"{path}.publicReceipt.receiptArtifactPaths",
                "gallery public receipt receiptArtifactPaths must match gallery receipt artifacts",
            )
        )
    if not isinstance(payload.get("observedAt"), str) or not payload.get("observedAt"):
        failures.append(
            failure(
                "missing_gallery_public_receipt_observed_at",
                f"{path}.publicReceipt.observedAt",
                "gallery public receipt observedAt is required",
            )
        )
    if verify_files_root is not None and isinstance(artifact_path, str):
        resolved_gallery = resolve_artifact_path(artifact_path, verify_files_root)
        content_length = payload.get("contentLengthBytes")
        if (
            resolved_gallery is not None
            and resolved_gallery.is_file()
            and isinstance(content_length, int)
            and content_length != resolved_gallery.stat().st_size
        ):
            failures.append(
                failure(
                    "gallery_public_receipt_length_mismatch",
                    f"{path}.publicReceipt.contentLengthBytes",
                    "gallery public receipt contentLengthBytes must match gallery artifact size",
                )
            )
    return failures


def check_gallery_page_content(
    row: dict[str, Any],
    path: str,
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    if verify_files_root is None:
        return []
    text = artifact_text(row.get("artifact"), verify_files_root)
    if text is None:
        return []
    failures: list[dict[str, str]] = []
    category = row.get("category")
    if isinstance(category, str) and category and category not in text:
        failures.append(
            failure(
                "gallery_page_missing_category_text",
                f"{path}.artifact",
                f"gallery page artifact must show category: {category}",
            )
        )
    contract_path = row.get("workloadContractPath")
    if isinstance(contract_path, str) and contract_path and contract_path not in text:
        failures.append(
            failure(
                "gallery_page_missing_contract_link",
                f"{path}.workloadContractPath",
                f"gallery page artifact must link workload contract: {contract_path}",
            )
        )
    receipt_ids = row.get("receiptIds")
    if isinstance(receipt_ids, list):
        for index, receipt_id in enumerate(receipt_ids):
            if isinstance(receipt_id, str) and receipt_id and receipt_id not in text:
                failures.append(
                    failure(
                        "gallery_page_missing_receipt_id_text",
                        f"{path}.receiptIds[{index}]",
                        f"gallery page artifact must show receipt ID: {receipt_id}",
                    )
                )
    workload_ids = row.get("workloadIds")
    if isinstance(workload_ids, list):
        for index, workload_id in enumerate(workload_ids):
            if isinstance(workload_id, str) and workload_id and workload_id not in text:
                failures.append(
                    failure(
                        "gallery_page_missing_workload_id_text",
                        f"{path}.workloadIds[{index}]",
                        f"gallery page artifact must show workload ID: {workload_id}",
                    )
                )
    receipt_artifacts = row.get("receiptArtifacts")
    if isinstance(receipt_artifacts, list):
        for index, artifact in enumerate(receipt_artifacts):
            if not isinstance(artifact, dict):
                continue
            artifact_path = artifact.get("path")
            if isinstance(artifact_path, str) and artifact_path and artifact_path not in text:
                failures.append(
                    failure(
                        "gallery_page_missing_receipt_link",
                        f"{path}.receiptArtifacts[{index}].path",
                        f"gallery page artifact must link receipt artifact: {artifact_path}",
                    )
                )
            payload = load_artifact_payload(
                artifact,
                f"{path}.receiptArtifacts[{index}]",
                verify_files_root,
            )
            if not valid_loaded_payload(payload):
                continue
            assert payload is not None
            for label, fragment in receipt_visibility_fragments(payload):
                if not visible_fragment_present(text, fragment):
                    failures.append(
                        failure(
                            "gallery_page_missing_receipt_fact_text",
                            f"{path}.receiptArtifacts[{index}]",
                            f"gallery page artifact must show receipt {label}: {fragment}",
                        )
                    )
    return failures


def comparison_visibility_requirements(
    row: dict[str, Any],
    path: str,
) -> list[tuple[str, str, str, str]]:
    requirements: list[tuple[str, str, str, str]] = []
    comparison_id = row.get("comparisonId")
    if isinstance(comparison_id, str) and comparison_id:
        requirements.append(
            (
                "comparison_id_text",
                f"{path}.comparisonId",
                "comparison ID",
                comparison_id,
            )
        )
    workload_id = row.get("workloadId")
    if isinstance(workload_id, str) and workload_id:
        requirements.append(
            (
                "comparison_workload_text",
                f"{path}.workloadId",
                "comparison workload ID",
                workload_id,
            )
        )
    comparison_artifact = row.get("comparisonArtifact")
    if isinstance(comparison_artifact, dict):
        artifact_path = comparison_artifact.get("path")
        if isinstance(artifact_path, str) and artifact_path:
            requirements.append(
                (
                    "comparison_artifact_link",
                    f"{path}.comparisonArtifact.path",
                    "comparison artifact",
                    artifact_path,
                )
            )
    runner = row.get("runner")
    if isinstance(runner, dict):
        for field, label in (("pageArtifactPath", "comparison runner page"), ("executionScope", "comparison runner scope")):
            value = runner.get(field)
            if isinstance(value, str) and value:
                requirements.append((f"comparison_runner_{field}", f"{path}.runner.{field}", label, value))
        modes = runner.get("modes")
        if isinstance(modes, list):
            for mode in modes:
                if isinstance(mode, str) and mode:
                    requirements.append(("comparison_runner_mode_text", f"{path}.runner.modes", "comparison runner mode", mode))
        if runner.get("emitsSideBySideReceipts") is True:
            requirements.append(("comparison_runner_receipts_text", f"{path}.runner.emitsSideBySideReceipts", "comparison runner receipt emission", "side_by_side_receipts"))
    for field, label in (("dawnReceipt", "Dawn"), ("doeReceipt", "Doe")):
        receipt = row.get(field)
        if not isinstance(receipt, dict):
            continue
        receipt_id = receipt.get("receiptId")
        if isinstance(receipt_id, str) and receipt_id:
            requirements.append(
                (
                    "comparison_receipt_id_text",
                    f"{path}.{field}.receiptId",
                    f"{label} receipt ID",
                    receipt_id,
                )
            )
        receipt_path = receipt.get("path")
        if isinstance(receipt_path, str) and receipt_path:
            requirements.append(
                (
                    "comparison_receipt_link",
                    f"{path}.{field}.path",
                    f"{label} receipt payload",
                    receipt_path,
                )
            )
    return requirements


def check_comparison_surface_visibility(
    proof_page: Any,
    gallery_pages: Any,
    comparison_receipts: Any,
    verify_files_root: Path | None,
) -> list[dict[str, str]]:
    if verify_files_root is None or not isinstance(comparison_receipts, list):
        return []
    failures: list[dict[str, str]] = []
    proof_text = (
        artifact_text(proof_page.get("artifact"), verify_files_root)
        if isinstance(proof_page, dict)
        else None
    )
    gallery_texts: list[str] = []
    if isinstance(gallery_pages, list):
        for row in gallery_pages:
            if not isinstance(row, dict):
                continue
            text = artifact_text(row.get("artifact"), verify_files_root)
            if text is not None:
                gallery_texts.append(text)
    for index, row in enumerate(comparison_receipts):
        path = f"comparisonReceipts[{index}]"
        if not isinstance(row, dict):
            continue
        requirements = comparison_visibility_requirements(row, path)
        if proof_text is not None:
            for code_suffix, requirement_path, label, fragment in requirements:
                if fragment not in proof_text:
                    failures.append(
                        failure(
                            f"proof_page_missing_{code_suffix}",
                            requirement_path,
                            f"proof page artifact must expose {label}: {fragment}",
                        )
                    )
        if gallery_texts and not any(
            all(fragment in text for _, _, _, fragment in requirements)
            for text in gallery_texts
        ):
            failures.append(
                failure(
                    "gallery_page_missing_comparison_mode",
                    path,
                    "at least one gallery page artifact must expose the comparison ID, workload ID, comparison artifact, and both Dawn/Doe receipt links",
                )
            )
    return failures


def check_comparison_runner(row: dict[str, Any], path: str, gallery_pages: Any, verify_files_root: Path | None) -> list[dict[str, str]]:
    runner = row.get("runner")
    if not isinstance(runner, dict):
        return [failure("missing_comparison_runner", f"{path}.runner", "comparison receipt must bind a same-page Dawn/Doe runner")]
    failures: list[dict[str, str]] = []
    page_path = runner.get("pageArtifactPath")
    gallery_by_path = {
        artifact.get("path"): gallery
        for gallery in (gallery_pages if isinstance(gallery_pages, list) else [])
        if isinstance(gallery, dict)
        for artifact in [gallery.get("artifact")]
        if isinstance(artifact, dict) and isinstance(artifact.get("path"), str)
    }
    if not isinstance(page_path, str) or not page_path:
        failures.append(failure("missing_comparison_runner_page", f"{path}.runner.pageArtifactPath", "comparison runner pageArtifactPath is required"))
    elif gallery_by_path and page_path not in gallery_by_path:
        failures.append(failure("comparison_runner_page_not_gallery", f"{path}.runner.pageArtifactPath", "comparison runner pageArtifactPath must match a gallery page artifact"))
    if runner.get("executionScope") != "same_page":
        failures.append(failure("invalid_comparison_runner_scope", f"{path}.runner.executionScope", "comparison runner executionScope must be same_page"))
    if runner.get("modes") != ["dawn", "doe"]:
        failures.append(failure("invalid_comparison_runner_modes", f"{path}.runner.modes", "comparison runner modes must be dawn then doe"))
    if runner.get("emitsSideBySideReceipts") is not True:
        failures.append(failure("comparison_runner_missing_side_by_side_receipts", f"{path}.runner.emitsSideBySideReceipts", "comparison runner must emit side-by-side receipts"))
    gallery = gallery_by_path.get(page_path)
    text = artifact_text(gallery.get("artifact"), verify_files_root) if isinstance(gallery, dict) else None
    if text is not None and not all(fragment in text for _, _, _, fragment in comparison_visibility_requirements(row, path)):
        failures.append(failure("comparison_runner_page_missing_comparison_mode", f"{path}.runner.pageArtifactPath", "comparison runner page must expose the same-page Dawn/Doe comparison evidence"))
    return failures


def check_comparison_policy(
    policy: Any,
    path: str,
    dawn_payload: dict[str, Any] | None = None,
    doe_payload: dict[str, Any] | None = None,
) -> list[dict[str, str]]:
    if not isinstance(policy, dict):
        return [
            failure(
                "missing_comparison_policy",
                f"{path}.comparisonPolicy",
                "comparison receipt must declare the paired evidence policy",
            )
        ]
    failures: list[dict[str, str]] = []
    for field in sorted(REQUIRED_COMPARISON_POLICY_FIELDS):
        value = policy.get(field)
        if not isinstance(value, str) or not value:
            failures.append(
                failure(
                    "missing_comparison_policy_field",
                    f"{path}.comparisonPolicy.{field}",
                    f"comparison policy field is required: {field}",
                )
            )
    expected_values = {
        "adapterDeviceIdentity": "same_device_identity",
        "commandCoverage": "exact_match",
        "fallbackPolicy": "no_hidden_fallback",
        "sourceShaderIdentity": "same_source_shader_identity",
        "workloadIdentity": "same_workload_id",
    }
    for field, expected in expected_values.items():
        if policy.get(field) != expected:
            failures.append(
                failure(
                    "invalid_comparison_policy_value",
                    f"{path}.comparisonPolicy.{field}",
                    f"comparison policy {field} must be {expected}",
                )
            )
    if policy.get("outputIdentity") not in {"same_output_hash", "same_frame_hash"}:
        failures.append(
            failure(
                "invalid_comparison_policy_value",
                f"{path}.comparisonPolicy.outputIdentity",
                "comparison policy outputIdentity must be same_output_hash or same_frame_hash",
            )
        )
    if valid_loaded_payload(dawn_payload) and valid_loaded_payload(doe_payload):
        assert dawn_payload is not None
        assert doe_payload is not None
        timing = timing_class(dawn_payload)
        if policy.get("timingScope") != timing or timing != timing_class(doe_payload):
            failures.append(
                failure(
                    "comparison_policy_timing_scope_mismatch",
                    f"{path}.comparisonPolicy.timingScope",
                    "comparison policy timingScope must match both receipt timing classes",
                )
            )
        output_policy = output_identity_kind(dawn_payload)
        if policy.get("outputIdentity") != output_policy or output_policy != output_identity_kind(doe_payload):
            failures.append(
                failure(
                    "comparison_policy_output_identity_mismatch",
                    f"{path}.comparisonPolicy.outputIdentity",
                    "comparison policy outputIdentity must match both receipt output identity kinds",
                )
            )
    return failures


def comparison_mode_result(payload: dict[str, Any], mode: str) -> dict[str, Any] | None:
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


def check_comparison_mode_result_receipt_binding(
    *,
    mode_result: dict[str, Any],
    receipt_payload: dict[str, Any],
    mode: str,
    path: str,
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
                    "comparison_artifact_receipt_identity_mismatch",
                    path,
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
                        "comparison_artifact_receipt_identity_mismatch",
                        path,
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
                    "comparison_artifact_receipt_identity_mismatch",
                    path,
                    (
                        f"comparison artifact {label} modeResult adapterIdentity.{source_field} "
                        f"must match {label} execution receipt device.{field}"
                    ),
                )
            )
    return failures


def check_comparison_artifact_receipt_bindings(
    comparison_payload: dict[str, Any] | None,
    dawn_payload: dict[str, Any] | None,
    doe_payload: dict[str, Any] | None,
    path: str,
) -> list[dict[str, str]]:
    if (
        not valid_loaded_payload(comparison_payload)
        or not valid_loaded_payload(dawn_payload)
        or not valid_loaded_payload(doe_payload)
    ):
        return []
    assert comparison_payload is not None
    assert dawn_payload is not None
    assert doe_payload is not None
    failures: list[dict[str, str]] = []
    for mode, receipt_payload in (("dawn", dawn_payload), ("doe", doe_payload)):
        mode_result = comparison_mode_result(comparison_payload, mode)
        if not isinstance(mode_result, dict):
            continue
        failures.extend(
            check_comparison_mode_result_receipt_binding(
                mode_result=mode_result,
                receipt_payload=receipt_payload,
                mode=mode,
                path=path,
            )
        )
    return failures


def check_comparison_receipts(
    comparison_receipts: Any,
    verify_files_root: Path | None,
    gallery_pages: Any = None,
    *,
    require_source_text: bool = False,
) -> list[dict[str, str]]:
    if not isinstance(comparison_receipts, list) or not comparison_receipts:
        return [
            failure(
                "missing_comparison_receipts",
                "comparisonReceipts",
                "published proof surface must link paired comparison receipts",
            )
        ]
    failures: list[dict[str, str]] = []
    for index, row in enumerate(comparison_receipts):
        path = f"comparisonReceipts[{index}]"
        if not isinstance(row, dict):
            failures.append(failure("invalid_comparison_receipt", path, "comparison receipt must be object"))
            continue
        for field in ["comparisonId", "workloadId"]:
            if not isinstance(row.get(field), str) or not row.get(field):
                failures.append(
                    failure(
                        "missing_comparison_receipt_field",
                        f"{path}.{field}",
                        f"comparison receipt field is required: {field}",
                    )
                )
        failures.extend(check_comparison_runner(row, path, gallery_pages, verify_files_root))
        failures.extend(
            check_artifact(
                row.get("comparisonArtifact"),
                f"{path}.comparisonArtifact",
                verify_files_root,
            )
        )
        failures.extend(
            check_comparison_artifact_payload(
                row.get("comparisonArtifact"),
                f"{path}.comparisonArtifact",
                verify_files_root,
            )
        )
        failures.extend(
            check_receipt_artifact(
                row.get("dawnReceipt"),
                f"{path}.dawnReceipt",
                verify_files_root,
                expected_runtime="dawn",
                require_source_text=require_source_text,
            )
        )
        failures.extend(
            check_receipt_artifact(
                row.get("doeReceipt"),
                f"{path}.doeReceipt",
                verify_files_root,
                expected_runtime="doe",
                require_source_text=require_source_text,
            )
        )
        dawn = row.get("dawnReceipt")
        doe = row.get("doeReceipt")
        if isinstance(dawn, dict) and isinstance(doe, dict):
            if dawn.get("receiptId") == doe.get("receiptId"):
                failures.append(
                    failure(
                        "unpaired_comparison_receipt_ids",
                        path,
                        "Dawn and Doe comparison receipts must use distinct receipt IDs",
                    )
                )
            if dawn.get("path") == doe.get("path"):
                failures.append(
                    failure(
                        "unpaired_comparison_receipt_paths",
                        path,
                        "Dawn and Doe comparison receipts must link distinct payload paths",
                    )
                )
            dawn_payload = load_artifact_payload(dawn, f"{path}.dawnReceipt", verify_files_root)
            doe_payload = load_artifact_payload(doe, f"{path}.doeReceipt", verify_files_root)
            comparison_payload = (
                load_comparison_artifact_payload(
                    row["comparisonArtifact"],
                    f"{path}.comparisonArtifact",
                    verify_files_root,
                )
                if isinstance(row.get("comparisonArtifact"), dict)
                else None
            )
            failures.extend(
                check_comparison_artifact_receipt_bindings(
                    comparison_payload,
                    dawn_payload,
                    doe_payload,
                    path,
                )
            )
            failures.extend(
                check_comparison_policy(
                    row.get("comparisonPolicy"),
                    path,
                    dawn_payload,
                    doe_payload,
                )
            )
            if valid_loaded_payload(dawn_payload) and valid_loaded_payload(doe_payload):
                assert dawn_payload is not None
                assert doe_payload is not None
                row_workload_id = row.get("workloadId")
                for label, payload in (("dawnReceipt", dawn_payload), ("doeReceipt", doe_payload)):
                    if payload.get("workloadId") != row_workload_id:
                        failures.append(
                            failure(
                                "comparison_workload_id_mismatch",
                                f"{path}.{label}",
                                "comparison workloadId must match each receipt payload workloadId",
                            )
                        )
                if source_shader_identity(dawn_payload) != source_shader_identity(doe_payload):
                    failures.append(
                        failure(
                            "comparison_source_identity_mismatch",
                            path,
                            "Dawn and Doe comparison receipts must bind the same source shader identity",
                        )
                    )
                if output_identity(dawn_payload) != output_identity(doe_payload):
                    failures.append(
                        failure(
                            "comparison_output_identity_mismatch",
                            path,
                            "Dawn and Doe comparison receipts must bind the same output identity",
                        )
                    )
                if timing_class(dawn_payload) != timing_class(doe_payload):
                    failures.append(
                        failure(
                            "comparison_timing_class_mismatch",
                            path,
                            "Dawn and Doe comparison receipts must use the same timing class",
                        )
                    )
                if dawn_payload.get("commandCoverage") != doe_payload.get("commandCoverage"):
                    failures.append(
                        failure(
                            "comparison_command_coverage_mismatch",
                            path,
                            "Dawn and Doe comparison receipts must prove matching command coverage",
                        )
                    )
                if dawn_payload.get("device") != doe_payload.get("device"):
                    failures.append(
                        failure(
                            "comparison_device_identity_mismatch",
                            path,
                            "Dawn and Doe comparison receipts must use matching device identity",
                        )
                    )
                if dawn_payload.get("driver") != doe_payload.get("driver"):
                    failures.append(
                        failure(
                            "comparison_driver_identity_mismatch",
                            path,
                            "Dawn and Doe comparison receipts must use matching driver identity",
                        )
                    )
        else:
            failures.extend(check_comparison_policy(row.get("comparisonPolicy"), path))
    return failures


def check_surface(
    payload: dict[str, Any],
    *,
    verify_files_root: Path | None = None,
    root: Path = REPO_ROOT,
    require_public_urls: bool = False,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("schemaVersion") != 1:
        failures.append(failure("invalid_schema_version", "schemaVersion", "schemaVersion must be 1"))
    if payload.get("artifactKind") != "browser_published_proof_surface":
        failures.append(
            failure(
                "invalid_artifact_kind",
                "artifactKind",
                "artifactKind must be browser_published_proof_surface",
            )
        )
    if not isinstance(payload.get("surfaceId"), str) or not payload.get("surfaceId"):
        failures.append(failure("missing_surface_id", "surfaceId", "surfaceId is required"))
    failures.extend(check_capture_policy_reference(payload.get("capturePolicyPath"), root))
    runtime_identity_failures, runtime_identity = check_runtime_identity_reference(
        payload.get("runtimeIdentityPath"),
        root,
    )
    failures.extend(runtime_identity_failures)
    if runtime_identity is not None:
        selected_runtime = runtime_identity.get("selectedRuntime")
        if selected_runtime != "doe":
            failures.append(
                failure(
                    "proof_surface_runtime_not_doe",
                    "runtimeIdentityPath.selectedRuntime",
                    "published Doe proof surface must bind a Doe runtime identity",
                )
            )
        if runtime_identity.get("doeRuntimeActive") is not True:
            failures.append(
                failure(
                    "proof_surface_doe_runtime_inactive",
                    "runtimeIdentityPath.doeRuntimeActive",
                    "published Doe proof surface must bind active Doe runtime evidence",
                )
            )
        proof_page = payload.get("proofPage")
        diagnostics = proof_page.get("diagnostics") if isinstance(proof_page, dict) else None
        if isinstance(diagnostics, dict) and isinstance(selected_runtime, str):
            active_runtime = diagnostics.get("activeRuntime")
            if active_runtime != selected_runtime:
                failures.append(
                    failure(
                        "proof_page_runtime_identity_mismatch",
                        "proofPage.diagnostics.activeRuntime",
                        "proof page active runtime must match runtime identity selectedRuntime",
                    )
                )
    failures.extend(
        check_proof_page(
            payload.get("proofPage"),
            verify_files_root,
            proof_surface=payload,
            runtime_identity_path=payload.get("runtimeIdentityPath"),
            require_diagnostic_receipt=require_public_urls,
            require_source_text=require_public_urls,
        )
    )
    failures.extend(
        check_gallery_pages(
            payload.get("galleryPages"),
            verify_files_root,
            root,
            require_public_urls=require_public_urls,
            require_source_text=require_public_urls,
        )
    )
    failures.extend(
        check_comparison_receipts(
            payload.get("comparisonReceipts"),
            verify_files_root,
            payload.get("galleryPages"),
            require_source_text=require_public_urls,
        )
    )
    failures.extend(
        check_comparison_surface_visibility(
            payload.get("proofPage"),
            payload.get("galleryPages"),
            payload.get("comparisonReceipts"),
            verify_files_root,
        )
    )
    return failures


def build_report(
    surface_path: Path,
    *,
    verify_files_root: Path | None = None,
    require_public_urls: bool = False,
) -> dict[str, Any]:
    failures = check_surface(
        load_json(surface_path),
        verify_files_root=verify_files_root,
        root=REPO_ROOT,
        require_public_urls=require_public_urls,
    )
    return {
        "schemaVersion": 1,
        "artifactKind": "browser_published_proof_surface_check",
        "surfacePath": repo_relative(surface_path),
        "surfaceSha256": sha256_file(surface_path),
        "verifyFilesRootProvided": verify_files_root is not None,
        "requirePublicUrls": require_public_urls,
        "status": "fail" if failures else "pass",
        "failures": failures,
    }


def main() -> int:
    args = parse_args()
    surface_path = Path(args.surface)
    verify_files_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    report = build_report(
        surface_path,
        verify_files_root=verify_files_root,
        require_public_urls=args.require_public_urls,
    )
    failures = report["failures"]
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: browser published proof surface")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser published proof surface")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
