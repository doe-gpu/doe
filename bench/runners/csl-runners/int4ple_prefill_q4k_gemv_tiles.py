"""Tiling, compilation, and adapter helpers for prefill Q4K GEMV."""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from pathlib import Path
from typing import Any

import numpy as np

from int4ple_compile_target_core import (
    DEFAULT_PREFILL_Q4K_GEMV_ADAPTER_STEP_BUDGET,
    DEFAULT_PREFILL_Q4K_GEMV_OUTPUT_PE_ROWS,
    PREFILL_GEMV_FABRIC_EAST_RESERVED,
    PREFILL_GEMV_FABRIC_NORTH_RESERVED,
    PREFILL_GEMV_FABRIC_SOUTH_RESERVED,
    PREFILL_GEMV_FABRIC_WEST_RESERVED,
    PREFILL_GEMV_HOST_REDUCE_MIN_SOURCE_COLS,
    PREFILL_GEMV_IN_DIM_PER_PE,
    PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
    PREFILL_GEMV_OUT_DIM_PER_PE,
    PREFILL_GEMV_SOURCE_TILE_BLOCKS,
    PREFILL_GEMV_SOURCE_TILE_COLS,
    PREFILL_GEMV_WIDE_IN_DIM_PER_PE,
    PREFILL_GEMV_WIDE_SOURCE_COLS,
    PREFILL_Q4K_GEMV_PATTERN,
    Q4K_BLOCK_BYTES,
    Q4K_BLOCK_ELEMENTS,
    SDK_D2H_ELEMENT_COUNT_LIMIT,
    cslc_executable,
    write_json,
)
from int4ple_compile_target_materialization import _read_weight_prefix_bytes
from int4ple_compile_target_predicates import _ceil_div


def _prefill_gemv_blocks_per_pe(in_dim_per_pe: int) -> int:
    if in_dim_per_pe % Q4K_BLOCK_ELEMENTS != 0:
        raise ValueError(
            "prefill_gemv_in_dim_per_pe_unaligned:"
            f"{in_dim_per_pe}%{Q4K_BLOCK_ELEMENTS}"
        )
    return in_dim_per_pe // Q4K_BLOCK_ELEMENTS


def _prefill_gemv_in_dim_per_pe(source_cols: int) -> int:
    if source_cols >= PREFILL_GEMV_WIDE_SOURCE_COLS:
        return PREFILL_GEMV_WIDE_IN_DIM_PER_PE
    return PREFILL_GEMV_IN_DIM_PER_PE


def _prefill_gemv_output_pe_rows(value: int) -> int:
    output_pe_rows = max(1, int(value))
    if output_pe_rows > PREFILL_GEMV_MAX_OUTPUT_PE_ROWS:
        raise ValueError(
            "prefill_q4k_gemv_output_pe_rows_unsupported:"
            f"{output_pe_rows}>{PREFILL_GEMV_MAX_OUTPUT_PE_ROWS}"
        )
    return output_pe_rows


def _prefill_gemv_split_d2h_rows(
    *,
    output_tile_cols: int,
    output_region_height: int,
) -> bool:
    if int(output_region_height) > 1:
        return True
    return int(output_tile_cols) >= SDK_D2H_ELEMENT_COUNT_LIMIT


def _prefill_gemv_source_tiles(source_cols: int) -> list[dict[str, int]]:
    source_cols = int(source_cols)
    if source_cols <= 0:
        raise ValueError("prefill_q4k_gemv_source_cols_missing")
    source_blocks = _ceil_div(source_cols, Q4K_BLOCK_ELEMENTS)
    compile_source_cols = max(
        source_cols,
        PREFILL_GEMV_HOST_REDUCE_MIN_SOURCE_COLS,
    )
    compile_block_count = _ceil_div(compile_source_cols, Q4K_BLOCK_ELEMENTS)
    if source_cols <= PREFILL_GEMV_SOURCE_TILE_COLS:
        return [
            {
                "sourceTileIndex": 0,
                "sourceColStart": 0,
                "sourceCols": source_cols,
                "sourceBlockStart": 0,
                "sourceBlockCount": source_blocks,
                "compileSourceCols": compile_source_cols,
                "compileBlockCount": compile_block_count,
            }
        ]

    tiles: list[dict[str, int]] = []
    for source_block_start in range(
        0,
        source_blocks,
        PREFILL_GEMV_SOURCE_TILE_BLOCKS,
    ):
        source_block_count = min(
            PREFILL_GEMV_SOURCE_TILE_BLOCKS,
            source_blocks - source_block_start,
        )
        source_col_start = source_block_start * Q4K_BLOCK_ELEMENTS
        source_tile_cols = min(
            source_cols - source_col_start,
            source_block_count * Q4K_BLOCK_ELEMENTS,
        )
        compile_source_cols = max(
            PREFILL_GEMV_SOURCE_TILE_COLS,
            PREFILL_GEMV_HOST_REDUCE_MIN_SOURCE_COLS,
        )
        tiles.append({
            "sourceTileIndex": len(tiles),
            "sourceColStart": source_col_start,
            "sourceCols": source_tile_cols,
            "sourceBlockStart": source_block_start,
            "sourceBlockCount": source_block_count,
            "compileSourceCols": compile_source_cols,
            "compileBlockCount": _ceil_div(
                compile_source_cols,
                Q4K_BLOCK_ELEMENTS,
            ),
        })
    return tiles


def _prefill_gemv_weight_rows_source_tile(
    *,
    weight_rows: np.ndarray,
    source_block_start: int,
    source_block_count: int,
    compile_block_count: int,
) -> np.ndarray:
    source_block_start = int(source_block_start)
    source_block_count = int(source_block_count)
    compile_block_count = int(compile_block_count)
    if min(source_block_count, compile_block_count) <= 0:
        raise ValueError("prefill_q4k_gemv_source_tile_blocks_missing")
    if source_block_count > compile_block_count:
        raise ValueError(
            "prefill_q4k_gemv_source_tile_block_overflow:"
            f"{source_block_count}>{compile_block_count}"
        )
    byte_start = source_block_start * Q4K_BLOCK_BYTES
    byte_count = source_block_count * Q4K_BLOCK_BYTES
    compile_byte_count = compile_block_count * Q4K_BLOCK_BYTES
    if weight_rows.shape[1] < byte_start + byte_count:
        raise ValueError(
            "prefill_q4k_gemv_source_tile_weight_short:"
            f"{weight_rows.shape[1]}<{byte_start + byte_count}"
        )
    tile = np.zeros((weight_rows.shape[0], compile_byte_count), dtype=np.uint8)
    tile[:, :byte_count] = weight_rows[:, byte_start : byte_start + byte_count]
    return tile


def _compile_tiled_q4k_gemv_target(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    source_cols: int,
    output_pe_rows: int = DEFAULT_PREFILL_Q4K_GEMV_OUTPUT_PE_ROWS,
) -> tuple[Path, dict[str, Any]]:
    in_dim_per_pe = _prefill_gemv_in_dim_per_pe(source_cols)
    out_dim_per_pe = PREFILL_GEMV_OUT_DIM_PER_PE
    output_pe_rows = _prefill_gemv_output_pe_rows(output_pe_rows)
    width = _ceil_div(source_cols, in_dim_per_pe)
    blocks_per_pe = _prefill_gemv_blocks_per_pe(in_dim_per_pe)
    source_compile_dir = Path(str(launch.get("compileDir") or ""))
    compile_root = source_compile_dir.parent.parent
    if str(launch.get("kernelPattern") or "") == PREFILL_Q4K_GEMV_PATTERN:
        raw_layout_path = str(launch.get("layoutPath") or "")
        layout_path = (
            Path(raw_layout_path)
            if raw_layout_path
            else compile_root / str(launch.get("targetName") or "") / "layout.csl"
        )
    else:
        layout_path = compile_root / "gemv" / "layout.csl"
    if not layout_path.is_absolute():
        layout_path = compile_root / layout_path
    output_dir = (
        runtime_dir
        / "tiled-q4k-gemv"
        / (
            f"compiled_w{width:04d}_h{output_pe_rows:04d}"
            f"_o{out_dim_per_pe:04d}_i{in_dim_per_pe:04d}_dr1"
        )
    )
    params = {
        "width": width,
        "height": output_pe_rows,
        "outDim": output_pe_rows * out_dim_per_pe,
        "outDimPerPe": out_dim_per_pe,
        "inDimPerPe": in_dim_per_pe,
        "numBlocksPerRow": blocks_per_pe,
        "fabricWidth": (
            width
            + PREFILL_GEMV_FABRIC_WEST_RESERVED
            + PREFILL_GEMV_FABRIC_EAST_RESERVED
        ),
        "fabricHeight": (
            output_pe_rows
            + PREFILL_GEMV_FABRIC_NORTH_RESERVED
            + PREFILL_GEMV_FABRIC_SOUTH_RESERVED
        ),
        "fabricOffsetX": PREFILL_GEMV_FABRIC_WEST_RESERVED,
        "fabricOffsetY": PREFILL_GEMV_FABRIC_NORTH_RESERVED,
        "hostReduce": False,
    }
    if (output_dir / "out.json").is_file() and (output_dir / "bin").is_dir():
        return output_dir, {**params, "reused": True}
    if output_dir.exists():
        shutil.rmtree(output_dir)
    receipt_path = output_dir / "prefill-gemv-compile.json"
    command = [
        cslc_executable(),
        str(layout_path),
        "--arch=wse3",
        f"--fabric-dims={params['fabricWidth']},{params['fabricHeight']}",
        f"--fabric-offsets={params['fabricOffsetX']},{params['fabricOffsetY']}",
        "--channels=1",
        (
            f"--params=width:{width},height:{output_pe_rows},"
            f"out_dim:{output_pe_rows * out_dim_per_pe},"
            f"out_dim_per_pe:{out_dim_per_pe},"
            f"in_dim_per_pe:{in_dim_per_pe},"
            f"num_blocks_per_row:{blocks_per_pe},"
            "host_reduce:0"
        ),
        "-o",
        str(output_dir),
        "--memcpy",
    ]
    scratch_cwd = output_dir / "scratch"
    scratch_tmp = output_dir / "tmp"
    scratch_cwd.mkdir(parents=True, exist_ok=True)
    scratch_tmp.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["TMPDIR"] = str(scratch_tmp)
    started_ns = time.monotonic_ns()
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        cwd=str(scratch_cwd),
        env=env,
    )
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "int4ple_prefill_q4k_gemv_compile_receipt",
        "status": "succeeded" if completed.returncode == 0 else "blocked",
        "blockers": []
        if completed.returncode == 0
        else [f"prefill_q4k_gemv_compile_exit_code_{completed.returncode}"],
        "layoutPath": str(layout_path),
        "compileDir": str(output_dir),
        "params": params,
        "command": command,
        "wallclockNs": time.monotonic_ns() - started_ns,
        "stdoutTail": completed.stdout.strip().splitlines()[-4:],
        "stderrTail": completed.stderr.strip().splitlines()[-4:],
    }
    write_json(receipt_path, receipt)
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or "unknown"
        raise ValueError(f"prefill_q4k_gemv_compile_failed:{detail[-400:]}")
    return output_dir, {
        **params,
        "reused": False,
        "receiptPath": str(receipt_path),
        "stdoutTail": completed.stdout.strip().splitlines()[-3:],
        "stderrTail": completed.stderr.strip().splitlines()[-3:],
    }


def _q4k_weight_row_bytes(source_cols: int) -> int:
    return _ceil_div(source_cols, Q4K_BLOCK_ELEMENTS) * Q4K_BLOCK_BYTES


def _load_q4k_weight_rows(
    *,
    materialization: dict[str, Any],
    source_rows: int,
    source_cols: int,
) -> np.ndarray:
    mapping = materialization.get("weightMapping")
    if not isinstance(mapping, dict):
        raise ValueError("prefill_q4k_gemv_weight_mapping_missing")
    byte_count = source_rows * _q4k_weight_row_bytes(source_cols)
    raw = _read_weight_prefix_bytes(mapping, byte_count)
    return np.frombuffer(raw, dtype=np.uint8).reshape(source_rows, -1)


def _materialize_prefill_gemv_activation_tile(
    *,
    activation_row: np.ndarray,
    source_cols: int,
    width: int,
    height: int,
    in_dim_per_pe: int,
) -> np.ndarray:
    tile = np.zeros((height, width, in_dim_per_pe), dtype=np.float16)
    row = activation_row[:source_cols].astype(np.float16, copy=False)
    for pe_x in range(width):
        col_start = pe_x * in_dim_per_pe
        col_end = min(col_start + in_dim_per_pe, source_cols)
        if col_end > col_start:
            tile[:, pe_x, : col_end - col_start] = row[col_start:col_end]
    return tile.reshape(-1)


def _materialize_prefill_gemv_weight_tile(
    *,
    weight_rows: np.ndarray,
    source_cols: int,
    output_start: int,
    output_cols: int,
    width: int,
    height: int,
    out_dim_per_pe: int,
    blocks_per_pe: int,
) -> np.ndarray:
    source_blocks = _ceil_div(source_cols, Q4K_BLOCK_ELEMENTS)
    bytes_per_row = source_blocks * Q4K_BLOCK_BYTES
    if weight_rows.shape[1] != bytes_per_row:
        raise ValueError(
            "prefill_q4k_gemv_weight_row_byte_mismatch:"
            f"{weight_rows.shape[1]}!={bytes_per_row}"
        )
    chunk_bytes = out_dim_per_pe * blocks_per_pe * Q4K_BLOCK_BYTES
    tile = np.zeros((height, width, chunk_bytes), dtype=np.uint8)
    for pe_y in range(height):
        row_base = output_start + pe_y * out_dim_per_pe
        for local_row in range(out_dim_per_pe):
            source_row = row_base + local_row
            if source_row >= output_cols:
                continue
            row_bytes = weight_rows[source_row]
            local_base = local_row * blocks_per_pe * Q4K_BLOCK_BYTES
            for pe_x in range(width):
                source_block = pe_x * blocks_per_pe
                for block_index in range(blocks_per_pe):
                    block = source_block + block_index
                    if block >= source_blocks:
                        continue
                    dst = local_base + block_index * Q4K_BLOCK_BYTES
                    src = block * Q4K_BLOCK_BYTES
                    tile[pe_y, pe_x, dst : dst + Q4K_BLOCK_BYTES] = row_bytes[
                        src : src + Q4K_BLOCK_BYTES
                    ]
    return tile.reshape(-1)


def _run_prefill_gemv_tile(
    *,
    command: list[str],
    timeout_seconds: int | None,
) -> tuple[int, str, str, bool, int]:
    started_ns = time.monotonic_ns()
    timeout = timeout_seconds if timeout_seconds and timeout_seconds > 0 else None
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return (
            int(process.returncode or 0),
            stdout,
            stderr,
            False,
            time.monotonic_ns() - started_ns,
        )
    except subprocess.TimeoutExpired as exc:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        stdout = stdout if isinstance(stdout, str) else ""
        stderr = stderr if isinstance(stderr, str) else ""
        if isinstance(exc.stdout, str) and exc.stdout:
            stdout = exc.stdout + stdout
        if isinstance(exc.stderr, str) and exc.stderr:
            stderr = exc.stderr + stderr
        return -1, stdout, stderr, True, time.monotonic_ns() - started_ns


def _prefill_gemv_tile_output_status(
    path: Path,
    *,
    expected_elements: int,
    expected_dtype: np.dtype = np.dtype(np.float16),
) -> tuple[bool, str]:
    if not path.is_file() or path.stat().st_size <= 0:
        return False, "missing"
    try:
        loaded = np.load(path, allow_pickle=False).ravel()
    except (OSError, ValueError) as exc:
        return False, f"unreadable:{type(exc).__name__}"
    if loaded.dtype != expected_dtype:
        return False, f"dtype:{loaded.dtype}"
    if loaded.size != expected_elements:
        return False, f"size:{loaded.size}!={expected_elements}"
    return True, "ready"
