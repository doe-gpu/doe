"""Weight staging and dispatch planning for Gemma 4 31B af16 HostPlan runs."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from bench.tools._lane_dtype_profile import (
    canonical_dtype_profile,
    csl_dtype_contract_for_profile,
)
from bench.tools.int4ple_runtime_weight_mappings import (
    inferred_rmsnorm_weight_key,
    layer_index_from_step_weight_key,
    tensor_name_candidates_for_weight_key,
)
from gemma4_31b_af16_hostplan_common import (
    LANE_KEY,
    LINEAR_ATTENTION_POLICY,
    LM_HEAD_KERNELS,
    MODEL_ID,
    MODEL_LEVEL_DECODE_STEPS,
    MODEL_LEVEL_PREFILL_STEPS,
    PER_LAYER_INPUT_KEY_PREFIX,
    PLE_EMBED_KEY_PREFIX,
    PLE_PROJECTION_KEY_PREFIX,
    PLE_PROJECTION_NORM_KEY_PREFIX,
    load_json,
    rel,
    resolve,
    sha256_file,
)

def resolve_weight_root(manifest_path: Path, manifest: dict[str, Any]) -> Path:
    manifest_root = resolve(manifest_path).parent
    weights_ref = manifest.get("weightsRef") or {}
    raw_root = weights_ref.get("artifactRoot")
    if isinstance(raw_root, str) and raw_root:
        return (manifest_root / raw_root).resolve()
    return manifest_root


def expand_layer_weight_key(weight_key: str, layer_index: int) -> str:
    parts = weight_key.split(".")
    if len(parts) >= 2 and parts[0] == "layer" and parts[1] == "0":
        return ".".join(["layer", str(layer_index), *parts[2:]])
    if len(parts) >= 2 and parts[0] == "layer" and parts[1] == "linear_attn":
        return ".".join(["layer", str(layer_index), *parts[1:]])
    return weight_key


def infer_weight_key_for_step(
    step: dict[str, Any],
    layer_index: int,
) -> str | None:
    raw = step.get("weightsKey")
    if isinstance(raw, str) and raw:
        if raw == "per_layer_inputs.perLayerModelProjection":
            return f"{raw}.layer{layer_index}"
        if raw == "per_layer_inputs.embedTokensPerLayer":
            return f"{raw}.layer{layer_index}"
        if raw == "per_layer_inputs.perLayerProjectionNorm":
            return f"{raw}.layer{layer_index}"
        return expand_layer_weight_key(raw, layer_index)
    if step.get("op") == "rmsnorm" or step.get("kernelKey") == "rmsnorm":
        direct = layer_index_from_step_weight_key(raw)
        return inferred_rmsnorm_weight_key(
            str(step.get("name") or ""),
            direct if direct is not None else layer_index,
        )
    return None


def is_dense_lm_head_step(step: dict[str, Any] | None) -> bool:
    if not isinstance(step, dict):
        return False
    op = str(step.get("op") or "")
    kernel = str(step.get("kernelKey") or "")
    return op == "matmul" or kernel == "lm_head_prefill"


def is_q4k_lm_head_step(step: dict[str, Any] | None) -> bool:
    if not isinstance(step, dict):
        return False
    op = str(step.get("op") or "")
    kernel = str(step.get("kernelKey") or "")
    return op == "matmul_q4k" or kernel in {"lm_head_gemv", "lm_head_gemv"}


def tensor_candidates_for_key(
    weight_key: str,
    step: dict[str, Any] | None = None,
) -> list[str]:
    if weight_key.startswith(PLE_EMBED_KEY_PREFIX):
        layer = weight_key.removeprefix(PLE_EMBED_KEY_PREFIX)
        return [
            (
                "model.language_model.layers."
                f"{layer}.embed_tokens_per_layer.weight"
            ),
            f"model.layers.{layer}.embed_tokens_per_layer.weight",
            "model.language_model.embed_tokens_per_layer.weight",
            "language_model.embed_tokens_per_layer.weight",
            "model.embed_tokens_per_layer.weight",
            "embed_tokens_per_layer.weight",
            "model.language_model.embed_tokens.weight",
            "model.embed_tokens.weight",
        ]
    if weight_key.startswith(PLE_PROJECTION_NORM_KEY_PREFIX):
        return [
            "model.language_model.per_layer_projection_norm.weight",
            "language_model.per_layer_projection_norm.weight",
            "model.per_layer_projection_norm.weight",
            "per_layer_projection_norm.weight",
        ]
    if weight_key.startswith(PLE_PROJECTION_KEY_PREFIX):
        return [weight_key + ".f32"]
    if weight_key == "lm_head" and is_dense_lm_head_step(step):
        return [
            "model.language_model.embed_tokens.weight",
            "language_model.model.embed_tokens.weight",
            "model.embed_tokens.weight",
            "embed_tokens.weight",
            "model.language_model.lm_head.weight",
            "language_model.lm_head.weight",
            "model.lm_head.weight",
            "lm_head.weight",
        ]
    if weight_key.startswith("layer."):
        parts = weight_key.split(".")
        if len(parts) >= 4 and parts[2] == "linear_attn":
            layer = parts[1]
            suffix = ".".join(parts[3:])
            if suffix == "conv1d":
                suffix = "conv1d.weight"
            if suffix:
                return [
                    f"model.language_model.layers.{layer}.linear_attn.{suffix}",
                    f"model.layers.{layer}.linear_attn.{suffix}",
                ]
    try:
        return tensor_name_candidates_for_weight_key(weight_key)
    except ValueError:
        return [weight_key + ".f32"]


def layer_index_from_weight_key(weight_key: str) -> int | None:
    parts = weight_key.split(".")
    if len(parts) < 2 or parts[0] != "layer":
        return None
    try:
        return int(parts[1])
    except ValueError:
        return None


def is_linear_attention_weight_key(weight_key: str | None) -> bool:
    if not isinstance(weight_key, str):
        return False
    parts = weight_key.split(".")
    return len(parts) >= 3 and parts[0] == "layer" and parts[2] == "linear_attn"


def is_self_attention_weight_key(weight_key: str | None) -> bool:
    if not isinstance(weight_key, str):
        return False
    parts = weight_key.split(".")
    return len(parts) >= 3 and parts[0] == "layer" and parts[2] == "self_attn"


def linear_attention_layers_from_tensors(tensors: dict[str, Any]) -> list[int]:
    layers: set[int] = set()
    prefix = "model.language_model.layers."
    marker = ".linear_attn."
    for tensor_name in tensors:
        if not tensor_name.startswith(prefix) or marker not in tensor_name:
            continue
        rest = tensor_name.removeprefix(prefix)
        layer_text = rest.split(".", 1)[0]
        try:
            layers.add(int(layer_text))
        except ValueError:
            continue
    return sorted(layers)


def self_attention_layers_from_tensors(tensors: dict[str, Any]) -> list[int]:
    layers: set[int] = set()
    prefix = "model.language_model.layers."
    marker = ".self_attn."
    for tensor_name in tensors:
        if not tensor_name.startswith(prefix) or marker not in tensor_name:
            continue
        rest = tensor_name.removeprefix(prefix)
        layer_text = rest.split(".", 1)[0]
        try:
            layers.add(int(layer_text))
        except ValueError:
            continue
    return sorted(layers)


def tensor_exists(tensors: dict[str, Any], name: str) -> bool:
    return name in tensors


def is_linear_attention_absent_v_projection(
    weight_key: str,
    tensors: dict[str, Any],
) -> bool:
    if not weight_key.endswith(".self_attn.v_proj"):
        return False
    layer_index = layer_index_from_weight_key(weight_key)
    if layer_index is None:
        return False
    prefix = f"model.language_model.layers.{layer_index}.self_attn"
    has_v = tensor_exists(tensors, f"{prefix}.v_proj.weight")
    return (
        not has_v
        and tensor_exists(tensors, f"{prefix}.q_proj.weight")
        and tensor_exists(tensors, f"{prefix}.k_proj.weight")
        and tensor_exists(tensors, f"{prefix}.o_proj.weight")
    )


def per_layer_input_block_enabled(architecture: dict[str, Any]) -> bool:
    hidden = int(architecture.get("hiddenSizePerLayerInput") or 0)
    return hidden > 0


def is_architecture_disabled_per_layer_input_weight(
    weight_key: str,
    architecture: dict[str, Any],
) -> bool:
    return (
        weight_key.startswith(PER_LAYER_INPUT_KEY_PREFIX)
        and not per_layer_input_block_enabled(architecture)
    )


def is_linear_attention_session_state_key(weight_key: str) -> bool:
    parts = weight_key.split(".")
    return len(parts) == 3 and parts[0] == "layer" and parts[2] == "linear_attn"


def resolve_required_weight(
    *,
    weight_key: str,
    candidates: list[str],
    tensors: dict[str, Any],
    weight_root: Path,
    architecture: dict[str, Any],
    step: dict[str, Any] | None = None,
) -> dict[str, Any]:
    matched_tensor = next((c for c in candidates if c in tensors), None)
    matched_file = next((c for c in candidates if (weight_root / c).is_file()), None)
    if is_architecture_disabled_per_layer_input_weight(weight_key, architecture):
        return {
            "weightKey": weight_key,
            "candidates": candidates,
            "matchedTensor": None,
            "matchedFile": None,
            "resolutionKind": "architecture_disabled_session_input",
            "resolved": True,
        }
    if matched_tensor:
        if weight_key == "lm_head":
            tensor = tensors.get(matched_tensor) or {}
            dtype = str(tensor.get("dtype") or "")
            shape = tensor.get("shape") or []
            valid_dense = (
                is_dense_lm_head_step(step)
                and dtype in {"F16", "BF16", "F32"}
                and isinstance(shape, list)
                and len(shape) >= 2
                and int(shape[0] or 0) > 0
                and int(shape[1] or 0) > 0
            )
            valid_q4k = (
                is_q4k_lm_head_step(step)
                and dtype == "Q4_K_M"
                and (
                    ".lm_head." in matched_tensor
                    or matched_tensor.endswith("lm_head.weight")
                )
            )
            if not (valid_dense or valid_q4k):
                return {
                    "weightKey": weight_key,
                    "candidates": candidates,
                    "matchedTensor": matched_tensor,
                    "matchedFile": None,
                    "resolutionKind": "invalid_lm_head_dtype_selection",
                    "expected": (
                        "Q4_K_M explicit lm_head.weight"
                        if is_q4k_lm_head_step(step)
                        else "F16/BF16/F32 tied dense lm_head tensor"
                    ),
                    "actualDtype": dtype,
                    "actualShape": shape,
                    "resolved": False,
                }
        return {
            "weightKey": weight_key,
            "candidates": candidates,
            "matchedTensor": matched_tensor,
            "matchedFile": None,
            "resolutionKind": (
                "manifest_tied_dense_lm_head"
                if weight_key == "lm_head" and is_dense_lm_head_step(step)
                else "manifest_tensor"
            ),
            "resolved": True,
        }
    if matched_file:
        return {
            "weightKey": weight_key,
            "candidates": candidates,
            "matchedTensor": None,
            "matchedFile": matched_file,
            "resolutionKind": "sidecar_file",
            "resolved": True,
        }
    if is_linear_attention_absent_v_projection(weight_key, tensors):
        return {
            "weightKey": weight_key,
            "candidates": candidates,
            "matchedTensor": None,
            "matchedFile": None,
            "resolutionKind": "linear_attention_absent_v_projection",
            "linearAttentionPolicy": LINEAR_ATTENTION_POLICY,
            "resolved": True,
        }
    if is_linear_attention_session_state_key(weight_key):
        return {
            "weightKey": weight_key,
            "candidates": candidates,
            "matchedTensor": None,
            "matchedFile": None,
            "resolutionKind": "linear_attention_session_state",
            "resolved": True,
        }
    return {
        "weightKey": weight_key,
        "candidates": candidates,
        "matchedTensor": None,
        "matchedFile": None,
        "resolutionKind": "unresolved",
        "resolved": False,
    }


def build_weight_staging_plan(
    *,
    manifest_path: Path,
    smoke_config_path: Path,
    expected_model_id: str = MODEL_ID,
    lane_key: str = LANE_KEY,
) -> dict[str, Any]:
    manifest = load_json(manifest_path)
    smoke = load_json(smoke_config_path)
    profile = canonical_dtype_profile(manifest.get("quantizationInfo"))
    if manifest.get("modelId") != expected_model_id:
        raise ValueError(
            f"expected modelId {expected_model_id!r}, "
            f"got {manifest.get('modelId')!r}"
        )
    if profile.get("variantTag") != lane_key:
        raise ValueError(
            f"expected lane {lane_key!r}, got {profile.get('variantTag')!r}"
        )
    csl_dtype_contract = csl_dtype_contract_for_profile(
        profile,
        model_id=str(manifest.get("modelId") or ""),
    )

    weight_root = resolve_weight_root(manifest_path, manifest)
    shards = manifest.get("shards") or []
    missing_shards: list[str] = []
    size_mismatches: list[dict[str, Any]] = []
    present_shards = 0
    for shard in shards:
        if not isinstance(shard, dict):
            continue
        filename = str(shard.get("filename") or "")
        if not filename:
            continue
        path = weight_root / filename
        expected_size = int(shard.get("size") or 0)
        if not path.is_file():
            missing_shards.append(filename)
            continue
        present_shards += 1
        actual_size = path.stat().st_size
        if expected_size and actual_size != expected_size:
            size_mismatches.append({
                "filename": filename,
                "expectedSize": expected_size,
                "actualSize": actual_size,
            })

    tensors = manifest.get("tensors") or {}
    architecture = manifest.get("architecture") or {}
    ple_hidden = int(architecture.get("hiddenSizePerLayerInput") or 0)
    linear_attention_layers = linear_attention_layers_from_tensors(tensors)
    linear_attention_layer_set = set(linear_attention_layers)
    self_attention_layers = self_attention_layers_from_tensors(tensors)
    self_attention_layer_set = set(self_attention_layers)
    steps = [
        step
        for step in smoke.get("steps") or []
        if isinstance(step, dict)
    ]
    num_layers = int(
        architecture.get("numLayers")
        or (smoke.get("modelConfig") or {}).get("numLayers")
        or 0
    )
    required: dict[str, dict[str, Any]] = {}
    for layer_index in range(num_layers):
        for step in steps:
            key = infer_weight_key_for_step(step, layer_index)
            if not key:
                continue
            if (
                is_linear_attention_weight_key(key)
                and layer_index not in linear_attention_layer_set
            ):
                continue
            if (
                is_self_attention_weight_key(key)
                and self_attention_layer_set
                and layer_index not in self_attention_layer_set
            ):
                continue
            if key in required:
                continue
            candidates = tensor_candidates_for_key(key, step)
            required[key] = resolve_required_weight(
                weight_key=key,
                candidates=candidates,
                tensors=tensors,
                weight_root=weight_root,
                architecture=architecture,
                step=step,
            )

    unresolved = [
        key for key, record in required.items() if not record["resolved"]
    ]
    architecture_disabled_weight_keys = [
        key
        for key, record in required.items()
        if record.get("resolutionKind") == "architecture_disabled_session_input"
    ]
    return {
        "mode": "weightsRef_resident_session",
        "manifestPath": rel(manifest_path),
        "manifestSha256": sha256_file(manifest_path),
        "modelId": manifest.get("modelId"),
        "laneKey": profile["variantTag"],
        "dtypeProfile": profile,
        "cslDtypeContract": csl_dtype_contract,
        "weightPackId": (manifest.get("artifactIdentity") or {}).get(
            "weightPackId"
        ),
        "shardSetHash": (manifest.get("artifactIdentity") or {}).get(
            "shardSetHash"
        ),
        "weightRoot": rel(weight_root),
        "weightRootPresent": weight_root.is_dir(),
        "shardCount": len(shards),
        "presentShardCount": present_shards,
        "missingShards": missing_shards,
        "sizeMismatches": size_mismatches,
        "tensorCount": len(tensors),
        "modelLayerCount": num_layers,
        "linearAttentionLayers": linear_attention_layers,
        "selfAttentionLayers": self_attention_layers,
        "perLayerInputBlock": {
            "enabled": per_layer_input_block_enabled(architecture),
            "hiddenSizePerLayerInput": ple_hidden,
        },
        "requiredWeightCount": len(required),
        "resolvedWeightCount": sum(
            1 for record in required.values() if record["resolved"]
        ),
        "unresolvedWeightKeys": unresolved,
        "architectureDisabledWeightKeys": architecture_disabled_weight_keys,
        "requiredWeights": list(required.values()),
    }


def phase_steps(smoke: dict[str, Any], phase: str) -> list[dict[str, Any]]:
    return [
        step for step in smoke.get("steps") or []
        if isinstance(step, dict) and step.get("phase") == phase
    ]


def is_model_level_decode_step(step: dict[str, Any]) -> bool:
    name = str(step.get("name") or "")
    kernel = str(step.get("kernelKey") or "")
    return name in MODEL_LEVEL_DECODE_STEPS or kernel in LM_HEAD_KERNELS


def is_model_level_prefill_step(step: dict[str, Any]) -> bool:
    name = str(step.get("name") or "")
    kernel = str(step.get("kernelKey") or "")
    return name in MODEL_LEVEL_PREFILL_STEPS or kernel == "sample" or kernel in LM_HEAD_KERNELS


def build_dispatch_plan(
    *,
    smoke_config_path: Path,
    host_plan_path: Path,
    prefill_token_count: int,
    decode_token_count: int,
    model_layer_count: int | None = None,
    linear_attention_layers: list[int] | None = None,
    self_attention_layers: list[int] | None = None,
) -> dict[str, Any]:
    smoke = load_json(smoke_config_path)
    host_plan = load_json(host_plan_path)
    num_layers = int(
        model_layer_count
        if model_layer_count is not None
        else (smoke.get("modelConfig") or {}).get("numLayers") or 0
    )
    prefill_template = phase_steps(smoke, "prefill")
    decode_template = phase_steps(smoke, "decode")

    def layers_for_step(step: dict[str, Any]) -> list[int]:
        raw_key = step.get("weightsKey")
        if is_linear_attention_weight_key(raw_key):
            return list(linear_attention_layers or [])
        if is_self_attention_weight_key(raw_key) and self_attention_layers:
            return list(self_attention_layers)
        return list(range(num_layers))

    def expand_model_step(
        step: dict[str, Any],
        *,
        phase: str,
        token_index: int | None = None,
    ) -> dict[str, Any]:
        return {
            "phase": phase,
            "layer": None,
            "tokenIndex": token_index,
            "name": step.get("name"),
            "kernelKey": step.get("kernelKey"),
            "weightKey": infer_weight_key_for_step(step, 0),
        }

    def expand_layer_step(
        step: dict[str, Any],
        *,
        phase: str,
        layer_index: int,
        token_index: int | None = None,
    ) -> dict[str, Any]:
        record = {
            "phase": phase,
            "layer": layer_index,
            "name": step.get("name"),
            "kernelKey": step.get("kernelKey"),
            "weightKey": infer_weight_key_for_step(step, layer_index),
        }
        if token_index is not None:
            record["tokenIndex"] = token_index
        return record

    def expand_phase_steps(
        template: list[dict[str, Any]],
        *,
        phase: str,
        token_index: int | None = None,
    ) -> list[dict[str, Any]]:
        expanded: list[dict[str, Any]] = []
        layer_steps: list[dict[str, Any]] = []
        suffix_steps: list[dict[str, Any]] = []
        seen_layer_step = False
        for step in template:
            is_model_step = (
                step.get("kernelKey") == "embed"
                or (
                    is_model_level_prefill_step(step)
                    if phase == "prefill"
                    else is_model_level_decode_step(step)
                )
            )
            if is_model_step:
                if seen_layer_step:
                    suffix_steps.append(step)
                else:
                    expanded.append(
                        expand_model_step(
                            step,
                            phase=phase,
                            token_index=(
                                0
                                if step.get("kernelKey") == "sample"
                                and phase == "prefill"
                                else token_index
                            ),
                        )
                    )
                continue
            seen_layer_step = True
            layer_steps.append(step)

        for layer_index in range(num_layers):
            for step in layer_steps:
                if layer_index not in layers_for_step(step):
                    continue
                expanded.append(
                    expand_layer_step(
                        step,
                        phase=phase,
                        layer_index=layer_index,
                        token_index=token_index,
                    )
                )

        for step in suffix_steps:
            expanded.append(
                expand_model_step(
                    step,
                    phase=phase,
                    token_index=(
                        0
                        if step.get("kernelKey") == "sample"
                        and phase == "prefill"
                        else token_index
                    ),
                )
            )
        return expanded

    prefill: list[dict[str, Any]] = []
    prefill.extend(
        expand_phase_steps(
            prefill_template,
            phase="prefill",
        )
    )

    decode_by_token: list[dict[str, Any]] = []
    for token_index in range(1, decode_token_count):
        token_steps = expand_phase_steps(
            [
                step for step in decode_template
                if step.get("kernelKey") != "sample"
            ],
            phase="decode",
            token_index=token_index,
        )
        token_steps.append(
            {
                "phase": "decode",
                "tokenIndex": token_index,
                "layer": None,
                "name": "sample",
                "kernelKey": "sample",
                "weightKey": None,
            }
        )
        decode_by_token.append({
            "tokenIndex": token_index,
            "steps": token_steps,
        })

    compact_host_plan = host_plan.get("hostPlan") or {}
    return {
        "kind": "expanded_execution_v1_hostplan_stream",
        "smokeConfigPath": rel(smoke_config_path),
        "smokeConfigSha256": sha256_file(smoke_config_path),
        "hostPlanPath": rel(host_plan_path),
        "hostPlanHash": sha256_file(host_plan_path),
        "prefillTokenCount": prefill_token_count,
        "decodeTokenCount": decode_token_count,
        "modelLayerCount": num_layers,
        "prefillStepCount": len(prefill),
        "decodeStepCount": sum(len(item["steps"]) for item in decode_by_token),
        "prefillSteps": prefill,
        "decodeByToken": decode_by_token,
        "prefillPreview": prefill[:8],
        "decodePreview": decode_by_token[:1],
        "compactHostPlanPhaseKernelCounts": {
            key: len(value)
            for key, value in (compact_host_plan.get("phases") or {}).items()
            if isinstance(value, list)
        },
    }
