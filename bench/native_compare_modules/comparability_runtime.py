"""Runtime comparability checks for the compare lane."""

from __future__ import annotations

import json
import statistics
from pathlib import Path
from typing import Any

from bench.lib.hash_utils import file_sha256
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
    kernel_dispatch_command_count = 0
    output_oracle_count = 0
    final_kernel_dispatch_has_output_oracle = False
    final_kernel_dispatch_oracle_reference_class = ""
    output_oracle_dispatch_mismatches: list[dict[str, int]] = []
    for index, command in enumerate(payload):
        if not isinstance(command, dict):
            continue
        if str(command.get("kind", "")).strip() != "kernel_dispatch":
            continue
        kernel_dispatch_command_count += 1
        output_oracle = command.get("output_oracle") or command.get("outputOracle")
        if isinstance(output_oracle, dict):
            output_oracle_count += 1
            final_kernel_dispatch_has_output_oracle = True
            oracle_schema_version = safe_int(
                output_oracle.get("schema_version", output_oracle.get("schemaVersion")),
                default=1,
            )
            final_kernel_dispatch_oracle_reference_class = str(
                output_oracle.get(
                    "reference_class",
                    output_oracle.get(
                        "referenceClass",
                        "independent_v1" if oracle_schema_version == 1 else "",
                    ),
                )
            )
            timed_dispatch_count = safe_int(command.get("repeat"), default=1)
            oracle_dispatch_count = safe_int(
                output_oracle.get("dispatch_count", output_oracle.get("dispatchCount")),
                default=0,
            )
            if oracle_dispatch_count != timed_dispatch_count:
                output_oracle_dispatch_mismatches.append({
                    "commandIndex": index,
                    "timedDispatchCount": timed_dispatch_count,
                    "oracleDispatchCount": oracle_dispatch_count,
                })
        else:
            final_kernel_dispatch_has_output_oracle = False
            final_kernel_dispatch_oracle_reference_class = ""
        kernel = str(command.get("kernel", "")).strip()
        if not kernel:
            return [], details, f"kernel_dispatch command at index {index} is missing kernel"
        if kernel not in seen:
            seen.add(kernel)
            kernels.append(kernel)
    details["kernelDispatchCount"] = len(kernels)
    details["kernelDispatchCommandCount"] = kernel_dispatch_command_count
    details["kernelDispatchOutputOracleCount"] = output_oracle_count
    details["finalKernelDispatchHasOutputOracle"] = final_kernel_dispatch_has_output_oracle
    details["finalKernelDispatchOracleReferenceClass"] = (
        final_kernel_dispatch_oracle_reference_class
    )
    details["kernelDispatchOutputOracleDispatchMismatches"] = output_oracle_dispatch_mismatches
    details["kernelDispatchKernels"] = kernels
    return kernels, details, ""


def _expected_spirv_artifact_path(kernel: str) -> Path:
    kernel_path = Path(kernel)
    if kernel_path.suffix == ".spv":
        return _DEFAULT_COMPARE_KERNEL_ROOT / kernel_path
    if kernel_path.suffix == ".wgsl":
        return _DEFAULT_COMPARE_KERNEL_ROOT / kernel_path.with_suffix(".spv")
    return _DEFAULT_COMPARE_KERNEL_ROOT / f"{kernel}.spv"


def _expected_wgsl_source_path(kernel: str) -> Path:
    kernel_path = Path(kernel)
    if kernel_path.suffix == ".spv":
        return _DEFAULT_COMPARE_KERNEL_ROOT / kernel_path.with_suffix(".wgsl")
    if kernel_path.suffix == ".wgsl":
        return _DEFAULT_COMPARE_KERNEL_ROOT / kernel_path
    return _DEFAULT_COMPARE_KERNEL_ROOT / f"{kernel}.wgsl"


def _shader_manifest_receipts(
    samples: list[dict[str, Any]],
) -> tuple[set[str], list[dict[str, str]]]:
    manifest_paths: set[str] = set()
    trace_failures: list[dict[str, str]] = []
    inspected_trace_paths: set[Path] = set()
    for sample in samples:
        if not isinstance(sample, dict):
            continue
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            trace_meta = {}
        if str(trace_meta.get("executionBackend", "")) != "doe_vulkan":
            continue
        summary_path = str(trace_meta.get("shaderArtifactManifestPath", "")).strip()
        if summary_path:
            manifest_paths.add(summary_path)
        trace_artifacts = sample.get("traceArtifacts", {})
        if not isinstance(trace_artifacts, dict):
            trace_artifacts = {}
        raw_trace_path = str(
            trace_artifacts.get("jsonlPath", sample.get("traceJsonlPath", ""))
        ).strip()
        if not raw_trace_path:
            continue
        trace_path = _resolve_repo_relative_path(raw_trace_path)
        if trace_path in inspected_trace_paths:
            continue
        inspected_trace_paths.add(trace_path)
        try:
            trace_lines = trace_path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            trace_failures.append({
                "kernel": "<trace>",
                "reason": f"failed to load shader receipt trace {trace_path}: {exc}",
            })
            continue
        for line_number, line in enumerate(trace_lines, start=1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                trace_failures.append({
                    "kernel": "<trace>",
                    "reason": (
                        f"invalid shader receipt trace row {trace_path}:{line_number}: {exc}"
                    ),
                })
                continue
            if not isinstance(row, dict) or row.get("command") != "kernel_dispatch":
                continue
            if str(row.get("executionBackend", "")) != "doe_vulkan":
                continue
            manifest_path = str(
                row.get("executionShaderArtifactManifestPath", "")
            ).strip()
            if manifest_path:
                manifest_paths.add(manifest_path)
    return manifest_paths, trace_failures


def assess_native_shader_artifact_equivalence(
    *,
    workload_api: str,
    workload_commands_path: str,
    comparability_mode: str,
    is_dawn_vs_doe: bool,
    left_execution_backends: set[str],
    right_execution_backends: set[str],
    left_command_samples: list[dict[str, Any]],
    right_command_samples: list[dict[str, Any]],
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
    artifact_failures: list[dict[str, str]] = []
    doe_samples = (
        left_command_samples
        if "doe_vulkan" in left_execution_backends
        else right_command_samples
    )
    manifest_path_set, trace_receipt_failures = _shader_manifest_receipts(doe_samples)
    manifest_paths = sorted(manifest_path_set)
    details["shaderManifestReceiptPaths"] = manifest_paths
    details["shaderManifestTraceFailures"] = trace_receipt_failures
    artifact_failures.extend(trace_receipt_failures)
    manifests: list[tuple[Path, dict[str, Any]]] = []
    for raw_path in manifest_paths:
        manifest_path = _resolve_repo_relative_path(raw_path)
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            artifact_failures.append({
                "kernel": "<manifest>",
                "reason": f"failed to load shader artifact manifest {manifest_path}: {exc}",
            })
            continue
        if not isinstance(manifest, dict):
            artifact_failures.append({
                "kernel": "<manifest>",
                "reason": f"shader artifact manifest is not an object: {manifest_path}",
            })
            continue
        manifests.append((manifest_path, manifest))

    declared_oracle_count = int(command_details.get("kernelDispatchOutputOracleCount", 0) or 0)
    oracle_failures: list[dict[str, str]] = []
    kernel_dispatch_command_count = int(
        command_details.get("kernelDispatchCommandCount", 0) or 0
    )
    if declared_oracle_count == 0 or not bool(
        command_details.get("finalKernelDispatchHasOutputOracle", False)
    ):
        oracle_failures.append({
            "kernel": "<commands>",
            "reason": (
                "strict native command graphs require an output oracle on the final "
                "kernel_dispatch: "
                f"commands={kernel_dispatch_command_count} "
                f"uniqueKernels={len(kernels)} oracles={declared_oracle_count}"
            ),
        })
    elif (
        command_details.get("finalKernelDispatchOracleReferenceClass")
        != "independent_v1"
    ):
        oracle_failures.append({
            "kernel": "<commands>",
            "reason": (
                "strict native claims require an independent output oracle on the "
                "final kernel_dispatch: "
                f"referenceClass={command_details.get('finalKernelDispatchOracleReferenceClass')!r}"
            ),
        })
    oracle_dispatch_mismatches = command_details.get(
        "kernelDispatchOutputOracleDispatchMismatches", []
    )
    if oracle_dispatch_mismatches:
        oracle_failures.append({
            "kernel": "<commands>",
            "reason": (
                "strict native output oracle dispatch count must equal the timed command repeat: "
                f"{oracle_dispatch_mismatches}"
            ),
        })
    for side_name, samples in (("baseline", left_command_samples), ("comparison", right_command_samples)):
        for sample in samples:
            if not isinstance(sample, dict):
                continue
            trace_meta = sample.get("traceMeta", {})
            if not isinstance(trace_meta, dict):
                continue
            count = safe_int(trace_meta.get("outputOracleCount"), default=0)
            matched = safe_int(trace_meta.get("outputOracleMatchedCount"), default=0)
            failed = safe_int(trace_meta.get("outputOracleFailedCount"), default=0)
            expected = str(trace_meta.get("outputOracleExpectedSha256", ""))
            actual = str(trace_meta.get("outputOracleActualSha256", ""))
            if count != declared_oracle_count or matched != declared_oracle_count or failed != 0 or expected != actual:
                oracle_failures.append({
                    "kernel": "<output-oracle>",
                    "reason": (
                        f"{side_name} output oracle evidence is missing or failed: "
                        f"count={count} matched={matched} failed={failed} hashesMatch={bool(expected) and expected == actual}"
                    ),
                })

    for kernel in kernels:
        artifact_path = _expected_spirv_artifact_path(kernel)
        source_path = _expected_wgsl_source_path(kernel)
        artifact_entry = {
            "kernel": kernel,
            "expectedSpirvPath": str(artifact_path),
            "expectedWgslPath": str(source_path),
        }
        if not source_path.exists():
            artifact_failures.append({**artifact_entry, "reason": "WGSL source is missing"})
            continue
        if not artifact_path.exists():
            artifact_failures.append({**artifact_entry, "reason": "SPIR-V artifact is missing"})
            continue
        source_hash = file_sha256(source_path)
        spirv_hash = file_sha256(artifact_path)
        matching_manifests = [
            (path, manifest)
            for path, manifest in manifests
            if str(manifest.get("module", "")).strip() == kernel
        ]
        if not matching_manifests:
            artifact_failures.append({
                **artifact_entry,
                "reason": "Doe receipt has no shader manifest for this kernel",
            })
            continue
        manifest_mismatch = False
        for manifest_path, manifest in matching_manifests:
            if manifest.get("wgslSha256") != source_hash:
                artifact_failures.append({
                    **artifact_entry,
                    "manifestPath": str(manifest_path),
                    "reason": (
                        "shader manifest WGSL hash is stale: "
                        f"manifest={manifest.get('wgslSha256')!r} current={source_hash}"
                    ),
                })
                manifest_mismatch = True
            if manifest.get("spirvSha256") != spirv_hash:
                artifact_failures.append({
                    **artifact_entry,
                    "manifestPath": str(manifest_path),
                    "reason": (
                        "shader manifest SPIR-V hash does not match executed artifact: "
                        f"manifest={manifest.get('spirvSha256')!r} current={spirv_hash}"
                    ),
                })
                manifest_mismatch = True
        if not manifest_mismatch:
            resolved_artifacts.append({
                **artifact_entry,
                "wgslSha256": source_hash,
                "spirvSha256": spirv_hash,
            })
    details["resolvedSpirvArtifacts"] = resolved_artifacts
    artifact_failures.extend(oracle_failures)
    details["shaderArtifactFailures"] = artifact_failures
    details["nativeShaderArtifactMismatchCount"] = len(artifact_failures)
    if not artifact_failures:
        return True, True, details, ""
    failure_summary = "; ".join(
        f"{entry.get('kernel', '<unknown>')}: {entry.get('reason', 'artifact mismatch')}"
        for entry in artifact_failures
    )
    return (
        True,
        False,
        details,
        "strict native Vulkan compare requires source-bound SPIR-V artifacts for kernel_dispatch workloads; "
        f"{failure_summary}",
    )
