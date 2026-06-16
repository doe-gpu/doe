"""Runtime execution, checkpoint, and transcript assembly for 31B af16."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
from typing import Any

import numpy as np

from gemma4_31b_af16_session_common import (
    SESSION_ARTIFACT_PREFIX,
    load_json,
    optional_resolved_path,
    rel,
    resolve,
    session_artifact_prefix,
    session_runtime_source_sha256,
    sha256_file,
    sha256_json,
    write_json,
)
from gemma4_31b_af16_session_scheduler import build_real_session_scheduler
from gemma4_31b_af16_session_weights import (
    build_reference_request,
    build_runtime_weight_mappings,
    normalize_smoke_execution,
)
from int4ple_checkpoint import (
    CheckpointError,
    CheckpointMissingError,
    compute_identity as compute_checkpoint_identity,
    init_checkpoint,
    load_checkpoint,
)
from int4ple_compile_target_sim_runner import (
    DEFAULT_LAUNCH_TIMEOUT_SECONDS,
    execute_hostplan_runtime,
    execute_hostplan_runtime_bootstrap,
)
from int4ple_hostplan_execution_plan import build_hostplan_execution_plan
from int4ple_hostplan_executor_validator import validate_hostplan_executor

def host_io_layout_from_buffer_plan(
    buffer_plan: dict[str, Any],
) -> list[dict[str, Any]]:
    layout: list[dict[str, Any]] = []
    for buffer in buffer_plan.get("buffers") or []:
        if not isinstance(buffer, dict):
            continue
        storage = str(buffer.get("storageClass") or "")
        if storage not in {
            "shared_input",
            "captured_output",
            "persistent_state",
            "external_weight",
        }:
            continue
        layout.append(
            {
                "buffer": buffer.get("buffer"),
                "bufferRole": buffer.get("role"),
                "storageClass": storage,
                "dtype": buffer.get("dtype"),
                "plannedElementCount": buffer.get("plannedElementCount"),
                "plannedByteLength": buffer.get("plannedByteLength"),
            }
        )
    return layout


def _output_bindings_by_launch(
    execution_plan: dict[str, Any],
) -> dict[int, dict[str, dict[str, Any]]]:
    bindings: dict[int, dict[str, dict[str, Any]]] = {}
    for launch in execution_plan.get("launches") or []:
        if not isinstance(launch, dict):
            continue
        launch_index = int(launch.get("launchIndex") or 0)
        by_symbol: dict[str, dict[str, Any]] = {}
        for item in launch.get("outputBindings") or []:
            if not isinstance(item, dict):
                continue
            symbol = str(item.get("symbol") or "")
            if symbol:
                by_symbol[symbol] = item
        bindings[launch_index] = by_symbol
    return bindings


def _array_file_digest(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    return {
        "path": str(path),
        "sha256": hashlib.sha256(data).hexdigest(),
        "byteLength": len(data),
    }


def _read_first_u32(path: Path) -> int | None:
    values = np.load(path, allow_pickle=False).astype(np.uint32, copy=False).ravel()
    if values.size == 0:
        return None
    return int(values[0])


def build_runtime_transcript(
    *,
    session_dir: Path,
    runtime: dict[str, Any],
    execution_plan: dict[str, Any],
    requested_decode_steps: int,
    artifact_prefix: str = SESSION_ARTIFACT_PREFIX,
) -> dict[str, Any]:
    output_bindings = _output_bindings_by_launch(execution_plan)
    generated_tokens: list[dict[str, Any]] = []
    logits_digests: list[dict[str, Any]] = []
    kv_digests: list[dict[str, Any]] = []
    lm_head_dispatches: list[dict[str, Any]] = []

    for receipt in runtime.get("launches") or []:
        if not isinstance(receipt, dict):
            continue
        launch_index = int(receipt.get("launchIndex") or 0)
        bindings = output_bindings.get(launch_index, {})
        for output in receipt.get("outputs") or []:
            if not isinstance(output, dict):
                continue
            symbol = str(output.get("symbol") or "")
            binding = bindings.get(symbol) or {}
            role = str(binding.get("role") or "")
            path = Path(str(output.get("path") or ""))
            if not path.is_file():
                continue
            digest = _array_file_digest(path)
            record = {
                "launchIndex": launch_index,
                "symbol": symbol,
                "buffer": binding.get("buffer"),
                **digest,
            }
            if role == "generated_tokens":
                record["tokenId"] = _read_first_u32(path)
                generated_tokens.append(record)
            elif role == "logits":
                record["dispatchMode"] = str(
                    receipt.get("dispatchMode") or "monolithic_full_fabric"
                )
                if isinstance(receipt.get("sessionTileIdentity"), dict):
                    record["sessionTileIdentity"] = receipt[
                        "sessionTileIdentity"
                    ]
                if isinstance(receipt.get("tileCoverage"), dict):
                    record["tileCoverage"] = receipt["tileCoverage"]
                logits_digests.append(record)
                lm_head_dispatches.append(
                    {
                        "launchIndex": launch_index,
                        "dispatchMode": record["dispatchMode"],
                        "buffer": binding.get("buffer"),
                        "sessionTileIdentity": record.get(
                            "sessionTileIdentity",
                            {},
                        ),
                    }
                )
            elif role == "kv_cache":
                kv_digests.append(record)

    transcript = {
        "schemaVersion": 1,
        "artifactKind": f"{artifact_prefix}_csl_runtime_transcript",
        "status": "output_ready",
        "requestedDecodeSteps": requested_decode_steps,
        "actualDecodeSteps": len(generated_tokens),
        "generatedTokenIds": [item.get("tokenId") for item in generated_tokens],
        "generatedTokenDigests": generated_tokens,
        "logitsDigests": logits_digests,
        "lmHeadDispatches": lm_head_dispatches,
        "kvCache": {
            "mode": "runtime_captured",
            "digestCount": len(kv_digests),
            "digests": kv_digests,
        },
    }
    transcript_path = session_dir / "transcript.json"
    write_json(transcript_path, transcript)
    return {
        "path": rel(transcript_path),
        "sha256": sha256_file(transcript_path),
        "payload": transcript,
    }


def build_real_session_runtime(
    args: argparse.Namespace,
    dispatch_plan: dict[str, Any],
    weight_plan: dict[str, Any],
) -> dict[str, Any]:
    session_dir = resolve(args.session_out_dir)
    session_dir.mkdir(parents=True, exist_ok=True)
    plan = load_json(args.simulator_plan)
    runtime_config = load_json(args.runtime_config)
    runtime_config["mode"] = "sdk-runtime-command"
    runtime_config["modelConfig"] = {
        **(runtime_config.get("modelConfig") or {}),
        "numLayers": int(weight_plan.get("modelLayerCount") or 0),
    }
    state_buffers = runtime_config.setdefault("stateBuffers", [])
    existing_state_names = {
        str(item.get("name") or "")
        for item in state_buffers
        if isinstance(item, dict)
    }
    for name, role in (
        ("linear_attention", "linear_attention_state"),
        ("sliding_window", "position"),
    ):
        if name not in existing_state_names:
            state_buffers.append({"name": name, "role": role})
    mappings = build_runtime_weight_mappings(
        manifest_path=args.source_doppler_manifest,
        weight_plan=weight_plan,
        runtime_config=runtime_config,
    )
    runtime_config["weightMappings"] = mappings["mappings"]
    runtime_config["weightIdentity"] = mappings["identity"]
    normalized = normalize_smoke_execution(
        smoke_config_path=args.smoke_config,
        out_dir=session_dir,
        model_layer_count=int(weight_plan.get("modelLayerCount") or 0),
    )
    reference = build_reference_request(args=args, session_dir=session_dir)
    scheduler = build_real_session_scheduler(
        dispatch_plan=dispatch_plan,
        runtime_config=runtime_config,
        architecture_disabled_weight_keys=[
            str(item)
            for item in weight_plan.get("architectureDisabledWeightKeys") or []
        ],
        per_layer_input_block_enabled=bool(
            (weight_plan.get("perLayerInputBlock") or {}).get("enabled", True)
        ),
    )
    scheduler_record = {
        "path": str(args.host_plan),
        "present": True,
        "runtimeScheduler": scheduler,
        "launchesCarrySymbolDataflow": bool(scheduler.get("launches")),
    }
    manifest_preflight = {
        "status": "passed",
        "blockers": [],
        "source": f"{session_artifact_prefix(args)}_session_runtime_contract",
    }
    validator = validate_hostplan_executor(
        plan=plan,
        compile_root=resolve(args.compile_root),
        runtime_config=runtime_config,
        scheduler={"hostPlan": scheduler_record},
        manifest_preflight=manifest_preflight,
    )
    execution_plan = build_hostplan_execution_plan(
        plan=plan,
        compile_root=resolve(args.compile_root),
        runtime_config=runtime_config,
        scheduler={"hostPlan": scheduler_record},
        executor_validator=validator,
    )
    runtime_config["hostIoLayout"] = host_io_layout_from_buffer_plan(
        execution_plan.get("bufferPlan") or {}
    )
    runtime_config_path = session_dir / "runtime-config.json"
    execution_plan_path = session_dir / "hostplan-execution-plan.json"
    scheduler_path = session_dir / "runtime-scheduler.json"
    write_json(runtime_config_path, runtime_config)
    write_json(scheduler_path, scheduler)
    write_json(execution_plan_path, execution_plan)
    checkpoint_dir = optional_resolved_path(args, "checkpoint_dir")
    resume_dir = (
        optional_resolved_path(args, "resume_from_checkpoint")
        if not bool(getattr(args, "ignore_checkpoint", False))
        else None
    )
    result: dict[str, Any] = {
        "requested": bool(args.execute),
        "status": "planned",
        "sessionDir": rel(session_dir),
        "runtimeConfigPath": rel(runtime_config_path),
        "runtimeConfigSha256": sha256_file(runtime_config_path),
        "normalizedExecution": {
            "path": rel(Path(normalized["path"])),
            "sha256": normalized["sha256"],
        },
        "runtimeSchedulerPath": rel(scheduler_path),
        "executionPlanPath": rel(execution_plan_path),
        "weightMappingStatus": mappings["identity"],
        "hostIoLayoutCount": len(runtime_config["hostIoLayout"]),
        "schedulerStatus": scheduler.get("status"),
        "schedulerBlockers": scheduler.get("blockers") or [],
        "executorValidatorStatus": validator.get("status"),
        "executorValidatorBlockers": validator.get("blockers") or [],
        "executionPlanStatus": execution_plan.get("status"),
        "executionPlanBlockers": execution_plan.get("blockers") or [],
        "sampleFeedback": scheduler.get("sampleFeedback") or {},
        "checkpoint": {
            "checkpointDir": rel(checkpoint_dir) if checkpoint_dir else "",
            "resumeFromCheckpoint": rel(resume_dir) if resume_dir else "",
            "ignoreCheckpoint": bool(getattr(args, "ignore_checkpoint", False)),
            "allowRunnerVersionDrift": bool(
                getattr(args, "allow_checkpoint_runner_drift", False)
            ),
        },
    }
    blockers = [
        *[f"scheduler:{item}" for item in scheduler.get("blockers") or []],
        *[f"executor_validator:{item}" for item in validator.get("blockers") or []],
        *[f"execution_plan:{item}" for item in execution_plan.get("blockers") or []],
    ]
    if mappings["identity"]["missingWeightCount"]:
        blockers.append("runtime_weight_mappings_incomplete")
    if blockers:
        result["status"] = "blocked"
        result["blockers"] = blockers
        return result
    if not args.execute:
        result["status"] = "ready_not_executed"
        result["blockers"] = ["execution_not_requested"]
        return result

    progress_path = session_dir / "progress.jsonl"
    bootstrap = execute_hostplan_runtime_bootstrap(
        execution_plan=execution_plan,
        progress_path=progress_path,
        cmaddr=args.cmaddr.strip() or None,
    )
    result["bootstrap"] = bootstrap
    if bootstrap.get("status") != "ready_for_tensor_movement":
        result["status"] = "blocked"
        result["blockers"] = [
            f"bootstrap:{item}" for item in bootstrap.get("blockers") or ["unknown"]
        ]
        return result
    identity = compute_checkpoint_identity(
        plan=plan,
        plan_path=resolve(args.simulator_plan),
        runtime_config=runtime_config,
        runtime_config_path=runtime_config_path,
        export=reference,
        reference_export_path=session_dir / "reference-request.json",
        runner_version=session_runtime_source_sha256(),
    )
    result["checkpoint"]["identitySha256"] = sha256_json(identity)
    resume_state = None
    if resume_dir is not None:
        try:
            resume_state = load_checkpoint(
                checkpoint_dir=resume_dir,
                identity=identity,
                allow_runner_version_drift=bool(
                    getattr(args, "allow_checkpoint_runner_drift", False)
                ),
                allow_canonicalization_drift=bool(
                    getattr(
                        args,
                        "allow_checkpoint_canonicalization_drift",
                        False,
                    )
                ),
            )
            result["checkpoint"]["resumeStatus"] = "loaded"
            result["checkpoint"]["resumeStartIndex"] = resume_state.start_index
            result["checkpoint"]["resumeBufferCount"] = len(
                resume_state.buffer_files
            )
        except CheckpointMissingError:
            result["checkpoint"]["resumeStatus"] = "missing_treated_as_empty"
        except CheckpointError as exc:
            result["status"] = "blocked"
            result["blockers"] = [f"checkpoint:{getattr(exc, 'code', 'error')}"]
            result["checkpoint"]["resumeStatus"] = "rejected"
            result["checkpoint"]["resumeError"] = str(exc)
            return result
    if checkpoint_dir is not None:
        try:
            init_checkpoint(
                checkpoint_dir,
                identity,
                allow_runner_version_drift=bool(
                    getattr(args, "allow_checkpoint_runner_drift", False)
                ),
                allow_canonicalization_drift=bool(
                    getattr(
                        args,
                        "allow_checkpoint_canonicalization_drift",
                        False,
                    )
                ),
            )
            result["checkpoint"]["checkpointStatus"] = "initialized"
        except CheckpointError as exc:
            result["status"] = "blocked"
            result["blockers"] = [f"checkpoint:{getattr(exc, 'code', 'error')}"]
            result["checkpoint"]["checkpointStatus"] = "rejected"
            result["checkpoint"]["checkpointError"] = str(exc)
            return result
    runtime = execute_hostplan_runtime(
        bootstrap=bootstrap,
        export=reference,
        progress_path=progress_path,
        cmaddr=args.cmaddr.strip() or None,
        trace_path=session_dir / "trace.json",
        checkpoint_dir=checkpoint_dir,
        resume_state=resume_state,
        stop_after_launch=args.stop_after_launch,
        launch_timeout_seconds=getattr(
            args,
            "launch_timeout_seconds",
            DEFAULT_LAUNCH_TIMEOUT_SECONDS,
        ),
        session_lm_head_dispatch_mode=getattr(
            args,
            "session_lm_head_dispatch_mode",
            "monolithic",
        ),
        session_lm_head_tile_width=int(
            getattr(args, "session_lm_head_tile_width", 120)
        ),
        session_lm_head_tile_jobs=int(
            getattr(args, "session_lm_head_tile_jobs", 1)
        ),
        session_embed_roi_jobs=int(getattr(args, "session_embed_roi_jobs", 1)),
        session_embed_roi_hidden_per_pe=int(
            getattr(args, "session_embed_roi_hidden_per_pe", 0)
        ),
        session_prefill_q4k_gemv_jobs=int(
            getattr(args, "session_prefill_q4k_gemv_jobs", 1)
        ),
        session_prefill_q4k_gemv_output_pe_rows=int(
            getattr(args, "session_prefill_q4k_gemv_output_pe_rows", 1)
        ),
        session_prefill_q4k_gemv_adapter_step_budget=int(
            getattr(args, "session_prefill_q4k_gemv_adapter_step_budget", 1)
        ),
        session_ple_proj_dispatch_mode=str(
            getattr(args, "session_ple_proj_dispatch_mode", "monolithic_summa")
            or "monolithic_summa"
        ),
        session_attention_prefill_dispatch_mode=str(
            getattr(args, "session_attention_prefill_dispatch_mode", "hostplan_static")
            or "hostplan_static"
        ),
        session_lm_head_batch_runtime=bool(
            getattr(args, "session_lm_head_batch_runtime", False)
        ),
        session_lm_head_batch_runtime_step_budget=int(
            getattr(args, "session_lm_head_batch_runtime_step_budget", 16)
        ),
        session_lm_head_tile_dispatch_budget=int(
            getattr(args, "session_lm_head_tile_dispatch_budget", 0)
        ),
    )
    result["runtime"] = runtime
    runtime_status = str(runtime.get("status") or "")
    if runtime_status == "succeeded":
        result["status"] = "output_ready"
    elif runtime_status == "stopped_at_checkpoint":
        result["status"] = "checkpoint_stopped"
        result["blockers"] = ["execution_stopped_at_checkpoint"]
        result["checkpoint"] = {
            "stopAfterLaunch": int(args.stop_after_launch),
            "completedLaunchCount": len(runtime.get("launches") or []),
        }
    else:
        result["status"] = "blocked"
    if result["status"] == "blocked":
        runtime_blockers = runtime.get("blockers") or []
        if not runtime_blockers:
            runtime_blockers = [runtime_status or "unknown"]
        result["blockers"] = [
            f"runtime:{item}" for item in runtime_blockers
        ]
    elif result["status"] == "output_ready":
        transcript = build_runtime_transcript(
            session_dir=session_dir,
            runtime=runtime,
            execution_plan=execution_plan,
            requested_decode_steps=int(args.decode_token_count),
            artifact_prefix=session_artifact_prefix(args),
        )
        result["runtimeTranscriptPath"] = transcript["path"]
        result["runtimeTranscriptSha256"] = transcript["sha256"]
        result["runtimeTranscript"] = {
            key: transcript["payload"].get(key)
            for key in (
                "status",
                "requestedDecodeSteps",
                "actualDecodeSteps",
                "generatedTokenIds",
                "logitsDigests",
                "lmHeadDispatches",
                "kvCache",
            )
        }
        actual_steps = int(
            transcript["payload"].get("actualDecodeSteps") or 0
        )
        if actual_steps != int(args.decode_token_count):
            result["status"] = "blocked"
            result["blockers"] = [
                "runtime_transcript_decode_count_mismatch:"
                f"{actual_steps}!={int(args.decode_token_count)}"
            ]
    return result
