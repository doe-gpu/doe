"""ROI session launch handlers outside the patchable embed dispatch path."""

from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Any

import numpy as np

from int4ple_compile_target_core import (
    GATED_PREFILL_TARGETS,
    LAUNCH_STEP_ADAPTER,
    RESIDUAL_PREFILL_TARGETS,
    RMSNORM_ROI_TARGETS,
    append_progress,
    cs_python_executable,
    load_json,
    tail_lines,
    write_json,
)
from int4ple_compile_target_materialization import (
    _launch_receipt_path,
    _staged_input_buffer_records,
)


def _is_rmsnorm_roi_launch(launch: dict[str, Any]) -> bool:
    return str(launch.get("targetName") or "") in RMSNORM_ROI_TARGETS


def _compact_gated_prefill_compile_dir(
    launch: dict[str, Any],
    rows: int,
) -> Path:
    target_name = str(launch.get("targetName") or "")
    compile_dir = Path(str(launch.get("compileDir") or ""))
    return compile_dir.parent / f"{target_name}_roi{rows}"


def _is_compact_gated_prefill_launch(
    launch: dict[str, Any],
    staged_outputs: list[dict[str, Any]],
) -> bool:
    target_name = str(launch.get("targetName") or "")
    if target_name not in GATED_PREFILL_TARGETS:
        return False
    if not staged_outputs or not isinstance(staged_outputs[0], dict):
        return False
    transform = staged_outputs[0].get("outputTransform") or {}
    if str(transform.get("kind") or "") != "pe_rows_to_logical_matrix":
        return False
    rows = int(transform.get("rows") or 0)
    width = int((launch.get("targetGeometry") or {}).get("width") or 0)
    return rows > 0 and width > rows


def _is_residual_prefill_roi_launch(
    launch: dict[str, Any],
    staged_outputs: list[dict[str, Any]],
) -> bool:
    target_name = str(launch.get("targetName") or "")
    if target_name not in RESIDUAL_PREFILL_TARGETS:
        return False
    if not staged_outputs or not isinstance(staged_outputs[0], dict):
        return False
    transform = staged_outputs[0].get("outputTransform") or {}
    if str(transform.get("kind") or "") != "pe_rows_to_logical_matrix":
        return False
    rows = int(transform.get("rows") or 0)
    width = int((launch.get("targetGeometry") or {}).get("width") or 0)
    return rows > 0 and width > rows


def _execute_residual_prefill_roi_launch(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    staged_inputs: list[dict[str, Any]],
    staged_outputs: list[dict[str, Any]],
    progress_path: Path,
    cmaddr: str | None,
    timeout_seconds: int | None,
) -> dict[str, Any]:
    launch_index = int(launch.get("launchIndex") or 0)
    if len(staged_inputs) < 2 or not staged_outputs:
        raise ValueError("residual_prefill_roi_bindings_missing")
    output = staged_outputs[0]
    transform = output.get("outputTransform") or {}
    rows = int(transform.get("rows") or 0)
    cols = int(
        transform.get("cols")
        or staged_inputs[0].get("elementsPerPe")
        or 0
    )
    if rows <= 0 or cols <= 0:
        raise ValueError("residual_prefill_roi_shape_missing")
    compile_dir = Path(str(launch.get("compileDir") or ""))
    row_compile_dir = compile_dir.parent / "residual_decode"
    if not row_compile_dir.is_dir():
        raise ValueError(
            f"residual_prefill_roi_compile_dir_missing:{row_compile_dir}"
        )

    roi_dir = runtime_dir / "residual-prefill-roi" / f"launch-{launch_index:04d}"
    roi_dir.mkdir(parents=True, exist_ok=True)
    input_matrix = np.load(
        Path(str(staged_inputs[0]["path"])),
        allow_pickle=False,
    ).ravel()
    residual_matrix = np.load(
        Path(str(staged_inputs[1]["path"])),
        allow_pickle=False,
    ).ravel()
    expected = rows * cols
    if input_matrix.size < expected:
        raise ValueError(
            "residual_prefill_roi_input_too_small:"
            f"{input_matrix.size}<{expected}"
        )
    if residual_matrix.size < expected:
        raise ValueError(
            "residual_prefill_roi_residual_too_small:"
            f"{residual_matrix.size}<{expected}"
        )

    row_outputs: list[Path] = [
        roi_dir / f"row-{row:04d}-output.npy" for row in range(rows)
    ]
    row_receipts: list[dict[str, Any]] = []
    append_progress(
        progress_path,
        "residual_prefill_roi_group_start",
        launchIndex=launch_index,
        rows=rows,
        cols=cols,
        compileDir=str(row_compile_dir),
    )
    for row in range(rows):
        row_input_path = roi_dir / f"row-{row:04d}-input.npy"
        row_residual_path = roi_dir / f"row-{row:04d}-residual.npy"
        np.save(
            row_input_path,
            input_matrix[row * cols : (row + 1) * cols].astype(
                np.float16,
                copy=False,
            ),
        )
        np.save(
            row_residual_path,
            residual_matrix[row * cols : (row + 1) * cols].astype(
                np.float16,
                copy=False,
            ),
        )
        row_transform = dict(transform)
        row_transform["rows"] = 1
        row_spec = {
            "compileDir": str(row_compile_dir),
            "launchFunction": launch.get("launchFunction"),
            "launchIndex": launch_index,
            "cmaddr": cmaddr or "",
            "targetGeometry": {
                "width": 1,
                "height": 1,
                "peCount": 1,
                "runtimePeCount": 1,
            },
            "inputs": [
                {
                    **staged_inputs[0],
                    "path": str(row_input_path),
                    "elementsPerPe": cols,
                },
                {
                    **staged_inputs[1],
                    "path": str(row_residual_path),
                    "elementsPerPe": cols,
                },
            ],
            "outputs": [
                {
                    **output,
                    "path": str(row_outputs[row]),
                    "elementsPerPe": cols,
                    "outputTransform": row_transform,
                }
            ],
        }
        spec_path = roi_dir / f"row-{row:04d}-spec.json"
        receipt_path = roi_dir / f"row-{row:04d}-receipt.json"
        write_json(spec_path, row_spec)
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
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=(
                timeout_seconds
                if timeout_seconds and timeout_seconds > 0
                else None
            ),
        )
        receipt = load_json(receipt_path) if receipt_path.is_file() else {}
        if completed.returncode != 0 or receipt.get("status") != "succeeded":
            raise ValueError(
                "; ".join(
                    receipt.get("blockers")
                    or ["residual_prefill_roi_row_failed"]
                )
            )
        row_receipts.append(receipt)

    merged = np.concatenate(
        [np.load(path, allow_pickle=False).ravel()[:cols] for path in row_outputs]
    ).astype(np.float16, copy=False)
    output_path = Path(str(output["path"]))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    np.save(output_path, merged)
    digest = hashlib.sha256(merged.tobytes(order="C")).hexdigest()
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "int4ple_residual_prefill_roi_launch_receipt",
        "status": "succeeded",
        "blockers": [],
        "launchIndex": launch_index,
        "compileDir": str(row_compile_dir),
        "sourceCompileDir": str(compile_dir),
        "rowReceiptCount": len(row_receipts),
        "inputBuffers": _staged_input_buffer_records(staged_inputs),
        "output": {
            "buffer": output.get("buffer"),
            "path": str(output_path),
            "dtype": "f16",
            "shape": [rows, cols],
            "sha256": digest,
            "sha256Kind": "array_tobytes_c_order",
        },
    }
    write_json(_launch_receipt_path(runtime_dir, launch_index), receipt)
    append_progress(
        progress_path,
        "residual_prefill_roi_group_complete",
        launchIndex=launch_index,
        rows=rows,
        cols=cols,
    )
    return receipt


def _execute_compact_gated_prefill_launch(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    staged_inputs: list[dict[str, Any]],
    staged_outputs: list[dict[str, Any]],
    progress_path: Path,
    cmaddr: str | None,
    timeout_seconds: int | None,
) -> dict[str, Any]:
    launch_index = int(launch.get("launchIndex") or 0)
    if len(staged_inputs) < 2 or not staged_outputs:
        raise ValueError("compact_gated_prefill_bindings_missing")
    output = staged_outputs[0]
    transform = output.get("outputTransform") or {}
    rows = int(transform.get("rows") or 0)
    cols = int(transform.get("cols") or staged_inputs[0].get("elementsPerPe") or 0)
    if rows <= 0 or cols <= 0:
        raise ValueError("compact_gated_prefill_shape_missing")
    compact_compile_dir = _compact_gated_prefill_compile_dir(launch, rows)
    if not compact_compile_dir.is_dir():
        raise ValueError(f"compact_gated_compile_dir_missing:{compact_compile_dir}")
    compact_dir = runtime_dir / "gated-prefill-compact" / f"launch-{launch_index:04d}"
    compact_dir.mkdir(parents=True, exist_ok=True)

    compact_inputs: list[dict[str, Any]] = []
    for item in staged_inputs:
        source = np.load(Path(str(item["path"])), allow_pickle=False).ravel()
        expected = rows * cols
        if source.size < expected:
            raise ValueError(
                "compact_gated_prefill_input_too_small:"
                f"{item.get('symbol')}:{source.size}<{expected}"
            )
        compact_path = compact_dir / f"{str(item.get('symbol') or 'input')}.npy"
        np.save(compact_path, source[:expected].astype(np.float16, copy=False))
        compact_inputs.append(
            {
                **item,
                "path": str(compact_path),
                "elementsPerPe": cols,
            }
        )

    compact_output_path = compact_dir / "output.npy"
    compact_spec = {
        "compileDir": str(compact_compile_dir),
        "launchFunction": launch.get("launchFunction"),
        "launchIndex": launch_index,
        "cmaddr": cmaddr or "",
        "targetGeometry": {
            "width": rows,
            "height": 1,
            "peCount": rows,
            "runtimePeCount": rows,
        },
        "inputs": compact_inputs,
        "outputs": [
            {
                **output,
                "path": str(compact_output_path),
                "elementsPerPe": cols,
                "outputTransform": {**transform, "rows": rows, "cols": cols},
            }
        ],
    }
    spec_path = compact_dir / "spec.json"
    receipt_path = compact_dir / "receipt.json"
    write_json(spec_path, compact_spec)
    append_progress(
        progress_path,
        "compact_gated_prefill_start",
        launchIndex=launch_index,
        rows=rows,
        cols=cols,
        compileDir=str(compact_compile_dir),
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
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout_seconds if timeout_seconds and timeout_seconds > 0 else None,
    )
    receipt = load_json(receipt_path) if receipt_path.is_file() else {}
    if completed.returncode != 0 or receipt.get("status") != "succeeded":
        raise ValueError(
            "; ".join(receipt.get("blockers") or ["compact_gated_prefill_failed"])
        )
    merged = np.load(compact_output_path, allow_pickle=False).ravel()[: rows * cols]
    output_path = Path(str(output["path"]))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    np.save(output_path, merged.astype(np.float16, copy=False))
    digest = hashlib.sha256(merged.tobytes(order="C")).hexdigest()
    compact_receipt = {
        "schemaVersion": 1,
        "artifactKind": "int4ple_compact_gated_prefill_launch_receipt",
        "status": "succeeded",
        "blockers": [],
        "launchIndex": launch_index,
        "compileDir": str(compact_compile_dir),
        "sourceCompileDir": str(launch.get("compileDir") or ""),
        "inputBuffers": _staged_input_buffer_records(staged_inputs),
        "adapterReceipt": str(receipt_path),
        "stdoutTail": tail_lines(completed.stdout, 1),
        "stderrTail": tail_lines(completed.stderr, 1),
        "output": {
            "buffer": output.get("buffer"),
            "path": str(output_path),
            "dtype": "f16",
            "shape": [rows, cols],
            "sha256": digest,
            "sha256Kind": "array_tobytes_c_order",
        },
    }
    write_json(_launch_receipt_path(runtime_dir, launch_index), compact_receipt)
    append_progress(
        progress_path,
        "compact_gated_prefill_complete",
        launchIndex=launch_index,
        rows=rows,
        cols=cols,
    )
    return compact_receipt


def _execute_rmsnorm_roi_launch(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    staged_inputs: list[dict[str, Any]],
    staged_outputs: list[dict[str, Any]],
    progress_path: Path,
    cmaddr: str | None,
    timeout_seconds: int | None,
    jobs: int,
) -> dict[str, Any]:
    launch_index = int(launch.get("launchIndex") or 0)
    if len(staged_inputs) < 2 or not staged_outputs:
        raise ValueError("rmsnorm_roi_bindings_missing")
    output = staged_outputs[0]
    transform = output.get("outputTransform") or {}
    rows = int(transform.get("rows") or 0)
    cols = int(transform.get("cols") or staged_inputs[0].get("elementsPerPe") or 0)
    if rows <= 0 or cols <= 0:
        raise ValueError("rmsnorm_roi_shape_missing")
    roi_dir = runtime_dir / "rmsnorm-roi" / f"launch-{launch_index:04d}"
    roi_dir.mkdir(parents=True, exist_ok=True)
    input_matrix = np.load(Path(str(staged_inputs[0]["path"])), allow_pickle=False).ravel()
    weight_vector = np.load(Path(str(staged_inputs[1]["path"])), allow_pickle=False).ravel()[:cols]
    compile_dir = Path(str(launch.get("compileDir") or ""))
    roi_compile_dir = compile_dir.parent / "rmsnorm_decode"
    row_outputs: list[Path] = [roi_dir / f"row-{row:04d}-output.npy" for row in range(rows)]

    def run_row(row: int) -> dict[str, Any]:
        row_input = input_matrix[row * cols : (row + 1) * cols].astype(np.float16, copy=False)
        row_input_path = roi_dir / f"row-{row:04d}-input.npy"
        row_weight_path = roi_dir / f"row-{row:04d}-weight.npy"
        np.save(row_input_path, row_input)
        np.save(row_weight_path, weight_vector.astype(np.float16, copy=False))
        row_transform = dict(transform)
        row_transform["rows"] = 1
        row_spec = {
            "compileDir": str(roi_compile_dir),
            "launchFunction": launch.get("launchFunction"),
            "launchIndex": launch_index,
            "cmaddr": cmaddr or "",
            "targetGeometry": {"width": 1, "height": 1, "peCount": 1, "runtimePeCount": 1},
            "inputs": [
                {**staged_inputs[0], "path": str(row_input_path), "elementsPerPe": cols},
                {**staged_inputs[1], "path": str(row_weight_path), "elementsPerPe": cols},
            ],
            "outputs": [
                {**output, "path": str(row_outputs[row]), "elementsPerPe": cols, "outputTransform": row_transform}
            ],
        }
        spec_path = roi_dir / f"row-{row:04d}-spec.json"
        receipt_path = roi_dir / f"row-{row:04d}-receipt.json"
        write_json(spec_path, row_spec)
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
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_seconds if timeout_seconds and timeout_seconds > 0 else None,
        )
        receipt = load_json(receipt_path) if receipt_path.is_file() else {}
        if completed.returncode != 0 or receipt.get("status") != "succeeded":
            raise ValueError("; ".join(receipt.get("blockers") or ["rmsnorm_roi_row_failed"]))
        return receipt

    append_progress(
        progress_path,
        "rmsnorm_roi_group_start",
        launchIndex=launch_index,
        rows=rows,
        jobs=max(1, int(jobs)),
    )
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, int(jobs))) as pool:
        row_receipts = list(pool.map(run_row, range(rows)))
    merged = np.concatenate(
        [np.load(path, allow_pickle=False).ravel()[:cols] for path in row_outputs]
    ).astype(np.float16, copy=False)
    output_path = Path(str(output["path"]))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    np.save(output_path, merged)
    digest = hashlib.sha256(merged.tobytes(order="C")).hexdigest()
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "int4ple_rmsnorm_roi_launch_receipt",
        "status": "succeeded",
        "blockers": [],
        "launchIndex": launch_index,
        "compileDir": str(roi_compile_dir),
        "rowReceiptCount": len(row_receipts),
        "output": {
            "buffer": output.get("buffer"),
            "path": str(output_path),
            "dtype": "f16",
            "shape": [rows, cols],
            "sha256": digest,
            "sha256Kind": "array_tobytes_c_order",
        },
    }
    write_json(_launch_receipt_path(runtime_dir, launch_index), receipt)
    append_progress(progress_path, "rmsnorm_roi_group_complete", launchIndex=launch_index)
    return receipt
