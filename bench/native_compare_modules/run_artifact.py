"""Build and load standalone run receipts for product-based benchmarking."""

from __future__ import annotations

import json
import os
import platform
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from bench.lib import metal_pipeline_cache_manifest as metal_cache_manifest
from native_compare_modules import reporting as reporting_mod
from native_compare_modules import timing_selection as timing_selection_mod
from native_compare_modules.runner import file_sha256
from native_compare_modules.workload_provenance import workload_manifest_provenance
from native_compare_modules.workload_spec import ProductRunConfig, WorkloadSpec


REPO_ROOT = Path(__file__).resolve().parents[2]
RUN_ARTIFACT_SCHEMA_VERSION = 1
SUPPORTED_RUN_ARTIFACT_SCHEMA_VERSIONS = {1, 2}
RUN_ARTIFACT_KIND = "run-receipt"
ENV_WRAPPER = "env"
ENV_PATH_VARS = ("DYLD_LIBRARY_PATH", "LD_LIBRARY_PATH", "PATH")
DAWN_BACKEND_MARKERS = ("dawn_delegate", "dawn_direct")
DAWN_DELEGATE_LIBRARY_NAMES = (
    "libwebgpu_dawn.dylib",
    "libwebgpu_dawn.so",
    "libwebgpu_dawn.dll",
    "webgpu_dawn.dll",
)


def _safe_float(value: Any) -> float | None:
    return reporting_mod.safe_float(value)


def _sample_command(sample: dict[str, Any]) -> list[str]:
    command = sample.get("command", [])
    if isinstance(command, list):
        return [str(part) for part in command]
    if isinstance(command, str):
        return command.split()
    return []


def _timing_class(sample: dict[str, Any]) -> str:
    timing_source = str(sample.get("timingSource", "")).strip()
    if not timing_source:
        return ""
    return timing_selection_mod.classify_timing_source(timing_source)


def _subphase_ms(trace_meta: dict[str, Any]) -> dict[str, float | None]:
    execution_total_ns = _safe_float(trace_meta.get("executionTotalNs"))
    setup_ns = _safe_float(trace_meta.get("executionSetupTotalNs"))
    encode_ns = _safe_float(trace_meta.get("executionEncodeTotalNs"))
    submit_wait_ns = _safe_float(trace_meta.get("executionSubmitWaitTotalNs"))
    gpu_ns = _safe_float(trace_meta.get("gpuTimestampNs"))
    return {
        "executionMs": (
            execution_total_ns / 1_000_000.0 if execution_total_ns is not None else None
        ),
        "setupMs": setup_ns / 1_000_000.0 if setup_ns is not None else None,
        "encodeMs": encode_ns / 1_000_000.0 if encode_ns is not None else None,
        "submitWaitMs": (
            submit_wait_ns / 1_000_000.0 if submit_wait_ns is not None else None
        ),
        "gpuTimestampMs": gpu_ns / 1_000_000.0 if gpu_ns is not None else None,
    }


def _sample_success(sample: dict[str, Any]) -> bool:
    return int(sample.get("returnCode", 1)) == 0


def _sample_timing(sample: dict[str, Any]) -> dict[str, Any]:
    timing = sample.get("timing", {})
    return timing if isinstance(timing, dict) else {}


def _copy_optional_sample_fields(sample: dict[str, Any]) -> dict[str, Any]:
    copied: dict[str, Any] = {}
    timing = _sample_timing(sample)
    if timing:
        copied["timing"] = timing
    int_fields = (
        "commandRepeat",
        "uploadIgnoreFirstOps",
        "uploadSubmitEvery",
    )
    for field_name in int_fields:
        value = reporting_mod.safe_float(sample.get(field_name))
        if value is not None:
            copied[field_name] = int(value)
    float_fields = (
        "timingNormalizationDivisor",
        "workloadUnitNormalizationDivisor",
    )
    for field_name in float_fields:
        value = _safe_float(sample.get(field_name))
        if value is not None:
            copied[field_name] = value
    string_fields = (
        "uploadBufferUsage",
        "workloadDomain",
        "strictNormalizationUnit",
    )
    for field_name in string_fields:
        if field_name in sample:
            copied[field_name] = str(sample.get(field_name, "")).strip()
    return copied


def _receipt_samples(run_result: dict[str, Any]) -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []
    for sample in run_result.get("commandSamples", []):
        if not isinstance(sample, dict):
            continue
        return_code = int(sample.get("returnCode", 1))
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            trace_meta = {}
        samples.append(
            {
                "runIndex": int(sample.get("runIndex", 0)),
                "command": _sample_command(sample),
                "wallMs": _safe_float(sample.get("elapsedMs")),
                "measuredRawMs": _safe_float(sample.get("measuredRawMs")),
                "measuredMs": _safe_float(sample.get("measuredMs")),
                "timingSource": str(sample.get("timingSource", "")).strip(),
                "timingClass": _timing_class(sample),
                "traceArtifacts": {
                    "jsonlPath": str(sample.get("traceJsonlPath", "")).strip(),
                    "metaPath": str(sample.get("traceMetaPath", "")).strip(),
                },
                "subphasesMs": _subphase_ms(trace_meta),
                "resource": sample.get("resource", {}),
                "returnCode": return_code,
                "success": return_code == 0,
                "traceMeta": trace_meta,
                **_copy_optional_sample_fields(sample),
            }
        )
    return samples


def _is_env_assignment(token: str) -> bool:
    name, separator, _value = token.partition("=")
    return bool(separator and name and not name.startswith("-"))


def _unwrap_env_command(command: list[str]) -> list[str]:
    if not command or command[0] != ENV_WRAPPER:
        return command
    index = 1
    while index < len(command):
        token = command[index]
        if token == "--":
            return command[index + 1 :]
        if _is_env_assignment(token):
            index += 1
            continue
        if token in ("-i", "-0"):
            index += 1
            continue
        return command[index:]
    return []


def _resolve_binary(command: list[str]) -> tuple[str, str]:
    command = _unwrap_env_command(command)
    if not command:
        return "", ""
    raw_binary = command[0]
    candidate = Path(raw_binary)
    if candidate.exists():
        return str(candidate), file_sha256(candidate)
    resolved = shutil.which(raw_binary)
    if not resolved:
        return raw_binary, ""
    resolved_path = Path(resolved)
    return str(resolved_path), file_sha256(resolved_path)


def _env_search_paths(command: list[str]) -> list[Path]:
    if not command or command[0] != ENV_WRAPPER:
        return []

    paths: list[Path] = []
    index = 1
    while index < len(command):
        token = command[index]
        if token == "--":
            break
        if not _is_env_assignment(token):
            if token in ("-i", "-0"):
                index += 1
                continue
            break
        name, _separator, value = token.partition("=")
        if name in ENV_PATH_VARS:
            for raw_part in value.split(os.pathsep):
                part = raw_part.strip()
                if not part or part.startswith("$"):
                    continue
                paths.append(Path(part))
        index += 1
    return paths


def _resolve_dawn_delegate_library(command: list[str]) -> tuple[str, str] | None:
    search_paths = _env_search_paths(command)
    if not search_paths:
        search_paths = [Path("bench/vendor/dawn/out/Release")]

    for directory in search_paths:
        for library_name in DAWN_DELEGATE_LIBRARY_NAMES:
            candidate = directory / library_name
            if candidate.is_file():
                return str(candidate), file_sha256(candidate)
    return None


def _native_delegate_identity(
    *,
    executor_id: str,
    execution_backend: str,
    command: list[str],
) -> dict[str, str] | None:
    identity_key = f"{executor_id} {execution_backend}".lower()
    if not any(marker in identity_key for marker in DAWN_BACKEND_MARKERS):
        return None
    resolved = _resolve_dawn_delegate_library(command)
    if resolved is None:
        return None
    library_path, library_sha256 = resolved
    return {
        "kind": "dawn",
        "libraryPath": library_path,
        "librarySha256": library_sha256,
    }


def _infer_runtime_host(
    *,
    executor_id: str,
    samples: list[dict[str, Any]],
) -> str:
    for sample in samples:
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            continue
        runtime_host = str(trace_meta.get("runtimeHost", "")).strip().lower()
        if runtime_host:
            return runtime_host
        execution_backend = str(trace_meta.get("executionBackend", "")).strip().lower()
        if "node" in execution_backend:
            return "node"
        if "bun" in execution_backend:
            return "bun"
        if "deno" in execution_backend:
            return "deno"
    executor = executor_id.lower()
    if "node" in executor:
        return "node"
    if "bun" in executor:
        return "bun"
    if "deno" in executor:
        return "deno"
    return "native"


def _package_identity(provider_name: str) -> dict[str, str]:
    package_name = provider_name.strip()
    if not package_name:
        return {
            "packageName": "",
            "packageVersion": "",
            "packageLockHash": "",
        }
    if package_name == "doe-gpu" or package_name.startswith("doe-gpu/"):
        package_path = REPO_ROOT / "packages" / "doe-gpu" / "package.json"
        if package_path.exists():
            payload = json.loads(package_path.read_text(encoding="utf-8"))
            return {
                "packageName": "doe-gpu",
                "packageVersion": str(payload.get("version", "")).strip(),
                "packageLockHash": file_sha256(package_path),
            }
    return {
        "packageName": package_name,
        "packageVersion": "",
        "packageLockHash": "",
    }


def _runtime_identity(
    *,
    executor_id: str,
    samples: list[dict[str, Any]],
) -> dict[str, Any]:
    first_sample = samples[0] if samples else {}
    command = first_sample.get("command", [])
    if not isinstance(command, list):
        command = []
    binary_path, binary_sha256 = _resolve_binary([str(part) for part in command])
    trace_meta = first_sample.get("traceMeta", {})
    if not isinstance(trace_meta, dict):
        trace_meta = {}
    provider_name = str(
        trace_meta.get("executionProviderName")
        or trace_meta.get("providerName")
        or ""
    ).strip()
    payload = {
        "runtimeHost": _infer_runtime_host(
            executor_id=executor_id,
            samples=samples,
        ),
        "binaryPath": binary_path,
        "binarySha256": binary_sha256,
        "executionBackend": str(trace_meta.get("executionBackend", "")).strip(),
        "providerId": str(
            trace_meta.get("executionProvider")
            or trace_meta.get("provider")
            or ""
        ).strip(),
        "providerName": provider_name,
    }
    native_delegate = _native_delegate_identity(
        executor_id=executor_id,
        execution_backend=str(trace_meta.get("executionBackend", "")).strip(),
        command=[str(part) for part in command],
    )
    if native_delegate is not None:
        payload["nativeDelegate"] = native_delegate
    payload.update(_package_identity(provider_name))
    # Native pipeline cache state + warmup telemetry. The Zig runtime
    # emits a nested `pipelineCache` object in trace_meta containing state
    # (enabled|disabled), reason (default|cli-flag|non-doe-backend|platform-
    # unsupported), warmupCount, and warmupNs. Surfacing it inside
    # runtimeIdentity lets the comparability gate verify which native cache
    # mode each side ran with and quantify any cache-derived savings.
    # Backwards-compat: if the new nested object is absent, fall back to the
    # legacy top-level pipelineCacheWarmupCount/Ns fields (older artifacts).
    pipeline_cache = _pipeline_cache_telemetry(trace_meta)
    if pipeline_cache is not None:
        payload["pipelineCache"] = pipeline_cache
    return payload


def _pipeline_cache_telemetry(trace_meta: dict[str, Any]) -> dict[str, Any] | None:
    """Read native pipeline cache state + warmup telemetry from trace_meta.

    Prefers the nested `pipelineCache` object emitted by the Zig runtime today
    (state, reason, warmupCount, warmupNs). Falls back to legacy top-level
    `pipelineCacheWarmupCount` / `pipelineCacheWarmupNs` for older artifacts;
    in that path the state/reason are reported as "unknown" so a reader can
    distinguish "field absent because old artifact" from "field present with
    a known state". Returns None if neither shape is present.
    """
    nested = trace_meta.get("pipelineCache")
    if isinstance(nested, dict):
        payload = {
            "state": str(nested.get("state", "unknown")).strip() or "unknown",
            "reason": str(nested.get("reason", "unknown")).strip() or "unknown",
            "warmupCount": int(nested.get("warmupCount") or 0),
            "warmupNs": int(nested.get("warmupNs") or 0),
        }
        backend = str(nested.get("backend", "")).strip()
        if backend:
            payload["backend"] = backend
        if nested.get("flushNs") is not None:
            payload["flushNs"] = int(nested.get("flushNs") or 0)
        return payload
    legacy_count = trace_meta.get("pipelineCacheWarmupCount")
    legacy_ns = trace_meta.get("pipelineCacheWarmupNs")
    if legacy_count is None and legacy_ns is None:
        return None
    return {
        "state": "unknown",
        "reason": "unknown",
        "warmupCount": int(legacy_count or 0),
        "warmupNs": int(legacy_ns or 0),
    }


def _host_identity(
    *,
    workload_spec: WorkloadSpec,
    samples: list[dict[str, Any]],
) -> dict[str, Any]:
    trace_meta: dict[str, Any] = {}
    if samples:
        first_trace_meta = samples[0].get("traceMeta", {})
        if isinstance(first_trace_meta, dict):
            trace_meta = first_trace_meta
    adapter_info = trace_meta.get("adapterInfo", {})
    if not isinstance(adapter_info, dict):
        adapter_info = {}
    vendor_id = reporting_mod.safe_int(adapter_info.get("vendorID"))
    device_id = reporting_mod.safe_int(adapter_info.get("deviceID"))
    driver_version = reporting_mod.safe_int(adapter_info.get("driverVersion"))
    runtime_driver = (
        str(driver_version)
        if driver_version > 0
        else ""
    )
    return {
        "hostname": platform.node(),
        "os": platform.system().lower(),
        "kernel": platform.release(),
        "arch": platform.machine(),
        "api": workload_spec.api,
        "driver": runtime_driver or str(trace_meta.get("driver", "")).strip() or workload_spec.driver,
        "adapter": {
            "vendor": str(adapter_info.get("vendor", "")).strip() or workload_spec.vendor,
            "device": str(adapter_info.get("device", "")).strip(),
            "architecture": str(adapter_info.get("architecture", "")).strip(),
            "description": str(adapter_info.get("description", "")).strip(),
            "vendorID": vendor_id,
            "deviceID": device_id,
            "driverVersion": driver_version,
        },
    }


_AGGREGATE_FIELDS = ("wallMs", "measuredMs", "measuredRawMs")


def _sample_aggregates(samples: list[dict[str, Any]]) -> dict[str, dict[str, float]]:
    successful = [s for s in samples if s.get("success") is True]
    aggregates: dict[str, dict[str, float]] = {}
    for field_name in _AGGREGATE_FIELDS:
        values = [
            float(s[field_name])
            for s in successful
            if isinstance(s.get(field_name), (int, float))
        ]
        aggregates[field_name] = reporting_mod.format_stats(values)
    return aggregates


def _execution_summary(samples: list[dict[str, Any]]) -> dict[str, Any]:
    timed_samples = [
        sample
        for sample in samples
        if sample.get("success") is True
        and isinstance(sample.get("measuredMs"), (int, float))
    ]
    timing_sources = sorted(
        {
            str(sample.get("timingSource", "")).strip()
            for sample in samples
            if str(sample.get("timingSource", "")).strip()
        }
    )
    timing_classes = sorted(
        {
            str(sample.get("timingClass", "")).strip()
            for sample in samples
            if str(sample.get("timingClass", "")).strip()
        }
    )
    return {
        "success": bool(samples) and len(timed_samples) == len(samples),
        "timedSampleCount": len(timed_samples),
        "returnCodes": sorted(
            {int(sample.get("returnCode", 0)) for sample in samples}
        ),
        "timingSources": timing_sources,
        "timingClasses": timing_classes,
        "aggregates": _sample_aggregates(samples),
    }


def _resolve_metal_cache_asymmetry(
    *,
    workload_spec: WorkloadSpec,
    declared: bool,
    declared_note: str,
    pipeline_cache_state: str = "",
    pipeline_cache_reason: str = "",
) -> tuple[bool, str]:
    """Auto-set Apple Metal pathAsymmetry for cache-membership workloads.

    Returns the (path_asymmetry, path_asymmetry_note) the artifact should
    carry. When the workload spec already declared pathAsymmetry=true (e.g.
    UMA upload workloads), the declared note is preserved (auto-detection
    only ever escalates to true; it never demotes a declared asymmetry).

    Skips the cache-manifest auto-flag when the trace_meta indicates the cache
    was not active on this side. Concretely:
      - state="disabled" reason="cli-flag"             — fair-cold lane
      - state="disabled" reason="non-doe-backend"      — dawn_delegate Metal
      - state="disabled" reason="platform-unsupported" — non-Mac build
    In these cases the workload may be in the Doe Metal manifest but no Doe
    cache was loaded, so flagging pathAsymmetry would be incorrect. Workloads
    that explicitly declared pathAsymmetry (e.g. UMA upload) still keep it.
    """
    if declared:
        return True, declared_note
    if not metal_cache_manifest.workload_dispatches_cached_kernel(
        workload_api=workload_spec.api,
        workload_vendor=workload_spec.vendor,
        commands_path=workload_spec.commands_path,
    ):
        return declared, declared_note
    if pipeline_cache_state == "disabled":
        return declared, declared_note
    return True, metal_cache_manifest.auto_path_asymmetry_note()


def build_run_artifact(
    *,
    run_result: dict[str, Any],
    product: str,
    executor_id: str,
    workload_spec: WorkloadSpec,
    run_config: ProductRunConfig,
    iterations: int,
    warmup: int,
    resource_probe: str = "none",
    resource_sample_ms: int = 100,
    resource_sample_target_count: int = 0,
    workload_contract_path: str | Path | None = None,
) -> dict[str, Any]:
    """Wrap a run result into a standalone run receipt."""
    if workload_contract_path is None:
        raise ValueError(
            "run receipts require workload manifest metadata; pass "
            "workload_contract_path when building the receipt"
        )
    samples = _receipt_samples(run_result)
    invocation_command = samples[0]["command"] if samples else []
    workload_manifest = workload_manifest_provenance(workload_contract_path).to_dict()

    # Auto-detect Apple Metal pipeline-cache asymmetry. The Doe Metal native
    # runtime opens an MTLBinaryArchive at startup and pre-warms PSOs for any
    # kernel listed in `bench/kernels/doe_pipeline_archive.manifest`; the Dawn
    # delegate path has no equivalent cache, so any Apple Metal workload that
    # dispatches one of those kernels enjoys an undisclosed setup-time
    # advantage. CLAUDE.md non-negotiable #7 requires explicit transferability
    # caveats for hardware-path asymmetries; we set them here regardless of
    # what the workload manifest declared, because the asymmetry is determined
    # by the runtime, not the workload spec. The trace_meta pipelineCache
    # state is consulted to skip auto-flagging when the cache wasn't actually
    # active on this side (--no-pipeline-cache, dawn_delegate, non-Mac).
    sample_trace_meta: dict[str, Any] = {}
    if samples:
        first = samples[0].get("traceMeta", {})
        if isinstance(first, dict):
            sample_trace_meta = first
    cache_telemetry_for_asymmetry = _pipeline_cache_telemetry(sample_trace_meta) or {}
    auto_path_asymmetry, auto_path_note = _resolve_metal_cache_asymmetry(
        workload_spec=workload_spec,
        declared=workload_spec.path_asymmetry,
        declared_note=workload_spec.path_asymmetry_note,
        pipeline_cache_state=str(cache_telemetry_for_asymmetry.get("state", "")),
        pipeline_cache_reason=str(cache_telemetry_for_asymmetry.get("reason", "")),
    )

    artifact = {
        "schemaVersion": RUN_ARTIFACT_SCHEMA_VERSION,
        "artifactKind": RUN_ARTIFACT_KIND,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "product": product,
        "executorId": executor_id,
        "invocation": {
            "command": invocation_command,
            "iterations": iterations,
            "warmup": warmup,
            "resourceProbe": resource_probe,
            "resourceSampleMs": resource_sample_ms,
            "resourceSampleTargetCount": resource_sample_target_count,
        },
        "workloadManifest": workload_manifest,
        "workload": {
            "id": workload_spec.id,
            "name": workload_spec.name,
            "description": workload_spec.description,
            "domain": workload_spec.domain,
            "commandsPath": workload_spec.commands_path,
            "quirksPath": workload_spec.quirks_path,
            "planPath": workload_spec.plan_path,
            "vendor": workload_spec.vendor,
            "api": workload_spec.api,
            "family": workload_spec.family,
            "driver": workload_spec.driver,
            "comparable": workload_spec.comparable,
            "benchmarkClass": workload_spec.benchmark_class,
            "comparabilityNotes": workload_spec.comparability_notes,
            "directionalReason": workload_spec.directional_reason,
            "pathAsymmetry": auto_path_asymmetry,
            "pathAsymmetryNote": auto_path_note,
            "claimEligible": workload_spec.claim_eligible,
            "strictNormalizationUnit": workload_spec.strict_normalization_unit,
        },
        "normalization": {
            "commandRepeat": run_config.command_repeat,
            "ignoreFirstOps": run_config.ignore_first_ops,
            "timingDivisor": run_config.timing_divisor,
            "uploadBufferUsage": run_config.upload_buffer_usage,
            "uploadSubmitEvery": run_config.upload_submit_every,
            "timingNormalizationNote": run_config.timing_normalization_note,
            "allowNoExecution": run_config.allow_no_execution,
        },
        "runtimeIdentity": _runtime_identity(
            executor_id=executor_id,
            samples=samples,
        ),
        "hostIdentity": _host_identity(
            workload_spec=workload_spec,
            samples=samples,
        ),
        "execution": _execution_summary(samples),
        "samples": samples,
    }
    return artifact


def write_run_artifact(artifact: dict[str, Any], path: Path) -> Path:
    """Write a run receipt to disk."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(artifact, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def _legacy_workload_manifest(data: dict[str, Any]) -> dict[str, Any]:
    contract = data.get("workloadContract")
    if isinstance(contract, dict):
        path = str(contract.get("path", "")).strip()
        if path and Path(path).exists():
            return workload_manifest_provenance(path).to_dict()
        return {
            "path": path,
            "sha256": str(contract.get("sha256", "")).strip(),
            "ownership": "unknown",
            "inputFreshness": "unknown",
            "freshnessReason": "legacy run artifact missing workload manifest provenance",
        }
    raise ValueError("legacy run artifact missing workloadContract metadata")


def _legacy_samples(data: dict[str, Any]) -> list[dict[str, Any]]:
    samples: list[dict[str, Any]] = []
    for sample in data.get("commandSamples", []):
        if not isinstance(sample, dict):
            continue
        return_code = int(sample.get("returnCode", 1))
        trace_meta = sample.get("traceMeta", {})
        if not isinstance(trace_meta, dict):
            trace_meta = {}
        samples.append(
            {
                "runIndex": int(sample.get("runIndex", 0)),
                "command": _sample_command(sample),
                "wallMs": _safe_float(sample.get("elapsedMs")),
                "measuredRawMs": _safe_float(
                    sample.get("measuredRawMs", sample.get("measuredMs"))
                ),
                "measuredMs": _safe_float(sample.get("measuredMs")),
                "timingSource": str(sample.get("timingSource", "")).strip(),
                "timingClass": _timing_class(sample),
                "traceArtifacts": {
                    "jsonlPath": str(sample.get("traceJsonlPath", "")).strip(),
                    "metaPath": str(sample.get("traceMetaPath", "")).strip(),
                },
                "subphasesMs": _subphase_ms(trace_meta),
                "resource": sample.get("resource", {}),
                "returnCode": return_code,
                "success": return_code == 0,
                "traceMeta": trace_meta,
                **_copy_optional_sample_fields(sample),
            }
        )
    return samples


def _normalize_legacy_artifact(data: dict[str, Any]) -> dict[str, Any]:
    workload = data.get("workload", {})
    if not isinstance(workload, dict):
        raise ValueError("legacy run artifact missing workload object")
    run_parameters = data.get("runParameters", {})
    if not isinstance(run_parameters, dict):
        run_parameters = {}
    host = data.get("host", {})
    if not isinstance(host, dict):
        host = {}
    samples = _legacy_samples(data)
    execution = _execution_summary(samples)
    # Apply the same Apple Metal cache-asymmetry auto-detection used in
    # build_run_artifact, so legacy artifacts loaded today carry the correct
    # disclosure. Auto-detection only escalates to true; never demotes. The
    # trace_meta pipelineCache state is consulted to skip auto-flagging when
    # the cache wasn't actually active on this side (--no-pipeline-cache,
    # dawn_delegate, non-Mac).
    declared_path_asymmetry = bool(workload.get("pathAsymmetry", False))
    declared_path_note = str(workload.get("pathAsymmetryNote", "")).strip()
    legacy_workload_api = str(workload.get("api", "")).strip()
    legacy_workload_vendor = str(workload.get("vendor", "")).strip()
    legacy_commands_path = str(workload.get("commandsPath", "")).strip()
    legacy_trace_meta: dict[str, Any] = {}
    if samples:
        first = samples[0].get("traceMeta", {})
        if isinstance(first, dict):
            legacy_trace_meta = first
    legacy_cache = _pipeline_cache_telemetry(legacy_trace_meta) or {}
    legacy_cache_state = str(legacy_cache.get("state", ""))
    if (
        not declared_path_asymmetry
        and legacy_cache_state != "disabled"
        and metal_cache_manifest.workload_dispatches_cached_kernel(
            workload_api=legacy_workload_api,
            workload_vendor=legacy_workload_vendor,
            commands_path=legacy_commands_path,
        )
    ):
        declared_path_asymmetry = True
        if not declared_path_note:
            declared_path_note = metal_cache_manifest.auto_path_asymmetry_note()
    return {
        "schemaVersion": RUN_ARTIFACT_SCHEMA_VERSION,
        "artifactKind": RUN_ARTIFACT_KIND,
        "generatedAt": str(data.get("generatedAt", "")).strip(),
        "product": str(data.get("product", "")).strip(),
        "executorId": str(data.get("executorId", "")).strip(),
        "invocation": {
            "command": samples[0]["command"] if samples else [],
            "iterations": int(run_parameters.get("iterations", len(samples))),
            "warmup": int(run_parameters.get("warmup", 0)),
            "resourceProbe": str(run_parameters.get("resourceProbe", "")).strip(),
            "resourceSampleMs": int(run_parameters.get("resourceSampleMs", 0) or 0),
            "resourceSampleTargetCount": int(
                run_parameters.get("resourceSampleTargetCount", 0) or 0
            ),
        },
        "workloadManifest": _legacy_workload_manifest(data),
        "workload": {
            "id": str(workload.get("id", "")).strip(),
            "name": str(workload.get("name", "")).strip(),
            "description": str(workload.get("description", "")).strip(),
            "domain": str(workload.get("domain", "")).strip(),
            "commandsPath": str(workload.get("commandsPath", "")).strip(),
            "quirksPath": str(workload.get("quirksPath", "")).strip(),
            "planPath": str(workload.get("planPath", "")).strip(),
            "vendor": str(workload.get("vendor", "")).strip(),
            "api": str(workload.get("api", "")).strip(),
            "family": str(workload.get("family", "")).strip(),
            "driver": str(workload.get("driver", "")).strip(),
            "comparable": bool(workload.get("comparable", False)),
            "benchmarkClass": str(workload.get("benchmarkClass", "")).strip(),
            "comparabilityNotes": str(workload.get("comparabilityNotes", "")).strip(),
            "directionalReason": str(workload.get("directionalReason", "")).strip(),
            "pathAsymmetry": declared_path_asymmetry,
            "pathAsymmetryNote": declared_path_note,
            "claimEligible": bool(workload.get("claimEligible", True)),
            "strictNormalizationUnit": str(
                workload.get("strictNormalizationUnit", "")
            ).strip(),
        },
        "normalization": {
            "commandRepeat": int(run_parameters.get("commandRepeat", 1) or 1),
            "ignoreFirstOps": int(run_parameters.get("ignoreFirstOps", 0) or 0),
            "timingDivisor": float(run_parameters.get("timingDivisor", 1.0) or 1.0),
            "uploadBufferUsage": str(
                run_parameters.get("uploadBufferUsage", "")
            ).strip(),
            "uploadSubmitEvery": int(run_parameters.get("uploadSubmitEvery", 1) or 1),
            "timingNormalizationNote": str(
                run_parameters.get("timingNormalizationNote", "")
            ).strip(),
            "allowNoExecution": bool(run_parameters.get("allowNoExecution", False)),
        },
        "runtimeIdentity": _runtime_identity(
            executor_id=str(data.get("executorId", "")).strip(),
            samples=samples,
        ),
        "hostIdentity": {
            "hostname": platform.node(),
            "os": str(host.get("os", "")).strip() or platform.system().lower(),
            "kernel": platform.release(),
            "arch": str(host.get("arch", "")).strip() or platform.machine(),
            "api": str(workload.get("api", "")).strip(),
            "driver": str(workload.get("driver", "")).strip(),
            "adapter": {
                "vendor": str(workload.get("vendor", "")).strip(),
                "device": "",
                "architecture": "",
                "description": "",
            },
        },
        "execution": execution,
        "samples": samples,
    }


def load_run_artifact(path: str | Path) -> dict[str, Any]:
    """Load and normalize a run receipt from disk."""
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"run receipt not found: {p}")
    data = json.loads(p.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"run receipt must be a JSON object: {p}")
    version = data.get("schemaVersion")
    if version not in SUPPORTED_RUN_ARTIFACT_SCHEMA_VERSIONS:
        raise ValueError(
            f"unsupported run receipt schemaVersion={version}, "
            f"expected one of {sorted(SUPPORTED_RUN_ARTIFACT_SCHEMA_VERSIONS)}: {p}"
        )
    artifact_kind = data.get("artifactKind")
    if artifact_kind == RUN_ARTIFACT_KIND and version == RUN_ARTIFACT_SCHEMA_VERSION:
        for key in (
            "product",
            "executorId",
            "invocation",
            "workloadManifest",
            "workload",
            "normalization",
            "runtimeIdentity",
            "hostIdentity",
            "execution",
            "samples",
        ):
            if key not in data:
                raise ValueError(f"run receipt missing required field {key!r}: {p}")
        return data
    if artifact_kind == "run":
        return _normalize_legacy_artifact(data)
    raise ValueError(
        f"expected artifactKind={RUN_ARTIFACT_KIND!r} or 'run', "
        f"got {artifact_kind!r}: {p}"
    )


def artifact_filename(product: str, workload_id: str, timestamp: str) -> str:
    """Generate a conventional run receipt filename."""
    return f"{product}-{workload_id}-{timestamp}.run.json"
