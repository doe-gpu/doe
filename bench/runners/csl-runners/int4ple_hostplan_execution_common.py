"""Common metadata helpers for INT4 PLE HostPlan execution plans."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

_ELEMENTWISE_PHASE_VARIANT_KERNELS = frozenset({
    "rmsnorm",
    "residual",
    "gelu",
    "gelu_gated",
    "silu_gated",
    "sigmoid_gated",
})
_SUPPORTED_ELEMENTWISE_PHASES = frozenset({"prefill", "decode"})
_SUMMA_TARGETS = frozenset({"tiled", "tiled_31b", "ple_proj"})
PREFILL_Q4K_GEMV_PATTERN = "prefill_q4k_gemv"
_ROW_PARALLEL_TARGETS = frozenset({
    "rmsnorm_prefill",
    "residual_prefill",
    "gelu_prefill",
    "gelu_gated_prefill",
    "silu_gated_prefill",
    "sigmoid_gated_prefill",
})
_ROPE_TARGETS = frozenset({"rope", "rope_partial"})
_ATTENTION_TILED_TARGETS = frozenset({
    "attn_small",
    "attn_head256",
    "attn_head512",
})


def _resolve_phase_variant_target(
    *,
    kernel_name: str,
    phase: str,
    available_targets: dict[str, Any],
    launch_index: int,
    blockers: list[str],
    targets_metadata: dict[tuple[str, str], str] | None = None,
) -> str | None:
    """Remap an elementwise launch to its phase-specific compile target.

    rmsnorm/residual/gelu are compiled once per phase: the `_prefill` variant
    carries `width=attention_tokens` and the `_decode` variant carries
    `width=1`. Legacy elementwise launches without a phase pass through to the
    base target; launches with a phase must resolve to the matching variant.

    Non-elementwise kernels pass through unchanged.

    When `targets_metadata` (loaded from `compile/targets.metadata.json`) is
    provided, the (baseKernel, phase) → target name lookup uses the
    Zig-emitted truth instead of the legacy `f"{kernel_name}_{phase}"`
    suffix convention.
    """
    if kernel_name not in _ELEMENTWISE_PHASE_VARIANT_KERNELS:
        return kernel_name
    if not phase:
        return kernel_name
    if phase not in _SUPPORTED_ELEMENTWISE_PHASES:
        blockers.append(
            f"launch[{launch_index}].phase_variant_unsupported:"
            f"{kernel_name}:{phase}"
        )
        return None
    variant: str | None = None
    if targets_metadata is not None:
        variant = targets_metadata.get((kernel_name, phase))
    if variant is None:
        variant = f"{kernel_name}_{phase}"
    if variant not in available_targets:
        blockers.append(
            f"launch[{launch_index}].phase_variant_target_missing:{variant}"
        )
        return None
    return variant


def _load_targets_metadata(compile_root: Path) -> dict[tuple[str, str], str]:
    metadata_path = compile_root / "targets.metadata.json"
    if not metadata_path.is_file():
        return {}
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    if not isinstance(payload, dict):
        return {}
    by_base_phase: dict[tuple[str, str], str] = {}
    for entry in payload.get("targets") or []:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "")
        base = str(entry.get("baseKernel") or "")
        phase = entry.get("phase")
        if not name or not base or not isinstance(phase, str) or not phase:
            continue
        by_base_phase[(base, phase)] = name
    return by_base_phase


def _target_by_name(plan: dict[str, Any]) -> dict[str, dict[str, Any]]:
    targets = (plan.get("inputs") or {}).get("compileTargets") or []
    return {
        str(target.get("name")): target
        for target in targets
        if isinstance(target, dict) and target.get("name")
    }


def _target_pattern(target: dict[str, Any]) -> str:
    pattern = target.get("pattern")
    return str(pattern) if isinstance(pattern, str) and pattern else ""


def _runtime_scheduler(scheduler: dict[str, Any]) -> dict[str, Any]:
    host_plan = scheduler.get("hostPlan") or {}
    if isinstance(host_plan, dict):
        runtime_scheduler = host_plan.get("runtimeScheduler")
        if isinstance(runtime_scheduler, dict):
            return runtime_scheduler
    return {}


def _layout_path(compile_root: Path, target: dict[str, Any]) -> Path:
    raw = target.get("layout") or ""
    path = Path(str(raw))
    return path if path.is_absolute() else (compile_root / path)


def _compile_dir(compile_root: Path, target_name: str) -> Path:
    return compile_root / "compiled" / target_name


def _pe_program_path(compile_root: Path, target: dict[str, Any]) -> Path:
    raw = target.get("peProgram") or ""
    path = Path(str(raw))
    return path if path.is_absolute() else (compile_root / path)


def _parse_layout_exports(layout_path: Path) -> list[dict[str, Any]]:
    metadata_path = layout_path.with_suffix(".metadata.json")
    if metadata_path.is_file():
        return _layout_exports_from_metadata(metadata_path)
    return []


def _layout_exports_from_metadata(metadata_path: Path) -> list[dict[str, Any]]:
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return []
    if not isinstance(payload, dict):
        return []
    exports: list[dict[str, Any]] = []
    for entry in payload.get("exports") or []:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "")
        type_str = str(entry.get("type") or "")
        kind = str(entry.get("kind") or "")
        if not name or not type_str or kind not in {"device_variable", "device_function"}:
            continue
        exports.append(
            {
                "name": name,
                "type": type_str,
                "kind": kind,
                "mutable": bool(entry.get("mutable") or False),
            }
        )
    return exports


def _resolve_size_expr(size_expr: str, params: dict[str, int]) -> int | None:
    tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_]*|\d+|[+\-*()]", size_expr)
    substituted: list[str] = []
    for token in tokens:
        if token.isidentifier():
            if token not in params:
                return None
            substituted.append(str(params[token]))
        elif token.isdigit() or token in "+-*()":
            substituted.append(token)
        else:
            return None
    try:
        value = eval("".join(substituted), {"__builtins__": {}}, {})
    except Exception:
        return None
    if isinstance(value, int) and value >= 0:
        return value
    return None


def _parse_pe_program_arrays(pe_program_path: Path) -> tuple[dict[str, dict[str, Any]], dict[str, int]]:
    metadata_path = pe_program_path.with_suffix(".metadata.json")
    if metadata_path.is_file():
        decls = _decls_from_metadata(metadata_path)
        return decls, _compile_time_from_metadata(metadata_path)
    return {}, {}


def _decls_from_metadata(metadata_path: Path) -> dict[str, dict[str, Any]]:
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    if not isinstance(payload, dict):
        return {}
    decls: dict[str, dict[str, Any]] = {}
    for entry in payload.get("variables") or []:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "")
        size_expr = str(entry.get("sizeExpr") or "")
        elem_type = str(entry.get("elemType") or "")
        if not name or not size_expr or not elem_type:
            continue
        decls[name] = {"sizeExpr": size_expr, "elemType": elem_type}
    for entry in payload.get("exports") or []:
        if not isinstance(entry, dict):
            continue
        symbol = str(entry.get("symbol") or "")
        backing = str(entry.get("backing") or "")
        size_expr = str(entry.get("sizeExpr") or "")
        elem_type = str(entry.get("elemType") or "")
        pointer = str(entry.get("pointer") or "")
        if not symbol or not size_expr or not elem_type or symbol in decls:
            continue
        decls[symbol] = {
            "sizeExpr": size_expr,
            "elemType": elem_type,
            "backingVariable": backing,
            "exportPointer": pointer,
        }
    return decls


def _compile_time_from_metadata(metadata_path: Path) -> dict[str, int]:
    try:
        payload = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    if not isinstance(payload, dict):
        return {}
    compile_time: dict[str, int] = {}
    for entry in payload.get("compileTimeConstants") or []:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("name") or "")
        expr = str(entry.get("expr") or "")
        if not name or not expr:
            continue
        resolved = _resolve_size_expr(expr, compile_time)
        if resolved is not None:
            compile_time[name] = resolved
    return compile_time


def _memcpy_data_type(elem_type: str) -> str:
    if elem_type in {"u16", "i16"}:
        return "MEMCPY_16BIT"
    return "MEMCPY_32BIT"


def _dtype_for_elem_type(elem_type: str) -> str:
    if elem_type == "u8":
        return "u32"
    if elem_type == "f16":
        return "f16"
    if elem_type in {"u16", "i16"}:
        return "u16"
    if elem_type in {"u32", "i32"}:
        return "u32"
    return "f32"


def _dtype_byte_width(dtype: str) -> int:
    if dtype in {"f16", "u16"}:
        return 2
    return 4


def _model_hidden_dim(runtime_config: dict[str, Any]) -> int:
    model = runtime_config.get("modelConfig") or {}
    try:
        return int(model.get("hiddenDim") or 0)
    except (TypeError, ValueError):
        return 0


def _model_ple_width(runtime_config: dict[str, Any]) -> int:
    model = runtime_config.get("modelConfig") or {}
    try:
        return int(model.get("pleWidth") or 0)
    except (TypeError, ValueError):
        return 0


def _int_field(value: Any) -> int | None:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed > 0 else None
