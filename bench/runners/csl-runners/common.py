"""Shared helpers for governed CSL sdk-runtime-command runners."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Sequence

import numpy as np


def parse_runtime_args(description: str) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--compile-dir", required=True, help="cslc -o directory")
    parser.add_argument("--trace-out", required=True)
    parser.add_argument("--cmaddr", default="", help="Optional CS system endpoint")
    return parser.parse_args()


def endpoint(raw_cmaddr: str) -> str | None:
    stripped = raw_cmaddr.strip()
    return stripped or None


def execution_target(cmaddr: str | None) -> str:
    return "system" if cmaddr else "simfabric"


def max_abs_error(actual: np.ndarray, expected: np.ndarray) -> float:
    return float(np.max(np.abs(actual - expected)))


def write_explicit_trace(
    *,
    trace_out: str,
    kernel: str,
    cmaddr: str | None,
    width: int,
    chunk_size: int,
    total_elements: int,
    max_abs_err: float,
    sample_input: Sequence[Any],
    sample_expected: Sequence[Any],
    sample_actual: Sequence[Any],
) -> Path:
    trace = {
        "schemaVersion": 1,
        "artifactKind": "csl_simulator_trace",
        "target": "wse3",
        "contract": "explicit_simulator_trace",
        "kernel": kernel,
        "executionTarget": execution_target(cmaddr),
        "width": width,
        "chunkSize": chunk_size,
        "totalElements": total_elements,
        "runtimePassed": True,
        "runtimeMaxAbsErr": max_abs_err,
        "sampleInput": list(sample_input),
        "sampleExpected": list(sample_expected),
        "sampleActual": list(sample_actual),
    }
    trace_path = Path(trace_out)
    trace_path.parent.mkdir(parents=True, exist_ok=True)
    trace_path.write_text(json.dumps(trace, indent=2) + "\n", encoding="utf-8")
    return trace_path


def run_streaming_tiled_attention(
    *,
    runner: Any,
    q_global: np.ndarray,
    k_full: np.ndarray,
    v_full: np.ndarray,
    width: int,
    head_dim: int,
    q_len: int,
    q_len_per_pe: int,
    kv_len: int,
    block_size: int,
    q_symbol: str = "q",
    k_symbol: str = "k",
    v_symbol: str = "v",
    output_symbol: str = "output",
    compute_symbol: str = "compute",
    finalize_symbol: str = "finalize",
    memcpy_data_type: Any | None = None,
    memcpy_order: Any | None = None,
) -> np.ndarray:
    """Drive the streaming-KV tiled attention dispatch from the host.

    Contract (matches emit_csl_attention.zig:emitTiled, verified against
    bench/out/cslc-attn-streaming-probe/probe-result.json):

      1. H2D the per-PE query shard once (q_global reshaped to
         (width, q_len_per_pe, head_dim) → flat memcpy_h2d of
         q_len_per_pe * head_dim elements per PE).
      2. For tile_idx in range(ceil(kv_len / block_size)):
           H2D K_tile[tile_idx]    (block_size x head_dim, same on all PEs)
           H2D V_tile[tile_idx]
           launch(compute_symbol)
      3. launch(finalize_symbol) — normalizes output by accumulated l_state.
      4. D2H output from all width PEs; reshape to (width, q_len_per_pe,
         head_dim) and concatenate along axis 0 to reassemble the full
         (q_len, head_dim) attention result.

    Partial K/V tiles (last one when kv_len % block_size != 0) are padded
    with zeros so the PE's inner loop sees `block_size` rows with zeroed
    tail (contributes weight exp(-inf)=0 to softmax — no effect). The caller
    is responsible for making sure q_len_per_pe * width >= q_len; rows
    beyond q_len are not written back.

    Imports for `memcpy_data_type` and `memcpy_order` are passed through
    rather than imported here to avoid a hard dependency on
    `cerebras.sdk.runtime.sdkruntimepybind` in this shared module (it is
    only importable inside `cs_python`).
    """
    if memcpy_data_type is None or memcpy_order is None:
        raise ValueError(
            "run_streaming_tiled_attention requires MemcpyDataType and "
            "MemcpyOrder arguments (import from "
            "cerebras.sdk.runtime.sdkruntimepybind in the caller)"
        )

    if q_global.shape != (q_len, head_dim):
        raise ValueError(
            f"q_global shape {q_global.shape} does not match (q_len={q_len}, "
            f"head_dim={head_dim})"
        )
    if q_len_per_pe * width < q_len:
        raise ValueError(
            f"q_len_per_pe*width ({q_len_per_pe * width}) < q_len ({q_len})"
        )
    if block_size < 1 or kv_len < 1:
        raise ValueError("block_size and kv_len must be positive")

    padded_q = np.zeros((width, q_len_per_pe, head_dim), dtype=np.float32)
    padded_q.reshape(width * q_len_per_pe, head_dim)[:q_len, :] = q_global.astype(
        np.float32, copy=False
    )
    q_flat = padded_q.reshape(-1).astype(np.float32, copy=False)

    q_id = runner.get_id(q_symbol)
    k_id = runner.get_id(k_symbol)
    v_id = runner.get_id(v_symbol)
    out_id = runner.get_id(output_symbol)

    runner.memcpy_h2d(
        q_id, q_flat, 0, 0, width, 1, q_len_per_pe * head_dim,
        streaming=False, order=memcpy_order.ROW_MAJOR,
        data_type=memcpy_data_type.MEMCPY_32BIT, nonblock=False,
    )

    tile_count = (kv_len + block_size - 1) // block_size
    for tile_idx in range(tile_count):
        start = tile_idx * block_size
        end = min(start + block_size, kv_len)
        tile_len = end - start
        k_tile = np.zeros((block_size, head_dim), dtype=np.float32)
        v_tile = np.zeros((block_size, head_dim), dtype=np.float32)
        k_tile[:tile_len] = k_full[start:end].astype(np.float32, copy=False)
        v_tile[:tile_len] = v_full[start:end].astype(np.float32, copy=False)
        k_flat = np.tile(k_tile.reshape(-1), width).astype(np.float32, copy=False)
        v_flat = np.tile(v_tile.reshape(-1), width).astype(np.float32, copy=False)
        runner.memcpy_h2d(
            k_id, k_flat, 0, 0, width, 1, block_size * head_dim,
            streaming=False, order=memcpy_order.ROW_MAJOR,
            data_type=memcpy_data_type.MEMCPY_32BIT, nonblock=False,
        )
        runner.memcpy_h2d(
            v_id, v_flat, 0, 0, width, 1, block_size * head_dim,
            streaming=False, order=memcpy_order.ROW_MAJOR,
            data_type=memcpy_data_type.MEMCPY_32BIT, nonblock=False,
        )
        runner.launch(compute_symbol, nonblock=False)

    runner.launch(finalize_symbol, nonblock=False)

    out_flat = np.zeros(width * q_len_per_pe * head_dim, dtype=np.float32)
    runner.memcpy_d2h(
        out_flat, out_id, 0, 0, width, 1, q_len_per_pe * head_dim,
        streaming=False, order=memcpy_order.ROW_MAJOR,
        data_type=memcpy_data_type.MEMCPY_32BIT, nonblock=False,
    )
    output_padded = out_flat.reshape(width, q_len_per_pe, head_dim)
    return output_padded.reshape(width * q_len_per_pe, head_dim)[:q_len, :].copy()


def run_fused_gemv_2d(
    *,
    runner: Any,
    activation: np.ndarray,
    weight_shards: np.ndarray,
    width: int,
    height: int,
    in_dim_per_pe: int,
    out_dim_per_pe: int,
    out_dim_total: int,
    num_blocks_per_row: int,
    activation_symbol: str = "activation",
    weight_symbol: str = "weight",
    output_symbol: str = "output",
    compute_symbol: str = "compute",
    memcpy_data_type: Any | None = None,
    memcpy_order: Any | None = None,
    q4k_block_bytes: int = 144,
) -> np.ndarray:
    """Drive the 2-D fused-GEMV dispatch from the host.

    Contract (matches emit_csl_fused.zig:emit + emit_csl_layout.zig:emitFusedGemvLayout,
    verified at bench/out/cslc-lmhead-2d-probe/probe-result.json):

      1. H2D activation once (every PE needs the same in_dim_per_pe slice;
         host tiles activation across width).
      2. H2D weight_shards — shape
         (height, width, out_dim_per_pe * num_blocks_per_row * q4k_block_bytes)
         flattened row-major so each PE(pe_x, pe_y) receives its
         (row_shard_y, in_shard_x) slice.
      3. launch(compute_symbol). Per-row east-west reduce folds partials
         automatically.
      4. D2H from every (pe_x=width-1, pe_y) sink PE. Reassemble full
         out_dim vector by concatenating out_dim_per_pe slices across
         pe_y rows, trimming the tail when out_dim_per_pe * height >
         out_dim_total.

    `memcpy_data_type` and `memcpy_order` must be imported from
    cerebras.sdk.runtime.sdkruntimepybind by the caller (inside
    cs_python).
    """
    if memcpy_data_type is None or memcpy_order is None:
        raise ValueError(
            "run_fused_gemv_2d requires MemcpyDataType and MemcpyOrder "
            "arguments (import from "
            "cerebras.sdk.runtime.sdkruntimepybind in the caller)"
        )
    expected_weight_shape = (
        height,
        width,
        out_dim_per_pe * num_blocks_per_row * q4k_block_bytes,
    )
    if weight_shards.shape != expected_weight_shape:
        raise ValueError(
            f"weight_shards shape {weight_shards.shape} does not match "
            f"(height={height}, width={width}, bytesPerPe="
            f"{expected_weight_shape[2]})"
        )
    if out_dim_per_pe * height < out_dim_total:
        raise ValueError(
            f"out_dim_per_pe*height ({out_dim_per_pe * height}) "
            f"< out_dim_total ({out_dim_total})"
        )
    if activation.shape != (in_dim_per_pe,) and activation.shape != (width, in_dim_per_pe):
        raise ValueError(
            f"activation shape {activation.shape} must be (in_dim_per_pe,) "
            f"or (width, in_dim_per_pe); host tiles the first form across width"
        )

    if activation.ndim == 1:
        activation_per_pe = np.tile(
            activation.astype(np.float32, copy=False), (width, 1)
        )
    else:
        activation_per_pe = activation.astype(np.float32, copy=False)
    act_flat = np.tile(
        activation_per_pe.reshape(-1), height
    ).astype(np.float32, copy=False)

    act_id = runner.get_id(activation_symbol)
    wgt_id = runner.get_id(weight_symbol)
    out_id = runner.get_id(output_symbol)

    runner.memcpy_h2d(
        act_id, act_flat, 0, 0, width, height, in_dim_per_pe,
        streaming=False, order=memcpy_order.ROW_MAJOR,
        data_type=memcpy_data_type.MEMCPY_32BIT, nonblock=False,
    )

    # cslc's memcpy runtime does not support MEMCPY_8BIT as a data_type in
    # SDK 2.10; weight u8 payloads are transferred as MEMCPY_32BIT by
    # viewing the underlying byte array as uint32. The PE program declares
    # weight as `[]u8` in the fused GEMV emitter and indexes byte-by-byte,
    # so the on-device memory layout after a u32-typed memcpy matches the
    # expected byte layout (host and device are both little-endian).
    weight_bytes_flat = weight_shards.reshape(-1).astype(np.uint8, copy=False)
    bytes_per_pe = expected_weight_shape[2]
    if bytes_per_pe % 4 != 0:
        raise ValueError(
            f"weight bytes_per_pe ({bytes_per_pe}) must be 4-aligned so the "
            "MEMCPY_32BIT view preserves the byte layout"
        )
    weight_u32 = weight_bytes_flat.view(np.uint32)
    runner.memcpy_h2d(
        wgt_id, weight_u32, 0, 0, width, height, bytes_per_pe // 4,
        streaming=False, order=memcpy_order.ROW_MAJOR,
        data_type=memcpy_data_type.MEMCPY_32BIT, nonblock=False,
    )

    runner.launch(compute_symbol, nonblock=False)

    out_flat = np.zeros(height * out_dim_per_pe, dtype=np.float32)
    runner.memcpy_d2h(
        out_flat, out_id, width - 1, 0, 1, height, out_dim_per_pe,
        streaming=False, order=memcpy_order.ROW_MAJOR,
        data_type=memcpy_data_type.MEMCPY_32BIT, nonblock=False,
    )
    rows = out_flat.reshape(height, out_dim_per_pe)
    full = rows.reshape(-1)[:out_dim_total].astype(np.float32, copy=False)
    return full.copy()


def numpy_tiled_attention_reference(
    *,
    q: np.ndarray,
    k: np.ndarray,
    v: np.ndarray,
    scale: float = 0.125,
) -> np.ndarray:
    """Pure-numpy online-softmax flash attention — semantically equivalent to
    what emit_csl_attention.zig:emitTiled computes over streamed tiles.

    Host-side reference for parity checks against the simulator-produced
    output; single-PE, single-head. Shapes: q (q_len, head_dim),
    k/v (kv_len, head_dim), output (q_len, head_dim).
    """
    q32 = q.astype(np.float32, copy=False)
    k32 = k.astype(np.float32, copy=False)
    v32 = v.astype(np.float32, copy=False)
    scores = q32 @ k32.T * scale
    scores -= scores.max(axis=1, keepdims=True)
    weights = np.exp(scores)
    weights /= weights.sum(axis=1, keepdims=True)
    return (weights @ v32).astype(np.float32, copy=False)
