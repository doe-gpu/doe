#!/usr/bin/env python3
"""Compatibility facade for Gemma 4 31B af16 session runtime helpers."""

from __future__ import annotations

import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[3]
_RUNNER_DIR = Path(__file__).resolve().parent
for _entry in (_REPO_ROOT, _RUNNER_DIR):
    if str(_entry) not in sys.path:
        sys.path.insert(0, str(_entry))

from gemma4_31b_af16_session_common import (  # noqa: E402
    DEFAULT_PROMPT_TOKEN_IDS,
    LANE_KEY,
    LM_HEAD_KERNELS,
    MODEL_ID,
    PER_LAYER_INPUT_KERNELS,
    PREFILL_Q4K_GEMV_KERNELS,
    PREFILL_Q4K_GEMV_PATTERN,
    REPO_ROOT,
    RUNNER_DIR,
    SESSION_ARTIFACT_PREFIX,
    SUMMA_KERNELS,
    WORKSPACE_ROOT,
    expected_model_id,
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
from gemma4_31b_af16_session_runtime_exec import (  # noqa: E402
    _array_file_digest,
    _output_bindings_by_launch,
    _read_first_u32,
    DEFAULT_LAUNCH_TIMEOUT_SECONDS,
    build_real_session_runtime,
    build_runtime_transcript,
    host_io_layout_from_buffer_plan,
)
from gemma4_31b_af16_session_scheduler import (  # noqa: E402
    append_symbol_table_entry,
    binding,
    build_real_session_scheduler,
    output_buffer,
    routed_tensor_role,
    symbol_table_entry,
)
from gemma4_31b_af16_session_weights import (  # noqa: E402
    build_reference_request,
    build_runtime_weight_mappings,
    normalize_smoke_execution,
    resolve_weight_root,
    runtime_dtype,
    runtime_mapping_from_sidecar,
    runtime_mapping_from_tensor,
    runtime_quant,
    shard_identities_by_index,
    sidecar_shape_for_runtime,
    tensor_spans_for_runtime,
    token_prompt_ids,
)

__all__ = [
    "DEFAULT_PROMPT_TOKEN_IDS",
    "DEFAULT_LAUNCH_TIMEOUT_SECONDS",
    "LANE_KEY",
    "LM_HEAD_KERNELS",
    "MODEL_ID",
    "PER_LAYER_INPUT_KERNELS",
    "PREFILL_Q4K_GEMV_KERNELS",
    "PREFILL_Q4K_GEMV_PATTERN",
    "REPO_ROOT",
    "RUNNER_DIR",
    "SESSION_ARTIFACT_PREFIX",
    "SUMMA_KERNELS",
    "WORKSPACE_ROOT",
    "append_symbol_table_entry",
    "binding",
    "build_real_session_runtime",
    "build_real_session_scheduler",
    "build_reference_request",
    "build_runtime_transcript",
    "build_runtime_weight_mappings",
    "expected_model_id",
    "host_io_layout_from_buffer_plan",
    "load_json",
    "normalize_smoke_execution",
    "optional_resolved_path",
    "output_buffer",
    "rel",
    "resolve",
    "resolve_weight_root",
    "routed_tensor_role",
    "runtime_dtype",
    "runtime_mapping_from_sidecar",
    "runtime_mapping_from_tensor",
    "runtime_quant",
    "session_artifact_prefix",
    "session_runtime_source_sha256",
    "sha256_file",
    "sha256_json",
    "shard_identities_by_index",
    "sidecar_shape_for_runtime",
    "symbol_table_entry",
    "tensor_spans_for_runtime",
    "token_prompt_ids",
    "write_json",
]
