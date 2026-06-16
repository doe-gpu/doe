"""Shared constants and file helpers for Gemma 4 31B af16 session runtime."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
WORKSPACE_ROOT = REPO_ROOT.parent
RUNNER_DIR = Path(__file__).resolve().parent
for entry in (REPO_ROOT, RUNNER_DIR):
    if str(entry) not in sys.path:
        sys.path.insert(0, str(entry))

MODEL_ID = "gemma-4-31b-it-text-q4k-ehf16-af16"
LANE_KEY = "q4k-ehf16-af16"
SESSION_ARTIFACT_PREFIX = "gemma4_31b_af16"
DEFAULT_PROMPT_TOKEN_IDS = [2, 3]
LM_HEAD_KERNELS = frozenset({
    "lm_head_gemv",
    "lm_head_gemv",
    "lm_head_prefill",
})
PER_LAYER_INPUT_KERNELS = frozenset({
    "ple_embed",
    "ple_proj",
    "ple_rmsnorm",
    "ple_residual",
})
SUMMA_KERNELS = frozenset({"tiled", "ple_proj"})
PREFILL_Q4K_GEMV_KERNELS = frozenset({"tiled_31b"})
PREFILL_Q4K_GEMV_PATTERN = "prefill_q4k_gemv"
SESSION_RUNTIME_SOURCE_FILES = (
    "gemma4_31b_af16_session_runtime.py",
    "gemma4_31b_af16_session_common.py",
    "gemma4_31b_af16_session_weights.py",
    "gemma4_31b_af16_session_scheduler.py",
    "gemma4_31b_af16_session_runtime_exec.py",
)


def resolve(path: Path) -> Path:
    return path if path.is_absolute() else (REPO_ROOT / path).resolve()


def rel(path: Path) -> str:
    resolved = resolve(path)
    try:
        return resolved.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        pass
    try:
        return "../" + resolved.relative_to(WORKSPACE_ROOT).as_posix()
    except ValueError:
        return str(resolved)


def load_json(path: Path) -> Any:
    return json.loads(resolve(path).read_text(encoding="utf-8"))


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with resolve(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_json(value: Any) -> str:
    payload = json.dumps(value, separators=(",", ":"), sort_keys=True).encode(
        "utf-8"
    )
    return hashlib.sha256(payload).hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def expected_model_id(args: argparse.Namespace) -> str:
    return str(getattr(args, "expected_model_id", MODEL_ID) or MODEL_ID)


def session_artifact_prefix(args: argparse.Namespace) -> str:
    return str(
        getattr(args, "session_artifact_prefix", SESSION_ARTIFACT_PREFIX)
        or SESSION_ARTIFACT_PREFIX
    )


def optional_resolved_path(args: argparse.Namespace, name: str) -> Path | None:
    raw = getattr(args, name, None)
    if raw is None:
        return None
    text = str(raw).strip()
    if not text:
        return None
    return resolve(Path(text))


def session_runtime_source_sha256() -> str:
    h = hashlib.sha256()
    for filename in SESSION_RUNTIME_SOURCE_FILES:
        source = RUNNER_DIR / filename
        h.update(filename.encode("utf-8"))
        h.update(b"\0")
        h.update(source.read_bytes())
        h.update(b"\0")
    return h.hexdigest()
