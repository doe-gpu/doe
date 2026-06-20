"""Operator-manifest comparison for native compare reports."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from bench.lib.bench_utils import load_json
from native_compare_modules.runner import file_sha256


def _load_json_object(path: Path) -> dict[str, Any] | None:
    try:
        payload = load_json(path)
    except (OSError, UnicodeError, ValueError):
        return None
    if isinstance(payload, dict):
        return payload
    return None


def _load_json_array(path: Path) -> list[dict[str, Any]] | None:
    try:
        payload = load_json(path)
    except (OSError, UnicodeError, ValueError):
        return None
    if not isinstance(payload, list):
        return None
    rows: list[dict[str, Any]] = []
    for entry in payload:
        if not isinstance(entry, dict):
            return None
        rows.append(entry)
    return rows


def _sample_trace_meta(sample: dict[str, Any]) -> dict[str, Any] | None:
    inline = sample.get("traceMeta")
    if isinstance(inline, dict):
        return inline

    raw_path = sample.get("traceMetaPath")
    if not isinstance(raw_path, str) or not raw_path.strip():
        return None
    return _load_json_object(Path(raw_path.strip()))


def _resolve_artifact_path(raw_path: str, *, trace_meta_path: str | None) -> Path:
    path = Path(raw_path)
    if path.is_absolute():
        return path
    if isinstance(trace_meta_path, str) and trace_meta_path.strip():
        candidate = Path(trace_meta_path.strip()).parent / path
        if candidate.exists():
            return candidate
    return path


def _resolve_operator_manifest(sample: dict[str, Any]) -> dict[str, Any] | None:
    trace_meta = _sample_trace_meta(sample)
    if not isinstance(trace_meta, dict):
        return None

    raw_manifest_path = trace_meta.get("operatorRecordManifestPath")
    if not isinstance(raw_manifest_path, str) or not raw_manifest_path.strip():
        return None
    trace_meta_path = sample.get("traceMetaPath")
    path = _resolve_artifact_path(raw_manifest_path.strip(), trace_meta_path=trace_meta_path if isinstance(trace_meta_path, str) else None)
    if not path.exists():
        return None
    rows = _load_json_array(path)
    if rows is None:
        return None
    return {
        "path": str(path),
        "sha256": file_sha256(path),
        "rows": rows,
    }


def _identity_tuple(record: dict[str, Any]) -> tuple[Any, ...]:
    return (
        record.get("semanticOpId"),
        record.get("semanticStage"),
        record.get("semanticPhase"),
        record.get("semanticTokenIndex"),
        record.get("semanticLayerIndex"),
        record.get("semanticExecutionPlanHash"),
    )


def _command_shape(record: dict[str, Any]) -> dict[str, Any] | None:
    shape = record.get("commandShape")
    if isinstance(shape, dict):
        return shape
    return None


def _capture_info(record: dict[str, Any]) -> dict[str, Any] | None:
    capture = record.get("capture")
    if isinstance(capture, dict):
        return capture
    return None


def _execution_info(record: dict[str, Any]) -> dict[str, Any] | None:
    execution = record.get("execution")
    if isinstance(execution, dict):
        return execution
    return None


def _record_excerpt(record: dict[str, Any], manifest: dict[str, Any]) -> dict[str, Any]:
    shader_artifacts = record.get("shaderArtifacts")
    execution = _execution_info(record)
    capture = _capture_info(record)
    return {
        "manifestPath": manifest.get("path"),
        "manifestSha256": manifest.get("sha256"),
        "sourceIndex": record.get("sourceIndex"),
        "command": record.get("command"),
        "kernel": record.get("kernel"),
        "semanticOpId": record.get("semanticOpId"),
        "semanticStage": record.get("semanticStage"),
        "semanticPhase": record.get("semanticPhase"),
        "semanticTokenIndex": record.get("semanticTokenIndex"),
        "semanticLayerIndex": record.get("semanticLayerIndex"),
        "semanticExecutionPlanHash": record.get("semanticExecutionPlanHash"),
        "commandShape": _command_shape(record),
        "execution": {
            "backend": execution.get("backend") if execution else None,
            "status": execution.get("status") if execution else None,
            "statusCode": execution.get("statusCode") if execution else None,
            "backendLane": execution.get("backendLane") if execution else None,
            "selectionPolicyHash": execution.get("selectionPolicyHash") if execution else None,
            "shaderArtifactManifestHash": execution.get("shaderArtifactManifestHash") if execution else None,
        },
        "shaderArtifacts": shader_artifacts if isinstance(shader_artifacts, dict) else None,
        "capture": capture,
        "repro": record.get("repro") if isinstance(record.get("repro"), dict) else None,
    }


def _compare_manifest_rows(
    left_manifest: dict[str, Any],
    right_manifest: dict[str, Any],
) -> dict[str, Any]:
    left_rows = left_manifest["rows"]
    right_rows = right_manifest["rows"]
    capture_comparable_count = 0
    compared_count = 0

    max_count = max(len(left_rows), len(right_rows))
    for op_index in range(max_count):
        left_record = left_rows[op_index] if op_index < len(left_rows) else None
        right_record = right_rows[op_index] if op_index < len(right_rows) else None
        if left_record is None or right_record is None:
            return {
                "found": True,
                "type": "operator_count_mismatch",
                "message": "Operator manifests contain different numbers of semantic entries.",
                "opIndex": op_index,
                "baselineRecordPresent": left_record is not None,
                "comparisonRecordPresent": right_record is not None,
                "baselineRecord": _record_excerpt(left_record, left_manifest) if left_record else None,
                "comparisonRecord": _record_excerpt(right_record, right_manifest) if right_record else None,
                "comparedOperatorCount": compared_count,
                "captureComparableOperatorCount": capture_comparable_count,
            }

        compared_count += 1

        if _identity_tuple(left_record) != _identity_tuple(right_record):
            return {
                "found": True,
                "type": "semantic_identity_mismatch",
                "message": "Semantic operator identity diverged between baseline and comparison manifests.",
                "opIndex": op_index,
                "semanticOpId": left_record.get("semanticOpId") or right_record.get("semanticOpId"),
                "baselineRecord": _record_excerpt(left_record, left_manifest),
                "comparisonRecord": _record_excerpt(right_record, right_manifest),
                "comparedOperatorCount": compared_count,
                "captureComparableOperatorCount": capture_comparable_count,
            }

        if _command_shape(left_record) != _command_shape(right_record):
            return {
                "found": True,
                "type": "command_shape_mismatch",
                "message": "Semantic operator command shape diverged between baseline and comparison manifests.",
                "opIndex": op_index,
                "semanticOpId": left_record.get("semanticOpId"),
                "baselineRecord": _record_excerpt(left_record, left_manifest),
                "comparisonRecord": _record_excerpt(right_record, right_manifest),
                "comparedOperatorCount": compared_count,
                "captureComparableOperatorCount": capture_comparable_count,
            }

        left_execution = _execution_info(left_record)
        right_execution = _execution_info(right_record)
        left_execution_status = None if left_execution is None else (
            left_execution.get("status"),
            left_execution.get("statusCode"),
        )
        right_execution_status = None if right_execution is None else (
            right_execution.get("status"),
            right_execution.get("statusCode"),
        )
        if left_execution_status != right_execution_status:
            return {
                "found": True,
                "type": "execution_status_mismatch",
                "message": "Semantic operator execution status diverged between baseline and comparison manifests.",
                "opIndex": op_index,
                "semanticOpId": left_record.get("semanticOpId"),
                "baselineRecord": _record_excerpt(left_record, left_manifest),
                "comparisonRecord": _record_excerpt(right_record, right_manifest),
                "comparedOperatorCount": compared_count,
                "captureComparableOperatorCount": capture_comparable_count,
            }

        left_capture = _capture_info(left_record)
        right_capture = _capture_info(right_record)
        if left_capture is None and right_capture is None:
            continue
        if left_capture is None or right_capture is None:
            return {
                "found": True,
                "type": "capture_presence_mismatch",
                "message": "Only one benchmark participant emitted capture metadata for the semantic operator.",
                "opIndex": op_index,
                "semanticOpId": left_record.get("semanticOpId"),
                "baselineRecord": _record_excerpt(left_record, left_manifest),
                "comparisonRecord": _record_excerpt(right_record, right_manifest),
                "comparedOperatorCount": compared_count,
                "captureComparableOperatorCount": capture_comparable_count,
            }

        capture_comparable_count += 1
        left_capture_status = left_capture.get("status")
        right_capture_status = right_capture.get("status")
        if left_capture_status != right_capture_status:
            return {
                "found": True,
                "type": "capture_status_mismatch",
                "message": "Capture status diverged for the semantic operator.",
                "opIndex": op_index,
                "semanticOpId": left_record.get("semanticOpId"),
                "baselineRecord": _record_excerpt(left_record, left_manifest),
                "comparisonRecord": _record_excerpt(right_record, right_manifest),
                "comparedOperatorCount": compared_count,
                "captureComparableOperatorCount": capture_comparable_count,
            }

        if left_capture_status == "ok" and left_capture.get("sha256") != right_capture.get("sha256"):
            return {
                "found": True,
                "type": "capture_digest_mismatch",
                "message": "Capture digests diverged for the semantic operator.",
                "opIndex": op_index,
                "semanticOpId": left_record.get("semanticOpId"),
                "baselineRecord": _record_excerpt(left_record, left_manifest),
                "comparisonRecord": _record_excerpt(right_record, right_manifest),
                "comparedOperatorCount": compared_count,
                "captureComparableOperatorCount": capture_comparable_count,
            }

    return {
        "found": False,
        "type": "none",
        "message": "Operator manifests matched structurally for the compared sample pair.",
        "comparedOperatorCount": compared_count,
        "captureComparableOperatorCount": capture_comparable_count,
    }


def summarize_workload_operator_diff(
    baseline_run: dict[str, Any],
    comparison_run: dict[str, Any],
) -> dict[str, Any]:
    baseline_samples = baseline_run.get("commandSamples", [])
    comparison_samples = comparison_run.get("commandSamples", [])
    if not isinstance(baseline_samples, list) or not isinstance(comparison_samples, list):
        return {
            "available": False,
            "status": "missing_command_samples",
            "eligibleSamplePairCount": 0,
            "comparedSamplePairCount": 0,
            "firstDivergence": None,
        }

    pair_count = min(len(baseline_samples), len(comparison_samples))
    eligible_pairs = 0
    compared_pairs = 0
    for sample_index in range(pair_count):
        baseline_sample = baseline_samples[sample_index]
        comparison_sample = comparison_samples[sample_index]
        if not isinstance(baseline_sample, dict) or not isinstance(comparison_sample, dict):
            continue
        if baseline_sample.get("returnCode") != 0 or comparison_sample.get("returnCode") != 0:
            continue
        baseline_manifest = _resolve_operator_manifest(baseline_sample)
        comparison_manifest = _resolve_operator_manifest(comparison_sample)
        if baseline_manifest is None or comparison_manifest is None:
            continue

        eligible_pairs += 1
        compared_pairs += 1
        divergence = _compare_manifest_rows(baseline_manifest, comparison_manifest)
        if divergence.get("found"):
            return {
                "available": True,
                "status": "diverged",
                "eligibleSamplePairCount": eligible_pairs,
                "comparedSamplePairCount": compared_pairs,
                "samplePair": {
                    "sampleIndex": sample_index,
                    "baselineManifestPath": baseline_manifest["path"],
                    "baselineManifestSha256": baseline_manifest["sha256"],
                    "comparisonManifestPath": comparison_manifest["path"],
                    "comparisonManifestSha256": comparison_manifest["sha256"],
                },
                "firstDivergence": divergence,
            }

        return {
            "available": True,
            "status": "matched",
            "eligibleSamplePairCount": eligible_pairs,
            "comparedSamplePairCount": compared_pairs,
            "samplePair": {
                "sampleIndex": sample_index,
                "baselineManifestPath": baseline_manifest["path"],
                "baselineManifestSha256": baseline_manifest["sha256"],
                "comparisonManifestPath": comparison_manifest["path"],
                "comparisonManifestSha256": comparison_manifest["sha256"],
            },
            "firstDivergence": divergence,
        }

    return {
        "available": False,
        "status": "missing_operator_manifests",
        "eligibleSamplePairCount": eligible_pairs,
        "comparedSamplePairCount": compared_pairs,
        "firstDivergence": None,
    }
