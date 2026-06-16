"""Command-line entry point for the INT4 PLE compile-target runner."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

from int4ple_checkpoint import (
    CheckpointError,
    CheckpointMissingError,
    compute_identity as _compute_checkpoint_identity,
    init_checkpoint as _init_checkpoint,
    load_checkpoint as _load_checkpoint,
)
from int4ple_compile_target_core import (
    DEFAULT_LAUNCH_TIMEOUT_SECONDS,
    DEFAULT_PREFILL_Q4K_GEMV_ADAPTER_STEP_BUDGET,
    DEFAULT_PREFILL_Q4K_GEMV_OUTPUT_PE_ROWS,
    DEFAULT_SESSION_LM_HEAD_BATCH_STEP_BUDGET,
    DEFAULT_SESSION_LM_HEAD_TILE_JOBS,
    DEFAULT_SESSION_LM_HEAD_TILE_WIDTH,
    SESSION_ATTENTION_PREFILL_DISPATCH_MODES,
    SESSION_LM_HEAD_DISPATCH_MODES,
    SESSION_PLE_PROJ_DISPATCH_MODES,
    append_progress,
    common,
    int_param,
    load_json,
    source_program,
    target_by_name,
    write_array,
    write_json,
)
from int4ple_compile_target_planning import (
    execute_hostplan_runtime_bootstrap,
    scheduler_readiness,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--runtime-config", required=True)
    parser.add_argument("--compile-root", required=True)
    parser.add_argument("--reference-export", required=True)
    parser.add_argument("--trace-out", required=True)
    parser.add_argument("--progress-out", required=True)
    parser.add_argument("--diagnostic-compile-dir", default="")
    parser.add_argument("--cmaddr", default="")
    parser.add_argument(
        "--checkpoint-dir",
        default="",
        help="Persist per-launch HostPlan checkpoints under this directory.",
    )
    parser.add_argument(
        "--resume-from-checkpoint",
        default="",
        help="Validate the manifest under this directory and skip launches "
        "already recorded as succeeded. May share a path with --checkpoint-dir.",
    )
    parser.add_argument(
        "--stop-after-launch",
        type=int,
        default=-1,
        help="If >=0, break the launch loop after persisting the checkpoint "
        "for this launch index.",
    )
    parser.add_argument(
        "--launch-timeout-seconds",
        type=int,
        default=DEFAULT_LAUNCH_TIMEOUT_SECONDS,
        help="Per HostPlan launch-step subprocess timeout. Use 0 to disable.",
    )
    parser.add_argument(
        "--session-lm-head-dispatch-mode",
        choices=SESSION_LM_HEAD_DISPATCH_MODES,
        default="monolithic",
        help="Execution mode for session lm-head launches.",
    )
    parser.add_argument(
        "--session-lm-head-tile-width",
        type=int,
        default=DEFAULT_SESSION_LM_HEAD_TILE_WIDTH,
        help="Hidden-width tile used by dense_gemv_width_tiled_session.",
    )
    parser.add_argument(
        "--session-lm-head-tile-jobs",
        type=int,
        default=DEFAULT_SESSION_LM_HEAD_TILE_JOBS,
        help="Parallel tile subprocess count for dense_gemv_width_tiled_session.",
    )
    parser.add_argument(
        "--session-embed-roi-jobs",
        type=int,
        default=1,
        help="Parallel jobs for independent session embed/PLE ROI launches.",
    )
    parser.add_argument(
        "--session-embed-roi-hidden-per-pe",
        type=int,
        default=0,
        help=(
            "Override hidden elements per PE for session embed ROI launches; "
            "0 uses the HostPlan compile parameter."
        ),
    )
    parser.add_argument(
        "--session-prefill-q4k-gemv-jobs",
        type=int,
        default=1,
        help="Parallel adapter workers for session prefill Q4K GEMV launches.",
    )
    parser.add_argument(
        "--session-prefill-q4k-gemv-output-pe-rows",
        type=int,
        default=DEFAULT_PREFILL_Q4K_GEMV_OUTPUT_PE_ROWS,
        help="Output PE rows per session prefill Q4K GEMV launch tile.",
    )
    parser.add_argument(
        "--session-prefill-q4k-gemv-adapter-step-budget",
        type=int,
        default=DEFAULT_PREFILL_Q4K_GEMV_ADAPTER_STEP_BUDGET,
        help=(
            "Maximum Q4K GEMV tile steps per SDK adapter process. "
            "Use 1 to isolate simulator state between tile launches."
        ),
    )
    parser.add_argument(
        "--session-prefill-q4k-gemv-tile-dispatch-budget",
        type=int,
        default=0,
        help="Stop session prefill Q4K GEMV after this many fresh tile dispatches; 0 means unbounded.",
    )
    parser.add_argument(
        "--session-ple-proj-dispatch-mode",
        choices=SESSION_PLE_PROJ_DISPATCH_MODES,
        default="monolithic_summa",
        help="Execution mode for session PLE projection launches.",
    )
    parser.add_argument(
        "--session-attention-prefill-dispatch-mode",
        choices=SESSION_ATTENTION_PREFILL_DISPATCH_MODES,
        default="hostplan_static",
        help="Execution mode for session prefill attention launches.",
    )
    parser.add_argument(
        "--session-lm-head-batch-runtime",
        action="store_true",
        help="Run session lm-head tiles through the batched SDK adapter.",
    )
    parser.add_argument(
        "--session-lm-head-batch-runtime-step-budget",
        type=int,
        default=DEFAULT_SESSION_LM_HEAD_BATCH_STEP_BUDGET,
        help="Tile step group size for session lm-head batched runtime.",
    )
    parser.add_argument(
        "--session-lm-head-tile-dispatch-budget",
        type=int,
        default=0,
        help="Stop session lm-head tile dispatch after this many fresh tiles; 0 means unbounded.",
    )
    parser.add_argument(
        "--ignore-checkpoint",
        action="store_true",
        help="Run from launch 0 even if --resume-from-checkpoint points at a "
        "valid checkpoint. Disables identity validation.",
    )
    parser.add_argument(
        "--allow-checkpoint-runner-drift",
        action="store_true",
        help=(
            "Allow resume when only the checkpoint runnerVersion field drifted. "
            "Manifest/config/compile-target identity and buffer hashes still validate."
        ),
    )
    parser.add_argument(
        "--allow-checkpoint-canonicalization-drift",
        action="store_true",
        help=(
            "Allow resume across the tiled_31b prefill_q4k_gemv "
            "canonicalization boundary. Only hostplanSha256 and compile-target "
            "hashes for the same target set may drift; buffer hashes still validate."
        ),
    )
    return parser.parse_args()


def run_residual_target(
    *,
    compile_root: Path,
    diagnostic_compile_dir: Path | None,
    target: dict[str, Any],
    trace_path: Path,
    progress_path: Path,
    cmaddr: str | None,
) -> dict[str, Any]:
    # Import inside the runner so progress evidence can show SDK import/start
    # failures instead of failing before the governed entrypoint begins.
    # pylint: disable=import-error,import-outside-toplevel
    from cerebras.sdk.runtime.sdkruntimepybind import (
        MemcpyDataType,
        MemcpyOrder,
        SdkRuntime,
    )

    chunk_size = int_param(target, "chunk_size", 1024)
    input_host = (np.arange(chunk_size, dtype=np.float32) * 0.25) + 1.0
    expected = input_host.copy()
    actual = np.zeros(chunk_size, dtype=np.float32)
    compile_dir = diagnostic_compile_dir or (compile_root / "compiled" / "residual")
    compile_dir_source = "compact_diagnostic" if diagnostic_compile_dir else "production"
    if not (compile_dir / "out.json").is_file():
        raise FileNotFoundError(f"missing compiled residual target: {compile_dir}")

    append_progress(
        progress_path,
        "runtime_create",
        target="residual",
        compileDir=str(compile_dir),
        compileDirSource=compile_dir_source,
        cmaddrProvided=cmaddr is not None,
    )
    runner = SdkRuntime(str(compile_dir), cmaddr=cmaddr)
    input_sym = runner.get_id("input")
    output_sym = runner.get_id("output")

    try:
        append_progress(progress_path, "runtime_load", target="residual")
        runner.load()
        append_progress(progress_path, "runtime_run", target="residual")
        runner.run()
        append_progress(progress_path, "memcpy_h2d", target="residual", elements=chunk_size)
        runner.memcpy_h2d(
            input_sym,
            input_host,
            0,
            0,
            1,
            1,
            chunk_size,
            streaming=False,
            order=MemcpyOrder.ROW_MAJOR,
            data_type=MemcpyDataType.MEMCPY_32BIT,
            nonblock=False,
        )
        append_progress(progress_path, "launch_compute", target="residual")
        runner.launch("compute", nonblock=False)
        append_progress(progress_path, "memcpy_d2h", target="residual", elements=chunk_size)
        runner.memcpy_d2h(
            actual,
            output_sym,
            0,
            0,
            1,
            1,
            chunk_size,
            streaming=False,
            order=MemcpyOrder.ROW_MAJOR,
            data_type=MemcpyDataType.MEMCPY_32BIT,
            nonblock=False,
        )
    finally:
        append_progress(progress_path, "runtime_stop", target="residual")
        runner.stop()

    max_abs_err = common.max_abs_error(actual, expected)
    if not np.allclose(actual, expected, atol=1e-6, rtol=0.0):
        raise ValueError(f"residual target mismatch: max_abs_err={max_abs_err}")

    output_link = write_array(
        trace_path.parent / "int4ple-residual-diagnostic-output.f32",
        actual,
    )
    append_progress(
        progress_path,
        "runtime_target_succeeded",
        target="residual",
        maxAbsErr=max_abs_err,
        compileDirSource=compile_dir_source,
    )
    return {
        "target": "residual",
        "status": "succeeded",
        "compileDir": str(compile_dir),
        "compileDirSource": compile_dir_source,
        "roi": {"x": 0, "y": 0, "width": 1, "height": 1},
        "chunkSize": chunk_size,
        "maxAbsErr": max_abs_err,
        "inputSynthetic": True,
        "output": {
            **output_link,
            "dtype": "float32",
            "shape": [chunk_size],
        },
    }


def diagnostic_trace(
    *,
    export: dict[str, Any],
    runtime_config: dict[str, Any],
    scheduler: dict[str, Any],
    cmaddr: str | None,
    started: float,
    hostplan_executor_runtime: dict[str, Any] | None,
    kernel_results: list[dict[str, Any]],
    status: str,
    error: str | None = None,
) -> dict[str, Any]:
    elapsed_ms = (time.monotonic() - started) * 1000.0
    runtime_artifact_kind = (
        str(hostplan_executor_runtime.get("artifactKind"))
        if isinstance(hostplan_executor_runtime, dict)
        else ""
    )
    bootstrap_ready = (
        isinstance(hostplan_executor_runtime, dict)
        and hostplan_executor_runtime.get("status") == "ready_for_tensor_movement"
    )
    runtime_executed = runtime_artifact_kind == "int4ple_hostplan_executor_runtime"
    if runtime_executed:
        model_blocker = (
            "The HostPlan executor launched real CSL targets, but stopped "
            "before a full-model transcript because the bound launch graph "
            "still hit an unsupported materialization or tensor-handoff blocker."
        )
    elif bootstrap_ready:
        model_blocker = (
            "The HostPlan executor bootstrap loaded each compiled target, "
            "resolved the required runtime symbols, and materialized the "
            "concrete activation/KV/logit/token buffer plan, but weight "
            "staging, tensor movement, launch execution, and transcript "
            "capture are still pending."
        )
    elif scheduler.get("status") == "blocked_missing_full_model_runtime_execution":
        model_blocker = (
            "The HostPlan runtime scheduler has symbol-level dataflow, "
            "activation lifetime routing, KV read/write scheduling, and "
            "logit/token capture points bound, but this runner still only "
            "executes the residual diagnostic target. The full prefill/decode "
            "target interpreter has not executed the bound schedule."
        )
    else:
        model_blocker = (
            "HostPlan phase launches, weights, and the Doppler reference "
            "transcript are visible, but the runtime scheduler is not yet "
            "fully bound for symbol-level dataflow, activation routing, "
            "KV read/write scheduling, and logit/token capture."
        )
    production_targets = [
        str(item.get("targetName") or item.get("target"))
        for item in kernel_results
        if item.get("status") in {"resolved", "succeeded"}
    ]
    kernel_stage = (
        "int4ple_hostplan_executor_runtime"
        if runtime_executed
        else
        "int4ple_hostplan_executor_bootstrap"
        if hostplan_executor_runtime is not None
        else "int4ple_compile_target_runtime_diagnostic"
    )
    trace: dict[str, Any] = {
        "schemaVersion": 1,
        "artifactKind": "csl_simulator_trace",
        "target": "wse3",
        "contract": "explicit_simulator_trace",
        "sourceProgram": source_program(export),
        "simulatorRun": {
            "status": status,
            "executionTarget": common.execution_target(cmaddr),
            "compileStatus": "succeeded",
            "kernelStage": kernel_stage,
            "kernelIsStub": False,
            "elapsedMs": elapsed_ms,
        },
        "executedRun": {
            "fullModelDepthExecuted": False,
            "boundedTranscriptProduced": False,
            "productionCompileTargetsExecuted": production_targets,
            "runtimeConfigMode": runtime_config.get("mode"),
            "diagnosticOnly": hostplan_executor_runtime is None,
            "executorBootstrapOnly": (
                hostplan_executor_runtime is not None and not runtime_executed
            ),
            "schedulerStatus": scheduler.get("status"),
            "hostPlanExecutorRuntimeStatus": (
                hostplan_executor_runtime.get("status")
                if isinstance(hostplan_executor_runtime, dict)
                else "not_run"
            ),
        },
        "modelExecution": {
            "fullModelDepthExecuted": False,
            "blocker": model_blocker,
        },
        "hostPlanScheduler": scheduler,
        "kernelResults": kernel_results,
    }
    if hostplan_executor_runtime is not None:
        trace["hostPlanExecutorRuntime"] = hostplan_executor_runtime
    if error is not None:
        trace["simulatorRun"]["error"] = error
    return trace


def main(runtime_module: Any | None = None) -> int:
    runtime = runtime_module
    if runtime is None:
        import int4ple_compile_target_sim_runner as runtime
    args = parse_args()
    trace_path = Path(args.trace_out)
    progress_path = Path(args.progress_out)
    started = time.monotonic()
    append_progress(progress_path, "runner_start")
    hostplan_executor_runtime: dict[str, Any] | None = None

    checkpoint_dir = Path(args.checkpoint_dir) if args.checkpoint_dir.strip() else None
    resume_dir = (
        Path(args.resume_from_checkpoint)
        if args.resume_from_checkpoint.strip() and not args.ignore_checkpoint
        else None
    )

    try:
        plan = load_json(Path(args.plan))
        runtime_config = load_json(Path(args.runtime_config))
        export = load_json(Path(args.reference_export))
        cmaddr = common.endpoint(args.cmaddr)
        scheduler = scheduler_readiness(
            plan_path=Path(args.plan),
            plan=plan,
            runtime_config=runtime_config,
            export=export,
            reference_export_path=Path(args.reference_export),
            compile_root=Path(args.compile_root),
        )
        identity = _compute_checkpoint_identity(
            plan=plan,
            plan_path=Path(args.plan),
            runtime_config=runtime_config,
            runtime_config_path=Path(args.runtime_config),
            export=export,
            reference_export_path=Path(args.reference_export),
            runner_version=runtime._runner_version(),
        )
        resume_state = None
        if resume_dir is not None:
            try:
                resume_state = _load_checkpoint(
                    checkpoint_dir=resume_dir,
                    identity=identity,
                    allow_runner_version_drift=args.allow_checkpoint_runner_drift,
                    allow_canonicalization_drift=(
                        args.allow_checkpoint_canonicalization_drift
                    ),
                )
                append_progress(
                    progress_path,
                    "checkpoint_resume_validated",
                    startIndex=resume_state.start_index,
                    bufferCount=len(resume_state.buffer_files),
                )
            except CheckpointMissingError:
                # Fresh resume directory: treat as empty checkpoint.
                resume_state = None
            except CheckpointError as exc:
                append_progress(
                    progress_path,
                    "checkpoint_resume_rejected",
                    code=getattr(exc, "code", "checkpoint_error"),
                    error=str(exc),
                )
                raise
        if checkpoint_dir is not None:
            _init_checkpoint(
                checkpoint_dir,
                identity,
                allow_runner_version_drift=args.allow_checkpoint_runner_drift,
                allow_canonicalization_drift=(
                    args.allow_checkpoint_canonicalization_drift
                ),
            )
        append_progress(
            progress_path,
            "scheduler_readiness",
            status=scheduler["status"],
            blockers=scheduler["blockers"],
        )
        execution_plan = ((scheduler.get("hostPlanExecutor") or {}).get("executionPlan") or {})
        has_launch_plan = bool(execution_plan.get("targetSessions")) and bool(
            execution_plan.get("launches")
        )
        if has_launch_plan:
            hostplan_executor_runtime = execute_hostplan_runtime_bootstrap(
                execution_plan=execution_plan,
                progress_path=progress_path,
                cmaddr=cmaddr,
            )
            if hostplan_executor_runtime.get("status") != "ready_for_tensor_movement":
                raise ValueError(
                    "hostplan executor bootstrap blocked: "
                    + ", ".join(hostplan_executor_runtime.get("blockers") or ["unknown"])
                )
            hostplan_executor_runtime = runtime.execute_hostplan_runtime(
                bootstrap=hostplan_executor_runtime,
                export=export,
                progress_path=progress_path,
                cmaddr=cmaddr,
                trace_path=trace_path,
                checkpoint_dir=checkpoint_dir,
                resume_state=resume_state,
                stop_after_launch=args.stop_after_launch,
                launch_timeout_seconds=args.launch_timeout_seconds,
                session_lm_head_dispatch_mode=args.session_lm_head_dispatch_mode,
                session_lm_head_tile_width=args.session_lm_head_tile_width,
                session_lm_head_tile_jobs=args.session_lm_head_tile_jobs,
                session_embed_roi_jobs=args.session_embed_roi_jobs,
                session_embed_roi_hidden_per_pe=(
                    args.session_embed_roi_hidden_per_pe
                ),
                session_prefill_q4k_gemv_jobs=args.session_prefill_q4k_gemv_jobs,
                session_prefill_q4k_gemv_output_pe_rows=(
                    args.session_prefill_q4k_gemv_output_pe_rows
                ),
                session_prefill_q4k_gemv_adapter_step_budget=(
                    args.session_prefill_q4k_gemv_adapter_step_budget
                ),
                session_prefill_q4k_gemv_tile_dispatch_budget=(
                    args.session_prefill_q4k_gemv_tile_dispatch_budget
                ),
                session_ple_proj_dispatch_mode=args.session_ple_proj_dispatch_mode,
                session_attention_prefill_dispatch_mode=(
                    args.session_attention_prefill_dispatch_mode
                ),
                session_lm_head_batch_runtime=args.session_lm_head_batch_runtime,
                session_lm_head_batch_runtime_step_budget=(
                    args.session_lm_head_batch_runtime_step_budget
                ),
                session_lm_head_tile_dispatch_budget=(
                    args.session_lm_head_tile_dispatch_budget
                ),
            )
            runtime_status = hostplan_executor_runtime.get("status")
            if runtime_status not in ("succeeded", "stopped_at_checkpoint"):
                raise ValueError(
                    "hostplan executor runtime blocked: "
                    + ", ".join(hostplan_executor_runtime.get("blockers") or ["unknown"])
                )
            kernel_results = hostplan_executor_runtime.get("launches") or []
        else:
            residual_target = target_by_name(plan, "residual")
            diagnostic_compile_dir = (
                Path(args.diagnostic_compile_dir)
                if args.diagnostic_compile_dir.strip()
                else None
            )
            result = run_residual_target(
                compile_root=Path(args.compile_root),
                diagnostic_compile_dir=diagnostic_compile_dir,
                target=residual_target,
                trace_path=trace_path,
                progress_path=progress_path,
                cmaddr=cmaddr,
            )
            kernel_results = [result]
        trace = diagnostic_trace(
            export=export,
            runtime_config=runtime_config,
            scheduler=scheduler,
            cmaddr=cmaddr,
            started=started,
            hostplan_executor_runtime=hostplan_executor_runtime,
            kernel_results=kernel_results,
            status="succeeded",
        )
        write_json(trace_path, trace)
        append_progress(progress_path, "runner_succeeded", tracePath=str(trace_path))
        print(f"PASS: diagnostic INT4 PLE compile-target run wrote {trace_path}")
        return 0
    except Exception as exc:  # pragma: no cover - runner evidence path
        append_progress(progress_path, "runner_failed", error=str(exc))
        try:
            runtime_config = load_json(Path(args.runtime_config))
            export = load_json(Path(args.reference_export))
            cmaddr = common.endpoint(args.cmaddr)
            trace = diagnostic_trace(
                export=export,
                runtime_config=runtime_config,
                scheduler=scheduler_readiness(
                    plan_path=Path(args.plan),
                    plan=load_json(Path(args.plan)),
                    runtime_config=runtime_config,
                    export=export,
                    reference_export_path=Path(args.reference_export),
                    compile_root=Path(args.compile_root),
                ),
                cmaddr=cmaddr,
                started=started,
                hostplan_executor_runtime=hostplan_executor_runtime,
                kernel_results=(
                    hostplan_executor_runtime.get("launches")
                    or hostplan_executor_runtime.get("targetSessions")
                    or []
                    if isinstance(hostplan_executor_runtime, dict)
                    else []
                ),
                status="failed",
                error=str(exc),
            )
            write_json(trace_path, trace)
        except Exception:
            pass
        print(f"FAIL: diagnostic INT4 PLE compile-target run: {exc}", file=sys.stderr)
        return 1
