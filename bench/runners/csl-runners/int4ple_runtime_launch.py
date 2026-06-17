"""HostPlan runtime launch loop for INT4 PLE compile targets."""

from __future__ import annotations

import concurrent.futures
import subprocess
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from int4ple_checkpoint import (
    compute_launch_identity as _compute_launch_identity,
    persist_launch_checkpoint as _persist_launch_checkpoint,
)
from int4ple_compile_target_core import (
    DEFAULT_LAUNCH_TIMEOUT_SECONDS,
    DEFAULT_PREFILL_Q4K_GEMV_ADAPTER_STEP_BUDGET,
    DEFAULT_PREFILL_Q4K_GEMV_OUTPUT_PE_ROWS,
    DEFAULT_SESSION_LM_HEAD_BATCH_STEP_BUDGET,
    DEFAULT_SESSION_LM_HEAD_TILE_JOBS,
    DEFAULT_SESSION_LM_HEAD_TILE_WIDTH,
    EMBED_ROI_TARGETS,
    LAUNCH_STEP_ADAPTER,
    append_progress,
    cs_python_executable,
    load_json,
    tail_lines,
    write_json,
)
from int4ple_compile_target_materialization import (
    _buffer_path,
    _launch_receipt_path,
    _launch_spec_path,
    _staged_input_buffer_records,
)
from int4ple_compile_target_predicates import (
    _is_compact_attention_prefill_launch,
    _is_compact_ple_proj_launch,
    _is_session_tiled_lm_head_launch,
    _is_tiled_q4k_gemv_launch,
)
from int4ple_roi_session_runtime import (
    _is_compact_gated_prefill_launch,
    _is_residual_prefill_roi_launch,
    _is_rmsnorm_roi_launch,
)

LaunchReceiptHook = Callable[..., dict[str, Any]]
StageLaunchArraysHook = Callable[
    ...,
    tuple[list[dict[str, Any]], list[dict[str, Any]]],
]


@dataclass(frozen=True)
class HostPlanRuntimeLaunchHooks:
    """Execution hooks supplied by the front-door runner module."""

    execute_embed_roi_launch: LaunchReceiptHook
    stage_launch_arrays: StageLaunchArraysHook
    execute_tiled_q4k_gemv_launch: LaunchReceiptHook
    execute_compact_ple_proj_launch: LaunchReceiptHook
    execute_compact_attention_prefill_launch: LaunchReceiptHook
    execute_rmsnorm_roi_launch: LaunchReceiptHook
    execute_residual_prefill_roi_launch: LaunchReceiptHook
    execute_compact_gated_prefill_launch: LaunchReceiptHook
    execute_dense_gemv_tiled_session_launch: LaunchReceiptHook


def _is_embed_roi_launch(launch: dict[str, Any]) -> bool:
    if str(launch.get("targetName") or "") not in EMBED_ROI_TARGETS:
        return False
    params = launch.get("compileParams") or {}
    return all(
        int(params.get(key) or 0) > 0
        for key in ("rows_per_pe", "hidden_size", "hidden_per_pe", "tokens_per_chunk")
    )


def _launch_input_buffers(launch: dict[str, Any]) -> set[str]:
    buffers: set[str] = set()
    for binding in launch.get("inputBindings") or []:
        if isinstance(binding, dict) and binding.get("buffer"):
            buffers.add(str(binding["buffer"]))
    return buffers


def _launch_output_buffers(launch: dict[str, Any]) -> set[str]:
    buffers: set[str] = set()
    for key in ("resolvedOutputs", "outputBindings"):
        for binding in launch.get(key) or []:
            if isinstance(binding, dict) and binding.get("buffer"):
                buffers.add(str(binding["buffer"]))
    return buffers


def _embed_roi_launch_is_independent(launch: dict[str, Any]) -> bool:
    if not _is_embed_roi_launch(launch):
        return False
    for binding in launch.get("inputBindings") or []:
        if not isinstance(binding, dict):
            return False
        role = str(binding.get("role") or "")
        buffer = str(binding.get("buffer") or "")
        if role in {"tokenized_prompt", "weight"}:
            continue
        if buffer.startswith("input:") or buffer.startswith("weight:"):
            continue
        return False
    return bool(_launch_output_buffers(launch))


def _collect_parallel_embed_roi_group(
    launches: list[Any],
    start_position: int,
    *,
    stop_after_launch: int,
    max_jobs: int,
) -> list[dict[str, Any]]:
    if max_jobs <= 1:
        return []
    group: list[dict[str, Any]] = []
    produced_buffers: set[str] = set()
    for candidate in launches[start_position:]:
        if not isinstance(candidate, dict):
            break
        launch_index = int(candidate.get("launchIndex") or 0)
        if stop_after_launch >= 0 and launch_index > stop_after_launch:
            break
        if not _embed_roi_launch_is_independent(candidate):
            break
        if produced_buffers & _launch_input_buffers(candidate):
            break
        outputs = _launch_output_buffers(candidate)
        if produced_buffers & outputs:
            break
        group.append(candidate)
        produced_buffers.update(outputs)
        if len(group) >= max_jobs:
            break
    return group if len(group) > 1 else []


def _execute_embed_roi_launch_group(
    *,
    runtime_dir: Path,
    group: list[dict[str, Any]],
    buffer_files: dict[str, Path],
    export: dict[str, Any],
    progress_path: Path,
    cmaddr: str | None,
    jobs: int,
    timeout_seconds: int | None,
    execute_embed_roi_launch: LaunchReceiptHook,
    hidden_per_pe_override: int = 0,
) -> list[dict[str, Any]]:
    def run_one(launch: dict[str, Any]) -> dict[str, Any]:
        local_buffer_files = dict(buffer_files)
        started_at_unix = time.time()
        receipt = execute_embed_roi_launch(
            runtime_dir=runtime_dir,
            launch=launch,
            buffer_files=local_buffer_files,
            export=export,
            progress_path=progress_path,
            cmaddr=cmaddr,
            timeout_seconds=timeout_seconds,
            hidden_per_pe_override=hidden_per_pe_override,
        )
        output = receipt.get("output") or {}
        output_buffer = str(output.get("buffer") or "")
        output_path = Path(str(output.get("path") or ""))
        if not output_buffer or not output_path.is_file():
            raise ValueError("embed_roi_parallel_output_missing")
        return {
            "launch": launch,
            "receipt": receipt,
            "startedAtUnix": started_at_unix,
            "output": {
                "buffer": output_buffer,
                "path": str(output_path),
                "dtype": output.get("dtype", "unknown"),
                "shape": output.get("shape", []),
            },
        }

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        return list(pool.map(run_one, group))


def execute_hostplan_runtime(
    *,
    bootstrap: dict[str, Any],
    export: dict[str, Any],
    progress_path: Path,
    cmaddr: str | None,
    trace_path: Path,
    hooks: HostPlanRuntimeLaunchHooks,
    checkpoint_dir: Path | None = None,
    resume_state: Any = None,
    initial_buffer_files: dict[str, Path] | None = None,
    stop_after_launch: int = -1,
    launch_timeout_seconds: int | None = DEFAULT_LAUNCH_TIMEOUT_SECONDS,
    session_lm_head_dispatch_mode: str = "monolithic",
    session_lm_head_tile_width: int = DEFAULT_SESSION_LM_HEAD_TILE_WIDTH,
    session_lm_head_tile_jobs: int = DEFAULT_SESSION_LM_HEAD_TILE_JOBS,
    session_embed_roi_jobs: int = 1,
    session_embed_roi_hidden_per_pe: int = 0,
    session_prefill_q4k_gemv_jobs: int = 1,
    session_prefill_q4k_gemv_output_pe_rows: int = (
        DEFAULT_PREFILL_Q4K_GEMV_OUTPUT_PE_ROWS
    ),
    session_prefill_q4k_gemv_adapter_step_budget: int = (
        DEFAULT_PREFILL_Q4K_GEMV_ADAPTER_STEP_BUDGET
    ),
    session_prefill_q4k_gemv_tile_dispatch_budget: int = 0,
    session_ple_proj_dispatch_mode: str = "monolithic_summa",
    session_attention_prefill_dispatch_mode: str = "hostplan_static",
    session_lm_head_batch_runtime: bool = False,
    session_lm_head_batch_runtime_step_budget: int = DEFAULT_SESSION_LM_HEAD_BATCH_STEP_BUDGET,
    session_lm_head_tile_dispatch_budget: int = 0,
) -> dict[str, Any]:
    runtime_dir = trace_path.parent / "hostplan-runtime"
    runtime_dir.mkdir(parents=True, exist_ok=True)
    launches = bootstrap.get("launches") or []
    blockers: list[str] = []
    buffer_files: dict[str, Path] = dict(initial_buffer_files or {})
    executed_launches: list[dict[str, Any]] = []
    executed_count = 0
    start_index = 0
    if resume_state is not None:
        buffer_files.update(resume_state.buffer_files)
        start_index = int(resume_state.start_index)
        append_progress(
            progress_path,
            "hostplan_resume_loaded",
            startIndex=start_index,
            bufferCount=len(buffer_files),
        )
    elif initial_buffer_files:
        append_progress(
            progress_path,
            "hostplan_initial_buffers_loaded",
            bufferCount=len(initial_buffer_files),
        )
    stopped_at_checkpoint = False
    parallel_embed_roi_done: set[int] = set()
    for launch_position, launch in enumerate(launches):
        if not isinstance(launch, dict):
            blockers.append("launch_not_object")
            break
        launch_index = int(launch.get("launchIndex") or executed_count)
        if launch_index in parallel_embed_roi_done:
            continue
        if launch_index < start_index:
            append_progress(
                progress_path,
                "hostplan_launch_skipped_resume",
                launchIndex=launch_index,
                target=launch.get("targetName"),
            )
            executed_count += 1
            continue
        launch_started_at = time.time()
        append_progress(
            progress_path,
            "hostplan_launch_start",
            launchIndex=launch_index,
            target=launch.get("targetName"),
        )
        try:
            if _is_embed_roi_launch(launch):
                parallel_group = _collect_parallel_embed_roi_group(
                    launches,
                    launch_position,
                    stop_after_launch=stop_after_launch,
                    max_jobs=max(1, int(session_embed_roi_jobs)),
                )
                if parallel_group:
                    group_indices = [
                        int(item.get("launchIndex") or 0)
                        for item in parallel_group
                    ]
                    append_progress(
                        progress_path,
                        "hostplan_embed_roi_parallel_group_start",
                        launchIndices=group_indices,
                        jobs=max(1, int(session_embed_roi_jobs)),
                    )
                    for peer in parallel_group[1:]:
                        append_progress(
                            progress_path,
                            "hostplan_launch_start",
                            launchIndex=int(peer.get("launchIndex") or 0),
                            target=peer.get("targetName"),
                        )
                    group_results = _execute_embed_roi_launch_group(
                        runtime_dir=runtime_dir,
                        group=parallel_group,
                        buffer_files=buffer_files,
                        export=export,
                        progress_path=progress_path,
                        cmaddr=cmaddr,
                        jobs=max(1, int(session_embed_roi_jobs)),
                        timeout_seconds=launch_timeout_seconds,
                        execute_embed_roi_launch=hooks.execute_embed_roi_launch,
                        hidden_per_pe_override=max(
                            0,
                            int(session_embed_roi_hidden_per_pe),
                        ),
                    )
                    for result in group_results:
                        peer_launch = result["launch"]
                        peer_index = int(peer_launch.get("launchIndex") or 0)
                        launch_receipt = result["receipt"]
                        executed_launches.append(launch_receipt)
                        output = result["output"]
                        buffer_files[str(output["buffer"])] = Path(
                            str(output["path"])
                        )
                        executed_count += 1
                        append_progress(
                            progress_path,
                            "hostplan_launch_complete",
                            launchIndex=peer_index,
                            target=peer_launch.get("targetName"),
                            status="succeeded",
                            dispatchMode="embed_roi_parallel_group",
                        )
                        if checkpoint_dir is not None:
                            _persist_launch_checkpoint(
                                checkpoint_dir=checkpoint_dir,
                                launch_index=peer_index,
                                launch=peer_launch,
                                launch_receipt=launch_receipt,
                                staged_outputs=[output],
                                launch_identity=_compute_launch_identity(
                                    peer_launch,
                                    {},
                                ),
                                started_at_unix=float(result["startedAtUnix"]),
                            )
                    parallel_embed_roi_done.update(group_indices[1:])
                    append_progress(
                        progress_path,
                        "hostplan_embed_roi_parallel_group_complete",
                        launchIndices=group_indices,
                    )
                    if stop_after_launch >= 0 and group_indices[-1] >= stop_after_launch:
                        stopped_at_checkpoint = True
                        break
                    continue
                buffer_keys_before = set(buffer_files.keys())
                launch_receipt = hooks.execute_embed_roi_launch(
                    runtime_dir=runtime_dir,
                    launch=launch,
                    buffer_files=buffer_files,
                    export=export,
                    progress_path=progress_path,
                    cmaddr=cmaddr,
                    timeout_seconds=launch_timeout_seconds,
                    hidden_per_pe_override=max(
                        0,
                        int(session_embed_roi_hidden_per_pe),
                    ),
                )
                executed_launches.append(launch_receipt)
                executed_count += 1
                append_progress(
                    progress_path,
                    "hostplan_launch_complete",
                    launchIndex=launch_index,
                    target=launch.get("targetName"),
                    status="succeeded",
                )
                if checkpoint_dir is not None:
                    new_keys = sorted(set(buffer_files.keys()) - buffer_keys_before)
                    embed_outputs = [
                        {
                            "buffer": key,
                            "path": str(buffer_files[key]),
                            "dtype": "unknown",
                            "shape": [],
                        }
                        for key in new_keys
                    ]
                    _persist_launch_checkpoint(
                        checkpoint_dir=checkpoint_dir,
                        launch_index=launch_index,
                        launch=launch,
                        launch_receipt=launch_receipt,
                        staged_outputs=embed_outputs,
                        launch_identity=_compute_launch_identity(launch, {}),
                        started_at_unix=launch_started_at,
                    )
                if stop_after_launch >= 0 and launch_index >= stop_after_launch:
                    stopped_at_checkpoint = True
                    break
                continue
            if _is_tiled_q4k_gemv_launch(
                launch,
                session_ple_proj_dispatch_mode,
            ):
                launch_receipt = hooks.execute_tiled_q4k_gemv_launch(
                    runtime_dir=runtime_dir,
                    launch=launch,
                    buffer_files=buffer_files,
                    progress_path=progress_path,
                    cmaddr=cmaddr,
                    timeout_seconds=launch_timeout_seconds,
                    jobs=max(1, int(session_prefill_q4k_gemv_jobs)),
                    output_pe_rows=max(
                        1,
                        int(session_prefill_q4k_gemv_output_pe_rows),
                    ),
                    adapter_step_budget=max(
                        1,
                        int(session_prefill_q4k_gemv_adapter_step_budget),
                    ),
                    tile_dispatch_budget=max(
                        0,
                        int(session_prefill_q4k_gemv_tile_dispatch_budget),
                    ),
                )
                executed_launches.append(launch_receipt)
                output = launch_receipt.get("output") or {}
                if output.get("buffer") and output.get("path"):
                    buffer_files[str(output["buffer"])] = Path(str(output["path"]))
                executed_count += 1
                append_progress(
                    progress_path,
                    "hostplan_launch_complete",
                    launchIndex=launch_index,
                    target=launch.get("targetName"),
                    status="succeeded",
                    dispatchMode="tiled_q4k_gemv_device_reduce_runtime",
                )
                if checkpoint_dir is not None:
                    _persist_launch_checkpoint(
                        checkpoint_dir=checkpoint_dir,
                        launch_index=launch_index,
                        launch=launch,
                        launch_receipt=launch_receipt,
                        staged_outputs=[output] if output else [],
                        launch_identity=_compute_launch_identity(launch, {}),
                        started_at_unix=launch_started_at,
                    )
                if stop_after_launch >= 0 and launch_index >= stop_after_launch:
                    stopped_at_checkpoint = True
                    break
                continue
            if _is_compact_ple_proj_launch(
                launch,
                session_ple_proj_dispatch_mode,
            ):
                buffer_keys_before = set(buffer_files.keys())
                launch_receipt = hooks.execute_compact_ple_proj_launch(
                    runtime_dir=runtime_dir,
                    launch=launch,
                    buffer_files=buffer_files,
                    progress_path=progress_path,
                    cmaddr=cmaddr,
                    timeout_seconds=launch_timeout_seconds,
                )
                executed_launches.append(launch_receipt)
                for output in launch.get("resolvedOutputs") or []:
                    if isinstance(output, dict) and output.get("buffer"):
                        buffer_files[str(output["buffer"])] = _buffer_path(
                            runtime_dir,
                            str(output["buffer"]),
                        )
                executed_count += 1
                append_progress(
                    progress_path,
                    "hostplan_launch_complete",
                    launchIndex=launch_index,
                    target=launch.get("targetName"),
                    status="succeeded",
                    dispatchMode="compact_summa_session",
                )
                if checkpoint_dir is not None:
                    new_outputs = [
                        {
                            "buffer": key,
                            "path": str(buffer_files[key]),
                            "dtype": "unknown",
                            "shape": [],
                        }
                        for key in sorted(set(buffer_files.keys()) - buffer_keys_before)
                    ]
                    _persist_launch_checkpoint(
                        checkpoint_dir=checkpoint_dir,
                        launch_index=launch_index,
                        launch=launch,
                        launch_receipt=launch_receipt,
                        staged_outputs=new_outputs,
                        launch_identity=_compute_launch_identity(launch, {}),
                        started_at_unix=launch_started_at,
                    )
                if stop_after_launch >= 0 and launch_index >= stop_after_launch:
                    stopped_at_checkpoint = True
                    break
                continue
            if _is_compact_attention_prefill_launch(
                launch,
                session_attention_prefill_dispatch_mode,
            ):
                buffer_keys_before = set(buffer_files.keys())
                launch_receipt = hooks.execute_compact_attention_prefill_launch(
                    runtime_dir=runtime_dir,
                    launch=launch,
                    buffer_files=buffer_files,
                    progress_path=progress_path,
                    cmaddr=cmaddr,
                    timeout_seconds=launch_timeout_seconds,
                )
                executed_launches.append(launch_receipt)
                for output in launch.get("resolvedOutputs") or []:
                    if isinstance(output, dict) and output.get("buffer"):
                        buffer_files[str(output["buffer"])] = _buffer_path(
                            runtime_dir,
                            str(output["buffer"]),
                        )
                executed_count += 1
                append_progress(
                    progress_path,
                    "hostplan_launch_complete",
                    launchIndex=launch_index,
                    target=launch.get("targetName"),
                    status="succeeded",
                    dispatchMode="compact_width_session",
                )
                if checkpoint_dir is not None:
                    new_outputs = [
                        {
                            "buffer": key,
                            "path": str(buffer_files[key]),
                            "dtype": "unknown",
                            "shape": [],
                        }
                        for key in sorted(set(buffer_files.keys()) - buffer_keys_before)
                    ]
                    _persist_launch_checkpoint(
                        checkpoint_dir=checkpoint_dir,
                        launch_index=launch_index,
                        launch=launch,
                        launch_receipt=launch_receipt,
                        staged_outputs=new_outputs,
                        launch_identity=_compute_launch_identity(launch, {}),
                        started_at_unix=launch_started_at,
                    )
                if stop_after_launch >= 0 and launch_index >= stop_after_launch:
                    stopped_at_checkpoint = True
                    break
                continue
            staged_inputs, staged_outputs = hooks.stage_launch_arrays(
                runtime_dir=runtime_dir,
                launch=launch,
                buffer_files=buffer_files,
                export=export,
            )
            if _is_rmsnorm_roi_launch(launch):
                launch_receipt = hooks.execute_rmsnorm_roi_launch(
                    runtime_dir=runtime_dir,
                    launch=launch,
                    staged_inputs=staged_inputs,
                    staged_outputs=staged_outputs,
                    progress_path=progress_path,
                    cmaddr=cmaddr,
                    timeout_seconds=launch_timeout_seconds,
                    jobs=max(1, int(session_embed_roi_jobs)),
                )
                executed_launches.append(launch_receipt)
                for output in staged_outputs:
                    buffer_files[str(output["buffer"])] = Path(str(output["path"]))
                executed_count += 1
                append_progress(
                    progress_path,
                    "hostplan_launch_complete",
                    launchIndex=launch_index,
                    target=launch.get("targetName"),
                    status="succeeded",
                    dispatchMode="rmsnorm_roi_parallel",
                )
                if checkpoint_dir is not None:
                    _persist_launch_checkpoint(
                        checkpoint_dir=checkpoint_dir,
                        launch_index=launch_index,
                        launch=launch,
                        launch_receipt=launch_receipt,
                        staged_outputs=staged_outputs,
                        launch_identity=_compute_launch_identity(launch, {}),
                        started_at_unix=launch_started_at,
                    )
                if stop_after_launch >= 0 and launch_index >= stop_after_launch:
                    stopped_at_checkpoint = True
                    break
                continue
            if _is_residual_prefill_roi_launch(launch, staged_outputs):
                launch_receipt = hooks.execute_residual_prefill_roi_launch(
                    runtime_dir=runtime_dir,
                    launch=launch,
                    staged_inputs=staged_inputs,
                    staged_outputs=staged_outputs,
                    progress_path=progress_path,
                    cmaddr=cmaddr,
                    timeout_seconds=launch_timeout_seconds,
                )
                executed_launches.append(launch_receipt)
                for output in staged_outputs:
                    buffer_files[str(output["buffer"])] = Path(str(output["path"]))
                executed_count += 1
                append_progress(
                    progress_path,
                    "hostplan_launch_complete",
                    launchIndex=launch_index,
                    target=launch.get("targetName"),
                    status="succeeded",
                    dispatchMode="residual_prefill_roi_session",
                )
                if checkpoint_dir is not None:
                    _persist_launch_checkpoint(
                        checkpoint_dir=checkpoint_dir,
                        launch_index=launch_index,
                        launch=launch,
                        launch_receipt=launch_receipt,
                        staged_outputs=staged_outputs,
                        launch_identity=_compute_launch_identity(launch, {}),
                        started_at_unix=launch_started_at,
                    )
                if stop_after_launch >= 0 and launch_index >= stop_after_launch:
                    stopped_at_checkpoint = True
                    break
                continue
            if _is_compact_gated_prefill_launch(launch, staged_outputs):
                launch_receipt = hooks.execute_compact_gated_prefill_launch(
                    runtime_dir=runtime_dir,
                    launch=launch,
                    staged_inputs=staged_inputs,
                    staged_outputs=staged_outputs,
                    progress_path=progress_path,
                    cmaddr=cmaddr,
                    timeout_seconds=launch_timeout_seconds,
                )
                executed_launches.append(launch_receipt)
                for output in staged_outputs:
                    buffer_files[str(output["buffer"])] = Path(str(output["path"]))
                executed_count += 1
                append_progress(
                    progress_path,
                    "hostplan_launch_complete",
                    launchIndex=launch_index,
                    target=launch.get("targetName"),
                    status="succeeded",
                    dispatchMode="compact_gated_prefill_session",
                )
                if checkpoint_dir is not None:
                    _persist_launch_checkpoint(
                        checkpoint_dir=checkpoint_dir,
                        launch_index=launch_index,
                        launch=launch,
                        launch_receipt=launch_receipt,
                        staged_outputs=staged_outputs,
                        launch_identity=_compute_launch_identity(launch, {}),
                        started_at_unix=launch_started_at,
                    )
                if stop_after_launch >= 0 and launch_index >= stop_after_launch:
                    stopped_at_checkpoint = True
                    break
                continue
            if _is_session_tiled_lm_head_launch(
                launch,
                session_lm_head_dispatch_mode,
            ):
                buffer_keys_before = set(buffer_files.keys())
                launch_receipt = hooks.execute_dense_gemv_tiled_session_launch(
                    runtime_dir=runtime_dir,
                    launch=launch,
                    staged_inputs=staged_inputs,
                    staged_outputs=staged_outputs,
                    buffer_files=buffer_files,
                    progress_path=progress_path,
                    cmaddr=cmaddr,
                    timeout_seconds=(
                        launch_timeout_seconds
                        if launch_timeout_seconds is not None
                        and launch_timeout_seconds > 0
                        else DEFAULT_LAUNCH_TIMEOUT_SECONDS
                    ),
                    hidden_tile_width=session_lm_head_tile_width,
                    tile_jobs=session_lm_head_tile_jobs,
                    batch_runtime=session_lm_head_batch_runtime,
                    batch_runtime_step_budget=(
                        session_lm_head_batch_runtime_step_budget
                    ),
                    tile_dispatch_budget=session_lm_head_tile_dispatch_budget,
                )
                write_json(
                    _launch_receipt_path(runtime_dir, launch_index),
                    launch_receipt,
                )
                executed_launches.append(launch_receipt)
                if launch_receipt.get("status") != "succeeded":
                    raise ValueError(
                        "; ".join(
                            launch_receipt.get("blockers")
                            or ["session_lm_head_tiled_failed"]
                        )
                    )
                for output in staged_outputs:
                    buffer_files[str(output["buffer"])] = Path(str(output["path"]))
                executed_count += 1
                append_progress(
                    progress_path,
                    "hostplan_launch_complete",
                    launchIndex=launch_index,
                    target=launch.get("targetName"),
                    status="succeeded",
                    dispatchMode="dense_gemv_width_tiled_session",
                )
                if checkpoint_dir is not None:
                    new_outputs = [
                        {
                            "buffer": key,
                            "path": str(buffer_files[key]),
                            "dtype": "unknown",
                            "shape": [],
                        }
                        for key in sorted(set(buffer_files.keys()) - buffer_keys_before)
                    ]
                    _persist_launch_checkpoint(
                        checkpoint_dir=checkpoint_dir,
                        launch_index=launch_index,
                        launch=launch,
                        launch_receipt=launch_receipt,
                        staged_outputs=new_outputs,
                        launch_identity=_compute_launch_identity(launch, {}),
                        started_at_unix=launch_started_at,
                    )
                if stop_after_launch >= 0 and launch_index >= stop_after_launch:
                    stopped_at_checkpoint = True
                    break
                continue
            receipt_path = _launch_receipt_path(runtime_dir, launch_index)
            spec_path = _launch_spec_path(runtime_dir, launch_index)
            launch_spec = {
                "compileDir": launch.get("compileDir"),
                "launchFunction": launch.get("launchFunction"),
                "launchIndex": launch_index,
                "cmaddr": cmaddr or "",
                "targetGeometry": launch.get("targetGeometry") or {},
                "inputs": staged_inputs,
                "outputs": staged_outputs,
            }
            write_json(spec_path, launch_spec)
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
            timeout = (
                launch_timeout_seconds
                if launch_timeout_seconds is not None and launch_timeout_seconds > 0
                else None
            )
            try:
                completed = subprocess.run(
                    command,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                )
            except subprocess.TimeoutExpired as exc:
                timeout_receipt = {
                    "schemaVersion": 1,
                    "artifactKind": "int4ple_launch_step_receipt",
                    "status": "blocked",
                    "blockers": ["launch_step_timeout"],
                    "launchIndex": launch_index,
                    "targetName": launch.get("targetName"),
                    "inputBuffers": _staged_input_buffer_records(staged_inputs),
                    "timeoutSeconds": timeout,
                    "stdoutTail": tail_lines(exc.stdout, 1),
                    "stderrTail": tail_lines(exc.stderr, 1),
                }
                write_json(receipt_path, timeout_receipt)
                executed_launches.append(timeout_receipt)
                append_progress(
                    progress_path,
                    "hostplan_launch_timeout",
                    launchIndex=launch_index,
                    target=launch.get("targetName"),
                    timeoutSeconds=timeout,
                )
                raise ValueError("launch_step_timeout") from exc
            if not receipt_path.is_file():
                raise ValueError("launch_receipt_missing")
            launch_receipt = load_json(receipt_path)
            if not isinstance(launch_receipt.get("inputBuffers"), list):
                launch_receipt["inputBuffers"] = _staged_input_buffer_records(
                    staged_inputs
                )
            launch_receipt["stdoutTail"] = tail_lines(completed.stdout, 1)
            launch_receipt["stderrTail"] = tail_lines(completed.stderr, 1)
            write_json(receipt_path, launch_receipt)
            executed_launches.append(launch_receipt)
            if completed.returncode != 0 or launch_receipt.get("status") != "succeeded":
                raise ValueError(
                    "; ".join(launch_receipt.get("blockers") or ["launch_failed"])
                )
            for output in staged_outputs:
                buffer_files[str(output["buffer"])] = Path(str(output["path"]))
            executed_count += 1
            append_progress(
                progress_path,
                "hostplan_launch_complete",
                launchIndex=launch_index,
                target=launch.get("targetName"),
                status="succeeded",
            )
            if checkpoint_dir is not None:
                _persist_launch_checkpoint(
                    checkpoint_dir=checkpoint_dir,
                    launch_index=launch_index,
                    launch=launch,
                    launch_receipt=launch_receipt,
                    staged_outputs=staged_outputs,
                    launch_identity=_compute_launch_identity(launch, {}),
                    started_at_unix=launch_started_at,
                )
            if stop_after_launch >= 0 and launch_index >= stop_after_launch:
                stopped_at_checkpoint = True
                break
        except Exception as exc:
            blocker_detail = (
                "launch_step_timeout"
                if isinstance(exc, subprocess.TimeoutExpired)
                or "timed out after" in str(exc)
                else str(exc)
            )
            blockers.append(f"launch[{launch_index}]_blocked:{blocker_detail}")
            append_progress(
                progress_path,
                "hostplan_launch_blocked",
                launchIndex=launch_index,
                target=launch.get("targetName"),
                error=blocker_detail,
            )
            break
    if blockers:
        status = "blocked"
    elif stopped_at_checkpoint:
        status = "stopped_at_checkpoint"
    else:
        status = "succeeded"
    return {
        "schemaVersion": 1,
        "artifactKind": "int4ple_hostplan_executor_runtime",
        "status": status,
        "blockers": blockers,
        "executedLaunchCount": executed_count,
        "launchCount": len(launches),
        "bufferDir": str(runtime_dir / "buffers"),
        "launches": executed_launches,
        "targetSessions": bootstrap.get("targetSessions") or [],
        "stoppedAtCheckpoint": stopped_at_checkpoint,
        "launchTimeoutSeconds": launch_timeout_seconds,
        "sessionLmHeadDispatch": {
            "mode": session_lm_head_dispatch_mode,
            "tileWidth": session_lm_head_tile_width,
            "tileJobs": session_lm_head_tile_jobs,
            "batchRuntime": session_lm_head_batch_runtime,
            "batchRuntimeStepBudget": session_lm_head_batch_runtime_step_budget,
            "tileDispatchBudget": session_lm_head_tile_dispatch_budget,
        },
        "sessionEmbedRoi": {
            "jobs": max(1, int(session_embed_roi_jobs)),
            "hiddenPerPeOverride": max(0, int(session_embed_roi_hidden_per_pe)),
        },
        "sessionPrefillQ4kGemv": {
            "jobs": max(1, int(session_prefill_q4k_gemv_jobs)),
            "outputPeRows": max(
                1,
                int(session_prefill_q4k_gemv_output_pe_rows),
            ),
            "adapterStepBudget": max(
                1,
                int(session_prefill_q4k_gemv_adapter_step_budget),
            ),
            "tileDispatchBudget": max(
                0,
                int(session_prefill_q4k_gemv_tile_dispatch_budget),
            ),
        },
        "sessionPleProjDispatch": {
            "mode": session_ple_proj_dispatch_mode,
        },
        "sessionAttentionPrefillDispatch": {
            "mode": session_attention_prefill_dispatch_mode,
        },
    }
