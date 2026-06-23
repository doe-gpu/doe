#!/usr/bin/env python3
"""Validate the Chromium WebGPU integration overlay."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.browser.browser_gate import validate_runtime_selection, validate_smoke_report
from bench.lib.bench_utils import load_json_object as load_json


EXPECTED_SURFACE_ID = "doe-chromium"
VALID_STATUSES = {
    "passing",
    "not_supported",
    "diagnostic_wrapper_only",
    "source_patch_required",
    "implemented_untested_in_browser",
}
VALID_PHASES = {
    "wrapper_diagnostic",
    "source_selector_required",
    "source_selector_wired",
    "source_selector_runtime_bootstrap_gated",
    "source_selector_wire_runtime_active",
    "chromium_runtime_active",
}
REQUIRED_PASSING_CAPABILITIES = {
    "copyExternalImageToTexture",
    "requestAdapter",
    "requestDevice",
    "requestAdapter_xrCompatible",
    "computeDispatch",
    "renderDraw",
    "renderBundles",
    "renderPassIndirectDraw",
    "canvasContext",
    "bufferMapAsync",
    "copyTextureToBuffer",
    "copyBufferToBuffer",
    "queueWriteBuffer",
    "queueOnSubmittedWorkDone",
    "importExternalTexture",
    "textureDestroy",
    "querySetTimestamp",
}
REQUIRED_WIRE_NOTES = {
    "architecture",
    "instanceLifetime",
    "externalTextureGap",
}
SOURCE_RUNTIME_EVIDENCE_PHASES = {
    "source_selector_wire_runtime_active",
    "chromium_runtime_active",
}
REQUIRED_SOURCE_MODES = ("dawn", "doe")
SOURCE_CHROMIUM_OUT_PARTS = ("browser", "chromium", "src", "out")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--overlay", required=True, help="Chromium integration overlay JSON.")
    parser.add_argument(
        "--verify-artifact-root",
        default="",
        help="Optional root used to verify the referenced smoke artifact exists.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def _text(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def resolve_repo_path(root: Path, path_text: str) -> Path:
    return root.joinpath(*PurePosixPath(path_text).parts)


def path_contains_parts(path_text: str, required_parts: tuple[str, ...]) -> bool:
    if not path_text:
        return False
    parts = PurePosixPath(path_text.replace("\\", "/")).parts
    required_count = len(required_parts)
    return any(
        parts[index : index + required_count] == required_parts
        for index in range(0, len(parts) - required_count + 1)
    )


def source_chromium_binary_path(path_text: str) -> bool:
    return path_contains_parts(path_text, SOURCE_CHROMIUM_OUT_PARTS)


def doe_runtime_library_path(path_text: str) -> bool:
    if not path_text:
        return False
    name = PurePosixPath(path_text.replace("\\", "/")).name
    return name.startswith("libwebgpu_doe")


def runtime_selection_artifact(selection: dict[str, Any]) -> dict[str, Any]:
    artifact = selection.get("artifactIdentity")
    return artifact if isinstance(artifact, dict) else {}


def check_overlay(
    payload: dict[str, Any],
    *,
    verify_artifact_root: Path | None = None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("schemaVersion") != 1:
        failures.append(
            failure("invalid_schema_version", "schemaVersion", "schemaVersion must be 1")
        )
    if payload.get("surfaceId") != EXPECTED_SURFACE_ID:
        failures.append(
            failure(
                "invalid_surface_id",
                "surfaceId",
                f"surfaceId must be {EXPECTED_SURFACE_ID}",
            )
        )
    phase = payload.get("integrationPhase")
    if phase not in VALID_PHASES:
        failures.append(
            failure(
                "invalid_integration_phase",
                "integrationPhase",
                "integrationPhase must be wrapper_diagnostic, source_selector_required, source_selector_wired, source_selector_runtime_bootstrap_gated, source_selector_wire_runtime_active, or chromium_runtime_active",
            )
        )

    coverage = payload.get("coverage")
    if not isinstance(coverage, list) or not coverage:
        failures.append(failure("missing_coverage", "coverage", "coverage must be a non-empty array"))
        coverage = []

    seen_capabilities: set[str] = set()
    coverage_by_capability: dict[str, dict[str, Any]] = {}
    for index, row in enumerate(coverage):
        row_path = f"coverage[{index}]"
        if not isinstance(row, dict):
            failures.append(failure("invalid_coverage_row", row_path, "coverage row must be an object"))
            continue
        capability = _text(row.get("capability"))
        status = row.get("status")
        if not capability:
            failures.append(
                failure("missing_capability", f"{row_path}.capability", "capability must be non-empty")
            )
        elif capability in seen_capabilities:
            failures.append(
                failure(
                    "duplicate_capability",
                    f"{row_path}.capability",
                    f"duplicate capability {capability}",
                )
            )
        else:
            seen_capabilities.add(capability)
            coverage_by_capability[capability] = row

        if status not in VALID_STATUSES:
            failures.append(
                failure(
                    "invalid_status",
                    f"{row_path}.status",
                    "status must be passing, not_supported, diagnostic_wrapper_only, source_patch_required, or implemented_untested_in_browser",
                )
            )
        if phase != "chromium_runtime_active" and status == "passing":
            failures.append(
                failure(
                    "passing_before_source_runtime_active",
                    f"{row_path}.status",
                    "passing Chromium rows require integrationPhase=chromium_runtime_active",
                )
            )
        if not _text(row.get("domain")):
            failures.append(failure("missing_domain", f"{row_path}.domain", "domain must be non-empty"))
        if not _text(row.get("notes")):
            failures.append(failure("missing_notes", f"{row_path}.notes", "notes must be non-empty"))
        if status == "passing" and _text(row.get("blockedBy")):
            failures.append(
                failure(
                    "passing_row_blocked",
                    f"{row_path}.blockedBy",
                    "passing rows must not carry blockedBy",
                )
            )

    for capability in sorted(REQUIRED_PASSING_CAPABILITIES):
        row = coverage_by_capability.get(capability)
        if row is None:
            failures.append(
                failure(
                    "missing_required_capability",
                    "coverage",
                    f"missing required capability {capability}",
                )
            )
        elif phase == "chromium_runtime_active" and row.get("status") != "passing":
            failures.append(
                failure(
                    "required_capability_not_passing",
                    f"coverage[{capability}].status",
                    f"{capability} must be passing in the Chromium overlay",
                )
            )
        elif phase != "chromium_runtime_active" and row.get("status") not in {
            "diagnostic_wrapper_only",
            "source_patch_required",
            "implemented_untested_in_browser",
        }:
            failures.append(
                failure(
                    "required_capability_invalid_pre_source_status",
                    f"coverage[{capability}].status",
                    f"{capability} must stay diagnostic or source-blocked before Chromium runtime activation",
                )
            )

    wire_notes = payload.get("wireProtocolNotes")
    if not isinstance(wire_notes, dict):
        failures.append(
            failure("missing_wire_protocol_notes", "wireProtocolNotes", "wireProtocolNotes must be an object")
        )
    else:
        for field in sorted(REQUIRED_WIRE_NOTES):
            if not _text(wire_notes.get(field)):
                failures.append(
                    failure(
                        "missing_wire_protocol_note",
                        f"wireProtocolNotes.{field}",
                        f"wireProtocolNotes.{field} must be non-empty",
                    )
                )
        architecture = _text(wire_notes.get("architecture"))
        if phase == "chromium_runtime_active" and "DoeCommandDecoder" not in architecture:
            failures.append(
                failure(
                    "missing_decoder_architecture",
                    "wireProtocolNotes.architecture",
                    "architecture note must name DoeCommandDecoder",
                )
            )
        if phase != "chromium_runtime_active" and "require-runtime-selector" not in architecture:
            failures.append(
                failure(
                    "missing_source_selector_gate_note",
                    "wireProtocolNotes.architecture",
                    "architecture note must name the require-runtime-selector gate before Chromium runtime activation",
                )
            )

    if verify_artifact_root is not None:
        failures.extend(check_smoke_artifact(payload, verify_artifact_root, phase=_text(phase)))

    return failures


def check_smoke_artifact(
    payload: dict[str, Any],
    root: Path,
    *,
    phase: str = "",
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    smoke_path = _text(payload.get("smokeTestArtifact"))
    if not smoke_path:
        return [
            failure(
                "missing_smoke_artifact",
                "smokeTestArtifact",
                "smokeTestArtifact must be non-empty",
            )
        ]
    if not safe_repo_path(smoke_path):
        return [
            failure(
                "unsafe_smoke_artifact_path",
                "smokeTestArtifact",
                "smokeTestArtifact must be repo-relative",
            )
        ]
    artifact_path = resolve_repo_path(root, smoke_path)
    if not artifact_path.exists():
        return [
            failure(
                "missing_smoke_artifact_file",
                "smokeTestArtifact",
                f"missing smoke artifact {artifact_path}",
            )
        ]

    try:
        artifact = load_json(artifact_path)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        return [
            failure(
                "invalid_smoke_artifact_file",
                "smokeTestArtifact",
                f"failed to read smoke artifact: {exc}",
            )
        ]

    if artifact.get("reportKind") != "chromium-webgpu-playwright-smoke":
        failures.append(
            failure(
                "invalid_smoke_report_kind",
                "smokeTestArtifact.reportKind",
                "smoke artifact must be a Chromium WebGPU Playwright smoke report",
            )
        )
    if artifact.get("benchmarkClass") != "diagnostic":
        failures.append(
            failure(
                "invalid_smoke_benchmark_class",
                "smokeTestArtifact.benchmarkClass",
                "smoke artifact must remain diagnostic",
            )
        )
    if phase in SOURCE_RUNTIME_EVIDENCE_PHASES:
        failures.extend(check_source_runtime_smoke_evidence(artifact))
    return failures


def check_source_runtime_smoke_evidence(artifact: dict[str, Any]) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for message in validate_smoke_report(
        artifact,
        required_modes=REQUIRED_SOURCE_MODES,
        require_strict=True,
        require_hash_chain=True,
    ):
        failures.append(
            failure(
                "invalid_source_smoke_report_contract",
                "smokeTestArtifact",
                message,
            )
        )

    chrome_path = _text(artifact.get("chromePath"))
    if chrome_path and not source_chromium_binary_path(chrome_path):
        failures.append(
            failure(
                "non_source_chromium_binary",
                "smokeTestArtifact.chromePath",
                "source runtime evidence must use a browser/chromium/src/out Chromium binary",
            )
        )

    runtime_selections = artifact.get("runtimeSelections")
    if not isinstance(runtime_selections, list):
        failures.append(
            failure(
                "missing_source_runtime_selections",
                "smokeTestArtifact.runtimeSelections",
                "source runtime evidence must include top-level runtimeSelections",
            )
        )
    else:
        failures.extend(check_runtime_selection_rows(runtime_selections, "runtimeSelections"))

    mode_results = artifact.get("modeResults")
    if isinstance(mode_results, list):
        mode_rows = [
            row for row in mode_results
            if isinstance(row, dict) and row.get("mode") in REQUIRED_SOURCE_MODES
        ]
        failures.extend(
            check_runtime_selection_rows(
                [row.get("runtimeSelection") for row in mode_rows],
                "modeResults.runtimeSelection",
            )
        )
    else:
        failures.append(
            failure(
                "missing_source_mode_results",
                "smokeTestArtifact.modeResults",
                "source runtime evidence must include modeResults",
            )
        )

    return failures


def check_runtime_selection_rows(rows: list[Any], path_name: str) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    seen_modes: set[str] = set()
    for index, row in enumerate(rows):
        row_path = f"smokeTestArtifact.{path_name}[{index}]"
        if not isinstance(row, dict):
            failures.append(
                failure(
                    "invalid_source_runtime_selection",
                    row_path,
                    "runtime selection must be an object",
                )
            )
            continue
        mode = _text(row.get("selectionMode"))
        if mode in REQUIRED_SOURCE_MODES:
            seen_modes.add(mode)
            for message in validate_runtime_selection(row, mode, row_path):
                failures.append(
                    failure(
                        "invalid_source_runtime_selection",
                        row_path,
                        message,
                    )
                )
        else:
            failures.append(
                failure(
                    "missing_source_runtime_selection_mode",
                    f"{row_path}.selectionMode",
                    "runtime selection mode must be dawn or doe",
                )
            )

        artifact = runtime_selection_artifact(row)
        browser_path = _text(artifact.get("browserExecutablePath"))
        if not source_chromium_binary_path(browser_path):
            failures.append(
                failure(
                    "non_source_chromium_binary",
                    f"{row_path}.artifactIdentity.browserExecutablePath",
                    "source runtime evidence must use a browser/chromium/src/out Chromium binary",
                )
            )
        if mode == "doe" and not doe_runtime_library_path(_text(artifact.get("doeLibPath"))):
            failures.append(
                failure(
                    "invalid_doe_runtime_library",
                    f"{row_path}.artifactIdentity.doeLibPath",
                    "Doe runtime evidence must name a libwebgpu_doe runtime library",
                )
            )

    missing = set(REQUIRED_SOURCE_MODES) - seen_modes
    if missing:
        failures.append(
            failure(
                "missing_source_runtime_selection",
                f"smokeTestArtifact.{path_name}",
                f"source runtime evidence must include {sorted(missing)} runtime selection rows",
            )
        )
    return failures


def main() -> int:
    args = parse_args()
    overlay_path = Path(args.overlay)
    verify_root = Path(args.verify_artifact_root) if args.verify_artifact_root.strip() else None
    failures = check_overlay(load_json(overlay_path), verify_artifact_root=verify_root)
    report = {
        "schemaVersion": 1,
        "artifactKind": "webgpu_integration_chromium_check",
        "overlayPath": str(overlay_path),
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: Chromium WebGPU integration overlay")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: Chromium WebGPU integration overlay")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
