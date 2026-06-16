#!/usr/bin/env cs_python
"""Diagnostic runtime runner for generated INT4 PLE CSL compile targets.

This is not the final bounded transcript runner. It drives one generated
production-derived residual target through SdkRuntime so timeout/debug evidence
moves past compile-only mode. The trace intentionally keeps full-model
transcript depth false until the HostPlan scheduler emits token/logit/KV
artifacts.
"""

from __future__ import annotations

import concurrent.futures
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from int4ple_checkpoint import (
    CheckpointError,
    CheckpointMissingError,
    compute_identity as _compute_checkpoint_identity,
    compute_launch_identity as _compute_launch_identity,
    init_checkpoint as _init_checkpoint,
    load_checkpoint as _load_checkpoint,
    persist_launch_checkpoint as _persist_launch_checkpoint,
)
from int4ple_compile_target_cli import (
    diagnostic_trace,
    parse_args,
    run_residual_target,
)
from int4ple_compile_target_core import (
    DEFAULT_LAUNCH_TIMEOUT_SECONDS,
    DEFAULT_PREFILL_Q4K_GEMV_ADAPTER_STEP_BUDGET,
    DEFAULT_PREFILL_Q4K_GEMV_OUTPUT_PE_ROWS,
    DEFAULT_SESSION_LM_HEAD_BATCH_STEP_BUDGET,
    DEFAULT_SESSION_LM_HEAD_TILE_JOBS,
    DEFAULT_SESSION_LM_HEAD_TILE_WIDTH,
    EMBED_ROI_ADAPTER,
    EMBED_ROI_TARGETS,
    LAUNCH_STEP_ADAPTER,
    PREFILL_GEMV_MAX_OUTPUT_PE_ROWS,
    REPO_ROOT,
    SDK_D2H_ELEMENT_COUNT_LIMIT,
    append_progress,
    common,
    compile_target_coverage,
    compiled_target_params,
    cs_python_executable,
    cslc_executable,
    int_param,
    load_json,
    require_minimum,
    sha256_bytes,
    sha256_file,
    source_program,
    tail_lines,
    target_by_name,
    write_array,
    write_json,
)
from int4ple_compile_target_materialization import (
    _buffer_path,
    _launch_receipt_path,
    _launch_spec_path,
    _materialize_weight_input,
    _stage_launch_arrays,
    _staged_input_buffer_records,
    _tokenized_prompt_path,
    _transform_existing_input,
)
from int4ple_compile_target_planning import (
    execute_hostplan_runtime_bootstrap,
    host_plan_executor_preflight,
    host_plan_phase_summary,
    probe_target_session,
    reference_transcript_summary,
    runtime_input_summary,
    scheduler_readiness,
)
from int4ple_compile_target_predicates import (
    _is_compact_attention_prefill_launch,
    _is_compact_ple_proj_launch,
    _is_session_tiled_lm_head_launch,
    _is_tiled_q4k_gemv_launch,
)
from int4ple_compact_session_runtime import (
    _compact_ple_proj_output_transform,
    _compact_ple_proj_source_transform,
    _execute_compact_attention_prefill_launch,
    _execute_compact_ple_proj_launch,
    _execute_dense_gemv_tiled_session_launch,
    _load_compact_attention_input,
)
from int4ple_embed_roi import build_embed_roi_spec
from int4ple_prefill_q4k_gemv_runtime import (
    _execute_tiled_q4k_gemv_launch,
    _prefill_gemv_task_shards,
)
from int4ple_prefill_q4k_gemv_tiles import (
    _prefill_gemv_in_dim_per_pe,
    _prefill_gemv_output_pe_rows,
    _prefill_gemv_split_d2h_rows,
    _prefill_gemv_tile_output_status,
)
from int4ple_roi_session_runtime import (
    _execute_compact_gated_prefill_launch,
    _execute_residual_prefill_roi_launch,
    _execute_rmsnorm_roi_launch,
    _is_compact_gated_prefill_launch,
    _is_residual_prefill_roi_launch,
    _is_rmsnorm_roi_launch,
)

_RUNNER_VERSION_MODULES = (
    "int4ple_compile_target_sim_runner.py",
    "int4ple_compile_target_core.py",
    "int4ple_compile_target_planning.py",
    "int4ple_compile_target_materialization.py",
    "int4ple_compile_target_predicates.py",
    "int4ple_prefill_q4k_gemv_tiles.py",
    "int4ple_prefill_q4k_gemv_runtime.py",
    "int4ple_compact_session_runtime.py",
    "int4ple_roi_session_runtime.py",
    "int4ple_compile_target_cli.py",
)


def _runner_version() -> str:
    """Best-effort runner identity tag covering split helper modules."""
    try:
        digest = hashlib.sha256()
        base = Path(__file__).resolve().parent
        for name in _RUNNER_VERSION_MODULES:
            path = base / name
            digest.update(name.encode("utf-8"))
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
        return digest.hexdigest()[:16]
    except OSError:
        return "unknown"


def _is_embed_roi_launch(launch: dict[str, Any]) -> bool:
    if str(launch.get("targetName") or "") not in EMBED_ROI_TARGETS:
        return False
    params = launch.get("compileParams") or {}
    return all(
        int(params.get(key) or 0) > 0
        for key in ("rows_per_pe", "hidden_size", "hidden_per_pe", "tokens_per_chunk")
    )


def _compile_embed_roi_target(
    *,
    launch: dict[str, Any],
    roi_spec: dict[str, Any],
    roi_dir: Path,
) -> Path:
    source_compile_dir = Path(str(launch.get("compileDir") or ""))
    compile_root = source_compile_dir.parent.parent
    target_name = str(launch.get("targetName") or "embed")
    layout_path = compile_root / target_name / "layout.csl"
    output_dir = roi_dir / "compiled"
    params = roi_spec.get("compileParams") or {}
    compact_width = int(params.get("compactWidth") or 1)
    hidden_size = int(params.get("hiddenSize") or 0)
    hidden_per_pe = int(params.get("hiddenPerPe") or 0)
    rows_per_pe = int(params.get("rowsPerPe") or 0)
    tokens_per_chunk = int(params.get("tokensPerChunk") or 0)
    if min(compact_width, hidden_size, hidden_per_pe, rows_per_pe, tokens_per_chunk) <= 0:
        raise ValueError("embed_roi_compile_params_incomplete")
    command = [
        cslc_executable(),
        str(layout_path),
        "--arch=wse3",
        f"--fabric-dims={compact_width + 7},3",
        "--fabric-offsets=4,1",
        "--channels=1",
        "--params="
        + ",".join(
            [
                f"width:{compact_width}",
                "height:1",
                f"hidden_per_pe:{hidden_per_pe}",
                f"hidden_size:{hidden_size}",
                f"num_tokens:{tokens_per_chunk}",
                f"rows_per_pe:{rows_per_pe}",
                f"tokens_per_chunk:{tokens_per_chunk}",
            ]
        ),
        "-o",
        str(output_dir),
        "--memcpy",
    ]
    scratch_cwd = roi_dir / "scratch"
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
        raise ValueError(f"embed_roi_compile_failed:{detail[-400:]}")
    return output_dir


def _execute_embed_roi_launch(
    *,
    runtime_dir: Path,
    launch: dict[str, Any],
    buffer_files: dict[str, Path],
    export: dict[str, Any],
    progress_path: Path,
    cmaddr: str | None,
    timeout_seconds: int | None,
    hidden_per_pe_override: int = 0,
) -> dict[str, Any]:
    launch_index = int(launch.get("launchIndex") or 0)
    output_binding = next(
        (
            item
            for item in launch.get("resolvedOutputs") or []
            if isinstance(item, dict) and item.get("symbol") == "output"
        ),
        None,
    )
    if not isinstance(output_binding, dict):
        raise ValueError("embed_roi_output_binding_missing")
    output_buffer = str(output_binding.get("buffer") or "")
    if not output_buffer:
        raise ValueError("embed_roi_output_buffer_missing")
    roi_dir = runtime_dir / "embed-roi" / f"launch-{launch_index:04d}"
    output_path = _buffer_path(runtime_dir, output_buffer)
    prompt_path = _tokenized_prompt_path(export)
    roi_spec, roi_digest = build_embed_roi_spec(
        roi_dir=roi_dir,
        launch=launch,
        prompt_path=prompt_path,
        output_buffer_path=output_path,
        hidden_per_pe_override=max(0, int(hidden_per_pe_override)),
    )
    roi_compile_dir = _compile_embed_roi_target(
        launch=launch,
        roi_spec=roi_spec,
        roi_dir=roi_dir,
    )
    roi_spec["compileDir"] = str(roi_compile_dir)
    roi_spec["cmaddr"] = cmaddr or ""
    roi_digest = sha256_bytes(
        json.dumps(roi_spec, separators=(",", ":"), sort_keys=True).encode("utf-8")
    )
    spec_path = roi_dir / "launch-spec.json"
    receipt_path = _launch_receipt_path(runtime_dir, launch_index)
    write_json(spec_path, roi_spec)
    append_progress(
        progress_path,
        "embed_roi_spec_ready",
        launchIndex=launch_index,
        tokenCount=(roi_spec.get("prompt") or {}).get("tokenCount"),
        sublaunchCount=len(roi_spec.get("sublaunches") or []),
        specSha256=roi_digest,
    )
    command = [
        cs_python_executable(),
        str(EMBED_ROI_ADAPTER),
        "--spec",
        str(spec_path),
        "--receipt-out",
        str(receipt_path),
        "--progress-out",
        str(progress_path),
    ]
    timeout = timeout_seconds if timeout_seconds and timeout_seconds > 0 else None
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = (
            exc.stdout.decode("utf-8", "replace")
            if isinstance(exc.stdout, bytes)
            else (exc.stdout or "")
        )
        stderr = (
            exc.stderr.decode("utf-8", "replace")
            if isinstance(exc.stderr, bytes)
            else (exc.stderr or "")
        )
        receipt = {
            "schemaVersion": 1,
            "artifactKind": "int4ple_embed_roi_launch_receipt",
            "status": "blocked",
            "compileDir": str(roi_compile_dir),
            "launchFunction": str(launch.get("function") or "compute"),
            "launchIndex": launch_index,
            "blockers": ["embed_roi_launch_timeout"],
            "timeoutSeconds": timeout,
            "stdoutTail": (
                stdout.strip().splitlines()[-3:] if stdout.strip() else []
            ),
            "stderrTail": (
                stderr.strip().splitlines()[-3:] if stderr.strip() else []
            ),
            "roiSpecPath": str(spec_path),
            "roiSpecSha256": roi_digest,
        }
        write_json(receipt_path, receipt)
        append_progress(
            progress_path,
            "embed_roi_launch_timeout",
            launchIndex=launch_index,
            timeoutSeconds=timeout,
        )
        raise ValueError("embed_roi_launch_timeout") from exc
    if not receipt_path.is_file():
        raise ValueError("embed_roi_launch_receipt_missing")
    receipt = load_json(receipt_path)
    if not isinstance(receipt.get("inputBuffers"), list):
        prompt = roi_spec.get("prompt") or {}
        receipt["inputBuffers"] = [
            {
                "name": "prompt",
                "role": "prompt_tokens",
                "path": str(prompt.get("path") or ""),
                "dtype": "u32",
                "totalElements": int(prompt.get("tokenCount") or 0),
                "sha256": str(prompt.get("sha256") or ""),
                "sha256Kind": "raw_file_bytes",
            }
        ]
    receipt["stdoutTail"] = (
        completed.stdout.strip().splitlines()[-3:] if completed.stdout.strip() else []
    )
    receipt["stderrTail"] = (
        completed.stderr.strip().splitlines()[-3:] if completed.stderr.strip() else []
    )
    receipt["roiSpecPath"] = str(spec_path)
    receipt["roiSpecSha256"] = roi_digest
    write_json(receipt_path, receipt)
    if completed.returncode != 0 or receipt.get("status") != "succeeded":
        raise ValueError("; ".join(receipt.get("blockers") or ["embed_roi_launch_failed"]))
    buffer_files[output_buffer] = output_path
    return receipt


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
    hidden_per_pe_override: int = 0,
) -> list[dict[str, Any]]:
    def run_one(launch: dict[str, Any]) -> dict[str, Any]:
        local_buffer_files = dict(buffer_files)
        started_at_unix = time.time()
        receipt = _execute_embed_roi_launch(
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
                launch_receipt = _execute_embed_roi_launch(
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
                launch_receipt = _execute_tiled_q4k_gemv_launch(
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
                launch_receipt = _execute_compact_ple_proj_launch(
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
                launch_receipt = _execute_compact_attention_prefill_launch(
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
            staged_inputs, staged_outputs = _stage_launch_arrays(
                runtime_dir=runtime_dir,
                launch=launch,
                buffer_files=buffer_files,
                export=export,
            )
            if _is_rmsnorm_roi_launch(launch):
                launch_receipt = _execute_rmsnorm_roi_launch(
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
                launch_receipt = _execute_residual_prefill_roi_launch(
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
                launch_receipt = _execute_compact_gated_prefill_launch(
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
                launch_receipt = _execute_dense_gemv_tiled_session_launch(
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


def main() -> int:
    from int4ple_compile_target_cli import main as cli_main

    return cli_main(runtime_module=sys.modules[__name__])


if __name__ == "__main__":
    raise SystemExit(main())
