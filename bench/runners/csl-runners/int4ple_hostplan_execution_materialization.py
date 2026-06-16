"""Launch binding materialization for INT4 PLE HostPlan execution plans."""

from __future__ import annotations

from typing import Any

from int4ple_hostplan_execution_buffers import (
    _buffer_capacity,
    _buffer_storage_class,
    _decode_step_count,
    _grid_pe_count,
    _normalized_shape,
    _state_index,
    _state_root_name,
    _weight_index,
)
from int4ple_hostplan_execution_common import (
    PREFILL_Q4K_GEMV_PATTERN,
    _dtype_byte_width,
    _dtype_for_elem_type,
    _memcpy_data_type,
    _resolve_size_expr,
    _runtime_scheduler,
)
from int4ple_hostplan_execution_transforms import (
    _attention_tiled_output_transform,
    _attention_tiled_source_transform,
    _dense_gemv_output_transform,
    _dense_gemv_source_transform,
    _prefill_q4k_gemv_output_transform,
    _prefill_q4k_gemv_source_transform,
    _rope_output_transform,
    _rope_source_transform,
    _row_parallel_output_transform,
    _row_parallel_source_transform,
    _summa_output_transform,
    _summa_source_transform,
)

def _memcpy_element_count(elem_type: str, raw_element_count: int) -> int:
    if elem_type == "u8":
        return max(1, (raw_element_count + 3) // 4)
    return raw_element_count


def _target_geometry(
    target_name: str,
    compile_params: dict[str, int],
    runtime_config: dict[str, Any],
) -> dict[str, int]:
    runtime_pe_count = _grid_pe_count(runtime_config)
    width = int(compile_params.get("width") or 0)
    height = int(compile_params.get("height") or 0)
    if target_name in {
        "rope",
        "rmsnorm",
        "rmsnorm_prefill",
        "rmsnorm_decode",
        "final_norm_stable",
        "attn_head256",
        "attn_head512",
        "attn_decode",
        "gemv",
        "q4_widetile",
        "q4_decode_gemv",
        "sample",
    }:
        height = 1
    if target_name == "tiled":
        tiled_p = int(compile_params.get("P") or 0)
        width = tiled_p
        height = tiled_p
    if width <= 0:
        width = 1
    if height <= 0:
        height = 1
    pe_count = width * height
    return {
        "width": width,
        "height": height,
        "peCount": pe_count,
        "runtimePeCount": runtime_pe_count or pe_count,
    }


def _weight_span_byte_length(weight_item: dict[str, Any] | None) -> int | None:
    if weight_item is None:
        return None
    spans = weight_item.get("spans") or []
    if isinstance(spans, list) and spans:
        total = 0
        for span in spans:
            if not isinstance(span, dict):
                return None
            try:
                total += int(span.get("size") or 0)
            except (TypeError, ValueError):
                return None
        if total > 0:
            return total
    try:
        raw = int(weight_item.get("byteSize") or 0)
    except (TypeError, ValueError):
        raw = 0
    return raw or None


def _binding_materialization(
    *,
    item: dict[str, Any],
    target_name: str,
    target_pattern: str,
    compile_params: dict[str, int],
    pe_program_arrays: dict[str, dict[str, Any]],
    pe_program_compile_time: dict[str, int],
    target_geometry: dict[str, int],
    runtime_config: dict[str, Any],
    binding_metadata: dict[str, Any] | None = None,
    target_phase_name: str = "base",
) -> dict[str, Any]:
    symbol = str(item.get("symbol") or "")
    role = str(item.get("role") or "")
    buffer = str(item.get("buffer") or "")
    weight_item = _weight_index(runtime_config).get(buffer.removeprefix("weight:"))
    state_item = _state_index(runtime_config).get(_state_root_name(buffer))
    compile_time = dict(pe_program_compile_time)
    compile_time.update(compile_params)
    compile_time.setdefault("chunk_size", 1024)
    decl = pe_program_arrays.get(symbol)
    if decl is not None:
        raw_elements_per_pe = _resolve_size_expr(str(decl["sizeExpr"]), compile_time)
        elem_type = str(decl["elemType"])
        elements_per_pe = (
            None
            if raw_elements_per_pe is None
            else _memcpy_element_count(elem_type, raw_elements_per_pe)
        )
    else:
        elements_per_pe = None
        elem_type = "u32" if role in {"tokenized_prompt", "generated_tokens", "position"} else "f32"
    if elements_per_pe is None:
        capacity = _buffer_capacity(
            buffer=buffer,
            role=role,
            runtime_config=runtime_config,
            weight_item=weight_item,
            state_item=state_item,
            decode_steps=_decode_step_count(_runtime_scheduler({"hostPlan": {"runtimeScheduler": {}}})),
        )
        planned_elements = capacity.get("plannedElementCount")
        if isinstance(planned_elements, int) and planned_elements > 0:
            elements_per_pe = max(
                1,
                planned_elements // max(1, target_geometry["peCount"]),
            )
        else:
            elements_per_pe = 1
    dtype = _dtype_for_elem_type(elem_type)
    if weight_item is not None:
        raw_source_transform = weight_item.get("sourceTransform")
        source_transform = (
            raw_source_transform
            if isinstance(raw_source_transform, dict)
            else None
        )
        if dtype == "f32" and str(weight_item.get("dtype") or "") == "f16":
            source_transform = {
                "kind": "f16_to_f32",
                "sourceDtype": "f16",
                "targetDtype": "f32",
            }
        elif dtype == "f32" and str(weight_item.get("dtype") or "") == "bf16":
            source_transform = {
                "kind": "bf16_to_f32",
                "sourceDtype": "bf16",
                "targetDtype": "f32",
            }
        elif dtype == "f32" and str(weight_item.get("dtype") or "") == "u8_q4k":
            source_transform = {
                "kind": "q4km_rowwise_to_f32",
                "sourceDtype": "u8_q4k",
                "targetDtype": "f32",
            }
        elif dtype == "f16" and str(weight_item.get("dtype") or "") == "f16":
            source_transform = {
                "kind": "f16_passthrough",
                "sourceDtype": "f16",
                "targetDtype": "f16",
            }
        elif dtype == "f16" and str(weight_item.get("dtype") or "") == "bf16":
            source_transform = {
                "kind": "bf16_to_f16",
                "sourceDtype": "bf16",
                "targetDtype": "f16",
            }
        elif dtype == "f16" and str(weight_item.get("dtype") or "") == "u8_q4k":
            source_transform = {
                "kind": "q4km_rowwise_to_f32",
                "sourceDtype": "u8_q4k",
                "targetDtype": "f32",
            }
        elif dtype == "u32" and str(weight_item.get("dtype") or "") == "u8_q4k":
            source_transform = {
                "kind": "u8_bytes_to_u32_words",
                "sourceDtype": "u8_q4k",
                "targetDtype": "u32",
            }
        span_byte_length = _weight_span_byte_length(weight_item)
    else:
        source_transform = None
        span_byte_length = None
    metadata_staging = (binding_metadata or {}).get("stagingTransform")
    source_transform = _summa_source_transform(
        symbol=symbol,
        role=role,
        target_name=target_name,
        target_pattern=target_pattern,
        compile_params=compile_params,
        runtime_config=runtime_config,
        item=item,
        dtype=dtype,
        weight_item=weight_item,
        source_transform=source_transform,
    )
    source_transform = _prefill_q4k_gemv_source_transform(
        symbol=symbol,
        role=role,
        target_pattern=target_pattern,
        compile_params=compile_params,
        runtime_config=runtime_config,
        item=item,
        dtype=dtype,
        weight_item=weight_item,
        source_transform=source_transform,
    )
    source_transform = _dense_gemv_source_transform(
        symbol=symbol,
        role=role,
        target_name=target_name,
        compile_params=compile_params,
        runtime_config=runtime_config,
        weight_item=weight_item,
        source_transform=source_transform,
    )
    source_transform = _row_parallel_source_transform(
        symbol=symbol,
        role=role,
        target_name=target_name,
        target_geometry=target_geometry,
        elements_per_pe=elements_per_pe,
        dtype=dtype,
        source_transform=source_transform,
    )
    source_transform = _rope_source_transform(
        symbol=symbol,
        role=role,
        target_name=target_name,
        compile_params=compile_params,
        item=item,
        dtype=dtype,
        source_transform=source_transform,
    )
    source_transform = _attention_tiled_source_transform(
        symbol=symbol,
        role=role,
        target_name=target_name,
        compile_params=compile_params,
        item=item,
        dtype=dtype,
        source_transform=source_transform,
    )
    if source_transform is None and isinstance(metadata_staging, dict):
        source_transform = metadata_staging
    output_transform = _summa_output_transform(
        symbol=symbol,
        target_name=target_name,
        target_pattern=target_pattern,
        compile_params=compile_params,
        item=item,
        dtype=dtype,
    )
    prefill_q4k_output_transform = _prefill_q4k_gemv_output_transform(
        symbol=symbol,
        target_pattern=target_pattern,
        compile_params=compile_params,
        item=item,
        dtype=dtype,
    )
    if prefill_q4k_output_transform is not None:
        output_transform = prefill_q4k_output_transform
    metadata_detile = (binding_metadata or {}).get("detileTransform")
    if output_transform is None and isinstance(metadata_detile, dict):
        output_transform = metadata_detile
    dense_output_transform = _dense_gemv_output_transform(
        symbol=symbol,
        target_name=target_name,
        compile_params=compile_params,
    )
    if dense_output_transform is not None:
        output_transform = dense_output_transform
    output_transform = _rope_output_transform(
        symbol=symbol,
        role=role,
        target_name=target_name,
        compile_params=compile_params,
        item=item,
        dtype=dtype,
        output_transform=output_transform,
    )
    output_transform = _attention_tiled_output_transform(
        symbol=symbol,
        role=role,
        target_name=target_name,
        compile_params=compile_params,
        item=item,
        dtype=dtype,
        output_transform=output_transform,
    )
    output_transform = _row_parallel_output_transform(
        symbol=symbol,
        role=role,
        target_name=target_name,
        elements_per_pe=elements_per_pe,
        dtype=dtype,
        output_transform=output_transform,
    )
    element_byte_width = _dtype_byte_width(dtype)
    planned_elements = elements_per_pe * target_geometry["peCount"]
    planned_bytes = planned_elements * element_byte_width
    if span_byte_length is not None and role == "weight":
        planned_bytes = span_byte_length
    materialization = {
        "buffer": buffer,
        "symbol": symbol,
        "role": role,
        "targetName": target_name,
        "targetGeometry": target_geometry,
        "dtype": dtype,
        "elemType": elem_type,
        "memcpyDataType": _memcpy_data_type(elem_type),
        "elementsPerPe": elements_per_pe,
        "elementByteWidth": element_byte_width,
        "plannedElementCount": planned_elements,
        "plannedByteLength": planned_bytes,
        "storageClass": _buffer_storage_class(buffer, role),
        "targetPhase": target_phase_name,
    }
    if binding_metadata:
        if isinstance(binding_metadata.get("bindingShape"), dict):
            materialization["bindingShape"] = binding_metadata["bindingShape"]
        if isinstance(binding_metadata.get("perPeShape"), dict):
            materialization["perPeShape"] = binding_metadata["perPeShape"]
        if binding_metadata.get("weightSource") is not None:
            materialization["weightSource"] = binding_metadata.get("weightSource")
    if weight_item is not None:
        materialization["weightMapping"] = {
            "weightKey": weight_item.get("weightKey") or weight_item.get("tensor"),
            "path": weight_item.get("path") or weight_item.get("shard"),
            "sha256": weight_item.get("sha256"),
            "byteOffset": int(weight_item.get("byteOffset") or weight_item.get("offsetBytes") or 0),
            "byteSize": int(weight_item.get("byteSize") or 0),
            "dtype": weight_item.get("dtype"),
            "shape": weight_item.get("shape") or [],
            "spans": weight_item.get("spans") or [],
        }
    if source_transform is not None:
        materialization["sourceTransform"] = source_transform
        materialization["stagingTransform"] = source_transform
    if output_transform is not None:
        materialization["outputTransform"] = output_transform
        materialization["detileTransform"] = output_transform
    if state_item is not None:
        materialization["stateOwnership"] = {
            "stateRoot": state_item.get("name"),
            "stateKind": state_item.get("kind"),
            "bytesPerPe": int(state_item.get("bytesPerPe") or 0),
        }
    return materialization



def _choose_launch_function(function_names: set[str]) -> str:
    if "compute" in function_names:
        return "compute"
    if len(function_names) == 1:
        return next(iter(function_names))
    return "pending_runtime_function_resolution"


def _buffers_by_launch(items: list[dict[str, Any]], key: str) -> dict[int, list[dict[str, Any]]]:
    by_launch: dict[int, list[dict[str, Any]]] = {}
    for item in items:
        launch_index = item.get(key)
        if not isinstance(launch_index, int):
            continue
        by_launch.setdefault(launch_index, []).append(item)
    return by_launch
