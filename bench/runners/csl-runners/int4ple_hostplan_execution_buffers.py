"""Buffer planning helpers for INT4 PLE HostPlan execution plans."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from int4ple_hostplan_execution_common import (
    _dtype_byte_width,
)

def _compile_params(compile_dir: Path) -> dict[str, int]:
    out_path = compile_dir / "out.json"
    if not out_path.is_file():
        return {}
    try:
        value = json.loads(out_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    params = value.get("params") or {}
    if not isinstance(params, dict):
        return {}
    parsed: dict[str, int] = {}
    for key, raw in params.items():
        try:
            parsed[str(key)] = int(raw)
        except (TypeError, ValueError):
            continue
    return parsed


def _target_grid(compile_params: dict[str, int]) -> dict[str, int] | None:
    width = int(compile_params.get("width") or compile_params.get("P") or 0)
    height = int(compile_params.get("height") or compile_params.get("P") or 0)
    if width <= 0 or height <= 0:
        return None
    return {"width": width, "height": height, "peCount": width * height}


def _product(values: list[Any]) -> int | None:
    result = 1
    seen = False
    for value in values:
        try:
            parsed = int(value)
        except (TypeError, ValueError):
            return None
        if parsed <= 0:
            return None
        result *= parsed
        seen = True
    return result if seen else None


def _normalized_shape(values: list[Any]) -> list[int]:
    parsed: list[int] = []
    for value in values:
        try:
            item = int(value)
        except (TypeError, ValueError):
            return []
        if item <= 0:
            return []
        parsed.append(item)
    return parsed


def _weight_index(runtime_config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for item in runtime_config.get("weightMappings") or []:
        if not isinstance(item, dict):
            continue
        key = item.get("weightKey") or item.get("tensor")
        if not isinstance(key, str) or not key:
            continue
        result[key] = item
    return result


def _state_index(runtime_config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for item in runtime_config.get("stateBuffers") or []:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if isinstance(name, str) and name:
            result[name] = item
    return result


def _state_root_name(buffer: str) -> str:
    if not buffer.startswith("state:"):
        return ""
    return buffer.removeprefix("state:").split(":", 1)[0]


def _grid_pe_count(runtime_config: dict[str, Any]) -> int | None:
    grid = (runtime_config.get("memoryPlan") or {}).get("grid") or {}
    try:
        width = int(grid.get("width") or 0)
        height = int(grid.get("height") or 0)
    except (TypeError, ValueError):
        return None
    if width <= 0 or height <= 0:
        return None
    return width * height


def _decode_step_count(runtime_scheduler: dict[str, Any]) -> int:
    transcript = runtime_scheduler.get("transcriptCaptureSchedule") or {}
    try:
        return int(transcript.get("expectedActualDecodeSteps") or 0)
    except (TypeError, ValueError):
        return 0


def _buffer_storage_class(buffer: str, role: str) -> str:
    if buffer.startswith("weight:") or role == "weight":
        return "external_weight"
    if buffer.startswith("state:") or role in {"kv_cache", "position", "position_encoding", "uniform"}:
        return "persistent_state"
    if buffer.startswith("input:") or role == "tokenized_prompt":
        return "shared_input"
    if role == "generated_tokens":
        return "captured_output"
    if role == "logits":
        return "captured_output" if buffer.startswith("logits:") else "intermediate"
    return "intermediate"


def _buffer_dtype(
    *,
    role: str,
    weight_item: dict[str, Any] | None,
    state_item: dict[str, Any] | None,
) -> str:
    if weight_item is not None:
        return str(weight_item.get("dtype") or "unknown")
    if role in {"tokenized_prompt", "generated_tokens", "position"}:
        return "u32"
    if role == "weight":
        return "unknown"
    if role == "kv_cache":
        return "opaque"
    if role == "position_encoding":
        return "f32"
    if state_item is not None and str(state_item.get("kind") or "") == "position":
        return "u32"
    return "f32"


def _buffer_capacity(
    *,
    buffer: str,
    role: str,
    runtime_config: dict[str, Any],
    weight_item: dict[str, Any] | None,
    state_item: dict[str, Any] | None,
    decode_steps: int,
) -> dict[str, Any]:
    model = runtime_config.get("modelConfig") or {}
    try:
        hidden_dim = int(model.get("hiddenDim") or 0)
    except (TypeError, ValueError):
        hidden_dim = 0
    try:
        vocab_size = int(model.get("vocabSize") or model.get("pleVocabSize") or 0)
    except (TypeError, ValueError):
        vocab_size = 0
    try:
        max_seq_len = int(model.get("maxSeqLen") or 0)
    except (TypeError, ValueError):
        max_seq_len = 0
    grid_pe_count = _grid_pe_count(runtime_config)

    planned_elements: int | None = None
    planned_shape: list[int] = []
    planned_bytes: int | None = None
    capacity_source = "unknown"

    if weight_item is not None:
        planned_shape = _normalized_shape(weight_item.get("shape") or [])
        planned_elements = _product(planned_shape)
        try:
            planned_bytes = int(weight_item.get("byteSize") or 0) or None
        except (TypeError, ValueError):
            planned_bytes = None
        capacity_source = "runtime_weight_mapping"
    elif role == "activation":
        planned_elements = hidden_dim or None
        planned_shape = [hidden_dim] if hidden_dim > 0 else []
        planned_bytes = planned_elements * 4 if planned_elements is not None else None
        capacity_source = "model_hidden_dim"
    elif role == "logits":
        planned_elements = vocab_size or None
        planned_shape = [vocab_size] if vocab_size > 0 else []
        planned_bytes = planned_elements * 4 if planned_elements is not None else None
        capacity_source = "model_vocab_size"
    elif role == "generated_tokens":
        planned_elements = 1
        planned_shape = [1]
        planned_bytes = 4
        capacity_source = "single_generated_token"
    elif role == "tokenized_prompt":
        planned_elements = max_seq_len or None
        planned_shape = [max_seq_len] if max_seq_len > 0 else []
        planned_bytes = planned_elements * 4 if planned_elements is not None else None
        capacity_source = "model_max_seq_len"
    elif role in {"position", "uniform"}:
        planned_elements = 1
        planned_shape = [1]
        planned_bytes = 4
        capacity_source = "scalar_runtime_state"
    elif role == "position_encoding":
        planned_elements = max_seq_len or None
        planned_shape = [max_seq_len] if max_seq_len > 0 else []
        planned_bytes = planned_elements * 4 if planned_elements is not None else None
        capacity_source = "rope_table_seq_len"
    elif state_item is not None:
        try:
            bytes_per_pe = int(state_item.get("bytesPerPe") or 0)
        except (TypeError, ValueError):
            bytes_per_pe = 0
        if bytes_per_pe > 0 and grid_pe_count is not None:
            planned_bytes = bytes_per_pe * grid_pe_count
            capacity_source = "runtime_state_bytes_per_pe"
        elif buffer.startswith("state:kv_cache"):
            planned_elements = decode_steps or max_seq_len or None
            planned_shape = [planned_elements] if planned_elements is not None else []
            capacity_source = "decode_or_seq_capacity"
        elif str(state_item.get("kind") or "") == "position":
            planned_elements = 1
            planned_shape = [1]
            planned_bytes = 4
            capacity_source = "position_state_scalar"

    return {
        "plannedElementCount": planned_elements,
        "plannedShape": planned_shape,
        "plannedByteLength": planned_bytes,
        "capacitySource": capacity_source,
    }


def _append_unique(items: list[Any], value: Any) -> None:
    if value not in items:
        items.append(value)


def _buffer_plan(
    *,
    runtime_config: dict[str, Any],
    runtime_scheduler: dict[str, Any],
    launches: list[dict[str, Any]],
    executor_validator: dict[str, Any],
) -> dict[str, Any]:
    weights = _weight_index(runtime_config)
    states = _state_index(runtime_config)
    decode_steps = _decode_step_count(runtime_scheduler)
    buffers: dict[str, dict[str, Any]] = {}

    def ensure(buffer: str, role: str) -> dict[str, Any]:
        weight_item = weights.get(buffer.removeprefix("weight:")) if buffer.startswith("weight:") else None
        state_item = states.get(_state_root_name(buffer))
        entry = buffers.get(buffer)
        if entry is None:
            capacity = _buffer_capacity(
                buffer=buffer,
                role=role,
                runtime_config=runtime_config,
                weight_item=weight_item,
                state_item=state_item,
                decode_steps=decode_steps,
            )
            entry = {
                "buffer": buffer,
                "role": role,
                "dtype": _buffer_dtype(
                    role=role,
                    weight_item=weight_item,
                    state_item=state_item,
                ),
                "storageClass": _buffer_storage_class(buffer, role),
                "producerLaunchIndices": [],
                "consumerLaunchIndices": [],
                "producerTargetNames": [],
                "consumerTargetNames": [],
                "transcriptEmitterLaunchIndices": [],
                **capacity,
            }
            if weight_item is not None:
                entry["weightKey"] = weight_item.get("weightKey") or weight_item.get("tensor")
                entry["weightPath"] = weight_item.get("path") or weight_item.get("shard") or ""
                entry["weightSha256"] = weight_item.get("sha256") or ""
            if state_item is not None:
                entry["stateRoot"] = state_item.get("name")
                entry["stateKind"] = state_item.get("kind")
            buffers[buffer] = entry
        return entry

    ensure("input:prompt_token_ids", "tokenized_prompt")

    for launch in launches:
        if not isinstance(launch, dict):
            continue
        launch_index = int(launch.get("launchIndex") or 0)
        target_name = str(launch.get("kernelName") or "")
        for item in launch.get("inputs") or []:
            if not isinstance(item, dict):
                continue
            buffer = str(item.get("buffer") or "")
            role = str(item.get("role") or "")
            if not buffer or not role:
                continue
            entry = ensure(buffer, role)
            _append_unique(entry["consumerLaunchIndices"], launch_index)
            _append_unique(entry["consumerTargetNames"], target_name)
        for item in launch.get("outputs") or []:
            if not isinstance(item, dict):
                continue
            buffer = str(item.get("buffer") or "")
            role = str(item.get("role") or "")
            if not buffer or not role:
                continue
            entry = ensure(buffer, role)
            _append_unique(entry["producerLaunchIndices"], launch_index)
            _append_unique(entry["producerTargetNames"], target_name)

    transcript = runtime_scheduler.get("transcriptCaptureSchedule") or {}
    for emitter in transcript.get("emitters") or []:
        if not isinstance(emitter, dict):
            continue
        launch_index = emitter.get("launchIndex")
        buffer = str(emitter.get("buffer") or "")
        if buffer:
            entry = ensure(
                buffer,
                "generated_tokens"
                if emitter.get("kind") == "generated_token"
                else "logits",
            )
            if isinstance(launch_index, int):
                _append_unique(entry["transcriptEmitterLaunchIndices"], launch_index)
        logits_buffer = str(emitter.get("logitsBuffer") or "")
        if logits_buffer:
            entry = ensure(logits_buffer, "logits")
            if isinstance(launch_index, int):
                _append_unique(entry["transcriptEmitterLaunchIndices"], launch_index)

    serialized = sorted(buffers.values(), key=lambda item: item["buffer"])
    return {
        "sharedPromptBuffer": "input:prompt_token_ids",
        "declaredStateRoots": sorted(states.keys()),
        "producedBufferCount": int(executor_validator.get("producedBufferCount") or 0),
        "bufferCount": len(serialized),
        "activationBufferCount": sum(1 for item in serialized if item["role"] == "activation"),
        "logitBufferCount": sum(1 for item in serialized if item["role"] == "logits"),
        "tokenBufferCount": sum(1 for item in serialized if item["role"] == "generated_tokens"),
        "persistentStateBufferCount": sum(
            1 for item in serialized if item["storageClass"] == "persistent_state"
        ),
        "externalWeightBufferCount": sum(
            1 for item in serialized if item["storageClass"] == "external_weight"
        ),
        "buffers": serialized,
    }
