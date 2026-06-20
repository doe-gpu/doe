"""compare_assessment: the full comparability verdict for a workload pair.

Extracted from comparability_runtime.py to keep both files under the
1200-line Python cap. Depends on the helper + assess_* functions that
remain in comparability_runtime.py.
"""

from __future__ import annotations

import json
import statistics
import subprocess
from pathlib import Path
from typing import Any, Callable

from native_compare_modules.comparability import (
    DAWN_OPERATION_TIMING_SOURCES,
    DOE_OPERATION_TIMING_SOURCES,
    NATIVE_EXECUTION_OPERATION_TIMING_SOURCES,
    OBLIGATION_SCHEMA_VERSION,
    _PHASE_ASYMMETRY_THRESHOLD,
    _TIMING_PHASE_FIELDS,
    _normalized_domain,
    _record_obligation,
    _sources_match_with_runtime_compatibility,
    _timing_selection_policy_match_with_runtime_compatibility,
)
from native_compare_modules.comparability_runtime import (
    _sample_normalized_wall_ms,
    assess_native_shader_artifact_equivalence,
    assess_submit_scope_equivalence,
    assess_timing_phase_equivalence,
)
from native_compare_modules.compare_assessment_helpers import (
    assess_effective_readback_path_equivalence,
    assess_readback_capture_equivalence,
    collect_effective_readback_paths,
    collect_execution_backends,
    collect_execution_shapes,
    collect_resident_buffer_load_shapes,
    collect_shader_source_receipt_hashes,
    collect_trace_meta_optional_values,
    collect_trace_meta_values,
    collect_upload_ignore_first_violations,
    compare_execution_shapes,
    median_timing_wall_ratio,
    normalize_execution_shapes,
    ratio_asymmetry,
    uses_doe_execution,
    uses_package_execution,
)
from native_compare_modules.comparability_upload_contract import (
    assert_runtime_not_stale,
    find_fawn_runtime_index,
    is_dawn_writebuffer_upload_workload,
    subprocess_combined_output,
    validate_upload_apples_to_apples,
    verify_fawn_upload_runtime_contract,
)
from native_compare_modules.normalization import sample_normalized_elapsed_ms
from native_compare_modules.reporting import parse_int, safe_float, safe_int, valid_sync_mode
from native_compare_modules.timing_selection import canonical_timing_source, classify_timing_source


def compare_assessment(
    *,
    workload_id: str,
    workload_comparable: bool,
    workload_domain: str,
    workload_api: str,
    workload_commands_path: str,
    workload_path_asymmetry: bool,
    workload_path_asymmetry_note: str,
    baseline_command_repeat: int,
    comparison_command_repeat: int,
    baseline: dict[str, Any],
    comparison: dict[str, Any],
    required_timing_class: str,
    allow_baseline_no_execution: bool,
    resource_probe: str,
    comparability_mode: str,
    resource_sample_target_count: int,
) -> dict[str, Any]:
    left_samples_raw = baseline.get("commandSamples", [])
    right_samples_raw = comparison.get("commandSamples", [])
    left_samples = left_samples_raw if isinstance(left_samples_raw, list) else []
    right_samples = right_samples_raw if isinstance(right_samples_raw, list) else []
    left_measured_samples = [
        sample
        for sample in left_samples
        if isinstance(sample, dict) and safe_float(sample.get("measuredMs")) is not None
    ]
    right_measured_samples = [
        sample
        for sample in right_samples
        if isinstance(sample, dict) and safe_float(sample.get("measuredMs")) is not None
    ]

    left_sources = sorted({str(sample.get("timingSource", "")) for sample in left_samples})
    right_sources = sorted({str(sample.get("timingSource", "")) for sample in right_samples})
    left_classes = sorted({classify_timing_source(source) for source in left_sources if source})
    right_classes = sorted({classify_timing_source(source) for source in right_sources if source})
    left_class = left_classes[0] if len(left_classes) == 1 else "mixed"
    right_class = right_classes[0] if len(right_classes) == 1 else "mixed"
    left_trace_meta_sources = sorted(
        {
            canonical_timing_source(str(timing.get("traceMetaSource", "")))
            for sample in left_samples
            if isinstance(sample, dict)
            for timing in [sample.get("timing", {})]
            if isinstance(timing, dict) and str(timing.get("traceMetaSource", ""))
        }
    )
    right_trace_meta_sources = sorted(
        {
            canonical_timing_source(str(timing.get("traceMetaSource", "")))
            for sample in right_samples
            if isinstance(sample, dict)
            for timing in [sample.get("timing", {})]
            if isinstance(timing, dict) and str(timing.get("traceMetaSource", ""))
        }
    )
    left_selected_sources = sorted(
        {canonical_timing_source(source) for source in left_sources if source}
    )
    right_selected_sources = sorted(
        {canonical_timing_source(source) for source in right_sources if source}
    )
    left_timing_selection_policies = sorted(
        {
            (
                str(timing.get("timingSelectionPolicy"))
                if timing.get("timingSelectionPolicy") is not None
                else "<none>"
            )
            for sample in left_samples
            if isinstance(sample, dict)
            for timing in [sample.get("timing", {})]
            if isinstance(timing, dict)
        }
    )
    right_timing_selection_policies = sorted(
        {
            (
                str(timing.get("timingSelectionPolicy"))
                if timing.get("timingSelectionPolicy") is not None
                else "<none>"
            )
            for sample in right_samples
            if isinstance(sample, dict)
            for timing in [sample.get("timing", {})]
            if isinstance(timing, dict)
        }
    )
    left_queue_sync_modes = sorted(
        {
            str(trace_meta.get("queueSyncMode"))
            for sample in left_samples
            if isinstance(sample, dict)
            for trace_meta in [sample.get("traceMeta", {})]
            if isinstance(trace_meta, dict) and trace_meta.get("queueSyncMode") is not None
        }
    )
    right_queue_sync_modes = sorted(
        {
            str(trace_meta.get("queueSyncMode"))
            for sample in right_samples
            if isinstance(sample, dict)
            for trace_meta in [sample.get("traceMeta", {})]
            if isinstance(trace_meta, dict) and trace_meta.get("queueSyncMode") is not None
        }
    )
    left_execution_shapes = collect_execution_shapes(left_samples)
    right_execution_shapes = collect_execution_shapes(right_samples)
    normalized_domain = workload_domain.strip().lower()
    # Dispatch shape matching applies to all domains. If one side dispatches
    # N times and the other dispatches 0, the workloads are structurally
    # different regardless of domain.
    dispatch_shape_domain = True

    left_execution_backends = collect_execution_backends(left_samples)
    right_execution_backends = collect_execution_backends(right_samples)
    package_execution_applies = uses_package_execution(
        left_execution_backends
    ) or uses_package_execution(right_execution_backends)

    left_resident_buffer_load_modes = collect_trace_meta_values(
        left_samples,
        "packageResidentBufferLoads",
    )
    right_resident_buffer_load_modes = collect_trace_meta_values(
        right_samples,
        "packageResidentBufferLoads",
    )

    left_resident_buffer_load_shapes = collect_resident_buffer_load_shapes(left_samples)
    right_resident_buffer_load_shapes = collect_resident_buffer_load_shapes(right_samples)
    left_effective_readback_paths = collect_effective_readback_paths(left_samples)
    right_effective_readback_paths = collect_effective_readback_paths(right_samples)

    left_shader_source_receipt_hashes = collect_shader_source_receipt_hashes(left_samples)
    right_shader_source_receipt_hashes = collect_shader_source_receipt_hashes(right_samples)

    is_left_dawn_perf = "dawn-perf-tests" in left_execution_backends
    is_right_dawn_perf = "dawn-perf-tests" in right_execution_backends
    is_left_dawn_direct = any(
        backend.startswith("dawn_direct")
        for backend in left_execution_backends
    )
    is_right_dawn_direct = any(
        backend.startswith("dawn_direct")
        for backend in right_execution_backends
    )
    is_left_dawn_delegate = (
        "dawn_delegate" in left_execution_backends
        or "node_webgpu_package" in left_execution_backends
        or "bun_webgpu_package" in left_execution_backends
    )
    is_right_dawn_delegate = (
        "dawn_delegate" in right_execution_backends
        or "node_webgpu_package" in right_execution_backends
        or "bun_webgpu_package" in right_execution_backends
    )
    is_left_dawn = is_left_dawn_delegate or is_left_dawn_direct or is_left_dawn_perf
    is_right_dawn = is_right_dawn_delegate or is_right_dawn_direct or is_right_dawn_perf
    is_left_doe = uses_doe_execution(left_execution_backends)
    is_right_doe = uses_doe_execution(right_execution_backends)
    is_dawn_vs_doe = (is_left_dawn and is_right_doe) or (is_left_doe and is_right_dawn)

    reasons: list[str] = []
    resource_reasons: list[str] = []
    obligations: list[dict[str, Any]] = []

    _record_obligation(
        obligations,
        reasons,
        obligation_id="workload_marked_comparable",
        blocking=True,
        applicable=True,
        passes=bool(workload_comparable),
        failure_reason="workload is marked non-comparable by workload contract",
        details={"workloadComparable": bool(workload_comparable)},
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="left_samples_present",
        blocking=True,
        applicable=True,
        passes=len(left_measured_samples) > 0,
        failure_reason="baseline side has no measured samples",
        details={"baselineSampleCount": len(left_measured_samples)},
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="right_samples_present",
        blocking=True,
        applicable=True,
        passes=len(right_measured_samples) > 0,
        failure_reason="comparison side has no measured samples",
        details={"comparisonSampleCount": len(right_measured_samples)},
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="left_single_timing_class",
        blocking=True,
        applicable=True,
        passes=len(left_classes) == 1,
        failure_reason=f"baseline side uses mixed timing classes: {left_classes}",
        details={"baselineTimingClasses": left_classes},
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="right_single_timing_class",
        blocking=True,
        applicable=True,
        passes=len(right_classes) == 1,
        failure_reason=f"comparison side uses mixed timing classes: {right_classes}",
        details={"comparisonTimingClasses": right_classes},
    )

    required_timing_class_applies = required_timing_class != "any"
    _record_obligation(
        obligations,
        reasons,
        obligation_id="left_required_timing_class",
        blocking=True,
        applicable=required_timing_class_applies,
        passes=left_class == required_timing_class,
        failure_reason=f"baseline timing class is {left_class}, required {required_timing_class}",
        details={
            "requiredTimingClass": required_timing_class,
            "baselineTimingClass": left_class,
        },
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="right_required_timing_class",
        blocking=True,
        applicable=required_timing_class_applies,
        passes=right_class == required_timing_class,
        failure_reason=f"comparison timing class is {right_class}, required {required_timing_class}",
        details={
            "requiredTimingClass": required_timing_class,
            "comparisonTimingClass": right_class,
        },
    )

    timing_match_applies = left_class != "mixed" and right_class != "mixed"
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_timing_class_match",
        blocking=True,
        applicable=timing_match_applies,
        passes=left_class == right_class,
        failure_reason=f"baseline/comparison timing class mismatch: {left_class} vs {right_class}",
        details={
            "baselineTimingClass": left_class,
            "comparisonTimingClass": right_class,
        },
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_trace_meta_source_match",
        blocking=True,
        applicable=len(left_samples) > 0 and len(right_samples) > 0,
        passes=_sources_match_with_runtime_compatibility(
            left_sources=(
                left_selected_sources
                if required_timing_class == "process-wall"
                else left_trace_meta_sources
            ),
            right_sources=(
                right_selected_sources
                if required_timing_class == "process-wall"
                else right_trace_meta_sources
            ),
            workload_domain=workload_domain,
            comparability_mode=comparability_mode,
            required_timing_class=required_timing_class,
            is_dawn_vs_doe=is_dawn_vs_doe,
            is_left_dawn_perf=is_left_dawn_perf,
            is_right_dawn_perf=is_right_dawn_perf,
            is_left_dawn_delegate=is_left_dawn_delegate,
            is_right_dawn_delegate=is_right_dawn_delegate,
            is_left_dawn=is_left_dawn,
            is_right_dawn=is_right_dawn,
            is_left_doe=is_left_doe,
            is_right_doe=is_right_doe,
        ),
        failure_reason=(
            "baseline/comparison trace meta source mismatch or incompatible runtime families: "
            f"{left_trace_meta_sources} vs {right_trace_meta_sources}"
        ),
        details={
            "baselineTraceMetaSources": left_trace_meta_sources,
            "comparisonTraceMetaSources": right_trace_meta_sources,
            "baselineSelectedSources": left_selected_sources,
            "comparisonSelectedSources": right_selected_sources,
        },
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_timing_selection_policy_match",
        blocking=True,
        applicable=len(left_samples) > 0 and len(right_samples) > 0,
        passes=_timing_selection_policy_match_with_runtime_compatibility(
            left_policies=left_timing_selection_policies,
            right_policies=right_timing_selection_policies,
            workload_domain=workload_domain,
            comparability_mode=comparability_mode,
            required_timing_class=required_timing_class,
            is_dawn_vs_doe=is_dawn_vs_doe,
            is_left_dawn_perf=is_left_dawn_perf,
            is_right_dawn_perf=is_right_dawn_perf,
            is_left_dawn_delegate=is_left_dawn_delegate,
            is_right_dawn_delegate=is_right_dawn_delegate,
            is_left_dawn=is_left_dawn,
            is_right_dawn=is_right_dawn,
            is_left_doe=is_left_doe,
            is_right_doe=is_right_doe,
        ),
        failure_reason=(
            "baseline/comparison timing selection policy mismatch or incompatible runtime policies: "
            f"{left_timing_selection_policies} vs {right_timing_selection_policies}"
        ),
        details={
            "baselineTimingSelectionPolicies": left_timing_selection_policies,
            "comparisonTimingSelectionPolicies": right_timing_selection_policies,
        },
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_queue_sync_mode_match",
        blocking=True,
        applicable=len(left_samples) > 0 and len(right_samples) > 0,
        passes=left_queue_sync_modes == right_queue_sync_modes,
        failure_reason=(
            "baseline/comparison queue sync mode mismatch: "
            f"{left_queue_sync_modes} vs {right_queue_sync_modes}"
        ),
        details={
            "baselineQueueSyncModes": left_queue_sync_modes,
            "comparisonQueueSyncModes": right_queue_sync_modes,
        },
    )
    (
        submit_scope_match_applies,
        submit_scope_match,
        submit_scope_details,
        submit_scope_failure_reason,
    ) = assess_submit_scope_equivalence(
        left_command_samples=left_samples,
        right_command_samples=right_samples,
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_submit_scope_match",
        blocking=True,
        applicable=(
            comparability_mode == "strict"
            and is_dawn_vs_doe
            and package_execution_applies
            and submit_scope_match_applies
        ),
        passes=submit_scope_match,
        failure_reason=(
            "baseline/comparison submit scope mismatch: " + submit_scope_failure_reason
            if submit_scope_failure_reason
            else ""
        ),
        details={
            "comparabilityMode": comparability_mode,
            "isDawnVsDoe": is_dawn_vs_doe,
            "baselineExecutionBackends": sorted(left_execution_backends),
            "comparisonExecutionBackends": sorted(right_execution_backends),
            **submit_scope_details,
        },
    )
    (
        readback_path_match_applies,
        readback_path_match,
        readback_path_details,
        readback_path_failure_reason,
    ) = assess_effective_readback_path_equivalence(
        left_effective_readback_paths,
        right_effective_readback_paths,
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_effective_readback_path_match",
        blocking=True,
        applicable=(
            comparability_mode == "strict"
            and package_execution_applies
            and readback_path_match_applies
        ),
        passes=readback_path_match,
        failure_reason=readback_path_failure_reason,
        details=readback_path_details,
    )
    (
        timing_phase_match_applies,
        timing_phase_match,
        timing_phase_details,
        timing_phase_failure_reason,
    ) = assess_timing_phase_equivalence(
        left_command_samples=left_samples,
        right_command_samples=right_samples,
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_timing_phase_match",
        blocking=True,
        applicable=timing_phase_match_applies,
        passes=timing_phase_match,
        failure_reason=(
            "baseline/comparison timing phase mismatch: " + timing_phase_failure_reason
            if timing_phase_failure_reason
            else ""
        ),
        details=timing_phase_details,
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_package_resident_buffer_load_mode_match",
        blocking=True,
        applicable=(
            comparability_mode == "strict"
            and package_execution_applies
            and (
                bool(left_resident_buffer_load_modes)
                or bool(right_resident_buffer_load_modes)
            )
        ),
        passes=(
            len(left_resident_buffer_load_modes) <= 1
            and len(right_resident_buffer_load_modes) <= 1
            and left_resident_buffer_load_modes == right_resident_buffer_load_modes
        ),
        failure_reason=(
            "baseline/comparison package resident buffer-load mode mismatch: "
            f"{left_resident_buffer_load_modes} vs {right_resident_buffer_load_modes}"
        ),
        details={
            "baselinePackageResidentBufferLoadModes": sorted(
                str(value) for value in left_resident_buffer_load_modes
            ),
            "comparisonPackageResidentBufferLoadModes": sorted(
                str(value) for value in right_resident_buffer_load_modes
            ),
        },
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_package_resident_buffer_load_shape_match",
        blocking=True,
        applicable=(
            comparability_mode == "strict"
            and package_execution_applies
            and (
                True in left_resident_buffer_load_modes
                or True in right_resident_buffer_load_modes
            )
        ),
        passes=(
            len(left_resident_buffer_load_shapes) <= 1
            and len(right_resident_buffer_load_shapes) <= 1
            and left_resident_buffer_load_shapes == right_resident_buffer_load_shapes
        ),
        failure_reason=(
            "baseline/comparison resident buffer-load shape mismatch: "
            f"{left_resident_buffer_load_shapes} vs {right_resident_buffer_load_shapes}"
        ),
        details={
            "baselineResidentBufferLoadShapes": [
                {"count": count, "bytes": byte_count}
                for count, byte_count in sorted(left_resident_buffer_load_shapes)
            ],
            "comparisonResidentBufferLoadShapes": [
                {"count": count, "bytes": byte_count}
                for count, byte_count in sorted(right_resident_buffer_load_shapes)
            ],
        },
    )
    shader_source_receipts_match_applies = comparability_mode == "strict" and package_execution_applies
    shader_source_receipts_match = (
        len(left_shader_source_receipt_hashes) > 0
        and len(right_shader_source_receipt_hashes) > 0
        and left_shader_source_receipt_hashes == right_shader_source_receipt_hashes
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_shader_source_receipts_match",
        blocking=True,
        applicable=shader_source_receipts_match_applies,
        passes=shader_source_receipts_match,
        failure_reason=(
            "baseline/comparison package shader source receipt mismatch: "
            f"{sorted(left_shader_source_receipt_hashes)} vs "
            f"{sorted(right_shader_source_receipt_hashes)}"
        ),
        details={
            "baselineShaderSourceReceiptsHash": sorted(left_shader_source_receipt_hashes),
            "comparisonShaderSourceReceiptsHash": sorted(right_shader_source_receipt_hashes),
        },
    )

    normalized_left_execution_shapes, left_execution_shape_reason = normalize_execution_shapes(
        left_execution_shapes,
        side_name="baseline",
        command_repeat=baseline_command_repeat,
    )
    normalized_right_execution_shapes, right_execution_shape_reason = normalize_execution_shapes(
        right_execution_shapes,
        side_name="comparison",
        command_repeat=comparison_command_repeat,
    )
    execution_shape_match = False
    execution_shape_mismatch_reason = ""
    if left_execution_shape_reason:
        execution_shape_mismatch_reason = left_execution_shape_reason
    elif right_execution_shape_reason:
        execution_shape_mismatch_reason = right_execution_shape_reason
    else:
        execution_shape_match, execution_shape_mismatch_reason = compare_execution_shapes(
            normalized_left_execution_shapes,
            normalized_right_execution_shapes,
        )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_execution_shape_match",
        blocking=True,
        applicable=dispatch_shape_domain and len(left_execution_shapes) > 0 and len(right_execution_shapes) > 0,
        passes=execution_shape_match,
        failure_reason=(
            "baseline/comparison execution shape mismatch "
            "(dispatch/submit/row/success counts): "
            f"{left_execution_shapes} vs {right_execution_shapes}; "
            f"reason={execution_shape_mismatch_reason}"
        ),
        details={
            "workloadDomain": workload_domain,
            "dispatchShapeDomain": dispatch_shape_domain,
            "baselineExecutionShapes": left_execution_shapes,
            "comparisonExecutionShapes": right_execution_shapes,
            "baselineNormalizedExecutionShapes": normalized_left_execution_shapes,
            "comparisonNormalizedExecutionShapes": normalized_right_execution_shapes,
            "baselineCommandRepeat": baseline_command_repeat,
            "comparisonCommandRepeat": comparison_command_repeat,
            "comparisonReason": execution_shape_mismatch_reason,
        },
    )
    (
        readback_capture_match_applies,
        readback_capture_match,
        readback_capture_details,
        readback_capture_failure_reason,
    ) = assess_readback_capture_equivalence(left_samples, right_samples)
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_readback_capture_match",
        blocking=True,
        applicable=readback_capture_match_applies,
        passes=readback_capture_match,
        failure_reason=readback_capture_failure_reason,
        details=readback_capture_details,
    )
    hardware_path_match_applies = comparability_mode == "strict" and is_dawn_vs_doe
    hardware_path_failure_reason = (
        "workload contract marks pathAsymmetry=true: baseline/comparison use hardware-specific "
        "execution paths that are not structurally equivalent"
    )
    if workload_path_asymmetry_note:
        hardware_path_failure_reason += f" ({workload_path_asymmetry_note})"
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_hardware_path_match",
        blocking=True,
        applicable=hardware_path_match_applies,
        passes=not workload_path_asymmetry,
        failure_reason=hardware_path_failure_reason,
        details={
            "comparabilityMode": comparability_mode,
            "isDawnVsDoe": is_dawn_vs_doe,
            "workloadPathAsymmetry": bool(workload_path_asymmetry),
            "workloadPathAsymmetryNote": workload_path_asymmetry_note,
        },
    )
    (
        native_shader_artifact_match_applies,
        native_shader_artifact_match,
        native_shader_artifact_details,
        native_shader_artifact_failure_reason,
    ) = assess_native_shader_artifact_equivalence(
        workload_api=str(workload_api).strip().lower(),
        workload_commands_path=str(workload_commands_path),
        comparability_mode=comparability_mode,
        is_dawn_vs_doe=is_dawn_vs_doe,
        left_execution_backends=left_execution_backends,
        right_execution_backends=right_execution_backends,
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_explicit_native_shader_artifact_match",
        blocking=True,
        applicable=native_shader_artifact_match_applies,
        passes=native_shader_artifact_match,
        failure_reason=(
            "baseline/comparison native shader artifact mismatch: "
            + native_shader_artifact_failure_reason
            if native_shader_artifact_failure_reason
            else ""
        ),
        details=native_shader_artifact_details,
    )

    invalid_native_execution_sources: set[str] = set()
    for sample in left_samples:
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        execution_backend = str(trace_meta.get("executionBackend", ""))
        if execution_backend not in {
            "webgpu-ffi",
            "dawn_delegate",
            "dawn_direct_metal",
            "node_webgpu_package",
            "doe_node_webgpu",
            "doe_node_native_direct",
            "bun_webgpu_package",
            "doe_bun_package",
            "doe_metal",
            "doe_vulkan",
            "doe_d3d12",
        }:
            continue
        execution_dispatch = safe_int(trace_meta.get("executionDispatchCount"), default=0)
        execution_success = safe_int(trace_meta.get("executionSuccessCount"), default=0)
        execution_rows = safe_int(trace_meta.get("executionRowCount"), default=0)
        if execution_dispatch <= 0 and execution_success <= 0 and execution_rows <= 0:
            continue
        timing_source_raw = sample.get("timingSource")
        if not isinstance(timing_source_raw, str) or not timing_source_raw:
            invalid_native_execution_sources.add("<missing>")
            continue
        canonical_source = canonical_timing_source(timing_source_raw)
        if canonical_source not in NATIVE_EXECUTION_OPERATION_TIMING_SOURCES:
            invalid_native_execution_sources.add(canonical_source)
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_native_operation_timing_for_webgpu_ffi",
        blocking=True,
        applicable=required_timing_class == "operation",
        passes=len(invalid_native_execution_sources) == 0,
        failure_reason=(
            "baseline side uses non-native operation timing source(s) for native execution: "
            + ", ".join(sorted(invalid_native_execution_sources))
        ),
        details={
            "invalidCanonicalSources": sorted(invalid_native_execution_sources),
        },
    )

    left_upload_usages = collect_trace_meta_optional_values(left_samples, "uploadBufferUsage")
    right_upload_usages = collect_trace_meta_optional_values(right_samples, "uploadBufferUsage")
    left_upload_submit_cadence = collect_trace_meta_optional_values(left_samples, "uploadSubmitEvery")
    right_upload_submit_cadence = collect_trace_meta_optional_values(right_samples, "uploadSubmitEvery")

    upload_scope_applies = workload_domain == "upload"
    left_upload_scope_reasons = (
        collect_upload_ignore_first_violations(side_name="baseline", samples=left_samples)
        if upload_scope_applies
        else []
    )
    right_upload_scope_reasons = (
        collect_upload_ignore_first_violations(side_name="comparison", samples=right_samples)
        if upload_scope_applies
        else []
    )
    reasons.extend(left_upload_scope_reasons)
    reasons.extend(right_upload_scope_reasons)
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_upload_ignore_first_scope_consistent",
        blocking=True,
        applicable=upload_scope_applies,
        passes=len(left_upload_scope_reasons) == 0,
        details={"violationCount": len(left_upload_scope_reasons)},
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="comparison_upload_ignore_first_scope_consistent",
        blocking=True,
        applicable=upload_scope_applies,
        passes=len(right_upload_scope_reasons) == 0,
        details={"violationCount": len(right_upload_scope_reasons)},
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_upload_buffer_usage_match",
        blocking=True,
        applicable=upload_scope_applies and len(left_samples) > 0 and len(right_samples) > 0,
        passes=left_upload_usages == right_upload_usages,
        failure_reason=(
            f"baseline/comparison upload usage mismatch: {left_upload_usages} vs {right_upload_usages}"
        ),
        details={"baselineUploadUsages": sorted(list(str(u) for u in left_upload_usages)), "comparisonUploadUsages": sorted(list(str(u) for u in right_upload_usages))},
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_upload_submit_cadence_match",
        blocking=True,
        applicable=upload_scope_applies and len(left_samples) > 0 and len(right_samples) > 0,
        passes=left_upload_submit_cadence == right_upload_submit_cadence,
        failure_reason=(
            f"baseline/comparison upload submit cadence mismatch: {left_upload_submit_cadence} vs {right_upload_submit_cadence}"
        ),
        details={"baselineUploadSubmitCadences": sorted(list(str(c) for c in left_upload_submit_cadence)), "comparisonUploadSubmitCadences": sorted(list(str(c) for c in right_upload_submit_cadence))},
    )

    left_has_execution = False
    left_successful_execution = False
    left_has_unsupported_or_skipped = False
    for sample in left_samples:
        trace_meta = sample.get("traceMeta", {})
        execution_success = safe_int(trace_meta.get("executionSuccessCount"), default=0)
        execution_rows = safe_int(trace_meta.get("executionRowCount"), default=0)
        execution_unsupported = safe_int(trace_meta.get("executionUnsupportedCount"), default=0)
        execution_skipped = safe_int(trace_meta.get("executionSkippedCount"), default=0)
        if execution_success > 0 or execution_rows > 0:
            left_has_execution = True
        if execution_success > 0:
            left_successful_execution = True
        if execution_unsupported > 0 or execution_skipped > 0:
            left_has_unsupported_or_skipped = True

    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_execution_evidence_present",
        blocking=True,
        applicable=not allow_baseline_no_execution,
        passes=left_has_execution,
        failure_reason="baseline side has no execution evidence (executionSuccessCount/executionRowCount)",
        details={
            "allowBaselineNoExecution": bool(allow_baseline_no_execution),
            "baselineHasExecutionEvidence": left_has_execution,
        },
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_successful_execution_present",
        blocking=True,
        applicable=not allow_baseline_no_execution,
        passes=left_successful_execution,
        failure_reason="baseline side has no successful execution samples (executionSuccessCount=0)",
        details={
            "baselineSuccessfulExecution": left_successful_execution,
        },
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_success_or_unsupported_or_skipped",
        blocking=True,
        applicable=allow_baseline_no_execution,
        passes=left_successful_execution or left_has_unsupported_or_skipped,
        failure_reason=(
            "baseline side has no successful execution samples and no unsupported/skipped execution evidence"
        ),
        details={
            "baselineSuccessfulExecution": left_successful_execution,
            "baselineHasUnsupportedOrSkippedEvidence": left_has_unsupported_or_skipped,
        },
    )

    left_execution_error_samples = 0
    right_execution_error_samples = 0
    for sample in left_samples:
        trace_meta = sample.get("traceMeta", {})
        if safe_int(trace_meta.get("executionErrorCount"), default=0) > 0:
            left_execution_error_samples += 1
    for sample in right_samples:
        trace_meta = sample.get("traceMeta", {})
        if safe_int(trace_meta.get("executionErrorCount"), default=0) > 0:
            right_execution_error_samples += 1

    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_execution_errors_absent",
        blocking=True,
        applicable=True,
        passes=left_execution_error_samples == 0,
        failure_reason=(
            f"baseline side reported execution errors in {left_execution_error_samples}/{len(left_samples)} samples"
        ),
        details={
            "baselineExecutionErrorSampleCount": left_execution_error_samples,
            "baselineSampleCount": len(left_samples),
        },
    )
    _record_obligation(
        obligations,
        reasons,
        obligation_id="comparison_execution_errors_absent",
        blocking=True,
        applicable=True,
        passes=right_execution_error_samples == 0,
        failure_reason=(
            f"comparison side reported execution errors in {right_execution_error_samples}/{len(right_samples)} samples"
        ),
        details={
            "comparisonExecutionErrorSampleCount": right_execution_error_samples,
            "comparisonSampleCount": len(right_samples),
        },
    )

    # ── Timing plausibility: traced timing must not be pathologically detached
    # from workload-unit wall time. Symmetric low coverage can be legitimate
    # operation timing for package workloads; asymmetric low coverage means one
    # side is likely measuring a different scope.
    _PLAUSIBILITY_MIN_WALL_RATIO = 0.01
    _PLAUSIBILITY_MIN_WALL_MS = 5.0  # skip check for sub-5ms wall (noise)
    _PLAUSIBILITY_MAX_RATIO_ASYMMETRY = 128.0

    left_traced, left_wall, left_ratio, left_process_wall = median_timing_wall_ratio(
        left_samples,
        _sample_normalized_wall_ms,
    )
    right_traced, right_wall, right_ratio, right_process_wall = median_timing_wall_ratio(
        right_samples,
        _sample_normalized_wall_ms,
    )
    plausibility_ratio_asymmetry = ratio_asymmetry(left_ratio, right_ratio)

    plausibility_applies = (
        left_wall is not None
        and right_wall is not None
        and (left_wall >= _PLAUSIBILITY_MIN_WALL_MS or right_wall >= _PLAUSIBILITY_MIN_WALL_MS)
    )
    plausibility_failures: list[str] = []
    low_coverage_sides: list[str] = []
    if plausibility_applies:
        left_low_coverage = left_ratio is not None and left_ratio < _PLAUSIBILITY_MIN_WALL_RATIO
        right_low_coverage = right_ratio is not None and right_ratio < _PLAUSIBILITY_MIN_WALL_RATIO
        left_wall_checked = left_wall is not None and left_wall >= _PLAUSIBILITY_MIN_WALL_MS
        right_wall_checked = right_wall is not None and right_wall >= _PLAUSIBILITY_MIN_WALL_MS
        if left_low_coverage:
            low_coverage_sides.append("baseline")
        if right_low_coverage:
            low_coverage_sides.append("comparison")
        if len(low_coverage_sides) == 1 and (
            (low_coverage_sides[0] == "baseline" and left_wall_checked)
            or (low_coverage_sides[0] == "comparison" and right_wall_checked)
        ):
            side = low_coverage_sides[0]
            traced = left_traced if side == "baseline" else right_traced
            ratio = left_ratio if side == "baseline" else right_ratio
            wall = left_wall if side == "baseline" else right_wall
            plausibility_failures.append(
                f"{side} traced timing ({traced:.4f}ms) is {ratio:.4%} of normalized wall time "
                f"({wall:.1f}ms) while the other side is not; timing source scopes are asymmetric"
            )
        elif len(low_coverage_sides) == 2 and (
            plausibility_ratio_asymmetry is None
            or plausibility_ratio_asymmetry >= _PLAUSIBILITY_MAX_RATIO_ASYMMETRY
        ):
            plausibility_failures.append(
                "baseline and comparison traced timing both under-cover normalized wall time, "
                f"but median coverage differs by {plausibility_ratio_asymmetry}x; "
                "timing source scopes are asymmetric"
            )

    _record_obligation(
        obligations,
        reasons,
        obligation_id="baseline_comparison_timing_plausibility",
        blocking=True,
        applicable=plausibility_applies,
        passes=len(plausibility_failures) == 0,
        failure_reason="; ".join(plausibility_failures),
        details={
            "minWallRatio": _PLAUSIBILITY_MIN_WALL_RATIO,
            "minWallMs": _PLAUSIBILITY_MIN_WALL_MS,
            "maxRatioAsymmetry": _PLAUSIBILITY_MAX_RATIO_ASYMMETRY,
            "lowCoverageSides": low_coverage_sides,
            "medianRatioAsymmetry": plausibility_ratio_asymmetry,
            "baselineMedianTracedMs": left_traced,
            "baselineMedianWallMs": left_wall,
            "baselineMedianProcessWallMs": left_process_wall,
            "baselineMedianRatio": left_ratio,
            "comparisonMedianTracedMs": right_traced,
            "comparisonMedianWallMs": right_wall,
            "comparisonMedianProcessWallMs": right_process_wall,
            "comparisonMedianRatio": right_ratio,
        },
    )

    left_resource_sample_counts: list[int] = []
    right_resource_sample_counts: list[int] = []
    baseline_resource_probe_available = 0
    comparison_resource_probe_available = 0
    left_resource_truncated = 0
    right_resource_truncated = 0

    for sample in left_samples:
        resource = sample.get("resource", {})
        if isinstance(resource, dict):
            count = parse_int(resource.get("resourceSampleCount"))
            if count is not None:
                left_resource_sample_counts.append(count)
            if resource.get("gpuMemoryProbeAvailable") is True:
                baseline_resource_probe_available += 1
            if resource.get("resourceSamplingTruncated") is True:
                left_resource_truncated += 1
    for sample in right_samples:
        resource = sample.get("resource", {})
        if isinstance(resource, dict):
            count = parse_int(resource.get("resourceSampleCount"))
            if count is not None:
                right_resource_sample_counts.append(count)
            if resource.get("gpuMemoryProbeAvailable") is True:
                comparison_resource_probe_available += 1
            if resource.get("resourceSamplingTruncated") is True:
                right_resource_truncated += 1

    left_resource_sample_median = (
        int(statistics.median(left_resource_sample_counts))
        if left_resource_sample_counts
        else 0
    )
    right_resource_sample_median = (
        int(statistics.median(right_resource_sample_counts))
        if right_resource_sample_counts
        else 0
    )

    def record_resource_obligation(
        *,
        obligation_id: str,
        applicable: bool,
        passes: bool,
        failure_reason: str,
        details: dict[str, Any] | None = None,
    ) -> None:
        _record_obligation(
            obligations,
            reasons,
            obligation_id=obligation_id,
            blocking=True,
            applicable=applicable,
            passes=passes,
            failure_reason=failure_reason,
            details=details,
        )
        if applicable and (not passes):
            resource_reasons.append(failure_reason)

    resource_probe_applies = resource_probe != "none"
    record_resource_obligation(
        obligation_id="baseline_resource_probe_available",
        applicable=resource_probe_applies,
        passes=baseline_resource_probe_available > 0,
        failure_reason="baseline side has no successful GPU resource probe samples",
        details={"baselineResourceProbeAvailableCount": baseline_resource_probe_available},
    )
    record_resource_obligation(
        obligation_id="comparison_resource_probe_available",
        applicable=resource_probe_applies,
        passes=comparison_resource_probe_available > 0,
        failure_reason="comparison side has no successful GPU resource probe samples",
        details={"comparisonResourceProbeAvailableCount": comparison_resource_probe_available},
    )

    if resource_probe_applies and comparability_mode == "strict":
        target_positive = resource_sample_target_count > 0
        record_resource_obligation(
            obligation_id="strict_resource_sample_target_positive",
            applicable=True,
            passes=target_positive,
            failure_reason=(
                "strict resource comparability requires --resource-sample-target-count > 0 "
                "for N-vs-N probing"
            ),
            details={"resourceSampleTargetCount": resource_sample_target_count},
        )
        if target_positive:
            record_resource_obligation(
                obligation_id="baseline_resource_sample_target_match",
                applicable=True,
                passes=left_resource_sample_median == resource_sample_target_count,
                failure_reason=(
                    "baseline side resource sample median does not match target "
                    f"({left_resource_sample_median} vs target={resource_sample_target_count})"
                ),
                details={
                    "baselineResourceSampleMedian": left_resource_sample_median,
                    "resourceSampleTargetCount": resource_sample_target_count,
                },
            )
            record_resource_obligation(
                obligation_id="comparison_resource_sample_target_match",
                applicable=True,
                passes=right_resource_sample_median == resource_sample_target_count,
                failure_reason=(
                    "comparison side resource sample median does not match target "
                    f"({right_resource_sample_median} vs target={resource_sample_target_count})"
                ),
                details={
                    "comparisonResourceSampleMedian": right_resource_sample_median,
                    "resourceSampleTargetCount": resource_sample_target_count,
                },
            )
            record_resource_obligation(
                obligation_id="baseline_resource_sampling_not_truncated",
                applicable=True,
                passes=left_resource_truncated == 0,
                failure_reason=(
                    "baseline side resource probing truncated before process completion; "
                    "increase --resource-sample-target-count or reduce --resource-sample-ms"
                ),
                details={"baselineResourceSamplingTruncatedCount": left_resource_truncated},
            )
            record_resource_obligation(
                obligation_id="comparison_resource_sampling_not_truncated",
                applicable=True,
                passes=right_resource_truncated == 0,
                failure_reason=(
                    "comparison side resource probing truncated before process completion; "
                    "increase --resource-sample-target-count or reduce --resource-sample-ms"
                ),
                details={"comparisonResourceSamplingTruncatedCount": right_resource_truncated},
            )
    elif resource_probe_applies:
        record_resource_obligation(
            obligation_id="baseline_resource_sample_density_sufficient",
            applicable=True,
            passes=left_resource_sample_median >= 5,
            failure_reason=(
                "baseline side resource sampling too sparse "
                f"(median samples={left_resource_sample_median}, require >=5)"
            ),
            details={"baselineResourceSampleMedian": left_resource_sample_median},
        )
        record_resource_obligation(
            obligation_id="comparison_resource_sample_density_sufficient",
            applicable=True,
            passes=right_resource_sample_median >= 5,
            failure_reason=(
                "comparison side resource sampling too sparse "
                f"(median samples={right_resource_sample_median}, require >=5)"
            ),
            details={"comparisonResourceSampleMedian": right_resource_sample_median},
        )

    blocking_failed_obligations = [
        str(item.get("id", ""))
        for item in obligations
        if item.get("applicable") is True
        and item.get("blocking") is True
        and item.get("passes") is False
    ]
    advisory_failed_obligations = [
        str(item.get("id", ""))
        for item in obligations
        if item.get("applicable") is True
        and item.get("blocking") is False
        and item.get("passes") is False
    ]

    return {
        "comparable": len(blocking_failed_obligations) == 0,
        "requiredTimingClass": required_timing_class,
        "obligationSchemaVersion": OBLIGATION_SCHEMA_VERSION,
        "obligations": obligations,
        "blockingFailedObligations": blocking_failed_obligations,
        "advisoryFailedObligations": advisory_failed_obligations,
        "baselineTimingSources": left_sources,
        "comparisonTimingSources": right_sources,
        "baselineTraceMetaSources": left_trace_meta_sources,
        "comparisonTraceMetaSources": right_trace_meta_sources,
        "baselineTimingSelectionPolicies": left_timing_selection_policies,
        "comparisonTimingSelectionPolicies": right_timing_selection_policies,
        "baselineQueueSyncModes": left_queue_sync_modes,
        "comparisonQueueSyncModes": right_queue_sync_modes,
        "baselineExecutionShapes": left_execution_shapes,
        "comparisonExecutionShapes": right_execution_shapes,
        "baselineNormalizedExecutionShapes": normalized_left_execution_shapes,
        "comparisonNormalizedExecutionShapes": normalized_right_execution_shapes,
        "baselineCommandRepeat": baseline_command_repeat,
        "comparisonCommandRepeat": comparison_command_repeat,
        "workloadPathAsymmetry": bool(workload_path_asymmetry),
        "workloadPathAsymmetryNote": workload_path_asymmetry_note,
        "baselineTimingClass": left_class,
        "comparisonTimingClass": right_class,
        "resourceProbe": resource_probe,
        "baselineResourceSampleMedian": left_resource_sample_median,
        "comparisonResourceSampleMedian": right_resource_sample_median,
        "baselineResourceProbeAvailableCount": baseline_resource_probe_available,
        "comparisonResourceProbeAvailableCount": comparison_resource_probe_available,
        "resourceSampleTargetCount": max(resource_sample_target_count, 0),
        "baselineResourceSamplingTruncatedCount": left_resource_truncated,
        "comparisonResourceSamplingTruncatedCount": right_resource_truncated,
        "baselineExecutionErrorSampleCount": left_execution_error_samples,
        "comparisonExecutionErrorSampleCount": right_execution_error_samples,
        "resourceReasons": resource_reasons,
        "reasons": reasons,
    }
