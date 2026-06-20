"""Runtime comparability checks for the compare lane."""

from __future__ import annotations

import json
import statistics
from pathlib import Path
from typing import Any

from native_compare_modules.comparability import (
    _PHASE_ASYMMETRY_THRESHOLD,
    _PHASE_MATERIAL_FLOOR_FRACTION,
    _PHASE_MATERIAL_MIN_SAMPLES,
    _PHASE_ZERO_EPSILON,
    _TIMING_PHASE_FIELDS,
    _all_samples_zero,
    _material_sample_count,
)
from native_compare_modules.normalization import sample_normalized_elapsed_ms
from native_compare_modules.reporting import safe_int
from native_compare_modules.timing_selection import (
    effective_execution_total_ns_for_sample,
    effective_setup_total_ns_for_sample,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
_PACKAGE_EXECUTION_BACKENDS = frozenset({
    "node_webgpu_package",
    "doe_node_webgpu",
    "doe_node_native_direct",
    "bun_webgpu_package",
    "doe_bun_package",
})
_NATIVE_VULKAN_EXECUTION_BACKENDS = frozenset({
    "doe_vulkan",
    "dawn_delegate",
})
_DEFAULT_COMPARE_KERNEL_ROOT = REPO_ROOT / "bench" / "kernels"
_PACKAGE_SUBMIT_SCOPE_FIELDS: tuple[tuple[str, str], ...] = (
    ("addonCommandReplay", "submitAddonCommandReplayTotalNs"),
    ("addonFlush", "submitAddonFlushTotalNs"),
    ("queueWait", "submitQueueWaitTotalNs"),
)


def _sample_normalized_wall_ms(sample: dict[str, Any]) -> float | None:
    elapsed_ms = sample_normalized_elapsed_ms(sample)
    if elapsed_ms is None or elapsed_ms <= 0.0:
        return None
    return elapsed_ms


def _median_phase_fractions(
    command_samples: list[dict[str, Any]],
) -> dict[str, list[float]]:
    fractions: dict[str, list[float]] = {phase_key: [] for phase_key, _ in _TIMING_PHASE_FIELDS}
    for sample in command_samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        total = effective_execution_total_ns_for_sample(sample)
        if total <= 0:
            continue
        for phase_key, field_name in _TIMING_PHASE_FIELDS:
            if field_name == "executionSetupTotalNs":
                phase_total = effective_setup_total_ns_for_sample(sample)
            else:
                phase_total = safe_int(trace_meta.get(field_name), default=0)
            fractions[phase_key].append(phase_total / total)
    return fractions


def assess_timing_phase_equivalence(
    *,
    left_command_samples: list[dict[str, Any]],
    right_command_samples: list[dict[str, Any]],
) -> tuple[bool, bool, dict[str, Any], str]:
    left_fractions = _median_phase_fractions(left_command_samples)
    right_fractions = _median_phase_fractions(right_command_samples)
    left_medians: dict[str, float | None] = {}
    right_medians: dict[str, float | None] = {}
    phase_sample_counts: dict[str, dict[str, int]] = {}
    mismatches: list[str] = []

    for phase_key, field_name in _TIMING_PHASE_FIELDS:
        left_values = left_fractions.get(phase_key, [])
        right_values = right_fractions.get(phase_key, [])
        left_median = float(statistics.median(left_values)) if left_values else None
        right_median = float(statistics.median(right_values)) if right_values else None
        left_medians[phase_key] = left_median
        right_medians[phase_key] = right_median
        phase_sample_counts[phase_key] = {
            "baseline": len(left_values),
            "comparison": len(right_values),
        }
        if left_median is None or right_median is None:
            continue
        # Primary gate (CLAUDE.md #11): one side uniformly zero across samples
        # AND the other side has >= _PHASE_MATERIAL_MIN_SAMPLES samples above
        # the material floor. Median-fraction is still reported but no longer
        # the threshold; near-zero warm-cache signals that legitimately median
        # to ~0.1% no longer false-fire.
        left_all_zero = _all_samples_zero(left_values)
        right_all_zero = _all_samples_zero(right_values)
        left_material = _material_sample_count(left_values)
        right_material = _material_sample_count(right_values)
        if left_all_zero and right_material >= _PHASE_MATERIAL_MIN_SAMPLES:
            mismatches.append(
                f"baseline reports zero {field_name} on every sample while comparison has "
                f"{right_material} sample(s) >= {_PHASE_MATERIAL_FLOOR_FRACTION:.1%} of executionTotalNs "
                f"(median {right_median:.2%})"
            )
        elif right_all_zero and left_material >= _PHASE_MATERIAL_MIN_SAMPLES:
            mismatches.append(
                f"comparison reports zero {field_name} on every sample while baseline has "
                f"{left_material} sample(s) >= {_PHASE_MATERIAL_FLOOR_FRACTION:.1%} of executionTotalNs "
                f"(median {left_median:.2%})"
            )

    applies = any(
        counts["baseline"] > 0 and counts["comparison"] > 0 for counts in phase_sample_counts.values()
    )
    details: dict[str, Any] = {
        "phaseAsymmetryThreshold": _PHASE_ASYMMETRY_THRESHOLD,
        "phaseMaterialFloorFraction": _PHASE_MATERIAL_FLOOR_FRACTION,
        "phaseMaterialMinSamples": _PHASE_MATERIAL_MIN_SAMPLES,
        "phaseZeroEpsilon": _PHASE_ZERO_EPSILON,
        "phaseGateFormulation": "all-zero-one-side-vs-any-material-other-side",
        "baselineMedianPhaseFractions": left_medians,
        "comparisonMedianPhaseFractions": right_medians,
        "phaseSampleCounts": phase_sample_counts,
        "phaseMismatchCount": len(mismatches),
        "phaseMismatches": mismatches,
    }
    return applies, len(mismatches) == 0, details, "; ".join(mismatches)


def assess_submit_scope_equivalence(
    *,
    left_command_samples: list[dict[str, Any]],
    right_command_samples: list[dict[str, Any]],
) -> tuple[bool, bool, dict[str, Any], str]:
    def collect_scope_fractions(
        command_samples: list[dict[str, Any]],
    ) -> tuple[dict[str, list[float]], int]:
        fractions: dict[str, list[float]] = {
            scope_key: [] for scope_key, _ in _PACKAGE_SUBMIT_SCOPE_FIELDS
        }
        sample_count = 0
        for sample in command_samples:
            if not isinstance(sample, dict):
                continue
            trace_meta = sample.get("traceMeta", {})
            if not isinstance(trace_meta, dict):
                continue
            submit_wait_total = safe_int(trace_meta.get("executionSubmitWaitTotalNs"), default=0)
            breakdown = trace_meta.get("packageStepBreakdownNs")
            if submit_wait_total <= 0 or not isinstance(breakdown, dict):
                continue
            sample_count += 1
            for scope_key, field_name in _PACKAGE_SUBMIT_SCOPE_FIELDS:
                scope_total = safe_int(breakdown.get(field_name), default=0)
                fractions[scope_key].append(max(0, scope_total) / submit_wait_total)
        return fractions, sample_count

    left_fractions, left_sample_count = collect_scope_fractions(left_command_samples)
    right_fractions, right_sample_count = collect_scope_fractions(right_command_samples)
    left_medians: dict[str, float | None] = {}
    right_medians: dict[str, float | None] = {}
    sample_counts: dict[str, dict[str, int]] = {}
    mismatches: list[str] = []

    for scope_key, field_name in _PACKAGE_SUBMIT_SCOPE_FIELDS:
        left_values = left_fractions.get(scope_key, [])
        right_values = right_fractions.get(scope_key, [])
        left_median = float(statistics.median(left_values)) if left_values else None
        right_median = float(statistics.median(right_values)) if right_values else None
        left_medians[scope_key] = left_median
        right_medians[scope_key] = right_median
        sample_counts[scope_key] = {
            "baseline": len(left_values),
            "comparison": len(right_values),
        }
        if left_median is None or right_median is None:
            continue
        left_all_zero = _all_samples_zero(left_values)
        right_all_zero = _all_samples_zero(right_values)
        left_material = _material_sample_count(left_values)
        right_material = _material_sample_count(right_values)
        if left_all_zero and right_material >= _PHASE_MATERIAL_MIN_SAMPLES:
            mismatches.append(
                f"baseline submit_wait reports zero {field_name} on every sample while "
                f"comparison has {right_material} sample(s) >= {_PHASE_MATERIAL_FLOOR_FRACTION:.1%} "
                f"of submit_wait (median {right_median:.2%})"
            )
        elif right_all_zero and left_material >= _PHASE_MATERIAL_MIN_SAMPLES:
            mismatches.append(
                f"comparison submit_wait reports zero {field_name} on every sample while "
                f"baseline has {left_material} sample(s) >= {_PHASE_MATERIAL_FLOOR_FRACTION:.1%} "
                f"of submit_wait (median {left_median:.2%})"
            )

    applies = left_sample_count > 0 or right_sample_count > 0
    if applies and left_sample_count == 0:
        mismatches.append(
            "baseline package submit breakdown telemetry is missing while comparison reports submit scopes"
        )
    if applies and right_sample_count == 0:
        mismatches.append(
            "comparison package submit breakdown telemetry is missing while baseline reports submit scopes"
        )
    details: dict[str, Any] = {
        "phaseAsymmetryThreshold": _PHASE_ASYMMETRY_THRESHOLD,
        "phaseMaterialFloorFraction": _PHASE_MATERIAL_FLOOR_FRACTION,
        "phaseMaterialMinSamples": _PHASE_MATERIAL_MIN_SAMPLES,
        "phaseZeroEpsilon": _PHASE_ZERO_EPSILON,
        "phaseGateFormulation": "all-zero-one-side-vs-any-material-other-side",
        "baselineMedianSubmitScopeFractions": left_medians,
        "comparisonMedianSubmitScopeFractions": right_medians,
        "submitScopeSampleCounts": sample_counts,
        "baselineSubmitScopeSampleCount": left_sample_count,
        "comparisonSubmitScopeSampleCount": right_sample_count,
        "submitScopeMismatchCount": len(mismatches),
        "submitScopeMismatches": mismatches,
    }
    return applies, len(mismatches) == 0, details, "; ".join(mismatches)


def _resolve_repo_relative_path(path_text: str) -> Path:
    path = Path(path_text)
    if path.is_absolute():
        return path
    return REPO_ROOT / path


def _load_kernel_dispatch_kernels(commands_path: str) -> tuple[list[str], dict[str, Any], str]:
    resolved_commands_path = _resolve_repo_relative_path(commands_path)
    details: dict[str, Any] = {
        "commandsPath": commands_path,
        "resolvedCommandsPath": str(resolved_commands_path),
    }
    if not resolved_commands_path.exists():
        return [], details, f"commandsPath does not exist: {resolved_commands_path}"
    try:
        payload = json.loads(resolved_commands_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [], details, f"failed to load commandsPath {resolved_commands_path}: {exc}"
    if not isinstance(payload, list):
        return [], details, f"commandsPath {resolved_commands_path} must decode to a list"

    kernels: list[str] = []
    seen: set[str] = set()
    for index, command in enumerate(payload):
        if not isinstance(command, dict):
            continue
        if str(command.get("kind", "")).strip() != "kernel_dispatch":
            continue
        kernel = str(command.get("kernel", "")).strip()
        if not kernel:
            return [], details, f"kernel_dispatch command at index {index} is missing kernel"
        if kernel not in seen:
            seen.add(kernel)
            kernels.append(kernel)
    details["kernelDispatchCount"] = len(kernels)
    details["kernelDispatchKernels"] = kernels
    return kernels, details, ""


def _expected_spirv_artifact_path(kernel: str) -> Path:
    kernel_path = Path(kernel)
    if kernel_path.suffix == ".spv":
        return _DEFAULT_COMPARE_KERNEL_ROOT / kernel_path
    if kernel_path.suffix == ".wgsl":
        return _DEFAULT_COMPARE_KERNEL_ROOT / kernel_path.with_suffix(".spv")
    return _DEFAULT_COMPARE_KERNEL_ROOT / f"{kernel}.spv"


def assess_native_shader_artifact_equivalence(
    *,
    workload_api: str,
    workload_commands_path: str,
    comparability_mode: str,
    is_dawn_vs_doe: bool,
    left_execution_backends: set[str],
    right_execution_backends: set[str],
) -> tuple[bool, bool, dict[str, Any], str]:
    details: dict[str, Any] = {
        "comparabilityMode": comparability_mode,
        "isDawnVsDoe": is_dawn_vs_doe,
        "workloadApi": workload_api,
        "commandsPath": workload_commands_path,
        "kernelRoot": str(_DEFAULT_COMPARE_KERNEL_ROOT),
        "baselineExecutionBackends": sorted(left_execution_backends),
        "comparisonExecutionBackends": sorted(right_execution_backends),
    }
    applies = (
        comparability_mode == "strict"
        and is_dawn_vs_doe
        and workload_api == "vulkan"
        and bool(left_execution_backends & _NATIVE_VULKAN_EXECUTION_BACKENDS)
        and bool(right_execution_backends & _NATIVE_VULKAN_EXECUTION_BACKENDS)
        and bool(workload_commands_path.strip())
    )
    if not applies:
        return False, True, details, ""

    kernels, command_details, command_failure = _load_kernel_dispatch_kernels(workload_commands_path)
    details.update(command_details)
    if command_failure:
        return True, False, details, command_failure
    if not kernels:
        return False, True, details, ""

    resolved_artifacts: list[dict[str, str]] = []
    missing_artifacts: list[dict[str, str]] = []
    for kernel in kernels:
        artifact_path = _expected_spirv_artifact_path(kernel)
        artifact_entry = {
            "kernel": kernel,
            "expectedSpirvPath": str(artifact_path),
        }
        if artifact_path.exists():
            resolved_artifacts.append(artifact_entry)
        else:
            missing_artifacts.append(artifact_entry)
    details["resolvedSpirvArtifacts"] = resolved_artifacts
    details["missingSpirvArtifacts"] = missing_artifacts
    details["nativeShaderArtifactMismatchCount"] = len(missing_artifacts)
    if not missing_artifacts:
        return True, True, details, ""
    missing_summary = ", ".join(
        f"{entry['kernel']} -> {entry['expectedSpirvPath']}" for entry in missing_artifacts
    )
    return (
        True,
        False,
        details,
        "strict native Vulkan compare requires explicit SPIR-V artifacts for kernel_dispatch workloads; "
        f"missing {missing_summary}",
    )
