"""HostPlan scheduler assembly for Gemma 4 31B af16 sessions."""

from __future__ import annotations

from typing import Any

from gemma4_31b_af16_session_common import (
    LM_HEAD_KERNELS,
    PER_LAYER_INPUT_KERNELS,
    PREFILL_Q4K_GEMV_KERNELS,
    PREFILL_Q4K_GEMV_PATTERN,
    SUMMA_KERNELS,
)

def binding(
    *,
    symbol: str,
    buffer: str,
    role: str,
    access: str,
    source: str,
    **fields: Any,
) -> dict[str, Any]:
    result = {
        "symbol": symbol,
        "buffer": buffer,
        "role": role,
        "access": access,
        "source": source,
    }
    for key, value in fields.items():
        if value is not None:
            result[key] = value
    return result


def symbol_table_entry(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "buffer": item["buffer"],
        "role": item["role"],
        "access": item["access"],
    }


def append_symbol_table_entry(
    symbols: dict[str, dict[str, Any]],
    item: dict[str, Any],
) -> None:
    symbol = item["symbol"]
    entry = symbol_table_entry(item)
    existing = symbols.get(symbol)
    if existing is None:
        symbols[symbol] = entry
        return
    bindings = existing.get("bindings")
    if isinstance(bindings, list):
        bindings.append(entry)
    else:
        bindings = [symbol_table_entry(existing), entry]
    buffers = {str(record.get("buffer") or "") for record in bindings}
    roles = {str(record.get("role") or "") for record in bindings}
    accesses = {str(record.get("access") or "") for record in bindings}
    symbols[symbol] = {
        "buffer": next(iter(buffers)) if len(buffers) == 1 else "multiple",
        "role": next(iter(roles)) if len(roles) == 1 else "inout",
        "access": next(iter(accesses)) if len(accesses) == 1 else "readwrite",
        "bindings": bindings,
    }


def routed_tensor_role(buffer: str) -> str:
    if buffer.startswith("state:kv_cache"):
        return "kv_cache"
    return "activation"


def output_buffer(step: dict[str, Any], launch_index: int) -> str:
    layer = step.get("layer")
    token = step.get("tokenIndex")
    layer_part = "global" if layer is None else f"layer{layer}"
    token_part = "" if token is None else f":token{token}"
    return f"activation:{step['phase']}{token_part}:{launch_index:04d}:{layer_part}:{step['name']}"


def build_real_session_scheduler(
    *,
    dispatch_plan: dict[str, Any],
    runtime_config: dict[str, Any],
    architecture_disabled_weight_keys: list[str] | None = None,
    per_layer_input_block_enabled: bool = True,
    initial_activation_buffer: str = "input:prompt_token_ids",
) -> dict[str, Any]:
    launches: list[dict[str, Any]] = []
    blockers: list[str] = []
    sample_feedback_edges: list[dict[str, Any]] = []
    kv_operations: list[dict[str, Any]] = []
    transcript_emitters: list[dict[str, Any]] = []
    elided_operations: list[dict[str, Any]] = []
    lifetimes: dict[str, dict[str, Any]] = {}
    current = initial_activation_buffer
    layer_state: dict[int, dict[str, str]] = {}
    last_generated_token = "input:prompt_token_ids"
    last_logits = ""
    last_logits_launch_index: int | None = None
    disabled_weight_keys = {
        str(item)
        for item in architecture_disabled_weight_keys or []
        if str(item)
    }
    weight_shapes = {
        str(item.get("weightKey") or item.get("tensor") or ""): (
            item.get("shape") if isinstance(item.get("shape"), list) else []
        )
        for item in runtime_config.get("weightMappings") or []
        if isinstance(item, dict)
    }

    def weight_matrix_dims(weight_key: Any) -> tuple[int | None, int | None]:
        shape = weight_shapes.get(str(weight_key or "")) or []
        if len(shape) < 2:
            return None, None
        try:
            return int(shape[0]), int(shape[1])
        except (TypeError, ValueError):
            return None, None

    def touch_input(buffer: str, role: str, launch_index: int) -> None:
        item = lifetimes.setdefault(
            buffer,
            {
                "buffer": buffer,
                "role": role,
                "producerLaunchIndex": None,
                "firstConsumerLaunchIndex": None,
                "lastConsumerLaunchIndex": None,
                "consumerCount": 0,
            },
        )
        if item["firstConsumerLaunchIndex"] is None:
            item["firstConsumerLaunchIndex"] = launch_index
        item["lastConsumerLaunchIndex"] = launch_index
        item["consumerCount"] += 1

    def touch_output(buffer: str, role: str, launch_index: int) -> None:
        item = lifetimes.setdefault(
            buffer,
            {
                "buffer": buffer,
                "role": role,
                "producerLaunchIndex": None,
                "firstConsumerLaunchIndex": None,
                "lastConsumerLaunchIndex": None,
                "consumerCount": 0,
            },
        )
        if item["producerLaunchIndex"] is None:
            item["producerLaunchIndex"] = launch_index

    def make_launch(step: dict[str, Any]) -> None:
        nonlocal current, last_generated_token, last_logits, last_logits_launch_index
        launch_index = len(launches)
        kernel = str(step.get("kernelKey") or "")
        name = str(step.get("name") or kernel)
        weight_key = step.get("weightKey")
        is_lm_head = (
            name == "lm_head"
            or kernel in LM_HEAD_KERNELS
            or weight_key == "lm_head"
        )
        layer = step.get("layer")
        layer_idx = layer if isinstance(layer, int) else None
        state = layer_state.setdefault(layer_idx if layer_idx is not None else -1, {})
        inputs: list[dict[str, Any]] = []
        outputs: list[dict[str, Any]] = []

        def elide_operation(reason: str, *, input_buffer: str = "") -> None:
            elided_operations.append(
                {
                    "phase": step["phase"],
                    "layerIndex": layer_idx,
                    "decodeStepIndex": step.get("tokenIndex"),
                    "operationName": name,
                    "kernelName": kernel,
                    "weightKey": weight_key,
                    "reason": reason,
                    "inputBuffer": input_buffer,
                    "aliasRole": "current_activation",
                    "aliasBuffer": input_buffer,
                }
            )

        def add_input(
            symbol: str,
            buffer_name: str,
            role: str,
            source: str,
            **fields: Any,
        ) -> None:
            inputs.append(
                binding(
                    symbol=symbol,
                    buffer=buffer_name,
                    role=role,
                    access="read",
                    source=source,
                    **fields,
                )
            )
            touch_input(buffer_name, role, launch_index)

        def add_output(
            symbol: str,
            buffer_name: str,
            role: str,
            source: str,
            **fields: Any,
        ) -> None:
            outputs.append(
                binding(
                    symbol=symbol,
                    buffer=buffer_name,
                    role=role,
                    access="write",
                    source=source,
                    **fields,
                )
            )
            touch_output(buffer_name, role, launch_index)

        out = output_buffer(step, launch_index)
        if kernel in PER_LAYER_INPUT_KERNELS and not per_layer_input_block_enabled:
            elide_operation(
                "architecture_disabled_per_layer_input_block",
                input_buffer=current if kernel == "ple_residual" else "",
            )
            return
        if kernel in {"embed", "ple_embed"}:
            token_source = (
                "input:prompt_token_ids"
                if step["phase"] == "prefill"
                else last_generated_token
            )
            add_input("indices", token_source, "tokenized_prompt", "runtime_prompt")
            add_input("table", f"weight:{step.get('weightKey')}", "weight", "weights")
            add_output("output", out, "activation", f"{kernel}.output")
            if kernel == "ple_embed":
                state["ple_gather"] = out
            current = out
        elif kernel in SUMMA_KERNELS:
            matrix_n, matrix_k = weight_matrix_dims(weight_key)
            if kernel == "ple_proj":
                source = state.get("ple_gather", current)
            elif name in {"q_proj", "k_proj", "v_proj"}:
                source = state.get("attn_norm", current)
            elif name in {"gate_proj", "up_proj"}:
                source = state.get("ffn_norm", current)
            elif name == "down_proj":
                source = state.get("activation", current)
            else:
                source = current
            add_input(
                "a",
                source,
                "activation",
                "activation_router",
                matrixCols=matrix_k,
            )
            add_input("b", f"weight:{step.get('weightKey')}", "weight", "weights")
            add_output(
                "c",
                out,
                "logits" if is_lm_head else "activation",
                f"{kernel}.output",
                matrixCols=matrix_n,
            )
            if is_lm_head:
                decode_index = int(step.get("tokenIndex") or 0)
                last_logits = out
                last_logits_launch_index = launch_index
                transcript_emitters.append(
                    {
                        "kind": "logits_digest",
                        "stepIndex": decode_index,
                        "launchIndex": launch_index,
                        "symbol": "c",
                        "buffer": out,
                        "expectedSha256": None,
                    }
                )
            else:
                if kernel == "ple_proj":
                    state["ple_project"] = out
                    current = out
                elif name in {"q_proj", "k_proj", "v_proj"}:
                    state[name[0]] = out
                    state[f"{name[0]}_cols"] = matrix_n
                elif name in {"gate_proj", "up_proj"}:
                    state[name] = out
                else:
                    current = out
        elif kernel in PREFILL_Q4K_GEMV_KERNELS:
            matrix_n, matrix_k = weight_matrix_dims(weight_key)
            if name in {"q_proj", "k_proj", "v_proj"}:
                source = state.get("attn_norm", current)
            elif name in {"gate_proj", "up_proj"}:
                source = state.get("ffn_norm", current)
            elif name == "down_proj":
                source = state.get("activation", current)
            else:
                source = current
            add_input(
                "activation",
                source,
                "activation",
                "activation_router",
                matrixCols=matrix_k,
            )
            add_input("weight", f"weight:{step.get('weightKey')}", "weight", "weights")
            add_output(
                "output",
                out,
                "logits" if is_lm_head else "activation",
                f"{kernel}.output",
                matrixCols=matrix_n,
            )
            if is_lm_head:
                decode_index = int(step.get("tokenIndex") or 0)
                last_logits = out
                last_logits_launch_index = launch_index
                transcript_emitters.append(
                    {
                        "kind": "logits_digest",
                        "stepIndex": decode_index,
                        "launchIndex": launch_index,
                        "symbol": "output",
                        "buffer": out,
                        "expectedSha256": None,
                    }
                )
            else:
                if name in {"q_proj", "k_proj", "v_proj"}:
                    state[name[0]] = out
                    state[f"{name[0]}_cols"] = matrix_n
                elif name in {"gate_proj", "up_proj"}:
                    state[name] = out
                    current = out
                else:
                    current = out
        elif kernel in {"gemv", *LM_HEAD_KERNELS}:
            if name in {"q_proj", "k_proj", "v_proj"}:
                source = state.get("attn_norm", current)
            elif name in {"gate_proj", "up_proj"}:
                source = state.get("ffn_norm", current)
            elif name == "down_proj":
                source = state.get("activation", current)
            else:
                source = current
            add_input("activation", source, "activation", "activation_router")
            add_input("weight", f"weight:{weight_key}", "weight", "weights")
            add_output(
                "output",
                out,
                "logits" if is_lm_head else "activation",
                f"{kernel}.output",
            )
            if name in {"q_proj", "k_proj", "v_proj"}:
                state[name[0]] = out
            elif name in {"gate_proj", "up_proj"}:
                state[name] = out
            if is_lm_head:
                decode_index = int(step.get("tokenIndex") or 0)
                last_logits = out
                last_logits_launch_index = launch_index
                transcript_emitters.append(
                    {
                        "kind": "logits_digest",
                        "stepIndex": decode_index,
                        "launchIndex": launch_index,
                        "symbol": "output",
                        "buffer": out,
                        "expectedSha256": None,
                    }
                )
            else:
                if name not in {
                    "q_proj",
                    "k_proj",
                    "v_proj",
                    "gate_proj",
                    "up_proj",
                }:
                    current = out
        elif kernel in {"rmsnorm", "ple_rmsnorm"}:
            norm_input = (
                state.get("ple_project", current)
                if kernel == "ple_rmsnorm"
                else current
            )
            if kernel == "ple_rmsnorm" and str(weight_key or "") in disabled_weight_keys:
                state["ple_norm"] = norm_input
                current = norm_input
                elide_operation(
                    "architecture_disabled_session_input",
                    input_buffer=norm_input,
                )
                return
            add_input("input", norm_input, "activation", "activation_router")
            add_input("weight", f"weight:{step.get('weightKey')}", "weight", "weights")
            add_output("output", out, "activation", f"{kernel}.output")
            if kernel == "ple_rmsnorm":
                state["ple_norm"] = out
            if name == "input_norm":
                state["residual_base"] = current
                state["attn_norm"] = out
            elif name == "post_attn_norm":
                state["ffn_residual_base"] = current
                state["ffn_norm"] = out
            elif name == "q_norm":
                state["q"] = out
            elif name == "k_norm":
                state["k"] = out
            current = out
        elif kernel in {"rope", "rope_partial"}:
            source_key = "q" if name == "rope_q" else "k"
            source = state.get(source_key, current)
            source_cols = state.get(f"{source_key}_cols")
            add_input(
                "input",
                source,
                "activation",
                "activation_router",
                matrixCols=source_cols,
            )
            add_input(
                "cos_table",
                "state:rope_cos_table",
                "position_encoding",
                "runtime_state",
            )
            add_input(
                "sin_table",
                "state:rope_sin_table",
                "position_encoding",
                "runtime_state",
            )
            add_output(
                "input",
                out,
                "activation",
                "rope.output",
                matrixCols=source_cols,
            )
            state[source_key] = out
            if source_cols is not None:
                state[f"{source_key}_cols"] = source_cols
            if name not in {"rope_q", "rope_k"}:
                current = out
        elif kernel in {
            "attn_small",
            "attn_decode",
            "attn_decode_sliding",
            "attn_prefill_kv_axis_sharded",
        }:
            query = state.get("q", current)
            key = state.get("kv_key") or state.get("k", "state:kv_cache:key")
            val = state.get("kv_val") or state.get("v", "state:kv_cache:value")
            query_cols = state.get("q_cols")
            key_cols = state.get("k_cols")
            val_cols = state.get("v_cols")
            value_symbol = (
                "value"
                if kernel == "attn_prefill_kv_axis_sharded"
                else "val"
            )
            add_input(
                "query",
                query,
                "activation",
                "activation_router",
                matrixCols=query_cols,
            )
            add_input(
                "key",
                key,
                routed_tensor_role(key),
                "kv_or_activation_router",
                matrixCols=key_cols,
            )
            add_input(
                value_symbol,
                val,
                routed_tensor_role(val),
                "kv_or_activation_router",
                matrixCols=val_cols,
            )
            if kernel in {"attn_decode", "attn_decode_sliding"}:
                add_input(
                    "position",
                    "state:decode_position",
                    "position",
                    "runtime_state",
                )
                add_input(
                    "sliding_window",
                    "state:sliding_window",
                    "position",
                    "runtime_state",
                )
            add_output(
                "output",
                out,
                "activation",
                f"{kernel}.output",
                matrixCols=query_cols,
            )
            if query_cols is not None:
                state["attention_cols"] = query_cols
            kv_operations.append(
                {
                    "launchIndex": launch_index,
                    "phase": step["phase"],
                    "decodeStepIndex": step.get("tokenIndex"),
                    "layerIndex": layer_idx,
                    "attentionKernel": kernel,
                    "write": {
                        "keyBuffer": state.get("k", key),
                        "valueBuffer": state.get("v", val),
                        "cacheBuffer": "state:kv_cache",
                        "positionSource": "decode_position",
                    },
                    "read": {
                        "keyBuffer": key,
                        "valueBuffer": val,
                        "cacheBuffer": "state:kv_cache",
                        "slidingWindowSource": (
                            "sliding_window"
                            if kernel == "attn_decode"
                            else "prefill_full_context"
                        ),
                    },
                }
            )
            current = out
        elif kernel in {"kv_write", "kv_write_shared"}:
            key_cache = (
                f"state:kv_cache:layer{layer_idx}:"
                f"token{step.get('tokenIndex')}:key"
            )
            val_cache = (
                f"state:kv_cache:layer{layer_idx}:"
                f"token{step.get('tokenIndex')}:val"
            )
            add_input(
                "key_proj",
                state.get("k", current),
                "activation",
                "activation_router",
            )
            add_input(
                "val_proj",
                state.get("v", current),
                "activation",
                "activation_router",
            )
            add_input("position", "state:decode_position", "position", "runtime_state")
            add_output(
                "key_cache",
                key_cache,
                "kv_cache",
                f"{kernel}.key_cache",
            )
            add_output(
                "val_cache",
                val_cache,
                "kv_cache",
                f"{kernel}.val_cache",
            )
            state["kv_key"] = key_cache
            state["kv_val"] = val_cache
        elif kernel == "ssm_conv1d_depthwise":
            add_input("input", current, "activation", "activation_router")
            add_input("weight", f"weight:{weight_key}", "weight", "weights")
            add_input("bias", f"weight:{weight_key}:bias", "weight", "weights")
            add_output("output", out, "activation", f"{kernel}.output")
            current = out
        elif kernel == "ssm_l2_normalize":
            add_input("input", current, "activation", "activation_router")
            add_output("output", out, "activation", f"{kernel}.output")
            if name == "ssm_q_l2_normalize":
                state["q"] = out
            elif name == "ssm_k_l2_normalize":
                state["k"] = out
            current = out
        elif kernel == "ssm_linear_attention":
            add_input("query", state.get("q", current), "activation", "activation_router")
            add_input("key", state.get("k", current), "activation", "activation_router")
            add_input("value", state.get("v", current), "activation", "activation_router")
            add_input("gate", current, "activation", "activation_router")
            add_input(
                "linear_state",
                f"state:linear_attention:layer{layer_idx}",
                "linear_attention_state",
                "runtime_state",
            )
            add_output("output", out, "activation", f"{kernel}.output")
            current = out
        elif kernel in {"o_gate", "silu_gated", "gelu_gated", "sigmoid_gated"}:
            input_source = state.get("up_proj") if kernel == "gelu_gated" else current
            if not input_source:
                input_source = current
            gate_source = state.get("gate_proj") or current
            add_input("gate", gate_source, "activation", "activation_router")
            add_input("input", input_source, "activation", "activation_router")
            add_output("output", out, "activation", f"{kernel}.output")
            if name == "activation":
                state["activation"] = out
            current = out
        elif kernel == "residual":
            residual = (
                state.get("residual_base")
                if name == "attn_residual"
                else state.get("ffn_residual_base")
            )
            if not residual:
                residual = "activation:missing:residual"
                blockers.append(f"launch[{launch_index}].residual_base_missing:{name}")
            add_input("input", current, "activation", "activation_router")
            add_input("residual", residual, "activation", "activation_router")
            add_output("output", out, "activation", "residual.output")
            current = out
        elif kernel == "ple_residual":
            add_input("u", "state:decode_position", "position", "runtime_state")
            add_input(
                "input",
                state.get("ple_norm", current),
                "activation",
                "activation_router",
            )
            add_output("output", out, "activation", "ple_residual.output")
            state["ple_modulate"] = out
            current = out
        elif kernel == "gelu":
            gelu_input = state.get("gate_proj") or current
            add_input("input", gelu_input, "activation", "activation_router")
            add_output("output", out, "activation", "gelu.output")
            state["activation"] = out
            current = out
        elif kernel == "sample":
            if not last_logits:
                blockers.append(f"launch[{launch_index}].sample_logits_producer_missing")
                last_logits = "logits:missing"
            token_buffer = f"tokens:decode:{launch_index:04d}"
            add_input("logits", last_logits, "logits", "transcript_capture")
            add_output("tokens", token_buffer, "generated_tokens", "sample.output")
            transcript_emitters.append(
                {
                    "kind": "generated_token",
                    "stepIndex": int(step.get("tokenIndex") or 0),
                    "launchIndex": launch_index,
                    "symbol": "tokens",
                    "buffer": token_buffer,
                    "logitsBuffer": last_logits,
                    "logitsLaunchIndex": last_logits_launch_index,
                }
            )
            decode_index = int(step.get("tokenIndex") or 0)
            if decode_index + 1 < int(dispatch_plan["decodeTokenCount"]):
                sample_feedback_edges.append(
                    {
                        "fromLaunchIndex": launch_index,
                        "tokenBuffer": token_buffer,
                        "toDecodeStepIndex": decode_index + 1,
                    }
                )
            last_generated_token = token_buffer
        else:
            add_input("input", current, "activation", "activation_router")
            add_output("output", out, "activation", f"{kernel}.output")
            current = out

        symbols: dict[str, dict[str, Any]] = {}
        for item in [*inputs, *outputs]:
            append_symbol_table_entry(symbols, item)
        launches.append(
            {
                "launchIndex": launch_index,
                "phase": step["phase"],
                "phaseLaunchIndex": launch_index,
                "kernelName": kernel,
                "kernelPattern": PREFILL_Q4K_GEMV_PATTERN
                if kernel in PREFILL_Q4K_GEMV_KERNELS
                else kernel,
                "repeat": 1,
                "operationName": name,
                "layerIndex": layer_idx,
                "decodeStepIndex": step.get("tokenIndex"),
                "weightKey": step.get("weightKey"),
                "inputs": inputs,
                "outputs": outputs,
                "symbols": symbols,
                "symbolDataflowPresent": True,
                "inputSymbolCount": len(inputs),
                "outputSymbolCount": len(outputs),
                "symbolTablePresent": True,
            }
        )

    for step in dispatch_plan.get("prefillSteps") or []:
        make_launch(step)
    for token in dispatch_plan.get("decodeByToken") or []:
        for step in token.get("steps") or []:
            make_launch(step)

    model_layers = int(runtime_config.get("modelConfig", {}).get("numLayers") or 0)
    covered_layers = sorted(
        {
            op.get("layerIndex")
            for op in kv_operations
            if isinstance(op.get("layerIndex"), int)
        }
    )
    expected_decode_steps = int(dispatch_plan["decodeTokenCount"])
    is_suffix_splice = str(dispatch_plan.get("kind") or "").startswith(
        "doppler_csl_splice"
    )
    expected_kv_layer_count = len(covered_layers) if is_suffix_splice else model_layers
    logits_emitters = [
        item for item in transcript_emitters if item["kind"] == "logits_digest"
    ]
    token_emitters = [
        item for item in transcript_emitters if item["kind"] == "generated_token"
    ]
    if len(logits_emitters) != expected_decode_steps:
        blockers.append(
            f"transcript_logits_emitter_count:{len(logits_emitters)}!={expected_decode_steps}"
        )
    if len(token_emitters) != expected_decode_steps:
        blockers.append(
            f"transcript_token_emitter_count:{len(token_emitters)}!={expected_decode_steps}"
        )
    transcript_bound = (
        len(logits_emitters) == expected_decode_steps
        and len(token_emitters) == expected_decode_steps
    )
    transcript_status = "bound" if transcript_bound else "blocked_missing_decode_emitters"
    status = "bound" if not blockers else "blocked"
    return {
        "status": status,
        "blockers": blockers,
        "validationScope": {
            "kind": "doppler_csl_suffix_splice" if is_suffix_splice else "full_model",
            "requiresTranscript": expected_decode_steps > 0,
            "requiresFullKvCoverage": not is_suffix_splice,
            "expectedKvLayerCount": expected_kv_layer_count,
            "initialActivationBuffer": initial_activation_buffer,
        },
        "externalInputBuffers": (
            []
            if initial_activation_buffer == "input:prompt_token_ids"
            else [initial_activation_buffer]
        ),
        "runtimeExpansion": {
            "decodeIterationCount": int(dispatch_plan["decodeTokenCount"]),
            "runtimeLaunchCount": len(launches),
            "elidedOperationCount": len(elided_operations),
        },
        "elidedOperations": elided_operations,
        "activationRouting": {
            "status": "bound",
            "bufferCount": len(lifetimes),
            "routedBufferCount": len(lifetimes),
            "lifetimes": sorted(lifetimes.values(), key=lambda item: item["buffer"]),
        },
        "kvCacheSchedule": {
            "status": "bound" if kv_operations else "blocked_missing_kv_operations",
            "cacheWriteCount": len(kv_operations),
            "cacheReadCount": len(kv_operations),
            "layerCoverage": {
                "layerCount": model_layers,
                "expectedCoveredLayerCount": expected_kv_layer_count,
                "coveredLayerCount": len(covered_layers),
                "coveredLayers": covered_layers,
            },
            "operations": kv_operations,
        },
        "sampleFeedback": {
            "status": (
                "bound"
                if len(sample_feedback_edges)
                == max(0, int(dispatch_plan["decodeTokenCount"]) - 1)
                else "blocked"
            ),
            "edges": sample_feedback_edges,
        },
        "transcriptCaptureSchedule": {
            "status": transcript_status,
            "expectedActualDecodeSteps": expected_decode_steps,
            "logitsEmitterCount": len(logits_emitters),
            "tokenEmitterCount": len(token_emitters),
            "emitters": transcript_emitters,
        },
        "launches": launches,
    }
