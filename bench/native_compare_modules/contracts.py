"""Shared contract helpers for Dawn-vs-Doe gates and compare reports.

Consolidates the per-domain contract modules (backend, shader, host-plan,
csl-simulator, metal-sync, vulkan-sync) into one module. Each helper
preserves the public behavior of its original caller so gate/runner
semantics are unchanged.
"""

from __future__ import annotations

from json import JSONDecodeError
from pathlib import Path
from typing import Any

import jsonschema

from bench.lib.bench_utils import load_json_object as load_json
from bench.lib.hash_utils import file_sha256 as artifact_sha256
from native_compare_modules.reporting import safe_int, valid_sync_mode
from native_compare_modules.timing_selection import (
    canonical_timing_source,
    classify_timing_source,
)


REQUIRED_BACKEND_KEYS = (
    "backendId",
    "backendSelectionReason",
    "fallbackUsed",
    "selectionPolicyHash",
)


def load_schema(path: Path) -> dict[str, Any]:
    return load_json(path)


def resolve_relative_path(base_dir: Path, raw_path: str) -> Path:
    path = Path(raw_path)
    if path.is_absolute():
        return path
    return (base_dir / path).resolve()


def validate_artifact(
    path: Path,
    schema: dict[str, Any],
    *,
    expected_hash: str | None = None,
    label: str = "artifact",
) -> list[str]:
    if not path.exists():
        return [f"missing {label}: {path}"]

    try:
        payload = load_json(path)
    except (OSError, UnicodeError, JSONDecodeError, ValueError) as exc:
        return [f"{path}: invalid JSON: {exc}"]

    validator = jsonschema.Draft202012Validator(schema)
    errors: list[str] = []
    for err in validator.iter_errors(payload):
        location = ".".join(str(part) for part in err.absolute_path) or "<root>"
        errors.append(f"{path}: {location}: {err.message}")

    if expected_hash is not None:
        actual_hash = artifact_sha256(path)
        if actual_hash != expected_hash:
            errors.append(
                f"{path}: sha256 mismatch expected={expected_hash} got={actual_hash}"
            )

    return errors


def validate_manifest(path: Path, schema: dict[str, Any]) -> list[str]:
    return validate_artifact(path, schema, label="shader manifest")


def trace_meta_backend_fields(trace_meta: dict[str, Any]) -> dict[str, Any]:
    return {key: trace_meta.get(key) for key in REQUIRED_BACKEND_KEYS}


def is_backend_telemetry_present(trace_meta: dict[str, Any]) -> bool:
    return all(key in trace_meta for key in REQUIRED_BACKEND_KEYS)


def backend_telemetry_errors(trace_meta: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    backend_id = trace_meta.get("backendId")
    if not isinstance(backend_id, str) or not backend_id:
        errors.append("backendId missing/invalid")

    reason = trace_meta.get("backendSelectionReason")
    if not isinstance(reason, str) or not reason:
        errors.append("backendSelectionReason missing/invalid")

    fallback_used = trace_meta.get("fallbackUsed")
    if not isinstance(fallback_used, bool):
        errors.append("fallbackUsed missing/invalid")

    policy_hash = trace_meta.get("selectionPolicyHash")
    if not isinstance(policy_hash, str) or not policy_hash:
        errors.append("selectionPolicyHash missing/invalid")

    return errors


def evaluate_metal_sync_meta(
    trace_meta: dict[str, Any],
    expected_sync_mode: str,
) -> list[str]:
    errors: list[str] = []
    sync_mode = trace_meta.get("queueSyncMode")
    if not valid_sync_mode(sync_mode):
        errors.append("queueSyncMode missing/invalid")
        return errors
    if expected_sync_mode != "either" and sync_mode != expected_sync_mode:
        errors.append(
            f"queueSyncMode mismatch: expected {expected_sync_mode}, got {sync_mode}"
        )

    success = trace_meta.get("executionSuccessCount")
    if not isinstance(success, int) or success < 0:
        errors.append("executionSuccessCount missing/invalid")

    error_count = trace_meta.get("executionErrorCount")
    if not isinstance(error_count, int) or error_count < 0:
        errors.append("executionErrorCount missing/invalid")

    return errors


def evaluate_vulkan_sync_meta(
    sample: dict[str, Any],
    expected_sync_mode: str,
    *,
    required_timing_class: str = "any",
    require_upload_ignore_first_source: str = "",
) -> list[str]:
    errors: list[str] = []
    trace_meta = sample.get("traceMeta", {})
    if not isinstance(trace_meta, dict):
        errors.append("traceMeta missing/invalid")
        return errors

    sync_mode = trace_meta.get("queueSyncMode")
    if not valid_sync_mode(sync_mode):
        errors.append("queueSyncMode missing/invalid")
        return errors
    if expected_sync_mode != "either" and sync_mode != expected_sync_mode:
        errors.append(
            f"queueSyncMode mismatch: expected {expected_sync_mode}, got {sync_mode}"
        )

    success = safe_int(trace_meta.get("executionSuccessCount"), default=-1)
    error_count = safe_int(trace_meta.get("executionErrorCount"), default=-1)
    row_count = safe_int(trace_meta.get("executionRowCount"), default=-1)
    skipped_count = safe_int(trace_meta.get("executionSkippedCount"), default=-1)
    unsupported_count = safe_int(trace_meta.get("executionUnsupportedCount"), default=-1)
    total_ns = safe_int(trace_meta.get("executionTotalNs"), default=-1)

    if success < 0:
        errors.append("executionSuccessCount missing/invalid")
    if error_count < 0:
        errors.append("executionErrorCount missing/invalid")
    if row_count < 0:
        errors.append("executionRowCount missing/invalid")
    if skipped_count < 0:
        errors.append("executionSkippedCount missing/invalid")
    if unsupported_count < 0:
        errors.append("executionUnsupportedCount missing/invalid")
    if total_ns < 0:
        errors.append("executionTotalNs missing/invalid")

    if (
        row_count >= 0
        and success >= 0
        and error_count >= 0
        and skipped_count >= 0
        and unsupported_count >= 0
    ):
        if success == 0 and error_count == 0 and skipped_count == 0 and unsupported_count == 0:
            errors.append("no execution outcome recorded in traceMeta")
        if success > row_count:
            errors.append("executionSuccessCount exceeds executionRowCount")

    timing_source_raw = sample.get("timingSource")
    if isinstance(timing_source_raw, str) and timing_source_raw:
        canonical = canonical_timing_source(timing_source_raw)
        if required_timing_class not in ("any", ""):
            source_class = classify_timing_source(canonical)
            if source_class != "unknown" and source_class != required_timing_class:
                errors.append(
                    f"timingClass mismatch: expected {required_timing_class}, "
                    f"got {source_class} for timingSource={canonical!r}"
                )
            elif source_class == "unknown":
                errors.append(f"unknown timingSource {canonical!r} for contract validation")

    if (
        required_timing_class in {"operation", "process-wall"}
        and require_upload_ignore_first_source
    ):
        timing = sample.get("timing", {})
        if not isinstance(timing, dict):
            errors.append("timing metadata missing/invalid")
            return errors

        ignore_ops = safe_int(timing.get("uploadIgnoreFirstOps"), default=0)
        if row_count >= 0 and ignore_ops > 0 and row_count <= ignore_ops:
            errors.append(
                f"upload ignore-first invalid: row count {row_count} <= ignore count {ignore_ops}"
            )

        if timing.get("uploadIgnoreFirstApplied") is True:
            base_source = str(timing.get("uploadIgnoreFirstBaseTimingSource", ""))
            adjusted_source = str(
                timing.get("uploadIgnoreFirstAdjustedTimingSource", "")
            )
            if not base_source:
                errors.append("uploadIgnoreFirstBaseTimingSource missing while ignore-first is applied")
            if not adjusted_source:
                errors.append("uploadIgnoreFirstAdjustedTimingSource missing while ignore-first is applied")
            else:
                if canonical_timing_source(adjusted_source) != canonical_timing_source(
                    require_upload_ignore_first_source
                ):
                    errors.append(
                        f"upload adjusted ignore-first source mismatch: expected "
                        f"{require_upload_ignore_first_source!r}, got {adjusted_source!r}"
                    )
            if base_source and adjusted_source and canonical_timing_source(
                base_source
            ) != canonical_timing_source(adjusted_source):
                errors.append(
                    "upload ignore-first uses mixed base/adjusted timing sources "
                    f"({base_source!r} != {adjusted_source!r})"
                )

    return errors


def evaluate_csl_trace_parity(
    trace_payload: dict[str, Any],
    expected: dict[str, Any],
) -> list[str]:
    errors: list[str] = []
    expected_count = expected.get("compiledTargetCount")
    if expected_count is not None and trace_payload.get("compiledTargetCount") != expected_count:
        errors.append(
            "compiledTargetCount mismatch "
            f"expected={expected_count} got={trace_payload.get('compiledTargetCount')}"
        )

    for field in ("prefillLaunchCount", "decodeLaunchCount"):
        expected_value = expected.get(field)
        if expected_value is not None and trace_payload.get(field) != expected_value:
            errors.append(
                f"{field} mismatch expected={expected_value} got={trace_payload.get(field)}"
            )

    expected_grid = expected.get("peGrid")
    actual_grid = trace_payload.get("peGrid")
    if isinstance(expected_grid, dict):
        if not isinstance(actual_grid, dict):
            errors.append("peGrid missing/invalid in trace payload")
        else:
            for axis in ("width", "height"):
                if expected_grid.get(axis) != actual_grid.get(axis):
                    errors.append(
                        f"peGrid.{axis} mismatch expected={expected_grid.get(axis)} got={actual_grid.get(axis)}"
                    )

    return errors
