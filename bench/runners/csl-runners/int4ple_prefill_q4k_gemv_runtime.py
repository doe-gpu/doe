"""Runtime execution for prefill Q4K GEMV launch groups."""

from __future__ import annotations

import concurrent.futures
import hashlib
from pathlib import Path
from typing import Any

import numpy as np

from int4ple_compile_target_core import (
    CHAIN_STEP_ADAPTER,
    DEFAULT_PREFILL_Q4K_GEMV_ADAPTER_STEP_BUDGET,
    DEFAULT_PREFILL_Q4K_GEMV_OUTPUT_PE_ROWS,
    PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
    PREFILL_GEMV_SOURCE_TILE_BLOCKS,
    PREFILL_GEMV_SOURCE_TILE_COLS,
    Q4K_BLOCK_BYTES,
    SDK_D2H_ELEMENT_COUNT_LIMIT,
    append_progress,
    cs_python_executable,
    sha256_file,
    tail_lines,
    write_json,
)
from int4ple_compile_target_materialization import (
    _buffer_path,
    _launch_receipt_path,
)
from int4ple_compile_target_predicates import _binding_for_any_symbol, _ceil_div
from int4ple_prefill_q4k_gemv_tiles import (
    _compile_tiled_q4k_gemv_target,
    _load_q4k_weight_rows,
    _materialize_prefill_gemv_activation_tile,
    _materialize_prefill_gemv_weight_tile,
    _prefill_gemv_source_tiles,
    _prefill_gemv_split_d2h_rows,
    _prefill_gemv_tile_output_status,
    _prefill_gemv_weight_rows_source_tile,
    _run_prefill_gemv_tile,
)


def _prefill_gemv_task_shards(
    tasks: list[dict[str, Any]],
    *,
    jobs: int,
    adapter_step_budget: int,
) -> list[list[dict[str, Any]]]:
    if not tasks:
        return []
    del jobs
    shard_size = max(1, int(adapter_step_budget))
    return [
        tasks[start : start + shard_size]
        for start in range(0, len(tasks), shard_size)
    ]


def _execute_tiled_q4k_gemv_launch(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    buffer_files: dict[str, Path],
    progress_path: Path,
    cmaddr: str | None,
    timeout_seconds: int | None,
    jobs: int,
    output_pe_rows: int = DEFAULT_PREFILL_Q4K_GEMV_OUTPUT_PE_ROWS,
    adapter_step_budget: int = DEFAULT_PREFILL_Q4K_GEMV_ADAPTER_STEP_BUDGET,
    tile_dispatch_budget: int = 0,
) -> dict[str, Any]:
    launch_index = int(launch.get("launchIndex") or 0)
    a_binding = _binding_for_any_symbol(
        launch.get("resolvedInputs") or [],
        ("activation", "a"),
        launch_index=launch_index,
    )
    b_binding = _binding_for_any_symbol(
        launch.get("resolvedInputs") or [],
        ("weight", "b"),
        launch_index=launch_index,
    )
    c_binding = _binding_for_any_symbol(
        launch.get("resolvedOutputs") or [],
        ("output", "c"),
        launch_index=launch_index,
    )
    a_materialization = a_binding.get("materialization") or {}
    b_materialization = b_binding.get("materialization") or {}
    c_materialization = c_binding.get("materialization") or {}
    a_source = a_materialization.get("sourceTransform") or {}
    b_source = b_materialization.get("sourceTransform") or {}
    c_output = c_materialization.get("outputTransform") or {}
    source_cols = int(a_source.get("sourceCols") or b_source.get("sourceCols") or 0)
    output_cols = int(c_output.get("cols") or b_source.get("sourceRows") or 0)
    source_rows = int(b_source.get("sourceRows") or output_cols)
    if min(source_cols, output_cols, source_rows) <= 0:
        raise ValueError("prefill_q4k_gemv_shape_missing")
    if source_rows < output_cols:
        raise ValueError(
            f"prefill_q4k_gemv_source_rows_short:{source_rows}<{output_cols}"
        )
    a_buffer = str(a_binding.get("buffer") or "")
    c_buffer = str(c_binding.get("buffer") or "")
    activation_path = buffer_files.get(a_buffer)
    if activation_path is None or not activation_path.is_file():
        raise ValueError(f"prefill_q4k_gemv_activation_missing:{a_buffer}")
    activation = np.load(activation_path, allow_pickle=False).ravel()
    if activation.size % source_cols != 0:
        raise ValueError(
            f"prefill_q4k_gemv_activation_shape_mismatch:{activation.size}%{source_cols}"
        )
    rows = int(c_output.get("rows") or (activation.size // source_cols))
    if rows <= 0 or rows > activation.size // source_cols:
        raise ValueError("prefill_q4k_gemv_activation_rows_missing")
    source_tiles = _prefill_gemv_source_tiles(source_cols)
    compile_source_cols = max(
        int(tile["compileSourceCols"]) for tile in source_tiles
    )
    compile_dir, compile_identity = _compile_tiled_q4k_gemv_target(
        runtime_dir=runtime_dir,
        launch=launch,
        source_cols=compile_source_cols,
        output_pe_rows=output_pe_rows,
    )
    width = int(compile_identity["width"])
    height = int(compile_identity["height"])
    in_dim_per_pe = int(compile_identity["inDimPerPe"])
    out_dim_per_pe = int(compile_identity["outDimPerPe"])
    blocks_per_pe = int(compile_identity["numBlocksPerRow"])
    output_tile_cols = height * out_dim_per_pe
    output_region_x = max(0, width - 1)
    output_region_width = 1
    output_read_elements = output_region_width * output_tile_cols
    split_d2h_rows = _prefill_gemv_split_d2h_rows(
        output_tile_cols=output_read_elements,
        output_region_height=height,
    )
    weight_rows = _load_q4k_weight_rows(
        materialization=b_materialization,
        source_rows=source_rows,
        source_cols=source_cols,
    )
    launch_dir = runtime_dir / "tiled-q4k-gemv" / f"launch-{launch_index:04d}"
    output_matrix = np.zeros((rows, output_cols), dtype=np.float32)
    output_path = _buffer_path(runtime_dir, c_buffer)
    append_progress(
        progress_path,
        "prefill_q4k_gemv_group_start",
        launchIndex=launch_index,
        target=launch.get("targetName"),
        rows=rows,
        sourceCols=source_cols,
        outputCols=output_cols,
        jobs=max(1, int(jobs)),
    )

    tasks: list[dict[str, Any]] = []
    for row_index in range(rows):
        row = activation[
            row_index * source_cols : (row_index + 1) * source_cols
        ]
        for source_tile in source_tiles:
            source_tile_index = int(source_tile["sourceTileIndex"])
            source_col_start = int(source_tile["sourceColStart"])
            source_tile_cols = int(source_tile["sourceCols"])
            source_block_start = int(source_tile["sourceBlockStart"])
            source_block_count = int(source_tile["sourceBlockCount"])
            compile_tile_cols = int(source_tile["compileSourceCols"])
            compile_block_count = int(source_tile["compileBlockCount"])
            activation_tile_row = np.zeros(compile_tile_cols, dtype=np.float16)
            activation_tile_row[:source_tile_cols] = row[
                source_col_start : source_col_start + source_tile_cols
            ]
            weight_rows_tile = _prefill_gemv_weight_rows_source_tile(
                weight_rows=weight_rows,
                source_block_start=source_block_start,
                source_block_count=source_block_count,
                compile_block_count=compile_block_count,
            )
            for output_start in range(0, output_cols, output_tile_cols):
                tile_dir = (
                    launch_dir
                    / f"row-{row_index:04d}"
                    / f"src-{source_col_start:05d}"
                    / f"out-{output_start:05d}"
                )
                act_path = tile_dir / "in" / "activation.npy"
                weight_path = tile_dir / "in" / "weight.npy"
                tile_output_path = tile_dir / "out" / "output.npy"
                phase_trace_path = tile_dir / "phase-trace.log"
                act_tile = _materialize_prefill_gemv_activation_tile(
                    activation_row=activation_tile_row,
                    source_cols=compile_tile_cols,
                    width=width,
                    height=height,
                    in_dim_per_pe=in_dim_per_pe,
                )
                weight_tile = _materialize_prefill_gemv_weight_tile(
                    weight_rows=weight_rows_tile,
                    source_cols=compile_tile_cols,
                    output_start=output_start,
                    output_cols=output_cols,
                    width=width,
                    height=height,
                    out_dim_per_pe=out_dim_per_pe,
                    blocks_per_pe=blocks_per_pe,
                )
                act_path.parent.mkdir(parents=True, exist_ok=True)
                weight_path.parent.mkdir(parents=True, exist_ok=True)
                np.save(act_path, act_tile)
                np.save(weight_path, weight_tile)
                activation_spec = f"activation:{act_path}:f16:{in_dim_per_pe}"
                weight_spec = (
                    f"weight:{weight_path}:u8:"
                    f"{out_dim_per_pe * blocks_per_pe * Q4K_BLOCK_BYTES}"
                )
                output_spec = (
                    f"output:{tile_output_path}:f16:{out_dim_per_pe}:"
                    f"{output_region_x},0,{output_region_width},{height}"
                )
                command = [
                    cs_python_executable(),
                    str(CHAIN_STEP_ADAPTER),
                    "--compile-dir",
                    str(compile_dir),
                    "--width",
                    str(width),
                    "--height",
                    str(height),
                    "--chunk-size",
                    str(in_dim_per_pe),
                    "--input",
                    activation_spec,
                    "--input",
                    weight_spec,
                    "--output",
                    output_spec,
                    "--phase-trace",
                    str(phase_trace_path),
                ]
                if cmaddr:
                    command.extend(["--cmaddr", cmaddr])
                output_reusable, reuse_status = _prefill_gemv_tile_output_status(
                    tile_output_path,
                    expected_elements=output_read_elements,
                    expected_dtype=np.dtype(np.float16),
                )
                if not output_reusable:
                    tile_output_path.unlink(missing_ok=True)
                tasks.append({
                    "rowIndex": row_index,
                    "outputStart": output_start,
                    "sourceTileIndex": source_tile_index,
                    "sourceColStart": source_col_start,
                    "sourceCols": source_tile_cols,
                    "sourceBlockStart": source_block_start,
                    "sourceBlockCount": source_block_count,
                    "compileSourceCols": compile_tile_cols,
                    "compileBlockCount": compile_block_count,
                    "activationPath": act_path,
                    "weightPath": weight_path,
                    "outputPath": tile_output_path,
                    "phaseTracePath": phase_trace_path,
                    "activationSha256": sha256_file(act_path),
                    "weightSha256": sha256_file(weight_path),
                    "activationSpec": activation_spec,
                    "weightSpec": weight_spec,
                    "outputSpec": output_spec,
                    "command": command,
                    "reusedOutput": output_reusable,
                    "reuseStatus": reuse_status,
                })

    if not tasks:
        raise ValueError("prefill_q4k_gemv_tile_tasks_empty")
    total_task_count = len(tasks)
    tile_dispatch_budget = max(0, int(tile_dispatch_budget))
    budget_limited = (
        tile_dispatch_budget > 0 and total_task_count > tile_dispatch_budget
    )
    if budget_limited:
        tasks = tasks[:tile_dispatch_budget]
    pending_tasks = [task for task in tasks if not bool(task.get("reusedOutput"))]
    task_shards = _prefill_gemv_task_shards(
        pending_tasks,
        jobs=max(1, int(jobs)),
        adapter_step_budget=max(1, int(adapter_step_budget)),
    )
    for shard_index, shard_tasks in enumerate(task_shards):
        for batch_step_index, task in enumerate(shard_tasks):
            task["batchShardIndex"] = shard_index
            task["batchStepIndex"] = batch_step_index
    batch_path = launch_dir / "batch.json"
    shard_dir = launch_dir / "batch-shards"
    batch_payload = {
        "schemaVersion": 1,
        "artifactKind": "int4ple_prefill_q4k_gemv_tile_batch",
        "launchIndex": launch_index,
        "reusedOutputCount": len(tasks) - len(pending_tasks),
        "pendingStepCount": len(pending_tasks),
        "requestedJobCount": max(1, int(jobs)),
        "adapterStepBudget": max(1, int(adapter_step_budget)),
        "shardCount": len(task_shards),
        "totalTaskCountBeforeBudget": total_task_count,
        "tileDispatchBudget": tile_dispatch_budget,
        "budgetLimited": budget_limited,
        "splitD2HRows": split_d2h_rows,
        "maxOutputPeRows": PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
        "shards": [],
        "steps": [
            {
                "inputs": [task["activationSpec"], task["weightSpec"]],
                "outputs": [task["outputSpec"]],
            }
            for task in pending_tasks
        ],
    }

    shard_specs: list[dict[str, Any]] = []
    for shard_index, shard_tasks in enumerate(task_shards):
        shard_path = shard_dir / f"batch-{shard_index:04d}.json"
        shard_phase_trace_path = shard_dir / f"batch-{shard_index:04d}-phase.log"
        shard_payload = {
            "schemaVersion": 1,
            "artifactKind": "int4ple_prefill_q4k_gemv_tile_batch_shard",
            "launchIndex": launch_index,
            "shardIndex": shard_index,
            "stepCount": len(shard_tasks),
            "splitD2HRows": split_d2h_rows,
            "adapterStepBudget": max(1, int(adapter_step_budget)),
            "maxOutputPeRows": PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
            "steps": [
                {
                    "inputs": [task["activationSpec"], task["weightSpec"]],
                    "outputs": [task["outputSpec"]],
                }
                for task in shard_tasks
            ],
        }
        write_json(shard_path, shard_payload)
        command = [
            cs_python_executable(),
            str(CHAIN_STEP_ADAPTER),
            "--compile-dir",
            str(compile_dir),
            "--width",
            str(width),
            "--height",
            str(height),
            "--chunk-size",
            str(in_dim_per_pe),
            "--output",
            str(shard_tasks[0]["outputSpec"]),
            "--batch-json",
            str(shard_path),
            "--phase-trace",
            str(shard_phase_trace_path),
        ]
        if split_d2h_rows:
            command.append("--split-d2h-rows")
        if cmaddr:
            command.extend(["--cmaddr", cmaddr])
        shard_specs.append({
            "shardIndex": shard_index,
            "path": shard_path,
            "phaseTracePath": shard_phase_trace_path,
            "stepCount": len(shard_tasks),
            "command": command,
            "tasks": shard_tasks,
        })
        batch_payload["shards"].append({
            "shardIndex": shard_index,
            "path": str(shard_path),
            "phaseTracePath": str(shard_phase_trace_path),
            "stepCount": len(shard_tasks),
            "splitD2HRows": split_d2h_rows,
            "adapterStepBudget": max(1, int(adapter_step_budget)),
            "maxOutputPeRows": PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
        })
    write_json(batch_path, batch_payload)

    def run_batch_shard(shard: dict[str, Any]) -> dict[str, Any]:
        shard_timeout = (
            None
            if timeout_seconds is None or timeout_seconds <= 0
            else max(1, int(timeout_seconds))
        )
        (
            exit_code,
            stdout,
            stderr,
            timed_out,
            elapsed_ns,
        ) = _run_prefill_gemv_tile(
            command=list(shard["command"]),
            timeout_seconds=shard_timeout,
        )
        return {
            "shardIndex": int(shard["shardIndex"]),
            "batchPath": shard["path"],
            "phaseTracePath": shard["phaseTracePath"],
            "exitCode": exit_code,
            "stdout": stdout,
            "stderr": stderr,
            "timedOut": timed_out,
            "wallclockNs": elapsed_ns,
        }

    shard_results: dict[int, dict[str, Any]] = {}
    if shard_specs:
        worker_count = min(max(1, int(jobs)), len(shard_specs))
        with concurrent.futures.ThreadPoolExecutor(
            max_workers=worker_count
        ) as pool:
            for shard_result in pool.map(run_batch_shard, shard_specs):
                shard_results[int(shard_result["shardIndex"])] = shard_result
    else:
        worker_count = 0

    phase_lines_by_shard: dict[int, list[str]] = {}
    for shard_index, shard_result in shard_results.items():
        phase_trace_path = Path(str(shard_result.get("phaseTracePath") or ""))
        phase_text = str(shard_result.get("stdout") or "")
        if phase_trace_path.is_file():
            phase_text = phase_trace_path.read_text(encoding="utf-8")
        phase_lines_by_shard[shard_index] = [
            line for line in phase_text.splitlines() if line.startswith("phase:")
        ]

    def phase_tail_for_step(shard_index: int, step_index: int) -> list[str]:
        phase_lines = phase_lines_by_shard.get(shard_index, [])
        step_token = f"step={step_index}"
        return [line for line in phase_lines if step_token in line][-12:]

    results: list[dict[str, Any]] = []
    for task in tasks:
        step_index = int(task.get("batchStepIndex", -1))
        shard_index = int(task.get("batchShardIndex", -1))
        shard_result = shard_results.get(shard_index, {})
        output_record = {
            "path": str(task["outputPath"]),
            "totalBytes": (
                task["outputPath"].stat().st_size
                if task["outputPath"].is_file()
                else 0
            ),
            "sha256": (
                sha256_file(task["outputPath"])
                if task["outputPath"].is_file()
                else ""
            ),
        }
        output_ready, output_status = _prefill_gemv_tile_output_status(
            Path(str(task["outputPath"])),
            expected_elements=output_read_elements,
            expected_dtype=np.dtype(np.float16),
        )
        reused_output = bool(task.get("reusedOutput")) and output_ready
        results.append({
            **task,
            "batchShardIndex": shard_index,
            "batchStepIndex": step_index,
            "batchPath": shard_result.get("batchPath", ""),
            "batchPhaseTracePath": shard_result.get("phaseTracePath", ""),
            "exitCode": 0 if output_ready else int(shard_result.get("exitCode") or 0),
            "timedOut": False if output_ready else bool(shard_result.get("timedOut")),
            "wallclockNs": int(shard_result.get("wallclockNs") or 0),
            "output": output_record,
            "outputStatus": output_status,
            "phaseTail": (
                ["phase:verified_tile_output_reused"]
                if reused_output
                else phase_tail_for_step(shard_index, step_index)
            ),
            "stdoutTail": tail_lines(shard_result.get("stdout"), 3),
            "stderrTail": tail_lines(shard_result.get("stderr"), 3),
        })

    results.sort(
        key=lambda item: (
            int(item["rowIndex"]),
            int(item["outputStart"]),
            int(item["sourceTileIndex"]),
        )
    )
    batch_exit_code = next(
        (
            int(result.get("exitCode") or 0)
            for result in shard_results.values()
            if int(result.get("exitCode") or 0) != 0
        ),
        0,
    )
    batch_timed_out = any(
        bool(result.get("timedOut")) for result in shard_results.values()
    )
    batch_elapsed_ns = max(
        [int(result.get("wallclockNs") or 0) for result in shard_results.values()]
        or [0]
    )
    batch_wallclock_ns_sum = sum(
        int(result.get("wallclockNs") or 0) for result in shard_results.values()
    )
    batch_shards = [
        {
            "shardIndex": int(result.get("shardIndex") or 0),
            "batchPath": str(result.get("batchPath") or ""),
            "phaseTracePath": str(result.get("phaseTracePath") or ""),
            "exitCode": int(result.get("exitCode") or 0),
            "timedOut": bool(result.get("timedOut")),
            "wallclockNs": int(result.get("wallclockNs") or 0),
            "stdoutTail": tail_lines(result.get("stdout"), 3),
            "stderrTail": tail_lines(result.get("stderr"), 3),
        }
        for result in sorted(
            shard_results.values(),
            key=lambda item: int(item.get("shardIndex") or 0),
        )
    ]
    blockers: list[str] = []
    if budget_limited:
        blockers.append(
            "prefill_q4k_gemv_tile_dispatch_budget_exhausted:"
            f"{len(tasks)}<{total_task_count}"
        )
    for result in results:
        output_start = int(result["outputStart"])
        row_index = int(result["rowIndex"])
        source_tile_index = int(result["sourceTileIndex"])
        if bool(result["timedOut"]):
            blockers.append(
                "prefill_q4k_gemv_tile_timeout:"
                f"{row_index}:{output_start}:{source_tile_index}"
            )
            continue
        if int(result["exitCode"]) != 0:
            blockers.append(
                "prefill_q4k_gemv_tile_exit_code_"
                f"{int(result['exitCode'])}:{row_index}:{output_start}:"
                f"{source_tile_index}"
            )
            continue
        if str(result.get("outputStatus") or "") != "ready":
            blockers.append(
                "prefill_q4k_gemv_tile_output_invalid:"
                f"{result.get('outputStatus')}:{row_index}:{output_start}:"
                f"{source_tile_index}"
            )
            continue
        if int((result.get("output") or {}).get("totalBytes") or 0) <= 0:
            blockers.append(
                "prefill_q4k_gemv_tile_output_empty:"
                f"{row_index}:{output_start}:{source_tile_index}"
            )
            continue
        tile_values = np.load(
            Path(str((result.get("output") or {}).get("path") or "")),
            allow_pickle=False,
        ).astype(np.float32, copy=False).reshape(-1)
        tile_values = tile_values[:output_read_elements].reshape(
            height,
            output_region_width,
            out_dim_per_pe,
        ).sum(axis=1).reshape(-1)
        count = min(output_tile_cols, output_cols - output_start)
        output_matrix[row_index, output_start : output_start + count] += (
            tile_values[:count]
        )
    if blockers:
        receipt = {
            "schemaVersion": 1,
            "artifactKind": "int4ple_tiled_q4k_gemv_launch_receipt",
            "status": "blocked",
            "blockers": blockers,
            "launchIndex": launch_index,
            "targetName": launch.get("targetName"),
            "kernelPattern": launch.get("kernelPattern"),
            "dispatchMode": "tiled_q4k_gemv_device_reduce_runtime",
            "compileIdentity": compile_identity,
            "sourceTiling": {
                "sourceTileCols": PREFILL_GEMV_SOURCE_TILE_COLS,
                "sourceTileBlocks": PREFILL_GEMV_SOURCE_TILE_BLOCKS,
                "sourceTileCount": len(source_tiles),
                "tiles": source_tiles,
            },
            "batchRuntime": {
                "batchPath": str(batch_path),
                "exitCode": batch_exit_code,
                "timedOut": batch_timed_out,
                "wallclockNs": batch_elapsed_ns,
                "adapterWallclockNsSum": batch_wallclock_ns_sum,
                "requestedJobCount": max(1, int(jobs)),
                "workerCount": worker_count,
                "adapterStepBudget": max(1, int(adapter_step_budget)),
                "shardCount": len(task_shards),
                "totalTaskCountBeforeBudget": total_task_count,
                "tileDispatchBudget": tile_dispatch_budget,
                "budgetLimited": budget_limited,
                "pendingStepCount": len(pending_tasks),
                "reusedOutputCount": len(tasks) - len(pending_tasks),
                "splitD2HRows": split_d2h_rows,
                "maxOutputPeRows": PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
                "shards": batch_shards,
            },
            "tileCoverage": {
                "kind": "prefill_row_q4k_gemv_output_tiles",
                "rows": rows,
                "sourceCols": source_cols,
                "sourceTileCount": len(source_tiles),
                "sourceTileCols": PREFILL_GEMV_SOURCE_TILE_COLS,
                "outputCols": output_cols,
                "width": width,
                "height": height,
                "outputRegionX": output_region_x,
                "outputRegionWidth": output_region_width,
                "inDimPerPe": in_dim_per_pe,
                "outDimPerPe": out_dim_per_pe,
                "blocksPerPe": blocks_per_pe,
                "outputTileCols": output_tile_cols,
                "outputReadElements": output_read_elements,
                "outputReadDtype": "f16",
                "hostReduce": False,
                "splitD2HRows": split_d2h_rows,
                "maxOutputPeRows": PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
                "d2hElementCountLimit": SDK_D2H_ELEMENT_COUNT_LIMIT,
                "tileCount": len(results),
                "totalTaskCountBeforeBudget": total_task_count,
                "tileDispatchBudget": tile_dispatch_budget,
                "budgetLimited": budget_limited,
                "batchStepCount": len(tasks),
                "pendingBatchStepCount": len(pending_tasks),
                "reusedOutputCount": len(tasks) - len(pending_tasks),
                "covered": False,
            },
            "tileDispatches": [
                _prefill_gemv_tile_receipt_summary(result)
                for result in results
            ],
        }
        write_json(_launch_receipt_path(runtime_dir, launch_index), receipt)
        raise ValueError("; ".join(blockers))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_values = output_matrix.astype(np.float16)
    np.save(output_path, output_values.reshape(-1))
    digest = hashlib.sha256(output_values.tobytes(order="C")).hexdigest()
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "int4ple_tiled_q4k_gemv_launch_receipt",
        "status": "succeeded",
        "blockers": [],
        "launchIndex": launch_index,
        "targetName": launch.get("targetName"),
        "kernelPattern": launch.get("kernelPattern"),
            "dispatchMode": "tiled_q4k_gemv_device_reduce_runtime",
        "compileIdentity": compile_identity,
        "sourceTiling": {
            "sourceTileCols": PREFILL_GEMV_SOURCE_TILE_COLS,
            "sourceTileBlocks": PREFILL_GEMV_SOURCE_TILE_BLOCKS,
            "sourceTileCount": len(source_tiles),
            "tiles": source_tiles,
        },
        "batchRuntime": {
            "batchPath": str(batch_path),
            "exitCode": batch_exit_code,
            "timedOut": batch_timed_out,
            "wallclockNs": batch_elapsed_ns,
            "adapterWallclockNsSum": batch_wallclock_ns_sum,
                "requestedJobCount": max(1, int(jobs)),
                "workerCount": worker_count,
                "adapterStepBudget": max(1, int(adapter_step_budget)),
                "shardCount": len(task_shards),
            "totalTaskCountBeforeBudget": total_task_count,
            "tileDispatchBudget": tile_dispatch_budget,
            "budgetLimited": budget_limited,
            "pendingStepCount": len(pending_tasks),
            "reusedOutputCount": len(tasks) - len(pending_tasks),
            "splitD2HRows": split_d2h_rows,
            "maxOutputPeRows": PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
            "shards": batch_shards,
        },
        "inputBuffers": [
            {
                "name": a_buffer,
                "symbol": "a",
                "role": "activation",
                "path": str(activation_path),
                "dtype": "f16",
                "sha256": sha256_file(activation_path),
                "sha256Kind": "npy_file_bytes",
            },
            {
                "name": str(b_binding.get("buffer") or ""),
                "symbol": "b",
                "role": "weight",
                "dtype": "u8_q4k",
                "weightKey": (
                    (b_materialization.get("weightMapping") or {}).get("weightKey")
                ),
                "weightSha256": (
                    (b_materialization.get("weightMapping") or {}).get("sha256")
                ),
            },
        ],
        "tileCoverage": {
            "kind": "prefill_row_q4k_gemv_output_tiles",
            "rows": rows,
            "sourceCols": source_cols,
            "sourceTileCount": len(source_tiles),
            "sourceTileCols": PREFILL_GEMV_SOURCE_TILE_COLS,
            "outputCols": output_cols,
            "width": width,
            "height": height,
            "outputRegionX": output_region_x,
            "outputRegionWidth": output_region_width,
            "inDimPerPe": in_dim_per_pe,
            "outDimPerPe": out_dim_per_pe,
            "blocksPerPe": blocks_per_pe,
            "outputTileCols": output_tile_cols,
            "outputReadElements": output_read_elements,
            "outputReadDtype": "f16",
            "hostReduce": False,
            "splitD2HRows": split_d2h_rows,
            "maxOutputPeRows": PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
            "d2hElementCountLimit": SDK_D2H_ELEMENT_COUNT_LIMIT,
            "tileCount": len(results),
            "totalTaskCountBeforeBudget": total_task_count,
            "tileDispatchBudget": tile_dispatch_budget,
            "budgetLimited": budget_limited,
            "batchStepCount": len(tasks),
            "totalTaskCountBeforeBudget": total_task_count,
            "tileDispatchBudget": tile_dispatch_budget,
            "budgetLimited": budget_limited,
            "pendingBatchStepCount": len(pending_tasks),
            "reusedOutputCount": len(tasks) - len(pending_tasks),
            "covered": len(results)
            == rows * _ceil_div(output_cols, output_tile_cols) * len(source_tiles),
        },
        "tileDispatches": [
            _prefill_gemv_tile_receipt_summary(result)
            for result in results
        ],
        "output": {
            "buffer": c_buffer,
            "path": str(output_path),
            "dtype": "f16",
            "shape": [rows, output_cols],
            "sha256": digest,
            "sha256Kind": "array_tobytes_c_order",
        },
    }
    write_json(_launch_receipt_path(runtime_dir, launch_index), receipt)
    append_progress(
        progress_path,
        "prefill_q4k_gemv_group_complete",
        launchIndex=launch_index,
        target=launch.get("targetName"),
        rows=rows,
        outputCols=output_cols,
        tileCount=len(results),
    )
    return receipt


def _prefill_gemv_tile_receipt_summary(result: dict[str, Any]) -> dict[str, Any]:
    return {
        "rowIndex": int(result.get("rowIndex") or 0),
        "outputStart": int(result.get("outputStart") or 0),
        "sourceTileIndex": int(result.get("sourceTileIndex") or 0),
        "sourceColStart": int(result.get("sourceColStart") or 0),
        "sourceCols": int(result.get("sourceCols") or 0),
        "sourceBlockStart": int(result.get("sourceBlockStart") or 0),
        "sourceBlockCount": int(result.get("sourceBlockCount") or 0),
        "compileSourceCols": int(result.get("compileSourceCols") or 0),
        "compileBlockCount": int(result.get("compileBlockCount") or 0),
        "activation": {
            "path": str(result.get("activationPath") or ""),
            "sha256": str(result.get("activationSha256") or ""),
        },
        "weight": {
            "path": str(result.get("weightPath") or ""),
            "sha256": str(result.get("weightSha256") or ""),
        },
        "output": result.get("output") or {},
        "outputStatus": str(result.get("outputStatus") or ""),
        "reusedOutput": bool(result.get("reusedOutput")),
        "reuseStatus": str(result.get("reuseStatus") or ""),
        "batchShardIndex": int(result.get("batchShardIndex", -1)),
        "batchStepIndex": int(result.get("batchStepIndex") or 0),
        "batchPath": str(result.get("batchPath") or ""),
        "batchPhaseTracePath": str(result.get("batchPhaseTracePath") or ""),
        "exitCode": int(result.get("exitCode") or 0),
        "timedOut": bool(result.get("timedOut")),
        "wallclockNs": int(result.get("wallclockNs") or 0),
        "phaseTail": result.get("phaseTail") or [],
        "stdoutTail": result.get("stdoutTail") or [],
        "stderrTail": result.get("stderrTail") or [],
    }
