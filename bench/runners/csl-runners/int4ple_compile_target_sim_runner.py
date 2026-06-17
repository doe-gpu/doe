#!/usr/bin/env cs_python
"""Diagnostic runtime runner for generated INT4 PLE CSL compile targets.

This is not the final bounded transcript runner. It drives one generated
production-derived residual target through SdkRuntime so timeout/debug evidence
moves past compile-only mode. The trace intentionally keeps full-model
transcript depth false until the HostPlan scheduler emits token/logit/KV
artifacts.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import int4ple_runtime_launch as _runtime_launch
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
    target_by_name,
    write_array,
    write_json,
)
from int4ple_compile_target_materialization import (
    _buffer_path,
    _launch_receipt_path,
    _materialize_weight_input,
    _stage_launch_arrays,
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
    "int4ple_runtime_launch.py",
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



def _runtime_launch_hooks() -> _runtime_launch.HostPlanRuntimeLaunchHooks:
    return _runtime_launch.HostPlanRuntimeLaunchHooks(
        execute_embed_roi_launch=_execute_embed_roi_launch,
        stage_launch_arrays=_stage_launch_arrays,
        execute_tiled_q4k_gemv_launch=_execute_tiled_q4k_gemv_launch,
        execute_compact_ple_proj_launch=_execute_compact_ple_proj_launch,
        execute_compact_attention_prefill_launch=(
            _execute_compact_attention_prefill_launch
        ),
        execute_rmsnorm_roi_launch=_execute_rmsnorm_roi_launch,
        execute_residual_prefill_roi_launch=_execute_residual_prefill_roi_launch,
        execute_compact_gated_prefill_launch=_execute_compact_gated_prefill_launch,
        execute_dense_gemv_tiled_session_launch=(
            _execute_dense_gemv_tiled_session_launch
        ),
    )


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
    return _runtime_launch.execute_hostplan_runtime(
        bootstrap=bootstrap,
        export=export,
        progress_path=progress_path,
        cmaddr=cmaddr,
        trace_path=trace_path,
        hooks=_runtime_launch_hooks(),
        checkpoint_dir=checkpoint_dir,
        resume_state=resume_state,
        initial_buffer_files=initial_buffer_files,
        stop_after_launch=stop_after_launch,
        launch_timeout_seconds=launch_timeout_seconds,
        session_lm_head_dispatch_mode=session_lm_head_dispatch_mode,
        session_lm_head_tile_width=session_lm_head_tile_width,
        session_lm_head_tile_jobs=session_lm_head_tile_jobs,
        session_embed_roi_jobs=session_embed_roi_jobs,
        session_embed_roi_hidden_per_pe=session_embed_roi_hidden_per_pe,
        session_prefill_q4k_gemv_jobs=session_prefill_q4k_gemv_jobs,
        session_prefill_q4k_gemv_output_pe_rows=(
            session_prefill_q4k_gemv_output_pe_rows
        ),
        session_prefill_q4k_gemv_adapter_step_budget=(
            session_prefill_q4k_gemv_adapter_step_budget
        ),
        session_prefill_q4k_gemv_tile_dispatch_budget=(
            session_prefill_q4k_gemv_tile_dispatch_budget
        ),
        session_ple_proj_dispatch_mode=session_ple_proj_dispatch_mode,
        session_attention_prefill_dispatch_mode=(
            session_attention_prefill_dispatch_mode
        ),
        session_lm_head_batch_runtime=session_lm_head_batch_runtime,
        session_lm_head_batch_runtime_step_budget=(
            session_lm_head_batch_runtime_step_budget
        ),
        session_lm_head_tile_dispatch_budget=session_lm_head_tile_dispatch_budget,
    )


def main() -> int:
    from int4ple_compile_target_cli import main as cli_main

    return cli_main(runtime_module=sys.modules[__name__])


if __name__ == "__main__":
    raise SystemExit(main())
