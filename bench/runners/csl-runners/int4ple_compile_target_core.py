"""Shared constants and utility helpers for INT4 PLE compile-target runners."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

import common  # noqa: E402
from manifest_dense_gemv_tiles import SDK_D2H_ELEMENT_COUNT_LIMIT  # noqa: E402

SCHEDULE_PREVIEW_COUNT = 4
TARGET_SESSION_PROBE = Path(__file__).with_name("int4ple_target_session_probe.py")
LAUNCH_STEP_ADAPTER = Path(__file__).with_name("int4ple_launch_step_adapter.py")
CHAIN_STEP_ADAPTER = Path(__file__).with_name("chain_step_adapter.py")
EMBED_ROI_ADAPTER = Path(__file__).with_name("int4ple_embed_roi_adapter.py")
DEFAULT_LAUNCH_TIMEOUT_SECONDS = 3600
SESSION_LM_HEAD_DISPATCH_MODES = ("monolithic", "dense_gemv_width_tiled_session")
SESSION_PLE_PROJ_DISPATCH_MODES = ("monolithic_summa", "compact_summa_session")
SESSION_ATTENTION_PREFILL_DISPATCH_MODES = (
    "hostplan_static",
    "compact_width_session",
)
DEFAULT_SESSION_LM_HEAD_TILE_WIDTH = 120
DEFAULT_SESSION_LM_HEAD_TILE_JOBS = 1
DEFAULT_SESSION_LM_HEAD_BATCH_STEP_BUDGET = 16
DEFAULT_PREFILL_Q4K_GEMV_OUTPUT_PE_ROWS = 1
DEFAULT_PREFILL_Q4K_GEMV_ADAPTER_STEP_BUDGET = 1
COMPACT_ATTENTION_Q_ROWS_PER_PE = 1
EMBED_ROI_TARGETS = frozenset({"embed", "ple_embed"})
PLE_PROJ_TARGETS = frozenset({"ple_proj"})
TILED_Q4K_GEMV_TARGETS = frozenset({"tiled_31b"})
PREFILL_Q4K_GEMV_PATTERN = "prefill_q4k_gemv"
PREFILL_Q4K_GEMV_SYMBOL_RESOLUTION_MODE = "runtime_managed_prefill_q4k_gemv"
SESSION_TILED_LM_HEAD_TARGETS = frozenset({"lm_head_prefill"})
PREFILL_ATTENTION_TARGETS = frozenset({"attn_small"})
RMSNORM_ROI_TARGETS = frozenset({"rmsnorm_prefill", "rmsnorm_decode", "rmsnorm"})
GATED_PREFILL_TARGETS = frozenset({"gelu_gated_prefill"})
RESIDUAL_PREFILL_TARGETS = frozenset({"residual_prefill"})
Q4K_BLOCK_ELEMENTS = 256
Q4K_BLOCK_BYTES = 144
PREFILL_GEMV_SOURCE_TILE_BLOCKS = 128
PREFILL_GEMV_SOURCE_TILE_COLS = (
    PREFILL_GEMV_SOURCE_TILE_BLOCKS * Q4K_BLOCK_ELEMENTS
)
PREFILL_GEMV_IN_DIM_PER_PE = 512
PREFILL_GEMV_HOST_REDUCE_MIN_SOURCE_COLS = 2 * PREFILL_GEMV_IN_DIM_PER_PE
PREFILL_GEMV_WIDE_SOURCE_COLS = 8192
PREFILL_GEMV_WIDE_IN_DIM_PER_PE = 256
PREFILL_GEMV_OUT_DIM_PER_PE = 112
PREFILL_GEMV_FABRIC_WEST_RESERVED = 4
PREFILL_GEMV_FABRIC_EAST_RESERVED = 3
PREFILL_GEMV_FABRIC_NORTH_RESERVED = 1
PREFILL_GEMV_FABRIC_SOUTH_RESERVED = 1
PREFILL_GEMV_MAX_OUTPUT_PE_ROWS = 4
DEFAULT_CS_PYTHON_CANDIDATES = (
    "/home/x/cerebras-sdk-2.10.0/cs_python",
    "/home/x/cerebras-sdk/cs_python",
)
DEFAULT_CSLC_CANDIDATES = (
    "/home/x/cerebras-sdk/cslc",
    "/home/x/cerebras-sdk-2.10.0/cslc",
)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def tail_lines(value: str | bytes | None, count: int) -> list[str]:
    if value is None:
        return []
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="replace")
    stripped = value.strip()
    return stripped.splitlines()[-count:] if stripped else []


def append_progress(path: Path, phase: str, **fields: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "timestampUnix": time.time(),
        "phase": phase,
        **fields,
    }
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, sort_keys=True) + "\n")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cs_python_executable() -> str:
    for env_key in ("DOE_CSL_RUNTIME_EXECUTABLE", "DOE_CSL_CS_PYTHON"):
        candidate = os.environ.get(env_key, "").strip()
        if candidate and Path(candidate).is_file():
            return candidate
    sdk_root = os.environ.get("DOE_CSL_SDK_ROOT", "").strip()
    if sdk_root:
        candidate = Path(sdk_root) / "cs_python"
        if candidate.is_file():
            return str(candidate)
    for candidate in DEFAULT_CS_PYTHON_CANDIDATES:
        if Path(candidate).is_file():
            return candidate
    discovered = shutil.which("cs_python")
    if discovered:
        return discovered
    return "cs_python"


def cslc_executable() -> str:
    candidate = os.environ.get("DOE_CSLC_EXECUTABLE", "").strip()
    if candidate and Path(candidate).is_file():
        return candidate
    sdk_root = os.environ.get("DOE_CSL_SDK_ROOT", "").strip()
    if sdk_root:
        candidate_path = Path(sdk_root) / "cslc"
        if candidate_path.is_file():
            return str(candidate_path)
    for candidate_path in DEFAULT_CSLC_CANDIDATES:
        if Path(candidate_path).is_file():
            return candidate_path
    discovered = shutil.which("cslc")
    if discovered:
        return discovered
    return "cslc"


def target_by_name(plan: dict[str, Any], name: str) -> dict[str, Any]:
    for target in (plan.get("inputs") or {}).get("compileTargets") or []:
        if isinstance(target, dict) and target.get("name") == name:
            return target
    raise ValueError(f"simulator plan is missing compile target {name!r}")


def int_param(target: dict[str, Any], key: str, default: int) -> int:
    params = target.get("compileParams") or {}
    if isinstance(params, dict) and key in params:
        return int(params[key])
    return default


def source_program(export: dict[str, Any]) -> dict[str, Any]:
    graph = export.get("executionGraph") or {}
    return {
        "authoringSurface": "doppler_execution_v1",
        "manifestPath": export["manifestPath"],
        "manifestSha256": export["manifestSha256"],
        "graphPath": graph.get("path", "pending"),
        "graphSha256": export["executionGraphSha256"],
        "weightSetId": export["weightSetId"],
        "weightSha256": export["weightSetSha256"],
        "inputSetSha256": export["inputSetSha256"],
        "executionDepth": "not_executed",
    }


def write_array(path: Path, array: np.ndarray) -> dict[str, Any]:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = array.tobytes(order="C")
    path.write_bytes(data)
    return {
        "path": str(path),
        "sha256": sha256_bytes(data),
        "byteLength": len(data),
    }


def compile_target_coverage(
    plan: dict[str, Any],
    compile_root: Path,
) -> dict[str, Any]:
    targets: list[dict[str, Any]] = []
    source_ready = 0
    compiled_ready = 0
    for target in (plan.get("inputs") or {}).get("compileTargets") or []:
        if not isinstance(target, dict):
            continue
        name = str(target.get("name", ""))
        layout = str(target.get("layout", f"{name}/layout.csl"))
        pe_program = str(target.get("peProgram", f"{name}/pe_program.csl"))
        layout_path = compile_root / layout
        pe_program_path = compile_root / pe_program
        compiled_path = compile_root / "compiled" / name / "out.json"
        target_source_ready = layout_path.is_file() and pe_program_path.is_file()
        target_compiled_ready = compiled_path.is_file()
        source_ready += 1 if target_source_ready else 0
        compiled_ready += 1 if target_compiled_ready else 0
        targets.append(
            {
                "name": name,
                "sourceReady": target_source_ready,
                "compiledReady": target_compiled_ready,
                "layoutPath": str(layout_path),
                "peProgramPath": str(pe_program_path),
                "compiledOutPath": str(compiled_path),
            }
        )
    return {
        "totalTargetCount": len(targets),
        "sourceReadyTargetCount": source_ready,
        "compiledReadyTargetCount": compiled_ready,
        "allSourcesReady": bool(targets) and source_ready == len(targets),
        "allCompiledTargetsReady": bool(targets) and compiled_ready == len(targets),
        "targets": targets,
    }


def compiled_target_params(compile_root: Path, target_name: str) -> dict[str, int]:
    compiled_path = compile_root / "compiled" / target_name / "out.json"
    if not compiled_path.is_file():
        return {}
    try:
        compiled = load_json(compiled_path)
    except (OSError, json.JSONDecodeError):
        return {}
    params = compiled.get("params") or {}
    if not isinstance(params, dict):
        return {}
    parsed: dict[str, int] = {}
    for key, value in params.items():
        try:
            parsed[str(key)] = int(value)
        except (TypeError, ValueError):
            continue
    return parsed


def require_minimum(
    *,
    blockers: list[str],
    checks: list[dict[str, Any]],
    check_id: str,
    actual: int,
    minimum: int,
) -> None:
    passed = actual >= minimum
    checks.append(
        {
            "id": check_id,
            "actual": actual,
            "minimum": minimum,
            "passed": passed,
        }
    )
    if not passed:
        blockers.append(f"{check_id}:{actual}<{minimum}")
