#!/usr/bin/env python3
"""Helpers for neutral benchmark IR and normalized plan materialization."""

from __future__ import annotations

import json
from collections import OrderedDict
from pathlib import Path
from typing import Any

import jsonschema

from bench.lib import synthetic_assets
from bench.lib.hash_utils import json_sha256


REPO_ROOT = Path(__file__).resolve().parents[2]
IR_SCHEMA_PATH = REPO_ROOT / "bench" / "ir" / "benchmark_ir.schema.json"
PLAN_SCHEMA_PATH = REPO_ROOT / "bench" / "plans" / "normalized_plan.schema.json"
MATMUL_GEMV_KERNEL = "matmul-gemv.wgsl"
MATMUL_GEMV_ROW2_HELPER_EXACT_KERNEL = "matmul_gemv_row2_helper_exact.wgsl"
MATMUL_GEMV_VARIANT_DEFAULT = "default"
MATMUL_GEMV_VARIANT_ROW2_HELPER_EXACT = "row2_helper_exact"


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def json_text(payload: Any) -> str:
    return json.dumps(payload, indent=2) + "\n"


def write_json(path: Path, payload: Any) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = json_text(payload)
    if path.exists() and path.read_text(encoding="utf-8") == rendered:
        return False
    path.write_text(rendered, encoding="utf-8")
    return True


def _validate_schema(path: Path, payload: Any) -> None:
    schema = load_json(path)
    validator = jsonschema.Draft202012Validator(schema)
    errors = sorted(
        validator.iter_errors(payload),
        key=lambda item: tuple(str(part) for part in item.absolute_path),
    )
    if errors:
        first = errors[0]
        location = ".".join(str(part) for part in first.absolute_path) if first.absolute_path else "<root>"
        raise ValueError(f"{path}: {location}: {first.message}")


def validate_ir_document(ir_doc: Any) -> None:
    _validate_schema(IR_SCHEMA_PATH, ir_doc)


def validate_plan_document(plan_doc: Any) -> None:
    _validate_schema(PLAN_SCHEMA_PATH, plan_doc)


def _command_kind(command: dict[str, Any]) -> str:
    kind = command.get("kind") or command.get("command") or command.get("command_kind")
    return str(kind) if kind is not None else ""


def _normalize_command(command: dict[str, Any]) -> dict[str, Any]:
    kind = _command_kind(command)
    if not kind:
        raise ValueError("missing command kind in IR workload")
    if kind == "repeat":
        count = command.get("count")
        if not isinstance(count, int) or count < 0:
            raise ValueError("repeat command requires non-negative integer count")
        nested = command.get("commands") or command.get("steps")
        if not isinstance(nested, list):
            raise ValueError("repeat command requires commands/steps array")
        flattened: list[dict[str, Any]] = []
        for _ in range(count):
            flattened.extend(_expand_commands(nested))
        return {"kind": "repeat", "count": count, "commands": flattened}

    normalized = OrderedDict()
    normalized["kind"] = kind
    for key, value in command.items():
        if key in {"kind", "command", "command_kind"}:
            continue
        normalized[key] = value
    return dict(normalized)


def _expand_commands(commands: list[Any]) -> list[dict[str, Any]]:
    expanded: list[dict[str, Any]] = []
    for command in commands:
        if not isinstance(command, dict):
            raise ValueError("IR command entries must be objects")
        normalized = _normalize_command(command)
        if normalized.get("kind") == "repeat":
            expanded.extend(normalized["commands"])
        else:
            expanded.append(normalized)
    return expanded


def _apply_scenario_output_oracle(
    commands: list[dict[str, Any]],
    *,
    scenario: dict[str, Any],
) -> list[dict[str, Any]]:
    output_oracle = scenario.get("outputOracle")
    if output_oracle is None:
        return commands
    if not isinstance(output_oracle, dict):
        raise ValueError("scenario outputOracle must be an object")
    if not commands or _command_kind(commands[-1]) != "kernel_dispatch":
        raise ValueError(
            "scenario outputOracle requires the final expanded command to be "
            "kernel_dispatch"
        )
    if "output_oracle" in commands[-1] or "outputOracle" in commands[-1]:
        raise ValueError(
            "scenario outputOracle conflicts with the final command output oracle"
        )

    materialized = list(commands)
    final_command = dict(materialized[-1])
    final_command["output_oracle"] = dict(output_oracle)
    materialized[-1] = final_command
    return materialized


def _count_commands(commands: list[dict[str, Any]]) -> dict[str, int]:
    counts = {"buffer_write": 0, "buffer_load": 0, "kernel_dispatch": 0}
    for command in commands:
        kind = str(command.get("kind", ""))
        if kind in counts:
            counts[kind] += 1
    return counts


def _command_int(command: dict[str, Any], key: str, default: int = 0) -> int:
    value = command.get(key)
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    return default


def _binding_by_index(command: dict[str, Any], binding_index: int) -> dict[str, Any]:
    bindings = command.get("bindings")
    if not isinstance(bindings, list):
        raise ValueError("kernel_dispatch bindings must be an array")
    for binding in bindings:
        if not isinstance(binding, dict):
            raise ValueError("kernel_dispatch bindings must be objects")
        if _command_int(binding, "binding", -1) == binding_index:
            return binding
    raise ValueError(f"kernel_dispatch missing binding {binding_index}")


def _binding_handle(binding: dict[str, Any]) -> int:
    return int(
        binding.get("resource_handle")
        or binding.get("resourceHandle")
        or binding.get("handle")
        or 0
    )


def _binding_buffer_size(binding: dict[str, Any]) -> int:
    return int(binding.get("buffer_size") or binding.get("bufferSize") or 0)


def _matmul_gemv_shape(
    command: dict[str, Any],
    *,
    command_index: int,
    buffer_writes: dict[int, dict[str, Any]],
) -> tuple[int, int]:
    uniform_binding = _binding_by_index(command, 0)
    matrix_binding = _binding_by_index(command, 1)
    vector_binding = _binding_by_index(command, 2)
    output_binding = _binding_by_index(command, 3)
    uniform_handle = _binding_handle(uniform_binding)
    uniform_command = buffer_writes.get(uniform_handle)
    if uniform_command is None:
        raise ValueError(
            f"matmul-gemv command[{command_index}] references unwritten uniform handle {uniform_handle}"
        )
    uniform_data = uniform_command.get("data")
    if not isinstance(uniform_data, list) or len(uniform_data) < 2:
        raise ValueError(f"matmul-gemv command[{command_index}] uniform must provide rows and cols")
    rows = int(uniform_data[0])
    cols = int(uniform_data[1])
    if rows <= 0 or cols <= 0:
        raise ValueError(f"matmul-gemv command[{command_index}] rows and cols must be positive")

    output_bytes = _binding_buffer_size(output_binding)
    vector_bytes = _binding_buffer_size(vector_binding)
    matrix_bytes = _binding_buffer_size(matrix_binding)
    expected_output_bytes = rows * 4
    expected_vector_bytes = cols * 4
    expected_matrix_bytes = rows * cols * 4
    if output_bytes != expected_output_bytes:
        raise ValueError(
            f"matmul-gemv command[{command_index}] output bytes {output_bytes} "
            f"do not match rows*4 {expected_output_bytes}"
        )
    if vector_bytes != expected_vector_bytes:
        raise ValueError(
            f"matmul-gemv command[{command_index}] vector bytes {vector_bytes} "
            f"do not match cols*4 {expected_vector_bytes}"
        )
    if matrix_bytes != expected_matrix_bytes:
        raise ValueError(
            f"matmul-gemv command[{command_index}] matrix bytes {matrix_bytes} "
            f"do not match rows*cols*4 {expected_matrix_bytes}"
        )
    return rows, cols


def _validate_matmul_gemv_dispatch(
    command: dict[str, Any],
    *,
    command_index: int,
    buffer_writes: dict[int, dict[str, Any]],
) -> None:
    rows, _ = _matmul_gemv_shape(
        command,
        command_index=command_index,
        buffer_writes=buffer_writes,
    )
    if _command_int(command, "x") != rows or _command_int(command, "y", 1) != 1 or _command_int(command, "z", 1) != 1:
        raise ValueError(
            f"matmul-gemv command[{command_index}] dispatch must be [rows,1,1]; "
            f"got [{_command_int(command, 'x')},{_command_int(command, 'y', 1)},{_command_int(command, 'z', 1)}] "
            f"for rows={rows}"
        )


def _validate_matmul_gemv_row2_helper_exact_dispatch(
    command: dict[str, Any],
    *,
    command_index: int,
    buffer_writes: dict[int, dict[str, Any]],
) -> None:
    rows, cols = _matmul_gemv_shape(
        command,
        command_index=command_index,
        buffer_writes=buffer_writes,
    )
    if rows % 2 != 0:
        raise ValueError(f"matmul-gemv row2 command[{command_index}] rows must be even")
    if cols % 4 != 0:
        raise ValueError(f"matmul-gemv row2 command[{command_index}] cols must be divisible by 4")
    expected_x = rows // 2
    if _command_int(command, "x") != expected_x or _command_int(command, "y", 1) != 1 or _command_int(command, "z", 1) != 1:
        raise ValueError(
            f"matmul-gemv row2 command[{command_index}] dispatch must be [rows/2,1,1]; "
            f"got [{_command_int(command, 'x')},{_command_int(command, 'y', 1)},{_command_int(command, 'z', 1)}] "
            f"for rows={rows}"
        )


def _validate_command_semantics(commands: list[dict[str, Any]]) -> None:
    buffer_writes: dict[int, dict[str, Any]] = {}
    for index, command in enumerate(commands):
        kind = _command_kind(command)
        if kind == "buffer_write":
            handle = int(command.get("handle") or 0)
            if handle > 0:
                buffer_writes[handle] = command
            continue
        if kind != "kernel_dispatch":
            continue
        kernel = str(command.get("kernel", ""))
        if kernel == MATMUL_GEMV_KERNEL:
            _validate_matmul_gemv_dispatch(
                command,
                command_index=index,
                buffer_writes=buffer_writes,
            )
        elif kernel == MATMUL_GEMV_ROW2_HELPER_EXACT_KERNEL:
            _validate_matmul_gemv_row2_helper_exact_dispatch(
                command,
                command_index=index,
                buffer_writes=buffer_writes,
            )


def _matmul_gemv_variant(scenario: dict[str, Any]) -> str:
    variant = scenario.get("matmulGemvVariant")
    if variant is None:
        return MATMUL_GEMV_VARIANT_DEFAULT
    return str(variant)


def _apply_matmul_gemv_variant(
    commands: list[dict[str, Any]],
    *,
    scenario: dict[str, Any],
) -> list[dict[str, Any]]:
    variant = _matmul_gemv_variant(scenario)
    if variant == MATMUL_GEMV_VARIANT_DEFAULT:
        return commands
    if variant != MATMUL_GEMV_VARIANT_ROW2_HELPER_EXACT:
        raise ValueError(f"unsupported matmulGemvVariant {variant!r}")

    buffer_writes: dict[int, dict[str, Any]] = {}
    transformed: list[dict[str, Any]] = []
    for index, command in enumerate(commands):
        kind = _command_kind(command)
        if kind == "buffer_write":
            handle = int(command.get("handle") or 0)
            if handle > 0:
                buffer_writes[handle] = command
            transformed.append(command)
            continue
        if kind != "kernel_dispatch" or str(command.get("kernel", "")) != MATMUL_GEMV_KERNEL:
            transformed.append(command)
            continue

        rows, cols = _matmul_gemv_shape(
            command,
            command_index=index,
            buffer_writes=buffer_writes,
        )
        if rows % 2 != 0:
            raise ValueError(f"matmulGemvVariant row2_helper_exact command[{index}] requires even rows")
        if cols % 4 != 0:
            raise ValueError(f"matmulGemvVariant row2_helper_exact command[{index}] requires cols divisible by 4")
        if _command_int(command, "x") != rows or _command_int(command, "y", 1) != 1 or _command_int(command, "z", 1) != 1:
            raise ValueError(
                f"matmulGemvVariant row2_helper_exact command[{index}] requires source dispatch [rows,1,1]"
            )

        rewritten = dict(command)
        rewritten["kernel"] = MATMUL_GEMV_ROW2_HELPER_EXACT_KERNEL
        rewritten["x"] = rows // 2
        transformed.append(rewritten)
    return transformed


def _is_default_matmul_gemv_variant(scenario: dict[str, Any]) -> bool:
    return _matmul_gemv_variant(scenario) == MATMUL_GEMV_VARIANT_DEFAULT


def _normalize_binding_buffer_type(binding: dict[str, Any]) -> str:
    raw = str(
        binding.get("buffer_type")
        or binding.get("bufferType")
        or binding.get("type")
        or ""
    ).strip().lower()
    if raw in {"readonly", "read_only_storage", "read-only-storage", "readonly_storage"}:
        return "readonly"
    if raw == "uniform":
        return "uniform"
    return "storage"


def _synthetic_readonly_buffer_policy(ir_doc: dict[str, Any]) -> dict[str, Any] | None:
    shared = ir_doc.get("shared")
    if not isinstance(shared, dict):
        return None
    policy = shared.get("syntheticReadonlyBufferPolicy")
    if not isinstance(policy, dict):
        return None
    return {
        "cacheNamespace": str(policy.get("cacheNamespace", "")).strip(),
        "generator": synthetic_assets.normalize_generator(policy.get("generator")),
        "seed": synthetic_assets.normalize_seed(policy.get("seed")),
        "scale": synthetic_assets.normalize_scale(policy.get("scale", 1.0)),
    }


def _inject_synthetic_buffer_loads(
    *,
    ir_doc: dict[str, Any],
    scenario: dict[str, Any],
    commands: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    policy = _synthetic_readonly_buffer_policy(ir_doc)
    if policy is None:
        return commands
    if not policy["cacheNamespace"]:
        raise ValueError("syntheticReadonlyBufferPolicy.cacheNamespace must be non-empty")

    written_handles: set[int] = set()
    loaded_handles: set[int] = set()
    binding_roles: dict[int, set[str]] = {}
    first_use_index: dict[int, int] = {}
    max_size_by_handle: dict[int, int] = {}
    for index, command in enumerate(commands):
        kind = _command_kind(command)
        if kind == "buffer_write":
            written_handles.add(int(command.get("handle", 0)))
            continue
        if kind == "buffer_load":
            loaded_handles.add(int(command.get("handle", 0)))
            continue
        if kind != "kernel_dispatch":
            continue
        raw_bindings = command.get("bindings")
        if not isinstance(raw_bindings, list):
            continue
        for binding in raw_bindings:
            if not isinstance(binding, dict):
                raise ValueError("kernel_dispatch bindings must be objects")
            handle = int(
                binding.get("resource_handle")
                or binding.get("resourceHandle")
                or binding.get("handle")
                or 0
            )
            if handle <= 0:
                raise ValueError("kernel_dispatch bindings must provide a positive resource_handle")
            buffer_size = int(binding.get("buffer_size") or binding.get("bufferSize") or 0)
            if buffer_size <= 0:
                raise ValueError(f"kernel_dispatch binding handle={handle} must provide buffer_size > 0")
            binding_roles.setdefault(handle, set()).add(_normalize_binding_buffer_type(binding))
            first_use_index.setdefault(handle, index)
            max_size_by_handle[handle] = max(max_size_by_handle.get(handle, 0), buffer_size)

    insert_before: dict[int, list[dict[str, Any]]] = {}
    scenario_id = str(scenario.get("id", "")).strip() or "scenario"
    for handle in sorted(binding_roles.keys()):
        roles = binding_roles[handle]
        if roles != {"readonly"}:
            continue
        if handle in written_handles or handle in loaded_handles:
            continue
        buffer_size = max_size_by_handle[handle]
        seed = synthetic_assets.mix_seed(policy["seed"], handle)
        load_command = synthetic_assets.build_buffer_load_command(
            handle=handle,
            buffer_size=buffer_size,
            cache_namespace=policy["cacheNamespace"],
            generator=policy["generator"],
            seed=seed,
            scale=policy["scale"],
            asset_key=f"{scenario_id}:handle-{handle}",
        )
        insert_before.setdefault(first_use_index[handle], []).append(load_command)

    if not insert_before:
        return commands

    materialized: list[dict[str, Any]] = []
    for index, command in enumerate(commands):
        materialized.extend(insert_before.get(index, ()))
        materialized.append(command)
    return materialized


def load_ir_document(ir_path: Path) -> dict[str, Any]:
    payload = load_json(ir_path)
    if not isinstance(payload, dict):
        raise ValueError(f"invalid IR object: {ir_path}")
    validate_ir_document(payload)
    return payload


def load_ir_scenario(ir_path: Path, scenario_id: str) -> dict[str, Any]:
    ir_doc = load_ir_document(ir_path)
    scenarios = ir_doc.get("scenarios", [])
    if not isinstance(scenarios, list):
        raise ValueError(f"{ir_path}: scenarios must be an array")
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            continue
        if scenario.get("id") == scenario_id:
            return scenario
    raise ValueError(f"{ir_path}: missing IR scenario {scenario_id!r}")


def materialize_plan(ir_path: Path, scenario_id: str) -> dict[str, Any]:
    ir_doc = load_ir_document(ir_path)
    scenario = load_ir_scenario(ir_path, scenario_id)
    commands = _inject_synthetic_buffer_loads(
        ir_doc=ir_doc,
        scenario=scenario,
        commands=_expand_commands(scenario["commands"]),
    )
    commands = _apply_matmul_gemv_variant(commands, scenario=scenario)
    commands = _apply_scenario_output_oracle(commands, scenario=scenario)
    _validate_command_semantics(commands)
    counts = _count_commands(commands)
    ir_hash = json_sha256(ir_doc)
    compatibility_hash = json_sha256(commands)

    plan = OrderedDict()
    plan["schemaVersion"] = 1
    plan["planKind"] = ir_doc.get("kind", "benchmark_ir")
    plan["workloadId"] = scenario_id
    scenario_ir_path = scenario.get("irPath")
    if isinstance(scenario_ir_path, str) and scenario_ir_path:
        plan["irPath"] = scenario_ir_path
    else:
        try:
            plan["irPath"] = str(ir_path.relative_to(REPO_ROOT))
        except ValueError:
            plan["irPath"] = str(ir_path)
    plan["irScenario"] = scenario_id
    plan["description"] = scenario.get("description", "")
    plan["planPath"] = scenario.get("planPath", "")
    plan["commandsPath"] = scenario.get("commandsPath", "")
    if not _is_default_matmul_gemv_variant(scenario):
        plan["matmulGemvVariant"] = _matmul_gemv_variant(scenario)
    plan["commandCount"] = len(commands)
    plan["bufferWriteCount"] = counts["buffer_write"]
    plan["bufferLoadCount"] = counts["buffer_load"]
    plan["dispatchCount"] = counts["kernel_dispatch"]
    plan["sourceIrSha256"] = ir_hash
    plan["compatibilityCommandsSha256"] = compatibility_hash
    plan["commands"] = commands
    plan["planSha256"] = json_sha256(plan)

    validate_plan_document(plan)
    return plan


def materialize_plan_artifacts(ir_path: Path, scenario_id: str) -> dict[str, Any]:
    plan = materialize_plan(ir_path, scenario_id)
    return {
        "plan": plan,
        "commands": plan["commands"],
        "planPath": plan["planPath"],
        "commandsPath": plan["commandsPath"],
        "planSha256": plan["planSha256"],
        "irPath": plan["irPath"],
        "irScenario": plan["irScenario"],
        "commandCount": plan["commandCount"],
        "bufferWriteCount": plan["bufferWriteCount"],
        "bufferLoadCount": plan["bufferLoadCount"],
        "dispatchCount": plan["dispatchCount"],
        "sourceIrSha256": plan["sourceIrSha256"],
        "compatibilityCommandsSha256": plan["compatibilityCommandsSha256"],
    }
