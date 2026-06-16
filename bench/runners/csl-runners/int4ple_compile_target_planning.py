"""Planning and bootstrap helpers for INT4 PLE compile-target runtime."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path
from typing import Any

from bench.tools.int4ple_manifest_compile_params import (
    manifest_compile_param_projection,
    runtime_grid,
)
from int4ple_compile_target_core import (
    PREFILL_Q4K_GEMV_PATTERN,
    PREFILL_Q4K_GEMV_SYMBOL_RESOLUTION_MODE,
    SCHEDULE_PREVIEW_COUNT,
    TARGET_SESSION_PROBE,
    append_progress,
    compile_target_coverage,
    compiled_target_params,
    cs_python_executable,
    load_json,
    require_minimum,
)
from int4ple_hostplan_execution_plan import build_hostplan_execution_plan
from int4ple_hostplan_executor_validator import validate_hostplan_executor
from int4ple_runtime_scheduler import (
    count_by,
    load_normalized_execution,
    resolve_artifact_path,
    sha256_json,
    synthesize_runtime_scheduler,
)


def host_plan_executor_preflight(
    *,
    compile_root: Path,
    runtime_config: dict[str, Any],
    reference: dict[str, Any],
) -> dict[str, Any]:
    """Fail closed before a full-model executor can promote smoke targets."""

    model = runtime_config.get("modelConfig") or {}
    if not isinstance(model, dict) or not model:
        return {
            "status": "not_evaluated",
            "blockers": ["model_config_missing"],
            "checks": [],
            "targetParams": {},
        }

    target_names = (
        "embed",
        "tiled",
        "lm_head_gemv",
        "lm_head_gemv",
        "lm_head_prefill",
        "attn_head256",
        "attn_head512",
        "sample",
    )
    target_params = {
        name: compiled_target_params(compile_root, name)
        for name in target_names
    }
    if not any(target_params.values()):
        return {
            "status": "not_evaluated",
            "blockers": ["compiled_target_params_unavailable"],
            "checks": [],
            "targetParams": target_params,
        }

    blockers: list[str] = []
    checks: list[dict[str, Any]] = []
    vocab_size = int(model.get("vocabSize") or model.get("pleVocabSize") or 0)
    hidden_dim = int(model.get("hiddenDim") or 0)
    prompt_tokens = int(reference.get("promptTokenCount") or 0)

    embed = target_params.get("embed") or {}
    if embed:
        embed_rows = (
            int(embed.get("width") or 0)
            * int(embed.get("height") or 0)
            * int(embed.get("rows_per_pe") or 0)
        )
        require_minimum(
            blockers=blockers,
            checks=checks,
            check_id="embed_vocab_row_coverage",
            actual=embed_rows,
            minimum=vocab_size,
        )
        require_minimum(
            blockers=blockers,
            checks=checks,
            check_id="embed_prompt_token_capacity",
            actual=int(embed.get("num_tokens") or 0),
            minimum=prompt_tokens,
        )
    else:
        blockers.append("embed_target_params_missing")

    tiled = target_params.get("tiled") or {}
    if tiled:
        tile_m = int(tiled.get("Mt") or 0) * int(tiled.get("P") or 0)
        tile_n = int(tiled.get("Nt") or 0) * int(tiled.get("P") or 0)
        require_minimum(
            blockers=blockers,
            checks=checks,
            check_id="tiled_m_dimension_coverage",
            actual=tile_m,
            minimum=hidden_dim,
        )
        require_minimum(
            blockers=blockers,
            checks=checks,
            check_id="tiled_n_dimension_coverage",
            actual=tile_n,
            minimum=hidden_dim,
        )
    else:
        blockers.append("tiled_target_params_missing")

    global_head_dim = int(model.get("globalHeadDim") or 0)
    for target_name in ("attn_head256", "attn_head512"):
        params = target_params.get(target_name) or {}
        if not params:
            if target_name == "attn_head512" and global_head_dim <= 0:
                continue
            blockers.append(f"{target_name}_target_params_missing")
            continue
        require_minimum(
            blockers=blockers,
            checks=checks,
            check_id=f"{target_name}_prefill_q_len_coverage",
            actual=int(params.get("q_len") or 0),
            minimum=prompt_tokens,
        )
        require_minimum(
            blockers=blockers,
            checks=checks,
            check_id=f"{target_name}_prefill_kv_len_coverage",
            actual=int(params.get("kv_len") or 0),
            minimum=prompt_tokens,
        )

    lm_head = (
        target_params.get("lm_head_gemv")
        or target_params.get("lm_head_gemv")
        or target_params.get("lm_head_prefill")
        or {}
    )
    if lm_head:
        if "out_dim_per_pe" in lm_head:
            logits_coverage = int(lm_head.get("height") or 0) * int(
                lm_head.get("out_dim_per_pe") or 0
            )
        elif "out_dim" in lm_head:
            logits_coverage = int(lm_head.get("width") or 0) * int(
                lm_head.get("out_dim") or 0
            )
        else:
            logits_coverage = int(lm_head.get("P") or 0) * int(
                lm_head.get("Nt") or 0
            )
        require_minimum(
            blockers=blockers,
            checks=checks,
            check_id="lm_head_vocab_logit_coverage",
            actual=logits_coverage,
            minimum=vocab_size,
        )
    else:
        blockers.append("lm_head_target_params_missing")

    sample = target_params.get("sample") or {}
    if sample:
        sample_coverage = int(sample.get("width") or 0) * int(
            sample.get("chunk_size") or 0
        )
        require_minimum(
            blockers=blockers,
            checks=checks,
            check_id="sample_vocab_logit_coverage",
            actual=sample_coverage,
            minimum=vocab_size,
        )
    else:
        blockers.append("sample_target_params_missing")

    return {
        "status": "passed" if not blockers else "failed",
        "blockers": blockers,
        "checks": checks,
        "targetParams": target_params,
        "manifestCompileParamProjection": manifest_compile_param_projection(
            runtime_config=runtime_config,
            reference=reference,
        ),
    }


def host_plan_phase_summary(
    host_plan_path: Path,
    *,
    runtime_config: dict[str, Any] | None = None,
    normalized_execution: dict[str, Any] | None = None,
    reference: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if not host_plan_path.is_file():
        return {
            "path": str(host_plan_path),
            "present": False,
            "phaseLaunchCounts": {},
            "phaseInvocationCounts": {},
            "kernelLaunchCounts": {},
            "kernelInvocationCounts": {},
            "launchesCarrySymbolDataflow": False,
            "launchSchedule": {
                "schemaVersion": 1,
                "artifactKind": "int4ple_hostplan_launch_schedule",
                "status": "missing_host_plan",
                "launchDescriptorCount": 0,
                "scheduledInvocationCount": 0,
                "launches": [],
                "scheduleSha256": sha256_json([]),
            },
        }
    host_plan = load_json(host_plan_path)
    phases = (host_plan.get("hostPlan") or {}).get("phases") or {}
    phase_counts: dict[str, int] = {}
    phase_invocation_counts: dict[str, int] = {}
    launches: list[dict[str, Any]] = []
    if isinstance(phases, dict):
        phase_names = [
            name for name in ("prefill", "decode") if name in phases
        ] + sorted(
            str(name) for name in phases.keys() if name not in ("prefill", "decode")
        )
        for phase_name in phase_names:
            raw_steps = phases[phase_name]
            steps = raw_steps if isinstance(raw_steps, list) else []
            phase_counts[str(phase_name)] = len(steps)
            phase_invocation_counts[str(phase_name)] = sum(
                max(1, int(step.get("repeat") or 1))
                for step in steps
                if isinstance(step, dict)
            )
            launches.extend(
                {
                    **step,
                    "_phase": str(phase_name),
                    "_phaseIndex": index,
                }
                for index, step in enumerate(steps)
                if isinstance(step, dict)
            )
    kernels = (host_plan.get("hostPlan") or {}).get("kernels") or []
    kernel_patterns = {
        str(item.get("name")): str(item.get("pattern", "unknown"))
        for item in kernels
        if isinstance(item, dict) and item.get("name")
    }
    declared_kernel_counts = {
        str(item.get("name")): int(item.get("count") or 0)
        for item in kernels
        if isinstance(item, dict) and item.get("name")
    }
    schedule_records: list[dict[str, Any]] = []
    kernel_invocation_counts: dict[str, int] = {}
    for launch_index, step in enumerate(launches):
        kernel_name = str(step.get("kernelName") or step.get("name") or "unknown")
        repeat = max(1, int(step.get("repeat") or 1))
        inputs = step.get("inputs")
        outputs = step.get("outputs")
        symbols = step.get("symbols")
        symbol_dataflow_present = (
            isinstance(inputs, list)
            or isinstance(outputs, list)
            or isinstance(symbols, dict)
        )
        kernel_invocation_counts[kernel_name] = (
            kernel_invocation_counts.get(kernel_name, 0) + repeat
        )
        schedule_records.append(
            {
                "launchIndex": launch_index,
                "phase": step["_phase"],
                "phaseLaunchIndex": int(step["_phaseIndex"]),
                "kernelName": kernel_name,
                "kernelPattern": kernel_patterns.get(kernel_name, "unknown"),
                "repeat": repeat,
                "symbolDataflowPresent": symbol_dataflow_present,
                "inputSymbolCount": len(inputs) if isinstance(inputs, list) else 0,
                "outputSymbolCount": len(outputs) if isinstance(outputs, list) else 0,
                "symbolTablePresent": isinstance(symbols, dict),
            }
        )
    runtime_scheduler = synthesize_runtime_scheduler(
        launches=[
            {
                **step,
                "launchIndex": index,
                "phase": step["_phase"],
                "phaseLaunchIndex": int(step["_phaseIndex"]),
                "kernelName": str(step.get("kernelName") or step.get("name") or "unknown"),
                "kernelPattern": kernel_patterns.get(
                    str(step.get("kernelName") or step.get("name") or "unknown"),
                    "unknown",
                ),
                "repeat": max(1, int(step.get("repeat") or 1)),
            }
            for index, step in enumerate(launches)
        ],
        runtime_config=runtime_config,
        normalized_execution=normalized_execution,
        reference=reference,
    )
    if runtime_scheduler.get("status") == "bound":
        schedule_records = runtime_scheduler.get("launches") or schedule_records
    launches_with_dataflow = sum(
        1 for record in schedule_records if record["symbolDataflowPresent"]
    )
    all_launches_carry_dataflow = bool(schedule_records) and (
        launches_with_dataflow == len(schedule_records)
    )
    scheduled_invocation_count = sum(record["repeat"] for record in schedule_records)
    schedule_status = (
        "symbol_dataflow_bound"
        if all_launches_carry_dataflow
        else "blocked_missing_symbol_dataflow"
    )
    schedule = {
        "schemaVersion": 1,
        "artifactKind": "int4ple_hostplan_launch_schedule",
        "status": schedule_status,
        "launchDescriptorCount": len(schedule_records),
        "scheduledInvocationCount": scheduled_invocation_count,
        "phaseDescriptorCounts": phase_counts,
        "phaseInvocationCounts": phase_invocation_counts,
        "kernelDescriptorCounts": count_by(schedule_records, "kernelName"),
        "kernelInvocationCounts": dict(sorted(kernel_invocation_counts.items())),
        "launchesWithSymbolDataflowCount": launches_with_dataflow,
        "allLaunchesCarrySymbolDataflow": all_launches_carry_dataflow,
        "launches": schedule_records,
    }
    schedule["scheduleSha256"] = sha256_json(schedule_records)
    return {
        "path": str(host_plan_path),
        "present": True,
        "phaseLaunchCounts": phase_counts,
        "phaseInvocationCounts": phase_invocation_counts,
        "kernelLaunchCounts": dict(sorted(declared_kernel_counts.items())),
        "kernelInvocationCounts": dict(sorted(kernel_invocation_counts.items())),
        "launchesCarrySymbolDataflow": all_launches_carry_dataflow,
        "firstLaunches": schedule_records[:SCHEDULE_PREVIEW_COUNT],
        "lastLaunches": schedule_records[-SCHEDULE_PREVIEW_COUNT:],
        "launchSchedule": schedule,
        "runtimeScheduler": runtime_scheduler,
    }


def runtime_input_summary(runtime_config: dict[str, Any]) -> dict[str, Any]:
    weight_mappings = runtime_config.get("weightMappings") or []
    state_buffers = runtime_config.get("stateBuffers") or []
    host_io_layout = runtime_config.get("hostIoLayout") or []
    if not isinstance(weight_mappings, list):
        weight_mappings = []
    if not isinstance(state_buffers, list):
        state_buffers = []
    if not isinstance(host_io_layout, list):
        host_io_layout = []
    synthetic_host_entries = [
        entry
        for entry in host_io_layout
        if isinstance(entry, dict)
        and isinstance(entry.get("sourceIdentity"), dict)
        and entry["sourceIdentity"].get("synthetic") is True
    ]
    weight_identity = runtime_config.get("weightIdentity") or {}
    return {
        "weightMappingCount": len(weight_mappings),
        "requiredWeightCount": int(weight_identity.get("requiredWeightCount") or 0),
        "missingWeightCount": int(weight_identity.get("missingWeightCount") or 0),
        "stateBufferKinds": sorted(
            str(item.get("kind"))
            for item in state_buffers
            if isinstance(item, dict) and item.get("kind")
        ),
        "hostIoRoleCounts": count_by(
            [entry for entry in host_io_layout if isinstance(entry, dict)],
            "bufferRole",
        ),
        "syntheticHostEntryCount": len(synthetic_host_entries),
    }


def reference_transcript_summary(
    export: dict[str, Any],
    reference_export_path: Path,
) -> dict[str, Any]:
    transcript = export.get("decodeTranscript") or {}
    generated = transcript.get("generatedTokenIds") or {}
    logits = transcript.get("logitsDigests") or []
    transcript_payload: dict[str, Any] = {}
    transcript_link = transcript.get("transcript") or {}
    linked_path = transcript_link.get("path")
    if isinstance(linked_path, str) and linked_path:
        candidate = resolve_artifact_path(reference_export_path, linked_path)
        if candidate.is_file():
            transcript_payload = load_json(candidate)
    kv_cache = transcript_payload.get("kvCache") or {}
    return {
        "status": transcript.get("status", "pending"),
        "requestedDecodeSteps": int(transcript.get("requestedDecodeSteps") or 0),
        "actualDecodeSteps": int(transcript.get("actualDecodeSteps") or 0),
        "stopReason": transcript.get("stopReason", "pending"),
        "generatedTokenCount": int(generated.get("tokenCount") or 0),
        "logitsDigestCount": len(logits) if isinstance(logits, list) else 0,
        "promptTokenCount": int((export.get("inputSetComponents") or {}).get("tokenCount") or 0),
        "kvCacheMode": kv_cache.get("mode", "not_captured"),
        "kvLayerDigestCount": int(kv_cache.get("layerDigestCount") or 0),
    }


def scheduler_readiness(
    *,
    plan_path: Path,
    plan: dict[str, Any],
    runtime_config: dict[str, Any],
    export: dict[str, Any],
    reference_export_path: Path,
    compile_root: Path,
) -> dict[str, Any]:
    compile_targets = compile_target_coverage(plan, compile_root)
    runtime_inputs = runtime_input_summary(runtime_config)
    reference = reference_transcript_summary(export, reference_export_path)
    normalized_execution = load_normalized_execution(plan_path)
    host_plan = host_plan_phase_summary(
        plan_path.parent / "host-plan.json",
        runtime_config=runtime_config,
        normalized_execution=normalized_execution,
        reference=reference,
    )
    runtime_scheduler = host_plan.get("runtimeScheduler") or {}
    activation = runtime_scheduler.get("activationRouting") or {}
    kv_schedule = runtime_scheduler.get("kvCacheSchedule") or {}
    transcript = runtime_scheduler.get("transcriptCaptureSchedule") or {}
    executor_preflight = host_plan_executor_preflight(
        compile_root=compile_root,
        runtime_config=runtime_config,
        reference=reference,
    )
    executor_validator = validate_hostplan_executor(
        plan=plan,
        compile_root=compile_root,
        runtime_config=runtime_config,
        scheduler={"hostPlan": host_plan},
        manifest_preflight=executor_preflight,
    )
    execution_plan = build_hostplan_execution_plan(
        plan=plan,
        compile_root=compile_root,
        runtime_config=runtime_config,
        scheduler={"hostPlan": host_plan},
        executor_validator=executor_validator,
    )
    expected_runtime = plan.get("runtime") or {}
    readiness = {
        "phaseLaunchesMaterialized": bool(host_plan.get("phaseLaunchCounts")),
        "compileTargetsReady": compile_targets["allSourcesReady"]
        and compile_targets["allCompiledTargetsReady"],
        "weightMappingsReady": runtime_inputs["weightMappingCount"] > 0
        and runtime_inputs["missingWeightCount"] == 0,
        "stateBuffersDeclared": "kv_cache" in runtime_inputs["stateBufferKinds"],
        "referenceTranscriptReady": reference["status"] == "output_ready"
        and reference["actualDecodeSteps"] > 0
        and reference["generatedTokenCount"] == reference["actualDecodeSteps"]
        and reference["logitsDigestCount"] == reference["actualDecodeSteps"],
        "kvReferenceReady": reference["kvLayerDigestCount"] > 0,
        "launchesCarrySymbolDataflow": bool(host_plan["launchesCarrySymbolDataflow"]),
        "activationRoutingBound": activation.get("status") == "bound",
        "kvReadWriteScheduleBound": kv_schedule.get("status") == "bound",
        "transcriptEmittersBound": transcript.get("status") == "bound",
        "manifestShapePreflightPassed": executor_preflight.get("status") == "passed",
        "hostPlanExecutorValidatorPassed": executor_validator.get("status") == "passed",
        "hostPlanExecutionPlanReady": execution_plan.get("status") == "planned",
        "fullModelRuntimeExecutorBound": False,
    }
    blockers: list[str] = []
    if not readiness["compileTargetsReady"]:
        blockers.append("compiled_csl_targets_not_ready")
    if not readiness["weightMappingsReady"]:
        blockers.append("runtime_weight_mappings_incomplete")
    if not readiness["referenceTranscriptReady"]:
        blockers.append("doppler_reference_transcript_incomplete")
    if not readiness["kvReferenceReady"]:
        blockers.append("doppler_kv_reference_digest_missing")
    if not readiness["launchesCarrySymbolDataflow"]:
        blockers.append("hostplan_launches_lack_symbol_dataflow_bindings")
    if not readiness["activationRoutingBound"]:
        blockers.append("activation_tensor_lifetime_schedule_missing")
    if not readiness["kvReadWriteScheduleBound"]:
        blockers.append("kv_cache_write_read_schedule_missing")
    if not readiness["transcriptEmittersBound"]:
        blockers.append("logits_and_sample_output_capture_schedule_missing")
    metadata_ready = not blockers
    if metadata_ready and executor_preflight.get("status") == "failed":
        blockers.append("manifest_shape_preflight_failed")
    if metadata_ready and not readiness["hostPlanExecutorValidatorPassed"]:
        blockers.append("hostplan_executor_validator_not_passed")
    elif metadata_ready and not readiness["hostPlanExecutionPlanReady"]:
        blockers.append("hostplan_execution_plan_not_ready")
    elif metadata_ready:
        blockers.append("full_model_prefill_decode_runtime_executor_missing")
    status = (
        "blocked_missing_full_model_runtime_execution"
        if metadata_ready
        and readiness["hostPlanExecutorValidatorPassed"]
        and readiness["hostPlanExecutionPlanReady"]
        else "blocked_missing_runtime_scheduler"
    )
    return {
        "status": status,
        "readiness": readiness,
        "blockers": blockers,
        "expectedRuntime": {
            "prefillLaunchCount": int(expected_runtime.get("prefillLaunchCount") or 0),
            "decodeLaunchCount": int(expected_runtime.get("decodeLaunchCount") or 0),
            "maxDecodeTokens": expected_runtime.get("maxDecodeTokens"),
            "weightMappingCount": expected_runtime.get("weightMappingCount"),
            "stateBufferCount": expected_runtime.get("stateBufferCount"),
        },
        "hostPlan": host_plan,
        "compileTargetCoverage": compile_targets,
        "runtimeInputs": runtime_inputs,
        "referenceTranscript": reference,
        "hostPlanExecutor": {
            "status": "blocked",
            "fullModelRuntimeExecutorBound": False,
            "manifestShapePreflight": executor_preflight,
            "executorValidator": executor_validator,
            "executionPlan": execution_plan,
        },
        "nextRuntimeStep": (
            "stage runtime weight/input buffers onto the concrete HostPlan "
            "execution plan, execute the launch chain, and emit the bounded "
            "logit/token/KV transcript"
        ),
    }


def _probe_target_session_command(
    *,
    target_session: dict[str, Any],
    receipt_path: Path,
    cmaddr: str | None,
) -> list[str]:
    command = [
        cs_python_executable(),
        str(TARGET_SESSION_PROBE),
        "--compile-dir",
        str(target_session.get("compileDir") or ""),
        "--launch-fn",
        str(target_session.get("launchFunction") or "compute"),
        "--receipt-out",
        str(receipt_path),
    ]
    required_symbols = sorted(
        {
            str(symbol)
            for symbol in (
                (target_session.get("requiredInputSymbols") or [])
                + (target_session.get("requiredOutputSymbols") or [])
            )
            if isinstance(symbol, str) and symbol
        }
    )
    for symbol in required_symbols:
        command.extend(["--symbol", symbol])
    if cmaddr is not None:
        command.extend(["--cmaddr", cmaddr])
    return command


def probe_target_session(
    *,
    target_session: dict[str, Any],
    progress_path: Path,
    cmaddr: str | None,
) -> dict[str, Any]:
    target_name = str(target_session.get("targetName") or "unknown")
    if not TARGET_SESSION_PROBE.is_file():
        return {
            "schemaVersion": 1,
            "artifactKind": "int4ple_target_session_probe",
            "status": "blocked",
            "targetName": target_name,
            "compileDir": str(target_session.get("compileDir") or ""),
            "launchFunction": str(target_session.get("launchFunction") or "compute"),
            "resolvedSymbols": {},
            "blockers": [f"target_session_probe_missing:{TARGET_SESSION_PROBE}"],
        }

    with tempfile.TemporaryDirectory(prefix="int4ple-session-probe-") as tmpdir:
        receipt_path = Path(tmpdir) / f"{target_name}-probe.json"
        required_symbol_count = len(
            {
                str(symbol)
                for symbol in (
                    (target_session.get("requiredInputSymbols") or [])
                    + (target_session.get("requiredOutputSymbols") or [])
                )
                if isinstance(symbol, str) and symbol
            }
        )
        command = _probe_target_session_command(
            target_session=target_session,
            receipt_path=receipt_path,
            cmaddr=cmaddr,
        )
        append_progress(
            progress_path,
            "hostplan_target_session_probe_start",
            target=target_name,
            symbolCount=required_symbol_count,
            compileDir=str(target_session.get("compileDir") or ""),
        )
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
        if receipt_path.is_file():
            receipt = load_json(receipt_path)
        else:
            receipt = {
                "schemaVersion": 1,
                "artifactKind": "int4ple_target_session_probe",
                "status": "blocked",
                "targetName": target_name,
                "compileDir": str(target_session.get("compileDir") or ""),
                "launchFunction": str(target_session.get("launchFunction") or "compute"),
                "resolvedSymbols": {},
                "blockers": ["target_session_probe_receipt_missing"],
            }
        receipt.setdefault("targetName", target_name)
        receipt.setdefault("compileDir", str(target_session.get("compileDir") or ""))
        receipt.setdefault(
            "launchFunction",
            str(target_session.get("launchFunction") or "compute"),
        )
        blockers = list(receipt.get("blockers") or [])
        if completed.returncode != 0 and "target_session_probe_return_code" not in blockers:
            blockers.append(f"target_session_probe_return_code:{completed.returncode}")
        receipt["blockers"] = blockers
        if blockers:
            receipt["status"] = "blocked"
        if completed.stdout.strip():
            receipt["stdout"] = completed.stdout.strip().splitlines()[-1]
        if completed.stderr.strip():
            receipt["stderr"] = completed.stderr.strip().splitlines()[-1]
        append_progress(
            progress_path,
            "hostplan_target_session_probe_complete",
            target=target_name,
            status=receipt.get("status"),
            blockers=receipt.get("blockers"),
        )
        return receipt


def _is_prefill_q4k_gemv_plan_launch(launch: dict[str, Any]) -> bool:
    return str(launch.get("kernelPattern") or "") == PREFILL_Q4K_GEMV_PATTERN


def _prefill_q4k_gemv_target_session_receipt(
    target_session: dict[str, Any],
) -> dict[str, Any]:
    target_name = str(target_session.get("targetName") or "unknown")
    return {
        "schemaVersion": 1,
        "artifactKind": "int4ple_target_session_probe",
        "status": "resolved",
        "targetName": target_name,
        "compileDir": str(target_session.get("compileDir") or ""),
        "layoutPath": str(target_session.get("layoutPath") or ""),
        "launchFunction": str(target_session.get("launchFunction") or "compute"),
        "resolvedSymbols": {},
        "resolutionMode": PREFILL_Q4K_GEMV_SYMBOL_RESOLUTION_MODE,
        "blockers": [],
    }


def execute_hostplan_runtime_bootstrap(
    *,
    execution_plan: dict[str, Any],
    progress_path: Path,
    cmaddr: str | None,
    probe_session: Any | None = None,
) -> dict[str, Any]:
    probe_fn = probe_target_session if probe_session is None else probe_session
    blockers: list[str] = []
    target_sessions = execution_plan.get("targetSessions") or []
    launches = execution_plan.get("launches") or []
    if not isinstance(target_sessions, list) or not target_sessions:
        blockers.append("execution_plan_target_sessions_missing")
        target_sessions = []
    if not isinstance(launches, list) or not launches:
        blockers.append("execution_plan_launches_missing")
        launches = []

    append_progress(
        progress_path,
        "hostplan_executor_bootstrap_start",
        targetSessionCount=len(target_sessions),
        launchCount=len(launches),
    )

    launches_by_target: dict[str, list[dict[str, Any]]] = {}
    for launch in launches:
        if isinstance(launch, dict):
            target_name = str(launch.get("targetName") or "")
            launches_by_target.setdefault(target_name, []).append(launch)

    resolved_by_target: dict[str, dict[str, Any]] = {}
    runtime_symbol_targets: set[str] = set()
    target_receipts: list[dict[str, Any]] = []
    for target_session in target_sessions:
        if not isinstance(target_session, dict):
            blockers.append("target_session_not_object")
            continue
        target_name = str(target_session.get("targetName") or "unknown")
        target_launches = launches_by_target.get(target_name) or []
        if target_launches and all(
            _is_prefill_q4k_gemv_plan_launch(launch) for launch in target_launches
        ):
            receipt = _prefill_q4k_gemv_target_session_receipt(target_session)
            target_receipts.append(receipt)
            resolved_by_target[target_name] = {}
            runtime_symbol_targets.add(target_name)
            append_progress(
                progress_path,
                "hostplan_target_session_probe_skipped",
                target=target_name,
                resolutionMode=PREFILL_Q4K_GEMV_SYMBOL_RESOLUTION_MODE,
                launchCount=len(target_launches),
            )
            continue
        receipt = probe_fn(
            target_session=target_session,
            progress_path=progress_path,
            cmaddr=cmaddr,
        )
        target_receipts.append(receipt)
        if receipt.get("status") != "resolved":
            blockers.append(f"target_session_not_resolved:{target_name}")
            for blocker in receipt.get("blockers") or []:
                blockers.append(f"target[{target_name}]:{blocker}")
            continue
        resolved_symbols = receipt.get("resolvedSymbols") or {}
        if not isinstance(resolved_symbols, dict) or not resolved_symbols:
            blockers.append(f"target[{target_name}].resolved_symbols_missing")
            continue
        resolved_by_target[target_name] = resolved_symbols

    launch_receipts: list[dict[str, Any]] = []
    resolved_launch_count = 0
    for launch in launches:
        if not isinstance(launch, dict):
            blockers.append("launch_not_object")
            continue
        target_name = str(launch.get("targetName") or "")
        launch_index = int(launch.get("launchIndex") or len(launch_receipts))
        launch_blockers: list[str] = []
        target_symbols = resolved_by_target.get(target_name) or {}
        resolved_inputs: list[dict[str, Any]] = []
        resolved_outputs: list[dict[str, Any]] = []
        runtime_symbol_launch = (
            target_name in runtime_symbol_targets
            and _is_prefill_q4k_gemv_plan_launch(launch)
        )

        for side, source_items, resolved_items in (
            ("input", launch.get("inputBindings") or [], resolved_inputs),
            ("output", launch.get("outputBindings") or [], resolved_outputs),
        ):
            for item in source_items:
                if not isinstance(item, dict):
                    launch_blockers.append(f"launch[{launch_index}].{side}_binding_not_object")
                    continue
                symbol = str(item.get("symbol") or "")
                symbol_id = target_symbols.get(symbol)
                if symbol_id is None and not runtime_symbol_launch:
                    launch_blockers.append(
                        f"launch[{launch_index}].{side}_symbol_id_missing:{target_name}.{symbol}"
                    )
                resolved_item = {**item, "symbolId": symbol_id}
                if symbol_id is None and runtime_symbol_launch:
                    resolved_item["symbolResolutionMode"] = (
                        PREFILL_Q4K_GEMV_SYMBOL_RESOLUTION_MODE
                    )
                resolved_items.append(resolved_item)

        launch_status = "resolved" if not launch_blockers else "blocked"
        if launch_status == "resolved":
            resolved_launch_count += 1
        blockers.extend(launch_blockers)
        launch_receipts.append(
            {
                "launchIndex": launch_index,
                "targetName": target_name,
                "compileDir": launch.get("compileDir"),
                "compileParams": launch.get("compileParams") or {},
                "kernelPattern": launch.get("kernelPattern"),
                "layoutPath": launch.get("layoutPath"),
                "launchFunction": launch.get("launchFunction"),
                "targetGeometry": launch.get("targetGeometry") or {},
                "phase": launch.get("phase"),
                "decodeStepIndex": launch.get("decodeStepIndex"),
                "status": launch_status,
                "resolvedInputs": resolved_inputs,
                "resolvedOutputs": resolved_outputs,
                "runtimeActions": launch.get("runtimeActions") or [],
                "blockers": launch_blockers,
            }
        )

    status = "ready_for_tensor_movement" if not blockers else "blocked"
    receipt = {
        "schemaVersion": 1,
        "artifactKind": "int4ple_hostplan_executor_runtime_bootstrap",
        "status": status,
        "blockers": blockers,
        "cmaddrProvided": cmaddr is not None,
        "targetSessionCount": len(target_sessions),
        "targetSessionsLoadedCount": len(resolved_by_target),
        "launchCount": len(launches),
        "resolvedLaunchCount": resolved_launch_count,
        "targetSessions": target_receipts,
        "launches": launch_receipts,
        "bufferPlan": execution_plan.get("bufferPlan") or {},
        "nextAction": (
            "stage runtime weights and prompt/state buffers, execute each launch, "
            "and capture the bounded logit/token/KV transcript"
        ),
    }
    append_progress(
        progress_path,
        "hostplan_executor_bootstrap_complete",
        status=status,
        blockers=blockers,
        resolvedLaunchCount=resolved_launch_count,
    )
    return receipt
