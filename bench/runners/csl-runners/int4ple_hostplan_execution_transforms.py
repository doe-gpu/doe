"""Tensor transform metadata for INT4 PLE HostPlan execution plans."""

from __future__ import annotations

from typing import Any

from int4ple_hostplan_execution_buffers import _normalized_shape
from int4ple_hostplan_execution_common import (
    PREFILL_Q4K_GEMV_PATTERN,
    _ATTENTION_TILED_TARGETS,
    _ROPE_TARGETS,
    _ROW_PARALLEL_TARGETS,
    _SUMMA_TARGETS,
    _int_field,
    _model_hidden_dim,
    _model_ple_width,
)

def _summa_params(compile_params: dict[str, int]) -> dict[str, int] | None:
    p = _int_field(compile_params.get("P"))
    mt = _int_field(compile_params.get("Mt"))
    kt = _int_field(compile_params.get("Kt"))
    nt = _int_field(compile_params.get("Nt"))
    if p is None or mt is None or kt is None or nt is None:
        return None
    return {
        "gridWidth": p,
        "gridHeight": p,
        "tileRows": mt,
        "tileReduction": kt,
        "tileCols": nt,
        "paddedRows": p * mt,
        "paddedReduction": p * kt,
        "paddedCols": p * nt,
    }


def _summa_source_transform(
    *,
    symbol: str,
    role: str,
    target_name: str,
    target_pattern: str,
    compile_params: dict[str, int],
    runtime_config: dict[str, Any],
    item: dict[str, Any],
    dtype: str,
    weight_item: dict[str, Any] | None,
    source_transform: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if target_pattern and target_pattern != "tiled_matmul":
        return source_transform
    if target_name not in _SUMMA_TARGETS:
        return source_transform
    params = _summa_params(compile_params)
    if params is None:
        return source_transform
    symbol_key = symbol.lower()
    if symbol_key == "a" and role == "activation":
        source_cols = _int_field(item.get("matrixCols"))
        if source_cols is None and target_name == "ple_proj":
            source_cols = _model_ple_width(runtime_config)
        if source_cols is None:
            source_cols = _model_hidden_dim(runtime_config)
        if source_cols is None or source_cols <= 0:
            return source_transform
        return {
            "kind": "logical_matrix_to_summa_tiles",
            "matrixRole": "a",
            "sourceDtype": dtype,
            "targetDtype": dtype,
            "sourceCols": source_cols,
            **params,
        }
    if symbol_key == "b" and role == "weight" and weight_item is not None:
        shape = _normalized_shape(weight_item.get("shape") or [])
        if len(shape) < 2:
            return source_transform
        if (source_transform or {}).get("kind") == "weight_matrix_to_summa_tiles":
            source_transform = source_transform.get("sourceTransform")
        nested = source_transform or {
            "kind": "none",
            "sourceDtype": str(weight_item.get("dtype") or ""),
            "targetDtype": "f32",
        }
        return {
            "kind": "weight_matrix_to_summa_tiles",
            "matrixRole": "b",
            "targetDtype": dtype,
            "sourceRows": shape[0],
            "sourceCols": shape[1],
            "sourceTransform": nested,
            **params,
        }
    return source_transform


def _summa_output_transform(
    *,
    symbol: str,
    target_name: str,
    target_pattern: str,
    compile_params: dict[str, int],
    item: dict[str, Any],
    dtype: str,
) -> dict[str, Any] | None:
    if target_pattern and target_pattern != "tiled_matmul":
        return None
    if target_name not in _SUMMA_TARGETS or symbol.lower() != "c":
        return None
    params = _summa_params(compile_params)
    output_cols = _int_field(item.get("matrixCols"))
    if params is None or output_cols is None:
        return None
    return {
        "kind": "summa_tiles_to_logical_matrix",
        "matrixRole": "c",
        "rowsFromInput": "a",
        "cols": output_cols,
        "sourceDtype": dtype,
        "targetDtype": dtype,
        **params,
    }
def _row_parallel_source_transform(
    *,
    symbol: str,
    role: str,
    target_name: str,
    target_geometry: dict[str, int],
    elements_per_pe: int,
    dtype: str,
    source_transform: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if source_transform is not None:
        return source_transform
    if target_name not in _ROW_PARALLEL_TARGETS:
        return source_transform
    if role != "activation" or symbol not in {"input", "residual", "gate"}:
        return source_transform
    pe_count = int(target_geometry.get("peCount") or 0)
    if pe_count <= 1 or elements_per_pe <= 0:
        return source_transform
    return {
        "kind": "logical_matrix_to_pe_rows",
        "matrixRole": symbol,
        "sourceCols": elements_per_pe,
        "targetRows": pe_count,
        "sourceDtype": dtype,
        "targetDtype": dtype,
    }


def _row_parallel_output_transform(
    *,
    symbol: str,
    role: str,
    target_name: str,
    elements_per_pe: int,
    dtype: str,
    output_transform: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if output_transform is not None:
        return output_transform
    if target_name not in _ROW_PARALLEL_TARGETS:
        return output_transform
    if role != "activation" or symbol not in {"output", "input"}:
        return output_transform
    if elements_per_pe <= 0:
        return output_transform
    return {
        "kind": "pe_rows_to_logical_matrix",
        "matrixRole": symbol,
        "rowsFromInput": "input",
        "cols": elements_per_pe,
        "sourceDtype": dtype,
        "targetDtype": dtype,
    }


def _rope_source_transform(
    *,
    symbol: str,
    role: str,
    target_name: str,
    compile_params: dict[str, int],
    item: dict[str, Any],
    dtype: str,
    source_transform: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if source_transform is not None:
        return source_transform
    if target_name not in _ROPE_TARGETS:
        return source_transform
    if role != "activation" or symbol != "input":
        return source_transform
    source_cols = _int_field(item.get("matrixCols"))
    head_dim = _int_field(compile_params.get("head_dim"))
    target_rows = _int_field(compile_params.get("width"))
    if source_cols is None or head_dim is None or target_rows is None:
        return source_transform
    if min(source_cols, head_dim, target_rows) <= 0:
        return source_transform
    return {
        "kind": "logical_matrix_to_rope_pe_heads",
        "matrixRole": "input",
        "sourceCols": source_cols,
        "headDim": head_dim,
        "targetRows": target_rows,
        "sourceDtype": dtype,
        "targetDtype": dtype,
    }


def _rope_output_transform(
    *,
    symbol: str,
    role: str,
    target_name: str,
    compile_params: dict[str, int],
    item: dict[str, Any],
    dtype: str,
    output_transform: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if output_transform is not None:
        return output_transform
    if target_name not in _ROPE_TARGETS:
        return output_transform
    if role != "activation" or symbol != "input":
        return output_transform
    cols = _int_field(item.get("matrixCols"))
    head_dim = _int_field(compile_params.get("head_dim"))
    target_rows = _int_field(compile_params.get("width"))
    if cols is None or head_dim is None or target_rows is None:
        return output_transform
    if min(cols, head_dim, target_rows) <= 0:
        return output_transform
    return {
        "kind": "rope_pe_heads_to_logical_matrix",
        "matrixRole": "input",
        "rowsFromInput": "input",
        "cols": cols,
        "headDim": head_dim,
        "targetRows": target_rows,
        "sourceDtype": dtype,
        "targetDtype": dtype,
    }


def _attention_tiled_params(
    compile_params: dict[str, int],
) -> dict[str, int] | None:
    width = _int_field(compile_params.get("width"))
    head_dim = _int_field(compile_params.get("head_dim"))
    q_len_per_pe = _int_field(compile_params.get("q_len_per_pe"))
    block_size = _int_field(compile_params.get("block_size"))
    if width is None or head_dim is None or q_len_per_pe is None or block_size is None:
        return None
    if min(width, head_dim, q_len_per_pe, block_size) <= 0:
        return None
    return {
        "targetRows": width,
        "headDim": head_dim,
        "queryRowsPerPe": q_len_per_pe,
        "kvRowsPerPe": block_size,
    }


def _attention_tiled_source_transform(
    *,
    symbol: str,
    role: str,
    target_name: str,
    compile_params: dict[str, int],
    item: dict[str, Any],
    dtype: str,
    source_transform: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if source_transform is not None:
        return source_transform
    if target_name not in _ATTENTION_TILED_TARGETS:
        return source_transform
    if role != "activation":
        return source_transform
    symbol_key = symbol.lower()
    if symbol_key not in {"query", "key", "val", "value"}:
        return source_transform
    params = _attention_tiled_params(compile_params)
    source_cols = _int_field(item.get("matrixCols"))
    if params is None or source_cols is None or source_cols <= 0:
        return source_transform
    is_query = symbol_key == "query"
    return {
        "kind": (
            "logical_matrix_to_attention_query_rows"
            if is_query
            else "logical_matrix_to_attention_kv_rows"
        ),
        "matrixRole": symbol_key,
        "sourceCols": source_cols,
        "headDim": params["headDim"],
        "targetRows": params["targetRows"],
        "rowsPerPe": (
            params["queryRowsPerPe"] if is_query else params["kvRowsPerPe"]
        ),
        "sourceDtype": dtype,
        "targetDtype": dtype,
    }


def _attention_tiled_output_transform(
    *,
    symbol: str,
    role: str,
    target_name: str,
    compile_params: dict[str, int],
    item: dict[str, Any],
    dtype: str,
    output_transform: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if output_transform is not None:
        return output_transform
    if target_name not in _ATTENTION_TILED_TARGETS:
        return output_transform
    if role != "activation" or symbol.lower() != "output":
        return output_transform
    params = _attention_tiled_params(compile_params)
    cols = _int_field(item.get("matrixCols"))
    if params is None or cols is None or cols <= 0:
        return output_transform
    return {
        "kind": "attention_query_rows_to_logical_matrix",
        "matrixRole": "output",
        "rowsFromInput": "query",
        "cols": cols,
        "headDim": params["headDim"],
        "targetRows": params["targetRows"],
        "rowsPerPe": params["queryRowsPerPe"],
        "sourceDtype": dtype,
        "targetDtype": dtype,
    }


def _dense_gemv_params(compile_params: dict[str, int]) -> dict[str, int] | None:
    width = _int_field(compile_params.get("width"))
    height = _int_field(compile_params.get("height"))
    out_dim = _int_field(compile_params.get("out_dim"))
    out_dim_per_pe = _int_field(compile_params.get("out_dim_per_pe"))
    in_dim_per_pe = _int_field(compile_params.get("in_dim_per_pe"))
    if None in {width, height, out_dim, out_dim_per_pe, in_dim_per_pe}:
        return None
    return {
        "width": int(width),
        "height": int(height),
        "outDim": int(out_dim),
        "outDimPerPe": int(out_dim_per_pe),
        "inDimPerPe": int(in_dim_per_pe),
    }


def _dense_gemv_source_transform(
    *,
    symbol: str,
    role: str,
    target_name: str,
    compile_params: dict[str, int],
    runtime_config: dict[str, Any],
    weight_item: dict[str, Any] | None,
    source_transform: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if target_name != "lm_head_prefill":
        return source_transform
    params = _dense_gemv_params(compile_params)
    if params is None:
        return source_transform
    symbol_key = symbol.lower()
    if symbol_key == "activation" and role == "activation":
        hidden_dim = _model_hidden_dim(runtime_config)
        if hidden_dim <= 0:
            return source_transform
        return {
            "kind": "logical_vector_to_dense_gemv_activation_shards",
            "sourceDtype": "f16",
            "targetDtype": "f16",
            "sourceElements": hidden_dim,
            **params,
        }
    if symbol_key == "weight" and role == "weight" and weight_item is not None:
        shape = _normalized_shape(weight_item.get("shape") or [])
        if len(shape) < 2:
            return source_transform
        return {
            "kind": "tied_f16_embedding_to_dense_gemv_shards",
            "sourceDtype": str(weight_item.get("dtype") or ""),
            "targetDtype": "f16",
            "sourceRows": shape[0],
            "sourceCols": shape[1],
            "logicalCols": _model_hidden_dim(runtime_config),
            **params,
        }
    return source_transform


def _dense_gemv_output_transform(
    *,
    symbol: str,
    target_name: str,
    compile_params: dict[str, int],
) -> dict[str, Any] | None:
    if target_name != "lm_head_prefill" or symbol.lower() != "output":
        return None
    params = _dense_gemv_params(compile_params)
    if params is None:
        return None
    return {
        "kind": "dense_gemv_row_shards_to_logits",
        "sourceDtype": "f32",
        "targetDtype": "f32",
        **params,
    }


def _prefill_q4k_gemv_params(
    compile_params: dict[str, int],
) -> dict[str, int] | None:
    in_dim_per_pe = int(compile_params.get("in_dim_per_pe") or 0)
    out_dim_per_pe = int(compile_params.get("out_dim_per_pe") or 0)
    num_blocks_per_row = int(compile_params.get("num_blocks_per_row") or 0)
    output_pe_rows = int(
        compile_params.get("output_pe_rows") or compile_params.get("height") or 0
    )
    if min(in_dim_per_pe, out_dim_per_pe, num_blocks_per_row, output_pe_rows) <= 0:
        return None
    return {
        "inDimPerPe": in_dim_per_pe,
        "outDimPerPe": out_dim_per_pe,
        "numBlocksPerRow": num_blocks_per_row,
        "outputPeRows": output_pe_rows,
    }


def _prefill_q4k_gemv_source_transform(
    *,
    symbol: str,
    role: str,
    target_pattern: str,
    compile_params: dict[str, int],
    runtime_config: dict[str, Any],
    item: dict[str, Any],
    dtype: str,
    weight_item: dict[str, Any] | None,
    source_transform: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if target_pattern != PREFILL_Q4K_GEMV_PATTERN:
        return source_transform
    params = _prefill_q4k_gemv_params(compile_params)
    if params is None:
        return source_transform
    symbol_key = symbol.lower()
    if symbol_key in {"activation", "a"} and role == "activation":
        source_cols = _int_field(item.get("matrixCols"))
        if source_cols is None:
            source_cols = _model_hidden_dim(runtime_config)
        if source_cols is None or source_cols <= 0:
            return source_transform
        return {
            "kind": "logical_matrix_to_prefill_q4k_gemv_activation_shards",
            "sourceDtype": dtype,
            "targetDtype": "f16",
            "sourceCols": source_cols,
            **params,
        }
    if symbol_key in {"weight", "b"} and role == "weight" and weight_item is not None:
        shape = _normalized_shape(weight_item.get("shape") or [])
        if len(shape) < 2:
            return source_transform
        return {
            "kind": "q4km_rowwise_to_prefill_q4k_gemv_weight_tiles",
            "sourceDtype": str(weight_item.get("dtype") or ""),
            "targetDtype": "u8_q4k",
            "sourceRows": shape[0],
            "sourceCols": shape[1],
            **params,
        }
    return source_transform


def _prefill_q4k_gemv_output_transform(
    *,
    symbol: str,
    target_pattern: str,
    compile_params: dict[str, int],
    item: dict[str, Any],
    dtype: str,
) -> dict[str, Any] | None:
    if target_pattern != PREFILL_Q4K_GEMV_PATTERN:
        return None
    if symbol.lower() not in {"output", "c"}:
        return None
    params = _prefill_q4k_gemv_params(compile_params)
    output_cols = _int_field(item.get("matrixCols"))
    if params is None or output_cols is None:
        return None
    return {
        "kind": "prefill_q4k_gemv_row_tiles_to_logical_matrix",
        "cols": output_cols,
        "sourceDtype": dtype,
        "targetDtype": dtype,
        **params,
    }
