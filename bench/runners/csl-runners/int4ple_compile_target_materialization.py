"""Array materialization and staging helpers for HostPlan launches."""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

import numpy as np

from bench.tools.doppler_rdrr_q4k import dequantize_q4km_rowwise_bytes
from int4ple_compile_target_core import sha256_file
from int4ple_runtime_scheduler import resolve_artifact_path, sha256_json
from int4ple_summa_layout import (
    a_tiles_from_logical as _summa_a_tiles_from_logical,
    b_tiles_from_q4k_bytes as _summa_b_tiles_from_q4k_bytes,
    b_tiles_from_weight_matrix as _summa_b_tiles_from_weight_matrix,
    required_positive_int as _required_positive_int,
)


def _tokenized_prompt_path(export: dict[str, Any]) -> Path:
    tokenized = export.get("tokenizedPrompt") or {}
    raw_path = tokenized.get("path")
    if not isinstance(raw_path, str) or not raw_path:
        raise ValueError("tokenized prompt path missing")
    return resolve_artifact_path(Path(__file__), raw_path)


def _load_tokenized_prompt(export: dict[str, Any], expected_per_pe: int, pe_count: int) -> np.ndarray:
    prompt_path = _tokenized_prompt_path(export)
    tokens = np.fromfile(prompt_path, dtype=np.uint32)
    padded = np.zeros(expected_per_pe, dtype=np.uint32)
    count = min(tokens.size, expected_per_pe)
    if count > 0:
        padded[:count] = tokens[:count]
    return np.tile(padded, pe_count)


def _read_weight_prefix_bytes(weight_mapping: dict[str, Any], byte_count: int) -> bytes:
    remaining = byte_count
    chunks = bytearray()
    spans = weight_mapping.get("spans") or []
    if isinstance(spans, list) and spans:
        for span in spans:
            if remaining <= 0:
                break
            if not isinstance(span, dict):
                continue
            shard_path = Path(str(span.get("shardPath") or ""))
            offset = int(span.get("offset") or 0)
            size = min(int(span.get("size") or 0), remaining)
            if not shard_path.is_file():
                raise FileNotFoundError(f"weight shard missing: {shard_path}")
            with shard_path.open("rb") as handle:
                handle.seek(offset)
                payload = handle.read(size)
            chunks.extend(payload)
            remaining -= len(payload)
    else:
        shard_path = Path(str(weight_mapping.get("path") or weight_mapping.get("shard") or ""))
        offset = int(weight_mapping.get("byteOffset") or weight_mapping.get("offsetBytes") or 0)
        if not shard_path.is_file():
            raise FileNotFoundError(f"weight shard missing: {shard_path}")
        with shard_path.open("rb") as handle:
            handle.seek(offset)
            chunks.extend(handle.read(byte_count))
        remaining = byte_count - len(chunks)
    if remaining > 0:
        raise ValueError(
            f"weight bytes unavailable:{weight_mapping.get('weightKey') or weight_mapping.get('tensor')} "
            f"{byte_count - remaining}<{byte_count}"
        )
    return bytes(chunks[:byte_count])


def _materialize_weight_matrix_q4k_bytes(
    mapping: dict[str, Any],
    transform: dict[str, Any],
) -> np.ndarray:
    """Read raw Q4_K_M bytes for the [N, K] weight matrix without dequantizing.

    Mirror of ``_materialize_weight_matrix_f32`` for the Q4K passthrough
    path: on-PE dequant materializes the f32 working tile from these
    bytes inside the SUMMA broadcast step.
    """
    nested = transform.get("sourceTransform") or {}
    if not isinstance(nested, dict):
        nested = {}
    nested_kind = str(nested.get("kind") or "")
    if nested_kind != "q4km_rowwise_passthrough":
        raise ValueError(
            "unsupported_summa_q4k_source_transform:"
            f"{mapping.get('weightKey') or mapping.get('tensor')}:{nested_kind or 'none'}"
        )
    byte_count = int(mapping.get("byteSize") or 0)
    if byte_count <= 0:
        raise ValueError(
            "summa_q4k_byte_size_missing:"
            f"{mapping.get('weightKey') or mapping.get('tensor')}"
        )
    raw = _read_weight_prefix_bytes(mapping, byte_count)
    return np.frombuffer(raw, dtype=np.uint8).copy()


def _materialize_weight_matrix_f32(
    mapping: dict[str, Any],
    transform: dict[str, Any],
) -> np.ndarray:
    nested = transform.get("sourceTransform") or {}
    if not isinstance(nested, dict):
        nested = {}
    nested_kind = str(nested.get("kind") or "")
    source_rows = _required_positive_int(transform, "sourceRows")
    source_cols = _required_positive_int(transform, "sourceCols")
    element_count = source_rows * source_cols
    if nested_kind == "q4km_rowwise_to_f32":
        byte_count = int(mapping.get("byteSize") or 0)
        raw = _read_weight_prefix_bytes(mapping, byte_count)
        values = dequantize_q4km_rowwise_bytes(raw, [source_rows, source_cols])
        return np.asarray(values, dtype=np.float32)
    if nested_kind in {"f16_to_f32", "f16_passthrough", "f16_to_f16", "litert_axis_dequant"}:
        raw = _read_weight_prefix_bytes(mapping, element_count * 2)
        return np.frombuffer(raw, dtype=np.float16).astype(np.float32, copy=True)
    if nested_kind in {"bf16_to_f32", "bf16_to_f16"}:
        raw = _read_weight_prefix_bytes(mapping, element_count * 2)
        bf16_words = np.frombuffer(raw, dtype=np.uint16).astype(np.uint32, copy=False)
        return (bf16_words << 16).view(np.float32).copy()
    if nested_kind in {"", "none"} and str(mapping.get("dtype") or "") == "f32":
        raw = _read_weight_prefix_bytes(mapping, element_count * 4)
        return np.frombuffer(raw, dtype=np.float32).copy()
    if nested_kind in {"", "none"} and str(mapping.get("dtype") or "") == "f16":
        raw = _read_weight_prefix_bytes(mapping, element_count * 2)
        return np.frombuffer(raw, dtype=np.float16).astype(np.float32, copy=True)
    raise ValueError(
        "unsupported_summa_weight_source_transform:"
        f"{mapping.get('weightKey') or mapping.get('tensor')}:{nested_kind or 'none'}"
    )


def _dense_gemv_weight_shards(
    mapping: dict[str, Any],
    transform: dict[str, Any],
) -> np.ndarray:
    source_rows = _required_positive_int(transform, "sourceRows")
    source_cols = _required_positive_int(transform, "sourceCols")
    logical_cols = _required_positive_int(transform, "logicalCols")
    width = _required_positive_int(transform, "width")
    height = _required_positive_int(transform, "height")
    out_dim = _required_positive_int(transform, "outDim")
    out_dim_per_pe = _required_positive_int(transform, "outDimPerPe")
    in_dim_per_pe = _required_positive_int(transform, "inDimPerPe")
    if str(mapping.get("dtype") or "") != "f16":
        raise ValueError(
            "dense_gemv_weight_requires_f16:"
            f"{mapping.get('weightKey') or mapping.get('tensor')}"
        )
    raw = _read_weight_prefix_bytes(mapping, source_rows * source_cols * 2)
    matrix = np.frombuffer(raw, dtype=np.float16).reshape(source_rows, source_cols)
    values = np.zeros(
        (height, width, out_dim_per_pe, in_dim_per_pe),
        dtype=np.float16,
    )
    for pe_y in range(height):
        row_start = pe_y * out_dim_per_pe
        row_end = min(row_start + out_dim_per_pe, out_dim, source_rows)
        if row_end <= row_start:
            continue
        for pe_x in range(width):
            col_start = pe_x * in_dim_per_pe
            col_end = min(col_start + in_dim_per_pe, logical_cols, source_cols)
            if col_end <= col_start:
                continue
            values[
                pe_y,
                pe_x,
                : row_end - row_start,
                : col_end - col_start,
            ] = matrix[row_start:row_end, col_start:col_end]
    return values.reshape(-1)


def _dense_gemv_activation_shards(
    host: np.ndarray,
    transform: dict[str, Any],
) -> np.ndarray:
    width = _required_positive_int(transform, "width")
    height = _required_positive_int(transform, "height")
    in_dim_per_pe = _required_positive_int(transform, "inDimPerPe")
    source_elements = _required_positive_int(transform, "sourceElements")
    logical = np.asarray(host[:source_elements], dtype=np.float16)
    values = np.zeros((height, width, in_dim_per_pe), dtype=np.float16)
    for pe_x in range(width):
        col_start = pe_x * in_dim_per_pe
        col_end = min(col_start + in_dim_per_pe, logical.size)
        if col_end <= col_start:
            continue
        values[:, pe_x, : col_end - col_start] = logical[col_start:col_end]
    return values.reshape(-1)


def _logical_matrix_to_pe_rows(
    host: np.ndarray,
    transform: dict[str, Any],
    *,
    target_dtype: np.dtype | type,
) -> tuple[np.ndarray, int]:
    source_cols = _required_positive_int(transform, "sourceCols")
    target_rows = _required_positive_int(transform, "targetRows")
    if host.size % source_cols != 0:
        raise ValueError(
            f"pe_rows_logical_size_mismatch:{host.size}%{source_cols}"
        )
    rows = host.size // source_cols
    if rows > target_rows:
        raise ValueError(
            f"pe_rows_logical_rows_exceed_target:{rows}>{target_rows}"
        )
    dtype = np.dtype(target_dtype)
    padded = np.zeros((target_rows, source_cols), dtype=dtype)
    padded[:rows, :source_cols] = host.astype(dtype, copy=False).reshape(
        rows,
        source_cols,
    )
    return padded.reshape(-1).astype(dtype, copy=False), rows


def _logical_matrix_to_rope_pe_heads(
    host: np.ndarray,
    transform: dict[str, Any],
    *,
    target_dtype: np.dtype | type,
) -> tuple[np.ndarray, int]:
    source_cols = _required_positive_int(transform, "sourceCols")
    head_dim = _required_positive_int(transform, "headDim")
    target_rows = _required_positive_int(transform, "targetRows")
    if source_cols % head_dim != 0:
        raise ValueError(
            f"rope_heads_source_cols_mismatch:{source_cols}%{head_dim}"
        )
    if host.size % source_cols != 0:
        raise ValueError(
            f"rope_heads_logical_size_mismatch:{host.size}%{source_cols}"
        )
    rows = host.size // source_cols
    head_rows = rows * (source_cols // head_dim)
    if head_rows > target_rows:
        raise ValueError(
            f"rope_heads_logical_rows_exceed_target:{head_rows}>{target_rows}"
        )
    dtype = np.dtype(target_dtype)
    logical = host.astype(dtype, copy=False).reshape(rows, source_cols)
    heads = logical.reshape(rows, source_cols // head_dim, head_dim).reshape(
        head_rows,
        head_dim,
    )
    padded = np.zeros((target_rows, head_dim), dtype=dtype)
    padded[:head_rows, :head_dim] = heads
    return padded.reshape(-1).astype(dtype, copy=False), rows


def _logical_matrix_to_attention_rows(
    host: np.ndarray,
    transform: dict[str, Any],
    *,
    target_dtype: np.dtype | type,
) -> tuple[np.ndarray, int]:
    source_cols = _required_positive_int(transform, "sourceCols")
    head_dim = _required_positive_int(transform, "headDim")
    target_rows = _required_positive_int(transform, "targetRows")
    rows_per_pe = _required_positive_int(transform, "rowsPerPe")
    if source_cols % head_dim != 0:
        raise ValueError(
            f"attention_rows_source_cols_mismatch:{source_cols}%{head_dim}"
        )
    if host.size % source_cols != 0:
        raise ValueError(
            f"attention_rows_logical_size_mismatch:{host.size}%{source_cols}"
        )
    rows = host.size // source_cols
    head_rows = rows * (source_cols // head_dim)
    target_capacity = target_rows * rows_per_pe
    if head_rows > target_capacity:
        raise ValueError(
            f"attention_rows_logical_rows_exceed_target:{head_rows}>{target_capacity}"
        )
    dtype = np.dtype(target_dtype)
    logical = host.astype(dtype, copy=False).reshape(rows, source_cols)
    heads = logical.reshape(rows, source_cols // head_dim, head_dim).reshape(
        head_rows,
        head_dim,
    )
    padded = np.zeros((target_rows, rows_per_pe, head_dim), dtype=dtype)
    padded.reshape(target_capacity, head_dim)[:head_rows, :] = heads
    return padded.reshape(-1).astype(dtype, copy=False), rows


def _broadcast_factor_or_one(
    *,
    mapping: dict[str, Any],
    materialization: dict[str, Any],
    source_byte_width: int,
    total_elements: int,
) -> int:
    """Detect broadcast weights (e.g. layernorm scale vectors) where the source
    tensor holds one PE's worth of bytes and is meant to be replicated across
    every PE in the target grid. Returns the replication factor when the shape
    fits exactly; returns 1 (no broadcast) otherwise.

    A match requires: source byteSize == elementsPerPe * source_byte_width,
    AND elementsPerPe * peCount == total_elements. This avoids false positives
    on truncated or malformed weight mappings.
    """
    elements_per_pe = int(materialization.get("elementsPerPe") or 0)
    geometry = materialization.get("targetGeometry") or {}
    pe_count = int(geometry.get("peCount") or 0)
    if elements_per_pe <= 0 or pe_count <= 1:
        return 1
    try:
        source_bytes = int(mapping.get("byteSize") or 0)
    except (TypeError, ValueError):
        return 1
    if source_bytes != elements_per_pe * source_byte_width:
        return 1
    if elements_per_pe * pe_count != total_elements:
        return 1
    return pe_count


def _materialize_weight_input(
    materialization: dict[str, Any],
) -> np.ndarray:
    mapping = materialization.get("weightMapping")
    if not isinstance(mapping, dict):
        raise ValueError("weight mapping missing")
    dtype = str(materialization.get("dtype") or "")
    total_elements = int(materialization.get("plannedElementCount") or 0)
    source_transform = materialization.get("sourceTransform") or {}
    transform_kind = (
        str(source_transform.get("kind") or "")
        if isinstance(source_transform, dict)
        else ""
    )
    if dtype == "f32" and transform_kind == "weight_matrix_to_summa_tiles":
        matrix = _materialize_weight_matrix_f32(mapping, source_transform)
        values = _summa_b_tiles_from_weight_matrix(matrix, source_transform)
        if values.size != total_elements:
            raise ValueError(
                f"weight_summa_tile_size_mismatch:{values.size}!={total_elements}"
            )
        return values
    if dtype == "f16" and transform_kind == "weight_matrix_to_summa_tiles":
        matrix = _materialize_weight_matrix_f32(mapping, source_transform)
        values = _summa_b_tiles_from_weight_matrix(
            matrix,
            source_transform,
            target_dtype=np.float16,
        )
        if values.size != total_elements:
            raise ValueError(
                f"weight_summa_tile_size_mismatch:{values.size}!={total_elements}"
            )
        return values
    if dtype == "q4k_block256" and transform_kind == "weight_matrix_to_summa_q4k_tiles":
        # Q4K passthrough: ship 144-byte blocks per 256-weight chunk to
        # the fabric without host-side dequant. The PE program runs
        # `dequant_b_tile()` as a per-broadcast-step prologue (see
        # runtime/zig/src/doe_wgsl/emit_csl_matmul_q4k.zig).
        # plannedElementCount is in BYTES for this dtype, not weights.
        raw_bytes = _materialize_weight_matrix_q4k_bytes(mapping, source_transform)
        values = _summa_b_tiles_from_q4k_bytes(raw_bytes, source_transform)
        if values.size != total_elements:
            raise ValueError(
                f"weight_summa_q4k_tile_byte_mismatch:{values.size}!={total_elements}"
            )
        return values
    if dtype == "f16" and transform_kind == "tied_f16_embedding_to_dense_gemv_shards":
        values = _dense_gemv_weight_shards(mapping, source_transform)
        if values.size != total_elements:
            raise ValueError(
                f"weight_dense_gemv_shard_size_mismatch:{values.size}!={total_elements}"
            )
        return values
    if dtype == "f32" and transform_kind in {"f16_to_f32", "litert_axis_dequant"}:
        broadcast = _broadcast_factor_or_one(
            mapping=mapping,
            materialization=materialization,
            source_byte_width=2,
            total_elements=total_elements,
        )
        per_pe_elements = total_elements // broadcast
        raw = _read_weight_prefix_bytes(mapping, per_pe_elements * 2)
        per_pe = np.frombuffer(raw, dtype=np.float16).astype(np.float32, copy=True)
        values = np.tile(per_pe, broadcast) if broadcast > 1 else per_pe
        if values.size != total_elements:
            raise ValueError(f"weight_f16_to_f32_size_mismatch:{values.size}!={total_elements}")
        return values
    if dtype == "f16" and transform_kind in {"f16_passthrough", "f16_to_f16"}:
        broadcast = _broadcast_factor_or_one(
            mapping=mapping,
            materialization=materialization,
            source_byte_width=2,
            total_elements=total_elements,
        )
        per_pe_elements = total_elements // broadcast
        raw = _read_weight_prefix_bytes(mapping, per_pe_elements * 2)
        per_pe = np.frombuffer(raw, dtype=np.float16).copy()
        values = np.tile(per_pe, broadcast) if broadcast > 1 else per_pe
        if values.size != total_elements:
            raise ValueError(f"weight_f16_passthrough_size_mismatch:{values.size}!={total_elements}")
        return values
    if dtype == "f16" and transform_kind == "bf16_to_f16":
        broadcast = _broadcast_factor_or_one(
            mapping=mapping,
            materialization=materialization,
            source_byte_width=2,
            total_elements=total_elements,
        )
        per_pe_elements = total_elements // broadcast
        raw = _read_weight_prefix_bytes(mapping, per_pe_elements * 2)
        bf16_words = np.frombuffer(raw, dtype=np.uint16).astype(np.uint32, copy=False)
        per_pe = (bf16_words << 16).view(np.float32).astype(np.float16)
        values = np.tile(per_pe, broadcast) if broadcast > 1 else per_pe
        if values.size != total_elements:
            raise ValueError(f"weight_bf16_to_f16_size_mismatch:{values.size}!={total_elements}")
        return values
    if dtype == "f32" and transform_kind == "bf16_to_f32":
        broadcast = _broadcast_factor_or_one(
            mapping=mapping,
            materialization=materialization,
            source_byte_width=2,
            total_elements=total_elements,
        )
        per_pe_elements = total_elements // broadcast
        raw = _read_weight_prefix_bytes(mapping, per_pe_elements * 2)
        bf16_words = np.frombuffer(raw, dtype=np.uint16).astype(np.uint32, copy=False)
        per_pe = (bf16_words << 16).view(np.float32).copy()
        values = np.tile(per_pe, broadcast) if broadcast > 1 else per_pe
        if values.size != total_elements:
            raise ValueError(f"weight_bf16_to_f32_size_mismatch:{values.size}!={total_elements}")
        return values
    if dtype == "u32" and transform_kind == "u8_bytes_to_u32_words":
        raw = _read_weight_prefix_bytes(mapping, total_elements * 4)
        values = np.frombuffer(raw, dtype=np.uint32).copy()
        if values.size != total_elements:
            raise ValueError(f"weight_u8_to_u32_size_mismatch:{values.size}!={total_elements}")
        return values
    raise ValueError(
        "unsupported_weight_materialization:"
        f"{mapping.get('weightKey') or mapping.get('tensor')}:{dtype}:{transform_kind or 'none'}"
    )


def _materialize_constant_input(
    *,
    materialization: dict[str, Any],
    export: dict[str, Any],
) -> np.ndarray:
    dtype = str(materialization.get("dtype") or "")
    elements_per_pe = int(materialization.get("elementsPerPe") or 0)
    geometry = materialization.get("targetGeometry") or {}
    pe_count = int(geometry.get("peCount") or 1)
    role = str(materialization.get("role") or "")
    buffer = str(materialization.get("buffer") or "")
    if role == "tokenized_prompt":
        return _load_tokenized_prompt(export, elements_per_pe, pe_count)
    if role == "position_encoding":
        count = elements_per_pe
        pairs = np.arange(count, dtype=np.float32)
        values = np.cos(pairs) if buffer.endswith("cos_table") else np.sin(pairs)
        target_dtype = np.float16 if dtype == "f16" else np.float32
        return np.tile(values.astype(target_dtype), pe_count)
    if role == "position":
        value = 0
        if buffer.endswith("sliding_window"):
            value = 512
        return np.full(pe_count * max(1, elements_per_pe), value, dtype=np.uint32)
    if role == "uniform":
        return np.zeros(pe_count * max(1, elements_per_pe), dtype=np.uint32)
    if role == "kv_cache":
        target_dtype = np.float16 if dtype == "f16" else np.float32
        return np.zeros(pe_count * max(1, elements_per_pe), dtype=target_dtype)
    raise ValueError(f"unsupported_constant_input:{role}:{buffer}:{dtype}")


def _transform_existing_input(
    host: np.ndarray,
    materialization: dict[str, Any],
) -> tuple[np.ndarray, dict[str, int]]:
    source_transform = materialization.get("sourceTransform") or {}
    if not isinstance(source_transform, dict):
        return host, {}
    transform_kind = str(source_transform.get("kind") or "")
    if transform_kind == "logical_matrix_to_summa_tiles":
        target_dtype = (
            np.float16
            if str(materialization.get("dtype") or "") == "f16"
            else np.float32
        )
        values, rows = _summa_a_tiles_from_logical(
            host,
            source_transform,
            target_dtype=target_dtype,
        )
        return values, {
            "rows": rows,
            "cols": _required_positive_int(source_transform, "sourceCols"),
        }
    if transform_kind == "logical_vector_to_dense_gemv_activation_shards":
        return _dense_gemv_activation_shards(host, source_transform), {}
    if transform_kind == "logical_matrix_to_pe_rows":
        target_dtype = (
            np.float16
            if str(materialization.get("dtype") or "") == "f16"
            else np.float32
        )
        values, rows = _logical_matrix_to_pe_rows(
            host,
            source_transform,
            target_dtype=target_dtype,
        )
        return values, {
            "rows": rows,
            "cols": _required_positive_int(source_transform, "sourceCols"),
        }
    if transform_kind == "logical_matrix_to_rope_pe_heads":
        target_dtype = (
            np.float16
            if str(materialization.get("dtype") or "") == "f16"
            else np.float32
        )
        values, rows = _logical_matrix_to_rope_pe_heads(
            host,
            source_transform,
            target_dtype=target_dtype,
        )
        return values, {
            "rows": rows,
            "cols": _required_positive_int(source_transform, "sourceCols"),
        }
    if transform_kind in {
        "logical_matrix_to_attention_query_rows",
        "logical_matrix_to_attention_kv_rows",
    }:
        target_dtype = (
            np.float16
            if str(materialization.get("dtype") or "") == "f16"
            else np.float32
        )
        values, rows = _logical_matrix_to_attention_rows(
            host,
            source_transform,
            target_dtype=target_dtype,
        )
        return values, {
            "rows": rows,
            "cols": _required_positive_int(source_transform, "sourceCols"),
        }
    return host, {}


def _launch_spec_path(runtime_dir: Path, launch_index: int) -> Path:
    return runtime_dir / "launch-specs" / f"launch-{launch_index:04d}.json"


def _launch_receipt_path(runtime_dir: Path, launch_index: int) -> Path:
    return runtime_dir / "launch-receipts" / f"launch-{launch_index:04d}.json"


def _buffer_path(runtime_dir: Path, buffer_name: str) -> Path:
    safe = hashlib.sha256(buffer_name.encode("utf-8")).hexdigest()
    return runtime_dir / "buffers" / f"{safe}.npy"


def _staged_input_path(
    runtime_dir: Path,
    launch_index: int,
    symbol: str,
    buffer_name: str,
) -> Path:
    safe = hashlib.sha256(f"{launch_index}:{symbol}:{buffer_name}".encode("utf-8")).hexdigest()
    return runtime_dir / "staged-inputs" / f"{safe}.npy"


def _stage_launch_arrays(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    buffer_files: dict[str, Path],
    export: dict[str, Any],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    staged_inputs: list[dict[str, Any]] = []
    staged_outputs: list[dict[str, Any]] = []
    matrix_shapes: dict[str, dict[str, int]] = {}
    for side, source_items, staged in (
        ("input", launch.get("resolvedInputs") or [], staged_inputs),
        ("output", launch.get("resolvedOutputs") or [], staged_outputs),
    ):
        for item in source_items:
            if not isinstance(item, dict):
                raise ValueError(f"launch[{launch.get('launchIndex')}].{side}_binding_not_object")
            materialization = item.get("materialization") or {}
            if not isinstance(materialization, dict):
                raise ValueError(
                    f"launch[{launch.get('launchIndex')}].{side}_materialization_missing"
                )
            buffer_name = str(item.get("buffer") or "")
            role = str(item.get("role") or "")
            symbol = str(item.get("symbol") or "")
            path = _buffer_path(runtime_dir, buffer_name)
            if side == "input":
                existing = buffer_files.get(buffer_name)
                total_elements = int(materialization.get("plannedElementCount") or 0)
                source_transform = materialization.get("sourceTransform") or {}
                transform_kind = (
                    str(source_transform.get("kind") or "")
                    if isinstance(source_transform, dict)
                    else ""
                )
                cache_buffer_file = role != "weight" and transform_kind not in {
                    "logical_matrix_to_summa_tiles",
                    "weight_matrix_to_summa_tiles",
                    "logical_vector_to_dense_gemv_activation_shards",
                    "tied_f16_embedding_to_dense_gemv_shards",
                    "logical_matrix_to_rope_pe_heads",
                    "logical_matrix_to_attention_query_rows",
                    "logical_matrix_to_attention_kv_rows",
                }
                if not cache_buffer_file:
                    path = _staged_input_path(
                        runtime_dir,
                        int(launch.get("launchIndex") or 0),
                        symbol,
                        buffer_name,
                    )
                if existing is not None:
                    host = np.load(existing, allow_pickle=False).ravel()
                    host, matrix_shape = _transform_existing_input(
                        host,
                        materialization,
                    )
                    if matrix_shape:
                        matrix_role = str(source_transform.get("matrixRole") or symbol)
                        matrix_shapes[matrix_role] = matrix_shape
                    if int(host.size) != total_elements:
                        raise ValueError(
                            f"launch[{launch.get('launchIndex')}].input_buffer_size_mismatch:"
                            f"{buffer_name}:{host.size}!={total_elements}"
                        )
                elif role == "weight":
                    host = _materialize_weight_input(materialization)
                else:
                    host = _materialize_constant_input(
                        materialization=materialization,
                        export=export,
                    )
                    if int(host.size) != total_elements:
                        raise ValueError(
                            f"launch[{launch.get('launchIndex')}].constant_input_size_mismatch:"
                            f"{buffer_name}:{host.size}!={total_elements}"
                        )
                path.parent.mkdir(parents=True, exist_ok=True)
                np.save(path, host)
                if cache_buffer_file:
                    buffer_files[buffer_name] = path
            staged_item = {
                "symbol": symbol,
                "buffer": buffer_name,
                "role": role,
                "path": str(path),
                "dtype": str(materialization.get("dtype") or ""),
                "elemType": str(materialization.get("elemType") or ""),
                "elementsPerPe": int(materialization.get("elementsPerPe") or 0),
            }
            if side == "input" and isinstance(materialization.get("sourceTransform"), dict):
                staged_item["sourceTransform"] = materialization["sourceTransform"]
            if side == "output" and isinstance(materialization.get("outputTransform"), dict):
                output_transform = dict(materialization["outputTransform"])
                rows_from_input = str(output_transform.get("rowsFromInput") or "")
                if rows_from_input and not output_transform.get("rows"):
                    input_shape = matrix_shapes.get(rows_from_input)
                    if input_shape is None:
                        raise ValueError(
                            f"launch[{launch.get('launchIndex')}].output_rows_unresolved:"
                            f"{symbol}:{rows_from_input}"
                        )
                    output_transform["rows"] = input_shape["rows"]
                staged_item["outputTransform"] = output_transform
            staged.append(staged_item)
    return staged_inputs, staged_outputs


def _staged_tile_record(item: dict[str, Any]) -> dict[str, Any]:
    path = Path(str(item.get("path") or ""))
    record = {
        "symbol": str(item.get("symbol") or ""),
        "buffer": str(item.get("buffer") or ""),
        "path": str(path),
        "absolutePath": str(path),
        "elemType": str(item.get("elemType") or item.get("dtype") or "f32"),
        "perPeChunk": int(item.get("elementsPerPe") or 0),
        "totalBytes": path.stat().st_size if path.is_file() else 0,
        "sha256": sha256_file(path) if path.is_file() else "",
    }
    try:
        record["totalElements"] = int(np.load(path, mmap_mode="r").size)
    except (OSError, ValueError):
        record["totalElements"] = 0
    return record


def _staged_input_buffer_records(
    staged_inputs: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for item in staged_inputs:
        path = Path(str(item.get("path") or ""))
        record = {
            "name": str(item.get("buffer") or item.get("symbol") or ""),
            "symbol": str(item.get("symbol") or ""),
            "role": str(item.get("role") or "input"),
            "path": str(path),
            "dtype": str(item.get("elemType") or item.get("dtype") or ""),
            "elementsPerPe": int(item.get("elementsPerPe") or 0),
            "sha256Kind": "array_tobytes_c_order",
        }
        if path.is_file():
            try:
                array = np.load(path, allow_pickle=False).ravel()
                record["totalElements"] = int(array.size)
                record["sha256"] = hashlib.sha256(
                    array.tobytes(order="C")
                ).hexdigest()
            except (OSError, ValueError):
                record["totalElements"] = 0
                record["sha256"] = ""
        else:
            record["totalElements"] = 0
            record["sha256"] = ""
        records.append(record)
    return records


def _session_state_hash_payload(
    *,
    launch: dict[str, Any],
    buffer_files: dict[str, Path],
    staged_inputs: list[dict[str, Any]],
) -> dict[str, Any]:
    input_records = [_staged_tile_record(item) for item in staged_inputs]
    activation = next(
        (
            item
            for item in input_records
            if str(item.get("symbol") or "") == "activation"
        ),
        {},
    )
    state_records = []
    for buffer, path in sorted(buffer_files.items()):
        if not (buffer.startswith("state:") or buffer.startswith("tokens:")):
            continue
        state_records.append(
            {
                "buffer": buffer,
                "path": str(path),
                "sha256": sha256_file(path) if path.is_file() else "",
                "totalBytes": path.stat().st_size if path.is_file() else 0,
            }
        )
    payload = {
        "launchIndex": int(launch.get("launchIndex") or 0),
        "targetName": str(launch.get("targetName") or ""),
        "sessionStepId": (
            f"launch:{int(launch.get('launchIndex') or 0)}:"
            f"{str(launch.get('targetName') or '')}"
        ),
        "inputActivationSha256": str(activation.get("sha256") or ""),
        "stateBuffers": state_records,
    }
    payload["sessionStateSha256"] = sha256_json(payload)
    return payload
