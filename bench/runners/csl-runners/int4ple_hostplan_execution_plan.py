#!/usr/bin/env python3
"""Build a concrete multi-target runtime execution plan for INT4 PLE HostPlans."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from int4ple_binding_metadata import (
    binding_metadata_by_symbol,
    compile_params_from_target,
    pe_arrays_from_metadata,
    target_phase,
)
from int4ple_hostplan_execution_buffers import (
    _buffer_plan,
    _compile_params,
    _target_grid,
)
from int4ple_hostplan_execution_common import (
    PREFILL_Q4K_GEMV_PATTERN,
    _compile_dir,
    _layout_path,
    _load_targets_metadata,
    _parse_layout_exports,
    _parse_pe_program_arrays,
    _pe_program_path,
    _resolve_phase_variant_target,
    _runtime_scheduler,
    _target_by_name,
    _target_pattern,
)
from int4ple_hostplan_execution_materialization import (
    _binding_materialization,
    _buffers_by_launch,
    _choose_launch_function,
    _target_geometry,
)


def build_hostplan_execution_plan(
    *,
    plan: dict[str, Any],
    compile_root: Path,
    runtime_config: dict[str, Any],
    scheduler: dict[str, Any],
    executor_validator: dict[str, Any],
) -> dict[str, Any]:
    runtime_scheduler = _runtime_scheduler(scheduler)
    launches = runtime_scheduler.get("launches") or []
    blockers: list[str] = []

    if executor_validator.get("status") != "passed":
        blockers.append(
            f"executor_validator_not_passed:{executor_validator.get('status')}"
        )
    if runtime_scheduler.get("status") != "bound":
        blockers.append(f"runtime_scheduler_not_bound:{runtime_scheduler.get('status')}")
    if not isinstance(launches, list) or not launches:
        blockers.append("runtime_scheduler_launches_missing")
        launches = []

    targets = _target_by_name(plan)
    kv_by_launch = _buffers_by_launch(
        (runtime_scheduler.get("kvCacheSchedule") or {}).get("operations") or [],
        "launchIndex",
    )
    emitters_by_launch = _buffers_by_launch(
        (runtime_scheduler.get("transcriptCaptureSchedule") or {}).get("emitters") or [],
        "launchIndex",
    )

    targets_metadata = _load_targets_metadata(compile_root)
    target_sessions: dict[str, dict[str, Any]] = {}
    launch_records: list[dict[str, Any]] = []

    for launch in launches:
        if not isinstance(launch, dict):
            continue
        launch_index = int(launch.get("launchIndex") or len(launch_records))
        base_kernel_name = str(launch.get("kernelName") or "")
        target_name = _resolve_phase_variant_target(
            kernel_name=base_kernel_name,
            phase=str(launch.get("phase") or ""),
            available_targets=targets,
            launch_index=launch_index,
            blockers=blockers,
            targets_metadata=targets_metadata,
        )
        if target_name is None:
            continue
        target = targets.get(target_name)
        if target is None:
            blockers.append(f"launch[{launch_index}].target_missing:{target_name}")
            continue
        layout_path = _layout_path(compile_root, target)
        compile_dir = _compile_dir(compile_root, target_name)
        pe_program_path = _pe_program_path(compile_root, target)
        compile_params = _compile_params(compile_dir)
        compile_params.update(compile_params_from_target(target))
        target_pattern = _target_pattern(target) or str(launch.get("kernelPattern") or "")
        binding_metadata = binding_metadata_by_symbol(target)
        target_phase_name = target_phase(target)
        if binding_metadata:
            variable_exports = set(binding_metadata)
            function_exports = {"compute"}
            pe_program_arrays = pe_arrays_from_metadata(binding_metadata)
            pe_program_compile_time = {}
        else:
            exports = _parse_layout_exports(layout_path)
            pe_program_arrays, pe_program_compile_time = _parse_pe_program_arrays(
                pe_program_path
            )
            variable_exports = {
                str(item["name"])
                for item in exports
                if item.get("kind") == "device_variable"
            }
            function_exports = {
                str(item["name"])
                for item in exports
                if item.get("kind") == "device_function"
            }
        launch_function = _choose_launch_function(function_exports)
        target_geometry = _target_geometry(target_name, compile_params, runtime_config)
        if not variable_exports:
            blockers.append(f"target[{target_name}].layout_exports_missing")
        if launch_function == "pending_runtime_function_resolution":
            blockers.append(f"target[{target_name}].launch_function_unresolved")

        if target_name not in target_sessions:
            target_sessions[target_name] = {
                "targetName": target_name,
                "compileDir": str(compile_dir),
                "compileParams": compile_params,
                "layoutPath": str(layout_path),
                "launchFunction": launch_function,
                "targetGeometry": target_geometry,
                "exportedVariables": sorted(variable_exports),
                "exportedFunctions": sorted(function_exports),
                "grid": target_geometry,
                "launchCount": 0,
                "requiredInputSymbols": set(),
                "requiredOutputSymbols": set(),
            }
        session = target_sessions[target_name]
        session["launchCount"] += 1

        inputs = launch.get("inputs") or []
        outputs = launch.get("outputs") or []
        input_bindings: list[dict[str, Any]] = []
        output_bindings: list[dict[str, Any]] = []
        for item in inputs:
            if not isinstance(item, dict):
                continue
            symbol = str(item.get("symbol") or "")
            if symbol not in variable_exports:
                blockers.append(
                    f"launch[{launch_index}].input_symbol_not_exported:{target_name}.{symbol}"
                )
            session["requiredInputSymbols"].add(symbol)
            input_bindings.append(
                {
                    "symbol": symbol,
                    "buffer": item.get("buffer"),
                    "role": item.get("role"),
                    "access": item.get("access"),
                    "materialization": _binding_materialization(
                        item=item,
                        target_name=target_name,
                        target_pattern=target_pattern,
                        compile_params=compile_params,
                        pe_program_arrays=pe_program_arrays,
                        pe_program_compile_time=pe_program_compile_time,
                        target_geometry=target_geometry,
                        runtime_config=runtime_config,
                        binding_metadata=binding_metadata.get(symbol),
                        target_phase_name=target_phase_name,
                    ),
                }
            )
        for item in outputs:
            if not isinstance(item, dict):
                continue
            symbol = str(item.get("symbol") or "")
            if symbol not in variable_exports:
                blockers.append(
                    f"launch[{launch_index}].output_symbol_not_exported:{target_name}.{symbol}"
                )
            session["requiredOutputSymbols"].add(symbol)
            output_bindings.append(
                {
                    "symbol": symbol,
                    "buffer": item.get("buffer"),
                    "role": item.get("role"),
                    "access": item.get("access"),
                    "materialization": _binding_materialization(
                        item=item,
                        target_name=target_name,
                        target_pattern=target_pattern,
                        compile_params=compile_params,
                        pe_program_arrays=pe_program_arrays,
                        pe_program_compile_time=pe_program_compile_time,
                        target_geometry=target_geometry,
                        runtime_config=runtime_config,
                        binding_metadata=binding_metadata.get(symbol),
                        target_phase_name=target_phase_name,
                    ),
                }
            )

        kv_ops = kv_by_launch.get(launch_index, [])
        emitters = emitters_by_launch.get(launch_index, [])
        launch_records.append(
            {
                "launchIndex": launch_index,
                "hostPlanLaunchIndex": launch.get("hostPlanLaunchIndex"),
                "runtimeLaunchIndex": launch.get("runtimeLaunchIndex"),
                "phase": launch.get("phase"),
                "decodeStepIndex": launch.get("decodeStepIndex"),
                "kernelName": base_kernel_name,
                "kernelPattern": target_pattern,
                "targetName": target_name,
                "compileDir": str(compile_dir),
                "compileParams": compile_params,
                "layoutPath": str(layout_path),
                "launchFunction": launch_function,
                "targetGeometry": target_geometry,
                "inputBindings": input_bindings,
                "outputBindings": output_bindings,
                "kvOperationCount": len(kv_ops),
                "transcriptEmitterCount": len(emitters),
                "runtimeActions": [
                    {
                        "kind": "resolve_symbols",
                        "deviceFunction": launch_function,
                        "inputSymbolCount": len(input_bindings),
                        "outputSymbolCount": len(output_bindings),
                    },
                    {
                        "kind": "bind_inputs",
                        "count": len(input_bindings),
                    },
                    {
                        "kind": "launch",
                        "functionName": launch_function,
                    },
                    {
                        "kind": "capture_outputs",
                        "count": len(output_bindings),
                    },
                ],
            }
        )

    serialized_sessions = []
    for session in target_sessions.values():
        serialized_sessions.append(
            {
                **session,
                "requiredInputSymbols": sorted(session["requiredInputSymbols"]),
                "requiredOutputSymbols": sorted(session["requiredOutputSymbols"]),
            }
        )
    serialized_sessions.sort(key=lambda item: str(item["targetName"]))

    return {
        "schemaVersion": 1,
        "artifactKind": "int4ple_hostplan_execution_plan",
        "status": "planned" if not blockers else "blocked",
        "blockers": blockers,
        "targetSessionCount": len(serialized_sessions),
        "launchCount": len(launch_records),
        "targetSessions": serialized_sessions,
        "launches": launch_records,
        "bufferPlan": _buffer_plan(
            runtime_config=runtime_config,
            runtime_scheduler=runtime_scheduler,
            launches=launches,
            executor_validator=executor_validator,
        ),
    }
