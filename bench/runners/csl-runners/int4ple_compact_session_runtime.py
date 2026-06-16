"""Compact session launch handlers for SUMMA, attention, and lm-head tiles."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

import numpy as np

from int4ple_compile_target_core import (
    CHAIN_STEP_ADAPTER,
    COMPACT_ATTENTION_Q_ROWS_PER_PE,
    LAUNCH_STEP_ADAPTER,
    REPO_ROOT,
    append_progress,
    cs_python_executable,
    cslc_executable,
    load_json,
    sha256_file,
    tail_lines,
    write_json,
)
from int4ple_compile_target_materialization import (
    _buffer_path,
    _launch_receipt_path,
    _launch_spec_path,
    _materialize_weight_input,
    _session_state_hash_payload,
    _staged_input_buffer_records,
    _staged_tile_record,
    _transform_existing_input,
)
from int4ple_compile_target_predicates import (
    _binding_for_any_symbol,
    _binding_for_symbol,
    _ceil_div,
)
from int4ple_summa_layout import (
    a_tiles_from_logical as _summa_a_tiles_from_logical,
    required_positive_int as _required_positive_int,
)
from manifest_dense_gemv_tiles import run_dense_gemv_row_tiled


def _compact_ple_proj_source_transform(
    *,
    matrix_role: str,
    source_cols: int,
    source_rows: int | None = None,
) -> dict[str, Any]:
    transform: dict[str, Any] = {
        "gridHeight": 2,
        "gridWidth": 2,
        "kind": (
            "weight_matrix_to_summa_tiles"
            if matrix_role == "b"
            else "logical_matrix_to_summa_tiles"
        ),
        "matrixRole": matrix_role,
        "paddedReduction": 256,
        "sourceCols": source_cols,
        "targetDtype": "f32",
    }
    if matrix_role == "a":
        transform.update({
            "paddedRows": 32,
            "sourceDtype": "f32",
            "tileReduction": 128,
            "tileRows": 16,
        })
    else:
        transform.update({
            "paddedCols": 32,
            "sourceDtype": "f32",
            "sourceRows": source_rows or 4,
            "sourceTransform": {"kind": "none"},
            "tileCols": 16,
            "tileReduction": 128,
        })
    return transform


def _compact_ple_proj_output_transform(*, rows: int, cols: int) -> dict[str, Any]:
    return {
        "cols": cols,
        "gridHeight": 2,
        "gridWidth": 2,
        "kind": "summa_tiles_to_logical_matrix",
        "matrixRole": "c",
        "paddedCols": 32,
        "paddedReduction": 256,
        "paddedRows": 32,
        "rows": rows,
        "sourceDtype": "f32",
        "targetDtype": "f32",
        "tileCols": 16,
        "tileReduction": 128,
        "tileRows": 16,
    }


def _compile_compact_ple_proj_target(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
) -> tuple[Path, dict[str, Any]]:
    source_compile_dir = Path(str(launch.get("compileDir") or ""))
    compile_root = source_compile_dir.parent.parent
    layout_path = compile_root / "ple_proj" / "layout.csl"
    output_dir = runtime_dir / "ple-proj-compact" / "p0002_mt0016_kt0128_nt0016"
    compiled_dir = output_dir / "compiled"
    params = {
        "P": 2,
        "Mt": 16,
        "Kt": 128,
        "Nt": 16,
        "fabricWidth": 9,
        "fabricHeight": 4,
        "fabricOffsetX": 4,
        "fabricOffsetY": 1,
    }
    if (compiled_dir / "out.json").is_file():
        return compiled_dir, {**params, "reused": True}
    command = [
        cslc_executable(),
        str(layout_path),
        "--arch=wse3",
        f"--fabric-dims={params['fabricWidth']},{params['fabricHeight']}",
        f"--fabric-offsets={params['fabricOffsetX']},{params['fabricOffsetY']}",
        "--channels=1",
        "--params=P:2,Mt:16,Kt:128,Nt:16",
        "-o",
        str(compiled_dir),
        "--memcpy",
    ]
    scratch_cwd = output_dir / "scratch"
    scratch_cwd.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        cwd=str(scratch_cwd),
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or "unknown"
        raise ValueError(f"compact_ple_proj_compile_failed:{detail[-400:]}")
    return compiled_dir, {
        **params,
        "reused": False,
        "stdoutTail": completed.stdout.strip().splitlines()[-3:],
        "stderrTail": completed.stderr.strip().splitlines()[-3:],
    }


def _compact_ple_proj_materialization(
    materialization: dict[str, Any],
    *,
    source_transform: dict[str, Any],
    planned_element_count: int,
    elements_per_pe: int,
) -> dict[str, Any]:
    return {
        **materialization,
        "dtype": "f32",
        "elemType": "f32",
        "elementsPerPe": elements_per_pe,
        "plannedElementCount": planned_element_count,
        "sourceTransform": source_transform,
        "targetGeometry": {
            "height": 2,
            "peCount": 4,
            "width": 2,
        },
    }


def _execute_compact_ple_proj_launch(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    buffer_files: dict[str, Path],
    progress_path: Path,
    cmaddr: str | None,
    timeout_seconds: int | None,
) -> dict[str, Any]:
    launch_index = int(launch.get("launchIndex") or 0)
    compile_dir, compile_identity = _compile_compact_ple_proj_target(
        runtime_dir=runtime_dir,
        launch=launch,
    )
    a_binding = _binding_for_symbol(
        launch.get("resolvedInputs") or [],
        "a",
        launch_index=launch_index,
    )
    b_binding = _binding_for_symbol(
        launch.get("resolvedInputs") or [],
        "b",
        launch_index=launch_index,
    )
    c_binding = _binding_for_symbol(
        launch.get("resolvedOutputs") or [],
        "c",
        launch_index=launch_index,
    )
    a_buffer = str(a_binding.get("buffer") or "")
    c_buffer = str(c_binding.get("buffer") or "")
    if a_buffer not in buffer_files:
        raise ValueError(f"compact_ple_proj_input_missing:{a_buffer}")
    activation = np.load(buffer_files[a_buffer], allow_pickle=False).ravel()
    a_materialization = a_binding.get("materialization") or {}
    a_source = a_materialization.get("sourceTransform") or {}
    source_cols = int(a_source.get("sourceCols") or a_binding.get("matrixCols") or 256)
    if source_cols <= 0:
        raise ValueError("compact_ple_proj_source_cols_missing")
    rows = int(activation.size // source_cols)
    if rows <= 0:
        raise ValueError("compact_ple_proj_activation_rows_missing")
    a_transform = _compact_ple_proj_source_transform(
        matrix_role="a",
        source_cols=source_cols,
    )
    a_values, _rows = _summa_a_tiles_from_logical(
        activation,
        a_transform,
        target_dtype=np.float32,
    )
    b_materialization = b_binding.get("materialization") or {}
    b_source = b_materialization.get("sourceTransform") or {}
    source_rows = int(b_source.get("sourceRows") or c_binding.get("matrixCols") or 4)
    b_transform = _compact_ple_proj_source_transform(
        matrix_role="b",
        source_cols=source_cols,
        source_rows=source_rows,
    )
    b_values = _materialize_weight_input(
        _compact_ple_proj_materialization(
            b_materialization,
            source_transform=b_transform,
            planned_element_count=8192,
            elements_per_pe=2048,
        )
    )
    launch_dir = runtime_dir / "ple-proj-compact" / f"launch-{launch_index:04d}"
    a_path = launch_dir / "inputs" / "a.npy"
    b_path = launch_dir / "inputs" / "b.npy"
    a_path.parent.mkdir(parents=True, exist_ok=True)
    np.save(a_path, a_values)
    np.save(b_path, b_values)
    output_path = _buffer_path(runtime_dir, c_buffer)
    output_transform = _compact_ple_proj_output_transform(
        rows=rows,
        cols=source_rows,
    )
    spec = {
        "compileDir": str(compile_dir),
        "launchFunction": launch.get("launchFunction") or "compute",
        "launchIndex": launch_index,
        "cmaddr": cmaddr or "",
        "targetGeometry": {
            "height": 2,
            "peCount": 4,
            "width": 2,
        },
        "inputs": [
            {
                "symbol": "a",
                "buffer": a_buffer,
                "role": "activation",
                "path": str(a_path),
                "dtype": "f32",
                "elemType": "f32",
                "elementsPerPe": 2048,
                "sourceTransform": a_transform,
            },
            {
                "symbol": "b",
                "buffer": str(b_binding.get("buffer") or ""),
                "role": "weight",
                "path": str(b_path),
                "dtype": "f32",
                "elemType": "f32",
                "elementsPerPe": 2048,
                "sourceTransform": b_transform,
            },
        ],
        "outputs": [
            {
                "symbol": "c",
                "buffer": c_buffer,
                "role": "activation",
                "path": str(output_path),
                "dtype": "f32",
                "elemType": "f32",
                "elementsPerPe": 256,
                "outputTransform": output_transform,
            }
        ],
    }
    spec_path = _launch_spec_path(runtime_dir, launch_index)
    receipt_path = _launch_receipt_path(runtime_dir, launch_index)
    write_json(spec_path, spec)
    append_progress(
        progress_path,
        "session_ple_proj_compact_start",
        launchIndex=launch_index,
        target=launch.get("targetName"),
        dispatchMode="compact_summa_session",
        rows=rows,
        cols=source_rows,
    )
    command = [
        cs_python_executable(),
        str(LAUNCH_STEP_ADAPTER),
        "--spec",
        str(spec_path),
        "--receipt-out",
        str(receipt_path),
        "--progress-out",
        str(progress_path),
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds if timeout_seconds and timeout_seconds > 0 else None,
        )
    except subprocess.TimeoutExpired as exc:
        receipt = {
            "schemaVersion": 1,
            "artifactKind": "int4ple_launch_step_receipt",
            "status": "blocked",
            "blockers": ["compact_ple_proj_timeout"],
            "launchIndex": launch_index,
            "targetName": launch.get("targetName"),
            "dispatchMode": "compact_summa_session",
            "compileIdentity": compile_identity,
            "inputBuffers": [
                {
                    "name": a_buffer,
                    "role": "activation",
                    "path": str(a_path),
                    "sha256": sha256_file(a_path),
                    "sha256Kind": "npy_file_bytes",
                },
            ],
            "stdoutTail": tail_lines(exc.stdout, 1),
            "stderrTail": tail_lines(exc.stderr, 1),
        }
        write_json(receipt_path, receipt)
        raise ValueError("compact_ple_proj_timeout") from exc
    if not receipt_path.is_file():
        raise ValueError("compact_ple_proj_receipt_missing")
    receipt = load_json(receipt_path)
    if not isinstance(receipt.get("inputBuffers"), list):
        receipt["inputBuffers"] = _staged_input_buffer_records(spec["inputs"])
    receipt["targetName"] = launch.get("targetName")
    receipt["dispatchMode"] = "compact_summa_session"
    receipt["compileIdentity"] = compile_identity
    receipt["stdoutTail"] = tail_lines(completed.stdout, 1)
    receipt["stderrTail"] = tail_lines(completed.stderr, 1)
    write_json(receipt_path, receipt)
    append_progress(
        progress_path,
        "session_ple_proj_compact_complete",
        launchIndex=launch_index,
        target=launch.get("targetName"),
        status=receipt.get("status"),
        blocker=";".join(receipt.get("blockers") or []),
    )
    if completed.returncode != 0 or receipt.get("status") != "succeeded":
        raise ValueError(
            "; ".join(receipt.get("blockers") or ["compact_ple_proj_failed"])
        )
    return receipt


def _attention_required_pe_rows(source_transform: dict[str, Any], rows: int) -> int:
    source_cols = _required_positive_int(source_transform, "sourceCols")
    head_dim = _required_positive_int(source_transform, "headDim")
    target_rows = _required_positive_int(source_transform, "targetRows")
    rows_per_pe = _required_positive_int(source_transform, "rowsPerPe")
    if source_cols % head_dim != 0:
        raise ValueError(
            f"attention_compact_source_cols_mismatch:{source_cols}%{head_dim}"
        )
    head_rows = rows * (source_cols // head_dim)
    required_pe_rows = _ceil_div(head_rows, rows_per_pe)
    if required_pe_rows > target_rows:
        raise ValueError(
            "attention_compact_rows_exceed_target:"
            f"{head_rows}>{target_rows * rows_per_pe}"
        )
    return required_pe_rows


def _attention_compact_transform(
    source_transform: dict[str, Any],
    *,
    target_rows: int,
    rows_per_pe: int | None = None,
) -> dict[str, Any]:
    transform = {
        **source_transform,
        "targetRows": target_rows,
    }
    if rows_per_pe is not None:
        transform["rowsPerPe"] = rows_per_pe
    return transform


def _load_compact_attention_input(
    *,
    buffer_files: dict[str, Path],
    binding: dict[str, Any],
    compact_width: int,
    launch_index: int,
    rows_per_pe: int | None = None,
) -> tuple[np.ndarray, dict[str, int], dict[str, Any]]:
    buffer_name = str(binding.get("buffer") or "")
    path = buffer_files.get(buffer_name)
    if path is None or not path.is_file():
        raise ValueError(f"compact_attention_input_missing:{buffer_name}")
    materialization = dict(binding.get("materialization") or {})
    source_transform = dict(materialization.get("sourceTransform") or {})
    source_transform = _attention_compact_transform(
        source_transform,
        target_rows=compact_width,
        rows_per_pe=rows_per_pe,
    )
    materialization["sourceTransform"] = source_transform
    if rows_per_pe is not None:
        head_dim = _required_positive_int(source_transform, "headDim")
        materialization["elementsPerPe"] = rows_per_pe * head_dim
    host = np.load(path, allow_pickle=False).ravel()
    values, matrix_shape = _transform_existing_input(host, materialization)
    expected = compact_width * int(materialization.get("elementsPerPe") or 0)
    if values.size != expected:
        raise ValueError(
            f"launch[{launch_index}].compact_attention_input_size_mismatch:"
            f"{buffer_name}:{values.size}!={expected}"
        )
    return values, matrix_shape, materialization


def _compile_compact_attention_target(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    width: int,
    head_dim: int,
    q_len_per_pe: int,
    block_size: int,
) -> tuple[Path, dict[str, Any]]:
    source_compile_dir = Path(str(launch.get("compileDir") or ""))
    compile_root = source_compile_dir.parent.parent
    layout_path = compile_root / "attn_small" / "layout.csl"
    original_out = source_compile_dir / "out.json"
    q_len = 4096
    if original_out.is_file():
        original = load_json(original_out)
        params = original.get("params") if isinstance(original, dict) else {}
        if isinstance(params, dict):
            q_len = int(params.get("q_len") or q_len)
    output_dir = (
        runtime_dir
        / "attention-prefill-compact"
        / f"w{width:04d}_hd{head_dim:04d}_q{q_len_per_pe:04d}_b{block_size:04d}"
    )
    compiled_dir = output_dir / "compiled"
    params = {
        "width": width,
        "headDim": head_dim,
        "qLen": q_len,
        "qLenPerPe": q_len_per_pe,
        "blockSize": block_size,
        "fabricWidth": width + 8,
        "fabricHeight": 3,
        "fabricOffsetX": 4,
        "fabricOffsetY": 1,
    }
    if (compiled_dir / "out.json").is_file():
        return compiled_dir, {**params, "reused": True}
    command = [
        cslc_executable(),
        str(layout_path),
        "--arch=wse3",
        f"--fabric-dims={params['fabricWidth']},{params['fabricHeight']}",
        f"--fabric-offsets={params['fabricOffsetX']},{params['fabricOffsetY']}",
        "--channels=1",
        (
            "--params="
            f"width:{width},head_dim:{head_dim},q_len:{q_len},"
            f"q_len_per_pe:{q_len_per_pe},block_size:{block_size}"
        ),
        "-o",
        str(compiled_dir),
        "--memcpy",
    ]
    scratch_cwd = output_dir / "scratch"
    scratch_cwd.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        cwd=str(scratch_cwd),
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or "unknown"
        raise ValueError(f"compact_attention_compile_failed:{detail[-400:]}")
    return compiled_dir, {
        **params,
        "reused": False,
        "stdoutTail": completed.stdout.strip().splitlines()[-3:],
        "stderrTail": completed.stderr.strip().splitlines()[-3:],
    }


def _execute_compact_attention_prefill_launch(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    buffer_files: dict[str, Path],
    progress_path: Path,
    cmaddr: str | None,
    timeout_seconds: int | None,
) -> dict[str, Any]:
    launch_index = int(launch.get("launchIndex") or 0)
    query_binding = _binding_for_symbol(
        launch.get("resolvedInputs") or [],
        "query",
        launch_index=launch_index,
    )
    key_binding = _binding_for_symbol(
        launch.get("resolvedInputs") or [],
        "key",
        launch_index=launch_index,
    )
    val_binding = _binding_for_any_symbol(
        launch.get("resolvedInputs") or [],
        ("val", "value"),
        launch_index=launch_index,
    )
    output_binding = _binding_for_symbol(
        launch.get("resolvedOutputs") or [],
        "output",
        launch_index=launch_index,
    )
    query_materialization = query_binding.get("materialization") or {}
    query_transform = query_materialization.get("sourceTransform") or {}
    if not isinstance(query_transform, dict):
        raise ValueError("compact_attention_query_transform_missing")
    query_path = buffer_files.get(str(query_binding.get("buffer") or ""))
    if query_path is None or not query_path.is_file():
        raise ValueError("compact_attention_query_missing")
    query_host = np.load(query_path, allow_pickle=False).ravel()
    query_cols = _required_positive_int(query_transform, "sourceCols")
    if query_host.size % query_cols != 0:
        raise ValueError(
            f"compact_attention_query_shape_mismatch:{query_host.size}%{query_cols}"
        )
    rows = query_host.size // query_cols
    head_dim = _required_positive_int(query_transform, "headDim")
    q_len_per_pe = COMPACT_ATTENTION_Q_ROWS_PER_PE
    compact_query_transform = {
        **dict(query_transform),
        "rowsPerPe": q_len_per_pe,
    }
    compact_width = max(
        _attention_required_pe_rows(
            compact_query_transform,
            rows,
        ),
        _attention_required_pe_rows(
            dict((key_binding.get("materialization") or {}).get("sourceTransform") or {}),
            rows,
        ),
        _attention_required_pe_rows(
            dict((val_binding.get("materialization") or {}).get("sourceTransform") or {}),
            rows,
        ),
    )
    query_values, query_shape, query_materialization = _load_compact_attention_input(
        buffer_files=buffer_files,
        binding=query_binding,
        compact_width=compact_width,
        launch_index=launch_index,
        rows_per_pe=q_len_per_pe,
    )
    key_values, _key_shape, key_materialization = _load_compact_attention_input(
        buffer_files=buffer_files,
        binding=key_binding,
        compact_width=compact_width,
        launch_index=launch_index,
    )
    val_values, _val_shape, val_materialization = _load_compact_attention_input(
        buffer_files=buffer_files,
        binding=val_binding,
        compact_width=compact_width,
        launch_index=launch_index,
    )
    key_transform = (key_materialization.get("sourceTransform") or {})
    block_size = _required_positive_int(key_transform, "rowsPerPe")
    compile_dir, compile_identity = _compile_compact_attention_target(
        runtime_dir=runtime_dir,
        launch=launch,
        width=compact_width,
        head_dim=head_dim,
        q_len_per_pe=q_len_per_pe,
        block_size=block_size,
    )
    launch_dir = runtime_dir / "attention-prefill-compact" / f"launch-{launch_index:04d}"
    input_dir = launch_dir / "inputs"
    input_dir.mkdir(parents=True, exist_ok=True)
    query_input_path = input_dir / "query.npy"
    key_input_path = input_dir / "key.npy"
    val_input_path = input_dir / "val.npy"
    np.save(query_input_path, query_values)
    np.save(key_input_path, key_values)
    np.save(val_input_path, val_values)
    output_buffer = str(output_binding.get("buffer") or "")
    output_path = _buffer_path(runtime_dir, output_buffer)
    output_materialization = output_binding.get("materialization") or {}
    output_transform = dict(output_materialization.get("outputTransform") or {})
    output_transform["rows"] = int(query_shape.get("rows") or rows)
    output_transform["targetRows"] = compact_width
    output_transform["rowsPerPe"] = q_len_per_pe
    output_elements_per_pe = q_len_per_pe * head_dim
    spec = {
        "compileDir": str(compile_dir),
        "launchFunction": launch.get("launchFunction") or "compute",
        "postLaunchFunctions": ["finalize"],
        "launchIndex": launch_index,
        "cmaddr": cmaddr or "",
        "targetGeometry": {
            "height": 1,
            "peCount": compact_width,
            "runtimePeCount": compact_width,
            "width": compact_width,
        },
        "inputs": [
            {
                "symbol": "query",
                "buffer": str(query_binding.get("buffer") or ""),
                "role": "activation",
                "path": str(query_input_path),
                "dtype": str(query_materialization.get("dtype") or "f16"),
                "elemType": str(query_materialization.get("elemType") or "f16"),
                "elementsPerPe": int(query_materialization.get("elementsPerPe") or 0),
                "sourceTransform": query_materialization.get("sourceTransform"),
            },
            {
                "symbol": "key",
                "buffer": str(key_binding.get("buffer") or ""),
                "role": str(key_binding.get("role") or "activation"),
                "path": str(key_input_path),
                "dtype": str(key_materialization.get("dtype") or "f16"),
                "elemType": str(key_materialization.get("elemType") or "f16"),
                "elementsPerPe": int(key_materialization.get("elementsPerPe") or 0),
                "sourceTransform": key_materialization.get("sourceTransform"),
            },
            {
                "symbol": str(val_binding.get("symbol") or "val"),
                "buffer": str(val_binding.get("buffer") or ""),
                "role": str(val_binding.get("role") or "activation"),
                "path": str(val_input_path),
                "dtype": str(val_materialization.get("dtype") or "f16"),
                "elemType": str(val_materialization.get("elemType") or "f16"),
                "elementsPerPe": int(val_materialization.get("elementsPerPe") or 0),
                "sourceTransform": val_materialization.get("sourceTransform"),
            },
        ],
        "outputs": [
            {
                "symbol": "output",
                "buffer": output_buffer,
                "role": "activation",
                "path": str(output_path),
                "dtype": str(output_materialization.get("dtype") or "f16"),
                "elemType": str(output_materialization.get("elemType") or "f16"),
                "elementsPerPe": output_elements_per_pe,
                "outputTransform": output_transform,
            }
        ],
    }
    spec_path = _launch_spec_path(runtime_dir, launch_index)
    receipt_path = _launch_receipt_path(runtime_dir, launch_index)
    write_json(spec_path, spec)
    append_progress(
        progress_path,
        "session_attention_compact_start",
        launchIndex=launch_index,
        target=launch.get("targetName"),
        dispatchMode="compact_width_session",
        rows=rows,
        compactWidth=compact_width,
        qLenPerPe=q_len_per_pe,
        blockSize=block_size,
    )
    command = [
        cs_python_executable(),
        str(LAUNCH_STEP_ADAPTER),
        "--spec",
        str(spec_path),
        "--receipt-out",
        str(receipt_path),
        "--progress-out",
        str(progress_path),
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds if timeout_seconds and timeout_seconds > 0 else None,
        )
    except subprocess.TimeoutExpired as exc:
        receipt = {
            "schemaVersion": 1,
            "artifactKind": "int4ple_launch_step_receipt",
            "status": "blocked",
            "blockers": ["compact_attention_timeout"],
            "launchIndex": launch_index,
            "targetName": launch.get("targetName"),
            "dispatchMode": "compact_width_session",
            "compileIdentity": compile_identity,
            "stdoutTail": tail_lines(exc.stdout, 1),
            "stderrTail": tail_lines(exc.stderr, 1),
        }
        write_json(receipt_path, receipt)
        raise ValueError("compact_attention_timeout") from exc
    if not receipt_path.is_file():
        raise ValueError("compact_attention_receipt_missing")
    receipt = load_json(receipt_path)
    if not isinstance(receipt.get("inputBuffers"), list):
        receipt["inputBuffers"] = _staged_input_buffer_records(spec["inputs"])
    receipt["targetName"] = launch.get("targetName")
    receipt["dispatchMode"] = "compact_width_session"
    receipt["compileIdentity"] = compile_identity
    receipt["stdoutTail"] = tail_lines(completed.stdout, 1)
    receipt["stderrTail"] = tail_lines(completed.stderr, 1)
    write_json(receipt_path, receipt)
    append_progress(
        progress_path,
        "session_attention_compact_complete",
        launchIndex=launch_index,
        target=launch.get("targetName"),
        status=receipt.get("status"),
        blocker=";".join(receipt.get("blockers") or []),
    )
    if completed.returncode != 0 or receipt.get("status") != "succeeded":
        raise ValueError(
            "; ".join(receipt.get("blockers") or ["compact_attention_failed"])
        )
    return receipt


def _execute_dense_gemv_tiled_session_launch(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    staged_inputs: list[dict[str, Any]],
    staged_outputs: list[dict[str, Any]],
    buffer_files: dict[str, Path],
    progress_path: Path,
    cmaddr: str | None,
    timeout_seconds: int,
    hidden_tile_width: int,
    tile_jobs: int,
    batch_runtime: bool,
    batch_runtime_step_budget: int,
    tile_dispatch_budget: int,
) -> dict[str, Any]:
    launch_index = int(launch.get("launchIndex") or 0)
    target_name = str(launch.get("targetName") or "")
    compile_dir = Path(str(launch.get("compileDir") or ""))
    compile_root = compile_dir.parent
    source_root = compile_root.parent
    state_payload = _session_state_hash_payload(
        launch=launch,
        buffer_files=buffer_files,
        staged_inputs=staged_inputs,
    )
    input_records = [_staged_tile_record(item) for item in staged_inputs]
    output_records = [_staged_tile_record(item) for item in staged_outputs]
    receipt_identity = {
        "identityKind": "session_dense_gemv_width_tile",
        "sessionStepId": state_payload["sessionStepId"],
        "sessionStateSha256": state_payload["sessionStateSha256"],
        "inputActivationSha256": state_payload["inputActivationSha256"],
        "targetName": target_name,
        "launchIndex": launch_index,
    }
    scratch_dir = runtime_dir / "session-dense-gemv-tiles" / f"launch-{launch_index:04d}"
    append_progress(
        progress_path,
        "session_lm_head_tiled_start",
        launchIndex=launch_index,
        target=target_name,
        dispatchMode="dense_gemv_width_tiled_session",
        sessionStateSha256=state_payload["sessionStateSha256"],
    )
    tiled = run_dense_gemv_row_tiled(
        kernel=target_name,
        compile_root=compile_root,
        source_root=source_root,
        compile_params=dict(launch.get("compileParams") or {}),
        input_records=input_records,
        output_records=output_records,
        scratch_dir=scratch_dir,
        cs_python=Path(cs_python_executable()),
        adapter=CHAIN_STEP_ADAPTER,
        cmaddr=cmaddr or "",
        timeout_seconds=timeout_seconds,
        repo_root=REPO_ROOT,
        cslc=Path(cslc_executable()),
        hidden_tile_width=hidden_tile_width,
        allow_unsafe_tile_shapes=False,
        reuse_verified_tile_partials=True,
        tile_dispatch_budget=tile_dispatch_budget,
        tile_dispatch_jobs=max(1, int(tile_jobs)),
        max_row_tile_height=1,
        batch_runtime=batch_runtime,
        batch_runtime_step_budget=batch_runtime_step_budget,
        receipt_identity=receipt_identity,
    )
    if tiled is None:
        raise ValueError("session_lm_head_tiled_unavailable")
    outputs = []
    for output in tiled.output_records:
        outputs.append(
            {
                "symbol": output.get("symbol"),
                "buffer": output.get("buffer"),
                "path": output.get("absolutePath") or output.get("path"),
                "dtype": output.get("elemType"),
                "sha256": output.get("sha256"),
                "totalBytes": output.get("totalBytes"),
            }
        )
    blockers = []
    if tiled.blocker is not None:
        blockers.append(str(tiled.blocker))
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "int4ple_launch_step_receipt",
        "status": "blocked" if blockers else "succeeded",
        "blockers": blockers,
        "launchIndex": launch_index,
        "targetName": target_name,
        "dispatchMode": "dense_gemv_width_tiled_session",
        "inputBuffers": _staged_input_buffer_records(staged_inputs),
        "sessionTileIdentity": receipt_identity,
        "sessionState": state_payload,
        "tileCoverage": tiled.tile_coverage,
        "tileCompile": tiled.tile_compile,
        "tileDispatches": tiled.tile_dispatches,
        "outputs": outputs,
        "stdoutTail": tiled.dispatch_stdout.splitlines()[-3:],
        "stderrTail": tiled.dispatch_stderr.splitlines()[-3:],
    }
    append_progress(
        progress_path,
        "session_lm_head_tiled_complete",
        launchIndex=launch_index,
        target=target_name,
        status=receipt["status"],
        blocker=";".join(blockers),
    )
    return receipt
