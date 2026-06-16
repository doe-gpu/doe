"""Shared constants and file helpers for Gemma 4 31B af16 HostPlan front door."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
WORKSPACE_ROOT = REPO_ROOT.parent
RUNNER_DIR = Path(__file__).resolve().parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
if str(RUNNER_DIR) not in sys.path:
    sys.path.insert(0, str(RUNNER_DIR))

MODEL_ID = "gemma-4-31b-it-text-q4k-ehf16-af16"
LANE_KEY = "q4k-ehf16-af16"
TRACE_ARTIFACT_KIND = "doe_gemma4_31b_af16_hostplan_streaming_trace"
SESSION_ARTIFACT_PREFIX = "gemma4_31b_af16"
DEFAULT_CLAIM_SCOPE = (
    "Gemma 4 31B af16 real-inference runner front door, weight staging "
    "plan, dispatch expansion, per-kernel refresh command, and resumable "
    "HostPlan session contract are materialized."
)
DEFAULT_CLAIM_NOT_WHAT = (
    "Not a generated token transcript until status is output_ready and "
    "blockers is empty."
)
DEFAULT_CLAIM_SUMMARY = (
    "The runnable contract exists; current artifacts remain blocked before "
    "end-to-end CSL output."
)
PLE_EMBED_KEY_PREFIX = "per_layer_inputs.embedTokensPerLayer.layer"
PLE_PROJECTION_KEY_PREFIX = "per_layer_inputs.perLayerModelProjection.layer"
PLE_PROJECTION_NORM_KEY_PREFIX = "per_layer_inputs.perLayerProjectionNorm.layer"
PER_LAYER_INPUT_KEY_PREFIX = "per_layer_inputs."
LINEAR_ATTENTION_POLICY = "skip-with-layout-metadata"
MODEL_LEVEL_PREFILL_STEPS = frozenset({
    "final_norm_prefill",
    "lm_head_prefill",
    "sample_prefill",
})
MODEL_LEVEL_DECODE_STEPS = frozenset({"final_norm", "lm_head"})
LM_HEAD_KERNELS = frozenset({
    "lm_head_gemv",
    "lm_head_gemv",
    "lm_head_prefill",
})
DEFAULT_SOURCE_MANIFEST = (
    WORKSPACE_ROOT
    / "doppler/models/local/gemma-4-31b-it-text-q4k-ehf16-af16/manifest.json"
)
DEFAULT_SMOKE_CONFIG = (
    REPO_ROOT / "runtime/zig/examples/execution-v1/gemma-4-31b-af16-smoke.json"
)
DEFAULT_HOST_PLAN = (
    REPO_ROOT
    / "bench/out/r3-1-31b-af16-manifest-fullgraph-compile-steps/host-plan.json"
)
DEFAULT_SIMULATOR_PLAN = (
    REPO_ROOT
    / "bench/out/r3-1-31b-af16-manifest-fullgraph-compile-steps/simulator-plan.json"
)
DEFAULT_RUNTIME_CONFIG = (
    REPO_ROOT
    / "bench/out/r3-1-31b-af16-manifest-fullgraph-compile-steps/runtime-config.json"
)
DEFAULT_COMPILE_ROOT = (
    REPO_ROOT
    / "bench/out/r3-1-31b-af16-manifest-fullgraph-compile-steps/compile"
)
DEFAULT_PER_KERNEL_SUMMARY = (
    REPO_ROOT
    / "bench/out/r3-1-31b-af16-manifest-simfabric-per-kernel/summary.json"
)
DEFAULT_OUT = (
    REPO_ROOT / "bench/out/r3-1-31b-af16-hostplan-streaming/trace.json"
)
DEFAULT_REFRESH_OUT_DIR = (
    REPO_ROOT / "bench/out/r3-1-31b-af16-manifest-simfabric-per-kernel"
)
DEFAULT_SESSION_OUT_DIR = (
    REPO_ROOT / "bench/out/r3-1-31b-af16-hostplan-session"
)
DEFAULT_SOURCE_GRAPH_INVENTORY = (
    REPO_ROOT
    / "bench/out/r3-1-31b-af16-manifest-fullgraph-compile-steps/"
    "source-graph-inventory.json"
)
MANIFEST_KERNEL_PROBE_RUNNER = (
    REPO_ROOT / "bench/runners/csl-runners/manifest_kernel_probe_runner.py"
)
CS_PYTHON = REPO_ROOT / "runtime/zig/tools/cs_python_singularity.sh"
CHAIN_STEP_ADAPTER = (
    REPO_ROOT / "bench/runners/csl-runners/chain_step_adapter.py"
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
