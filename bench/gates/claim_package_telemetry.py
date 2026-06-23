"""Doe package telemetry checks used by the release claim gate."""

from __future__ import annotations

from typing import Any


PACKAGE_EFFECTIVE_READBACK_OBLIGATION_ID = (
    "baseline_comparison_effective_readback_path_match"
)
DOE_PACKAGE_EXECUTION_BACKENDS = {
    "doe_bun_package",
    "doe_node_native_direct",
    "doe_node_webgpu",
}
DOE_PACKAGE_PRODUCT_PREFIXES = (
    "doe_gpu_bun_package",
    "doe_gpu_node_native_direct",
    "doe_gpu_node_package",
)
DOE_PACKAGE_REQUIRED_BOOL_FIELDS = (
    "packagePreparedSession",
    "packageSetupIncludedInSelectedTiming",
)
DOE_PACKAGE_REQUIRED_STRING_FIELDS = ("packageReadbackMode",)
DOE_PACKAGE_EFFECTIVE_READBACK_PATHS = {
    "native-map-read-copy-unmap",
    "mapAsync",
}
DOE_PACKAGE_REQUIRED_STRING_LIST_FIELDS = ("packageEffectiveReadbackPaths",)
DOE_PACKAGE_REQUIRED_OBJECT_FIELDS = (
    "packageFastPathStats",
    "packageNativeFastPaths",
    "packageStepBreakdownNs",
    "packageWriteBreakdown",
)
DOE_PACKAGE_WRITE_BREAKDOWN_COUNTER_FIELDS = (
    "batchCallCount",
    "batchedWriteCount",
    "dynamicWriteBytes",
    "dynamicWriteCount",
    "staticBufferLoadBytes",
    "staticBufferLoadCount",
    "totalBytes",
    "totalCount",
    "unbatchedWriteCount",
)


def _successful_trace_metas(side_payload: Any) -> list[tuple[int, dict[str, Any]]]:
    if not isinstance(side_payload, dict):
        return []
    samples = side_payload.get("commandSamples")
    if not isinstance(samples, list):
        return []
    trace_metas: list[tuple[int, dict[str, Any]]] = []
    for sample_idx, sample in enumerate(samples):
        if not isinstance(sample, dict):
            continue
        if sample.get("returnCode") != 0:
            continue
        trace_meta = sample.get("traceMeta")
        if isinstance(trace_meta, dict):
            trace_metas.append((sample_idx, trace_meta))
    return trace_metas


def side_declares_doe_package(side_payload: Any) -> bool:
    if not isinstance(side_payload, dict):
        return False
    product_name = str(side_payload.get("name", "")).strip()
    if product_name.startswith(DOE_PACKAGE_PRODUCT_PREFIXES):
        return True
    for _, trace_meta in _successful_trace_metas(side_payload):
        execution_backend = str(trace_meta.get("executionBackend", "")).strip()
        if execution_backend in DOE_PACKAGE_EXECUTION_BACKENDS:
            return True
    return False


def required_comparability_obligation_ids_for_workload(
    *,
    require_claim_status: str,
    workload: dict[str, Any],
) -> set[str]:
    if require_claim_status != "claimable":
        return set()
    if side_declares_doe_package(workload.get("baseline")):
        return {PACKAGE_EFFECTIVE_READBACK_OBLIGATION_ID}
    if side_declares_doe_package(workload.get("comparison")):
        return {PACKAGE_EFFECTIVE_READBACK_OBLIGATION_ID}
    return set()


def _non_negative_number_dict(value: Any) -> bool:
    if not isinstance(value, dict) or not value:
        return False
    for item in value.values():
        if isinstance(item, bool):
            return False
        if not isinstance(item, (int, float)):
            return False
        if float(item) < 0.0:
            return False
    return True


def _non_negative_number(value: Any) -> bool:
    if isinstance(value, bool):
        return False
    if not isinstance(value, (int, float)):
        return False
    return float(value) >= 0.0


def _bool_dict(value: Any) -> bool:
    if not isinstance(value, dict) or not value:
        return False
    return all(isinstance(item, bool) for item in value.values())


def package_write_breakdown_failures(
    *,
    workload_id: str,
    side_name: str,
    sample_idx: int,
    value: Any,
) -> list[str]:
    prefix = f"{workload_id}: {side_name} sample {sample_idx}"
    if not isinstance(value, dict) or not value:
        return [f"{prefix} missing packageWriteBreakdown object"]

    failures: list[str] = []
    batch_method = value.get("batchMethod")
    if not isinstance(batch_method, str) or not batch_method.strip():
        failures.append(f"{prefix} missing packageWriteBreakdown.batchMethod string")

    for field_name in DOE_PACKAGE_WRITE_BREAKDOWN_COUNTER_FIELDS:
        if not _non_negative_number(value.get(field_name)):
            failures.append(
                f"{prefix} missing packageWriteBreakdown.{field_name} "
                "non-negative number"
            )

    by_data_kind = value.get("byDataKind")
    if not isinstance(by_data_kind, dict) or not by_data_kind:
        failures.append(f"{prefix} missing packageWriteBreakdown.byDataKind object")
    by_semantic_phase = value.get("bySemanticPhase")
    if not isinstance(by_semantic_phase, dict) or not by_semantic_phase:
        failures.append(f"{prefix} missing packageWriteBreakdown.bySemanticPhase object")

    if failures:
        return failures

    total_count = value["totalCount"]
    batched_count = value["batchedWriteCount"]
    unbatched_count = value["unbatchedWriteCount"]
    static_count = value["staticBufferLoadCount"]
    dynamic_count = value["dynamicWriteCount"]
    total_bytes = value["totalBytes"]
    static_bytes = value["staticBufferLoadBytes"]
    dynamic_bytes = value["dynamicWriteBytes"]
    batch_call_count = value["batchCallCount"]

    if batched_count + unbatched_count != total_count:
        failures.append(
            f"{prefix} packageWriteBreakdown batched+unbatched count "
            "must equal totalCount"
        )
    if static_count + dynamic_count != total_count:
        failures.append(
            f"{prefix} packageWriteBreakdown static+dynamic count "
            "must equal totalCount"
        )
    if static_bytes + dynamic_bytes != total_bytes:
        failures.append(
            f"{prefix} packageWriteBreakdown static+dynamic bytes "
            "must equal totalBytes"
        )
    if batch_method == "none":
        if batched_count != 0 or batch_call_count != 0:
            failures.append(
                f"{prefix} packageWriteBreakdown batchMethod=none requires "
                "zero batchedWriteCount and batchCallCount"
            )
    elif batched_count <= 0 or batch_call_count <= 0:
        failures.append(
            f"{prefix} packageWriteBreakdown batchMethod={batch_method!r} "
            "requires positive batchedWriteCount and batchCallCount"
        )
    return failures


def doe_package_telemetry_failures(
    *,
    workload_id: str,
    side_name: str,
    side_payload: Any,
) -> list[str]:
    if not side_declares_doe_package(side_payload):
        return []

    failures: list[str] = []
    trace_metas = _successful_trace_metas(side_payload)
    if not trace_metas:
        return [
            f"{workload_id}: {side_name} Doe package payload has no successful traceMeta samples"
        ]

    observed_doe_package_sample = False
    for sample_idx, trace_meta in trace_metas:
        execution_backend = str(trace_meta.get("executionBackend", "")).strip()
        if execution_backend not in DOE_PACKAGE_EXECUTION_BACKENDS:
            failures.append(
                f"{workload_id}: {side_name} sample {sample_idx} "
                f"executionBackend={execution_backend!r} is not a Doe package backend"
            )
            continue
        observed_doe_package_sample = True

        for field_name in DOE_PACKAGE_REQUIRED_BOOL_FIELDS:
            if not isinstance(trace_meta.get(field_name), bool):
                failures.append(
                    f"{workload_id}: {side_name} sample {sample_idx} "
                    f"missing {field_name} bool"
                )
        for field_name in DOE_PACKAGE_REQUIRED_STRING_FIELDS:
            value = trace_meta.get(field_name)
            if not isinstance(value, str) or not value.strip():
                failures.append(
                    f"{workload_id}: {side_name} sample {sample_idx} "
                    f"missing {field_name} string"
                )
        for field_name in DOE_PACKAGE_REQUIRED_STRING_LIST_FIELDS:
            value = trace_meta.get(field_name)
            if not isinstance(value, list) or not value:
                failures.append(
                    f"{workload_id}: {side_name} sample {sample_idx} "
                    f"missing {field_name} non-empty string list"
                )
                continue
            invalid_items = [
                item
                for item in value
                if not isinstance(item, str)
                or item not in DOE_PACKAGE_EFFECTIVE_READBACK_PATHS
            ]
            if invalid_items:
                failures.append(
                    f"{workload_id}: {side_name} sample {sample_idx} "
                    f"{field_name} contains invalid readback path"
                )
        for field_name in DOE_PACKAGE_REQUIRED_OBJECT_FIELDS:
            value = trace_meta.get(field_name)
            if field_name == "packageNativeFastPaths":
                if not _bool_dict(value):
                    failures.append(
                        f"{workload_id}: {side_name} sample {sample_idx} "
                        "missing packageNativeFastPaths boolean map"
                    )
            elif field_name in {"packageFastPathStats", "packageStepBreakdownNs"}:
                if not _non_negative_number_dict(value):
                    failures.append(
                        f"{workload_id}: {side_name} sample {sample_idx} "
                        f"missing {field_name} non-negative numeric map"
                    )
            elif field_name == "packageWriteBreakdown":
                failures.extend(
                    package_write_breakdown_failures(
                        workload_id=workload_id,
                        side_name=side_name,
                        sample_idx=sample_idx,
                        value=value,
                    )
                )
            elif not isinstance(value, dict) or not value:
                failures.append(
                    f"{workload_id}: {side_name} sample {sample_idx} "
                    f"missing {field_name} object"
                )

    if not observed_doe_package_sample:
        failures.append(
            f"{workload_id}: {side_name} payload did not report a Doe package backend"
        )
    return failures
