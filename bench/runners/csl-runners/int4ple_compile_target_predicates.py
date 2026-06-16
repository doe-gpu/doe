"""Launch classification and binding helpers for compile-target runtime."""

from __future__ import annotations

from typing import Any

from int4ple_compile_target_core import (
    PLE_PROJ_TARGETS,
    PREFILL_ATTENTION_TARGETS,
    PREFILL_Q4K_GEMV_PATTERN,
    SESSION_TILED_LM_HEAD_TARGETS,
    TILED_Q4K_GEMV_TARGETS,
)


def _is_session_tiled_lm_head_launch(
    launch: dict[str, Any],
    mode: str,
) -> bool:
    return (
        mode == "dense_gemv_width_tiled_session"
        and str(launch.get("targetName") or "") in SESSION_TILED_LM_HEAD_TARGETS
    )


def _is_compact_ple_proj_launch(launch: dict[str, Any], mode: str) -> bool:
    return (
        mode == "compact_summa_session"
        and str(launch.get("targetName") or "") in PLE_PROJ_TARGETS
    )


def _is_compact_attention_prefill_launch(
    launch: dict[str, Any],
    mode: str,
) -> bool:
    return (
        mode == "compact_width_session"
        and str(launch.get("targetName") or "") in PREFILL_ATTENTION_TARGETS
        and str(launch.get("kernelPattern") or "") == "attention_tiled"
    )


def _is_tiled_q4k_gemv_launch(launch: dict[str, Any], mode: str) -> bool:
    if str(launch.get("kernelPattern") or "") == PREFILL_Q4K_GEMV_PATTERN:
        return True
    if (
        mode != "compact_summa_session"
        or str(launch.get("targetName") or "") not in TILED_Q4K_GEMV_TARGETS
    ):
        return False
    try:
        b_binding = _binding_for_symbol(
            launch.get("resolvedInputs") or [],
            "b",
            launch_index=int(launch.get("launchIndex") or 0),
        )
    except ValueError:
        return False
    materialization = b_binding.get("materialization") or {}
    source_transform = materialization.get("sourceTransform") or {}
    nested = (
        source_transform.get("sourceTransform")
        if isinstance(source_transform, dict)
        else {}
    )
    return (
        isinstance(nested, dict)
        and str(nested.get("kind") or "") == "q4km_rowwise_to_f32"
    )


def _binding_for_any_symbol(
    bindings: list[dict[str, Any]],
    symbols: tuple[str, ...],
    *,
    launch_index: int,
) -> dict[str, Any]:
    last_error: ValueError | None = None
    for symbol in symbols:
        try:
            return _binding_for_symbol(
                bindings,
                symbol,
                launch_index=launch_index,
            )
        except ValueError as exc:
            last_error = exc
    if last_error is not None:
        raise last_error
    raise ValueError(f"launch[{launch_index}].binding_missing")


def _binding_for_symbol(
    bindings: list[Any],
    symbol: str,
    *,
    launch_index: int,
) -> dict[str, Any]:
    for binding in bindings:
        if isinstance(binding, dict) and str(binding.get("symbol") or "") == symbol:
            return binding
    raise ValueError(f"launch[{launch_index}].binding_missing:{symbol}")


def _ceil_div(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        raise ValueError("ceil_div_denominator_must_be_positive")
    return (numerator + denominator - 1) // denominator
