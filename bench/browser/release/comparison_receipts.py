"""Comparison receipts for browser release evidence."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from bench.browser.browser_gate import validate_smoke_report
from bench.browser.release.artifacts import (
    failure,
    sha256_file,
    unsafe_repo_path_reason,
)
from bench.browser.release.execution_receipts import (
    command_coverage_identity,
    command_evidence_artifact_paths,
    command_evidence_hashes,
    command_evidence_identity,
    load_execution_receipt_payload,
    output_identity,
    output_identity_kind,
    timing_class,
)
from bench.browser.release.receipt_state import (
    source_shader_identity,
    strict_sha256,
    validate_comparison_policy_payload_binding,
)

BROWSER_COMPARISON_ARTIFACT_KIND = "chromium-webgpu-playwright-smoke"


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
    mode = (
        expected_mode
        or selection.get("selectedRuntime")
        or selection.get("selectionMode")
    )
    checks = (
        ("browserExecutableSha256", "browserBinary"),
        ("dawnRuntimeSha256", "dawnFallbackRuntime"),
    )
    if mode == "doe":
        checks += (("doeLibSha256", "doeRuntime"),)

    failures: list[dict[str, str]] = []
    for identity_field, bundle_field in checks:
        expected_sha = release_bundle_artifact_sha256(release_bundle, bundle_field)
        if (
            expected_sha is not None
            and artifact_identity.get(identity_field) == expected_sha
        ):
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
    expected_modes = (
        runner.get("modes") if isinstance(runner, dict) else ["dawn", "doe"]
    )
    expected_timing_class = (
        policy.get("timingScope") if isinstance(policy, dict) else None
    )

    checks: tuple[tuple[Any, Any, str], ...] = (
        (
            payload.get("reportKind"),
            BROWSER_COMPARISON_ARTIFACT_KIND,
            "comparison artifact reportKind must identify the strict browser smoke report",
        ),
        (
            payload.get("mode"),
            "both",
            "comparison artifact mode must run both runtimes",
        ),
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


def expected_device_adapter_label(
    adapter_identity: dict[str, Any],
) -> tuple[str, str] | None:
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
    hashes = {value for value in (artifact.get("sha256"),) if strict_sha256(value)}
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
