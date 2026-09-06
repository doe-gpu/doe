"""Execution receipts for browser release evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from bench.browser.release.artifacts import (
    failure,
    nested_value,
    non_bool_int,
    sha256_file,
    unsafe_receipt_path_reason,
)
from bench.browser.release.receipt_state import (
    strict_sha256,
    validate_backend_runtime_binding_payload,
    validate_lowering_path_runtime_binding_payload,
    validate_no_hidden_fallback_payload,
    validate_output_identity_payload,
    validate_source_shader_hash_alias_payload,
    validate_source_shader_metadata_payload,
    validate_timing_payload,
)

BROWSER_EXECUTION_RECEIPT_KIND = "browser_execution_receipt"

COMMAND_EVIDENCE_HASH_FIELDS = ("sha256", "hash", "graphSha256", "artifactSha256")


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
        if (
            isinstance(artifact_path, str)
            and artifact_path
            and artifact_path not in paths
        ):
            paths.append(artifact_path)
    return paths


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
        elif (
            non_bool_int(command_count)
            and command_count > 0
            and dispatch_count > command_count
        ):
            failures.append(
                failure(
                    "browser_release_proof_surface_receipt_incomplete",
                    proof_surface_path,
                    "execution receipt commandCoverage.dispatchCount cannot exceed commandCount",
                )
            )
    return failures


def command_evidence_has_hash(evidence: dict[str, Any]) -> bool:
    return any(
        strict_sha256(evidence.get(field)) for field in COMMAND_EVIDENCE_HASH_FIELDS
    )


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
                refs.extend(
                    (artifact, None)
                    for artifact in artifacts
                    if isinstance(artifact, dict)
                )

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
