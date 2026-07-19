// emit_csl_host_runtime.zig — Full host-runtime scaffold for WSE-3 deployment.
//
// Extends the basic host plan (emit_csl_host.zig) with:
//   - Weight staging: shard→PE memcpy_h2d mapping and emission
//   - State allocation: KV cache zeroing, position counters, scratch buffers
//   - Decode orchestration: position tracking, KV append, batch support
//   - Output readback: logit extraction, token selection, multi-token output
//   - Failure handling: timeout, SRAM overflow pre-check, launch error recovery
//
// Emits an enhanced Python runner scaffold and a JSON runtime configuration.

const std = @import("std");
const host = @import("emit_csl_host.zig");
const spec = @import("csl_spec.zig");
const mem_plan = @import("emit_csl_mem_plan.zig");

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
};

/// Weight shard → PE buffer mapping for host-side staging.
pub const WeightMapping = struct {
    shard_name: []const u8,
    shard_path: []const u8,
    shard_sha256: []const u8,
    pe_buffer: []const u8,
    pe_start: u32,
    pe_end: u32,
    dtype: Dtype = .f16,
    tensor_name: []const u8,
    tensor_offset_bytes: u64,
    tensor_shape: []const u64,
    quant: QuantMetadata,

    pub const Dtype = enum { f16, u8_q4k, u8_q8 };

    pub const QuantMetadata = struct {
        format: []const u8,
        storage_dtype: []const u8,
        source_dtype: ?[]const u8 = null,
        block_size_elements: ?u32 = null,
        block_size_bytes: ?u32 = null,
        encoding: ?[]const u8 = null,
    };
};

pub const WeightMappingStatus = struct {
    status: Status,
    proof_status: ProofStatus,
    reason: []const u8,
    synthetic_weights: bool = false,

    pub const Status = enum { artifact_backed, blocked };
    pub const ProofStatus = enum { not_proven };
};

/// Persistent state buffer allocated on PEs.
pub const StateBuffer = struct {
    name: []const u8,
    kind: Kind,
    bytes_per_pe: u64,

    pub const Kind = enum { kv_cache, position, scratch };
};

/// Full host runtime configuration.
pub const RuntimeConfig = struct {
    plan: host.HostPlan,
    config: host.ModelConfig,
    weight_mappings: []const WeightMapping,
    weight_mapping_count: u32,
    weight_mapping_status: ?WeightMappingStatus = null,
    state_buffers: []const StateBuffer,
    state_buffer_count: u32,
    memory_plan: ?mem_plan.MemoryPlan = null,
    max_decode_tokens: u32 = 128,
    timeout_ms: u32 = 30_000,
    batch_size: u32 = 1,
};

/// Emit a JSON runtime configuration for programmatic consumers.
pub fn emitRuntimeConfigJson(buf: []u8, pos: *usize, rt: RuntimeConfig) EmitError!void {
    const wm_count = rt.weight_mapping_count;
    const mapping_status = rt.weight_mapping_status orelse defaultWeightMappingStatus(wm_count);

    try write(buf, pos, "{\n");
    try write(buf, pos, "  \"schemaVersion\": ");
    try writeInt(buf, pos, spec.RUNTIME_CONFIG_SCHEMA_VERSION);
    try write(buf, pos, ",\n  \"artifactKind\": \"");
    try write(buf, pos, spec.RUNTIME_CONFIG_ARTIFACT_KIND);
    try write(buf, pos, "\",\n  \"target\": \"");
    try write(buf, pos, spec.RUNTIME_CONFIG_TARGET);
    try write(buf, pos, "\",\n  \"contract\": \"");
    try write(buf, pos, spec.RUNTIME_CONFIG_CONTRACT);
    try write(buf, pos, "\",\n");
    try write(buf, pos, "  \"mode\": \"compile-only\",\n");
    try write(buf, pos, "  \"runtimeExecutableEnvVar\": \"DOE_CSL_RUNTIME_EXECUTABLE\",\n");
    try write(buf, pos, "  \"modelConfig\": {\n");
    try write(buf, pos, "    \"hiddenDim\": ");
    try writeInt(buf, pos, rt.config.hidden_dim);
    try write(buf, pos, ",\n    \"numHeads\": ");
    try writeInt(buf, pos, rt.config.num_heads);
    try write(buf, pos, ",\n    \"headDim\": ");
    try writeInt(buf, pos, rt.config.head_dim);
    if (rt.config.global_head_dim) |global_head_dim| {
        try write(buf, pos, ",\n    \"globalHeadDim\": ");
        try writeInt(buf, pos, global_head_dim);
    }
    if (rt.config.num_key_value_heads) |num_key_value_heads| {
        try write(buf, pos, ",\n    \"numKeyValueHeads\": ");
        try writeInt(buf, pos, num_key_value_heads);
    }
    try write(buf, pos, ",\n    \"numLayers\": ");
    try writeInt(buf, pos, rt.config.num_layers);
    try write(buf, pos, ",\n    \"vocabSize\": ");
    try writeInt(buf, pos, rt.config.vocab_size);
    try write(buf, pos, ",\n    \"maxSeqLen\": ");
    try writeInt(buf, pos, rt.config.max_seq_len);
    try write(buf, pos, ",\n    \"quantFormat\": \"");
    try write(buf, pos, @tagName(rt.config.quant_format));
    try write(buf, pos, "\",\n    \"ffnExpansionFactor\": ");
    try writeInt(buf, pos, rt.config.ffn_expansion_factor);
    try write(buf, pos, ",\n    \"ffnMatrixCount\": ");
    try writeInt(buf, pos, rt.config.ffn_matrix_count);
    if (rt.config.ple_width) |ple_width| {
        try write(buf, pos, ",\n    \"pleWidth\": ");
        try writeInt(buf, pos, ple_width);
    }
    if (rt.config.ple_vocab_size) |ple_vocab_size| {
        try write(buf, pos, ",\n    \"pleVocabSize\": ");
        try writeInt(buf, pos, ple_vocab_size);
    }
    try write(buf, pos, "\n  },\n");
    try write(buf, pos, "  \"maxDecodeTokens\": ");
    try writeInt(buf, pos, rt.max_decode_tokens);
    try write(buf, pos, ",\n  \"timeoutMs\": ");
    try writeInt(buf, pos, rt.timeout_ms);
    try write(buf, pos, ",\n  \"batchSize\": ");
    try writeInt(buf, pos, rt.batch_size);
    try write(buf, pos, ",\n");
    try write(buf, pos, "  \"weightMappingStatus\": {\n");
    try write(buf, pos, "    \"status\": ");
    try writeJsonString(buf, pos, @tagName(mapping_status.status));
    try write(buf, pos, ",\n    \"proofStatus\": ");
    try writeJsonString(buf, pos, @tagName(mapping_status.proof_status));
    try write(buf, pos, ",\n    \"reason\": ");
    try writeJsonString(buf, pos, mapping_status.reason);
    try write(buf, pos, ",\n    \"syntheticWeights\": ");
    try write(buf, pos, if (mapping_status.synthetic_weights) "true" else "false");
    try write(buf, pos, "\n  },\n");

    // Weight mappings
    try write(buf, pos, "  \"weightMappings\": [\n");
    for (rt.weight_mappings[0..wm_count], 0..) |wm, idx| {
        try write(buf, pos, "    {\n");
        try write(buf, pos, "      \"shard\": ");
        try writeJsonString(buf, pos, wm.shard_name);
        try write(buf, pos, ",\n      \"path\": ");
        try writeJsonString(buf, pos, wm.shard_path);
        try write(buf, pos, ",\n      \"sha256\": ");
        try writeJsonString(buf, pos, wm.shard_sha256);
        try write(buf, pos, ",\n      \"peBuffer\": ");
        try writeJsonString(buf, pos, wm.pe_buffer);
        try write(buf, pos, ",\n      \"peRange\": [");
        try writeInt(buf, pos, wm.pe_start);
        try write(buf, pos, ", ");
        try writeInt(buf, pos, wm.pe_end);
        try write(buf, pos, "],\n      \"dtype\": ");
        try writeJsonString(buf, pos, @tagName(wm.dtype));
        try write(buf, pos, ",\n      \"tensor\": ");
        try writeJsonString(buf, pos, wm.tensor_name);
        try write(buf, pos, ",\n      \"offsetBytes\": ");
        try writeInt(buf, pos, wm.tensor_offset_bytes);
        try write(buf, pos, ",\n      \"shape\": [");
        for (wm.tensor_shape, 0..) |dim, dim_idx| {
            if (dim_idx > 0) try write(buf, pos, ", ");
            try writeInt(buf, pos, dim);
        }
        try write(buf, pos, "],\n      \"quant\": {\n");
        try write(buf, pos, "        \"format\": ");
        try writeJsonString(buf, pos, wm.quant.format);
        try write(buf, pos, ",\n        \"storageDtype\": ");
        try writeJsonString(buf, pos, wm.quant.storage_dtype);
        if (wm.quant.source_dtype) |source_dtype| {
            try write(buf, pos, ",\n        \"sourceDtype\": ");
            try writeJsonString(buf, pos, source_dtype);
        }
        if (wm.quant.block_size_elements) |block_size_elements| {
            try write(buf, pos, ",\n        \"blockSizeElements\": ");
            try writeInt(buf, pos, block_size_elements);
        }
        if (wm.quant.block_size_bytes) |block_size_bytes| {
            try write(buf, pos, ",\n        \"blockSizeBytes\": ");
            try writeInt(buf, pos, block_size_bytes);
        }
        if (wm.quant.encoding) |encoding| {
            try write(buf, pos, ",\n        \"encoding\": ");
            try writeJsonString(buf, pos, encoding);
        }
        try write(buf, pos, "\n      }\n    }");
        if (idx + 1 < wm_count) try write(buf, pos, ",");
        try write(buf, pos, "\n");
    }
    try write(buf, pos, "  ],\n");

    if (rt.memory_plan) |memory_plan_value| {
        try write(buf, pos, "  \"memoryPlan\": {\n");
        try write(buf, pos, "    \"grid\": { \"width\": ");
        try writeInt(buf, pos, memory_plan_value.grid_width);
        try write(buf, pos, ", \"height\": ");
        try writeInt(buf, pos, memory_plan_value.grid_height);
        try write(buf, pos, " },\n");
        try write(buf, pos, "    \"residencyMode\": \"");
        try write(buf, pos, @tagName(memory_plan_value.residency_mode));
        try write(buf, pos, "\",\n    \"totalModelBytes\": ");
        try writeInt(buf, pos, memory_plan_value.total_model_bytes);
        try write(buf, pos, ",\n    \"totalPersistentBytes\": ");
        try writeInt(buf, pos, memory_plan_value.total_persistent_bytes);
        try write(buf, pos, ",\n    \"totalStreamedBytes\": ");
        try writeInt(buf, pos, memory_plan_value.total_streamed_bytes);
        try write(buf, pos, ",\n    \"persistentBytesPerPe\": ");
        try writeInt(buf, pos, memory_plan_value.persistent_bytes_per_pe);
        try write(buf, pos, ",\n    \"streamedWorkingSetBytesPerPe\": ");
        try writeInt(buf, pos, memory_plan_value.streamed_working_set_bytes_per_pe);
        try write(buf, pos, ",\n    \"fits\": ");
        try write(buf, pos, if (memory_plan_value.fits) "true" else "false");
        try write(buf, pos, "\n  },\n");
    }

    // State buffers
    try write(buf, pos, "  \"stateBuffers\": [\n");
    const sb_count = rt.state_buffer_count;
    for (rt.state_buffers[0..sb_count], 0..) |sb, idx| {
        try write(buf, pos, "    { \"name\": \"");
        try write(buf, pos, sb.name);
        try write(buf, pos, "\", \"kind\": \"");
        try write(buf, pos, @tagName(sb.kind));
        try write(buf, pos, "\", \"bytesPerPe\": ");
        try writeInt(buf, pos, sb.bytes_per_pe);
        try write(buf, pos, " }");
        if (idx + 1 < sb_count) try write(buf, pos, ",");
        try write(buf, pos, "\n");
    }
    try write(buf, pos, "  ]\n}\n");
}

/// Emit the enhanced Python runner with weight staging, state management,
/// decode orchestration, and failure handling.
pub fn emitFullPythonRunner(buf: []u8, pos: *usize, rt: RuntimeConfig) EmitError!void {
    try write(buf, pos, "#!/usr/bin/env python3\n");
    try write(buf, pos, "\"\"\"WSE-3 host runtime — generated from explicit host plan.\n\n");
    try write(buf, pos, "Capabilities: weight staging, state init, decode loop, error handling.\n");
    try write(buf, pos, "\"\"\"\n\n");
    try write(buf, pos, "import subprocess\nimport sys\nimport time\nimport numpy as np\nimport json\n\n");

    // Constants
    try emitConstants(buf, pos, rt);

    // Weight staging
    try emitWeightStaging(buf, pos, rt);

    // State initialization
    try emitStateInit(buf, pos, rt);

    // SRAM pre-check
    try emitSramPreCheck(buf, pos);

    // Launch helpers
    try emitLaunchHelpers(buf, pos, rt);

    // Decode orchestration
    try emitDecodeOrchestration(buf, pos, rt);

    // Output readback
    try emitOutputReadback(buf, pos);

    // Error handling wrapper
    try emitErrorHandling(buf, pos);

    // Main entry point
    try emitMainEntry(buf, pos);
}

fn emitConstants(buf: []u8, pos: *usize, rt: RuntimeConfig) EmitError!void {
    try write(buf, pos, "# --- Model constants ---\n");
    try write(buf, pos, "HIDDEN_DIM = ");
    try writeInt(buf, pos, rt.config.hidden_dim);
    try write(buf, pos, "\nNUM_HEADS = ");
    try writeInt(buf, pos, rt.config.num_heads);
    try write(buf, pos, "\nHEAD_DIM = ");
    try writeInt(buf, pos, rt.config.head_dim);
    try write(buf, pos, "\nNUM_LAYERS = ");
    try writeInt(buf, pos, rt.config.num_layers);
    try write(buf, pos, "\nVOCAB_SIZE = ");
    try writeInt(buf, pos, rt.config.vocab_size);
    try write(buf, pos, "\nMAX_SEQ_LEN = ");
    try writeInt(buf, pos, rt.config.max_seq_len);
    try write(buf, pos, "\n\n# --- Runtime constants ---\n");
    try write(buf, pos, "PE_GRID_WIDTH = ");
    try writeInt(buf, pos, rt.plan.pe_grid_width);
    try write(buf, pos, "\nPE_GRID_HEIGHT = ");
    try writeInt(buf, pos, rt.plan.pe_grid_height);
    try write(buf, pos, "\nMAX_DECODE_TOKENS = ");
    try writeInt(buf, pos, rt.max_decode_tokens);
    try write(buf, pos, "\nTIMEOUT_MS = ");
    try writeInt(buf, pos, rt.timeout_ms);
    try write(buf, pos, "\nBATCH_SIZE = ");
    try writeInt(buf, pos, rt.batch_size);
    try write(buf, pos, "\nPE_SRAM_BYTES = ");
    try writeInt(buf, pos, @as(u64, spec.PE_SRAM_BYTES));
    try write(buf, pos, "\nEOS_TOKEN_ID = ");
    if (rt.plan.eos_token_id) |eos| {
        try writeInt(buf, pos, eos);
    } else {
        try write(buf, pos, "None");
    }
    try write(buf, pos, "\n\n");
}

fn emitWeightStaging(buf: []u8, pos: *usize, rt: RuntimeConfig) EmitError!void {
    try write(buf, pos,
        \\# --- Weight staging ---
        \\WEIGHT_MAPPINGS = [
        \\
    );
    const wm_count = rt.weight_mapping_count;
    for (rt.weight_mappings[0..wm_count]) |wm| {
        try write(buf, pos, "    {'shard': '");
        try write(buf, pos, wm.shard_name);
        try write(buf, pos, "', 'pe_buffer': '");
        try write(buf, pos, wm.pe_buffer);
        try write(buf, pos, "', 'pe_range': (");
        try writeInt(buf, pos, wm.pe_start);
        try write(buf, pos, ", ");
        try writeInt(buf, pos, wm.pe_end);
        try write(buf, pos, "), 'dtype': '");
        try write(buf, pos, @tagName(wm.dtype));
        try write(buf, pos, "'},\n");
    }
    try write(buf, pos,
        \\]
        \\
        \\def load_and_stage_weights(runner, rdrr_path):
        \\    """Load RDRR shards and stage weight data to PE buffers via memcpy_h2d."""
        \\    manifest = json.load(open(f'{rdrr_path}/manifest.json'))
        \\    shard_data = {}
        \\    for shard in manifest['shards']:
        \\        blob = np.fromfile(f"{rdrr_path}/{shard['filename']}", dtype=np.uint8)
        \\        shard_data[shard['filename']] = blob
        \\    staged = 0
        \\    for wm in WEIGHT_MAPPINGS:
        \\        shard_name = wm['shard']
        \\        if shard_name not in shard_data:
        \\            raise RuntimeError(f"Weight shard '{shard_name}' not found in manifest")
        \\        data = shard_data[shard_name]
        \\        pe_start, pe_end = wm['pe_range']
        \\        pe_count = pe_end - pe_start
        \\        chunk_size = len(data) // pe_count
        \\        for pe_idx in range(pe_start, pe_end):
        \\            offset = (pe_idx - pe_start) * chunk_size
        \\            chunk = data[offset:offset + chunk_size]
        \\            runner.memcpy_h2d(wm['pe_buffer'], chunk, pe=pe_idx)
        \\        staged += 1
        \\    return staged
        \\
        \\
    );
}

fn emitStateInit(buf: []u8, pos: *usize, rt: RuntimeConfig) EmitError!void {
    try write(buf, pos,
        \\# --- State initialization ---
        \\STATE_BUFFERS = [
        \\
    );
    const sb_count = rt.state_buffer_count;
    for (rt.state_buffers[0..sb_count]) |sb| {
        try write(buf, pos, "    {'name': '");
        try write(buf, pos, sb.name);
        try write(buf, pos, "', 'kind': '");
        try write(buf, pos, @tagName(sb.kind));
        try write(buf, pos, "', 'bytes_per_pe': ");
        try writeInt(buf, pos, sb.bytes_per_pe);
        try write(buf, pos, "},\n");
    }
    try write(buf, pos,
        \\]
        \\
        \\def init_state(runner):
        \\    """Zero-initialize KV caches, position counters, and scratch buffers."""
        \\    for sb in STATE_BUFFERS:
        \\        zeros = np.zeros(sb['bytes_per_pe'], dtype=np.uint8)
        \\        for pe_idx in range(PE_GRID_WIDTH * PE_GRID_HEIGHT):
        \\            runner.memcpy_h2d(sb['name'], zeros, pe=pe_idx)
        \\    return len(STATE_BUFFERS)
        \\
        \\
    );
}

fn emitSramPreCheck(buf: []u8, pos: *usize) EmitError!void {
    try write(buf, pos,
        \\def sram_pre_check():
        \\    """Estimate per-PE SRAM usage and fail fast if it exceeds capacity."""
        \\    weight_bytes = sum(m.get('bytes_per_pe', 0) for m in WEIGHT_MAPPINGS if 'bytes_per_pe' in m)
        \\    state_bytes = sum(sb['bytes_per_pe'] for sb in STATE_BUFFERS)
        \\    total = weight_bytes + state_bytes
        \\    if total > PE_SRAM_BYTES:
        \\        raise RuntimeError(
        \\            f"SRAM overflow: {total} bytes/PE > {PE_SRAM_BYTES} capacity. "
        \\            f"Reduce model size or increase PE grid width."
        \\        )
        \\    return total
        \\
        \\
    );
}

fn emitLaunchHelpers(buf: []u8, pos: *usize, rt: RuntimeConfig) EmitError!void {
    try write(buf, pos, "# --- Launch sequences ---\nPREFILL_LAUNCHES = [\n");
    for (rt.plan.prefill_launches) |launch| {
        try writeLaunchDict(buf, pos, launch);
    }
    try write(buf, pos, "]\n\nDECODE_LAUNCHES = [\n");
    for (rt.plan.decode_launches) |launch| {
        try writeLaunchDict(buf, pos, launch);
    }
    try write(buf, pos,
        \\]
        \\
        \\def run_launches(runner, launches, current_pos=None):
        \\    """Execute a sequence of kernel launches with repeat counts."""
        \\    for launch in launches:
        \\        kernel_name = launch['kernelName']
        \\        repeat = launch['repeat']
        \\        for _ in range(repeat):
        \\            if 'slidingWindowSize' in launch:
        \\                runner.memcpy_h2d('sliding_window', np.array([launch['slidingWindowSize']], dtype=np.uint32))
        \\            if launch.get('currentPosSource') == 'decode_position':
        \\                if current_pos is None:
        \\                    raise ValueError('decode_position launch requires current_pos')
        \\                runner.memcpy_h2d('position', np.array([current_pos], dtype=np.uint32))
        \\            runner.launch(kernel_name)
        \\
        \\
    );
}

fn emitDecodeOrchestration(buf: []u8, pos: *usize, rt: RuntimeConfig) EmitError!void {
    _ = rt;
    try write(buf, pos,
        \\# --- Decode orchestration ---
        \\def run_prefill(runner, token_ids):
        \\    """Run prefill phase: stage full prompt, execute prefill launches."""
        \\    runner.memcpy_h2d('indices', np.array(token_ids, dtype=np.uint32))
        \\    runner.memcpy_h2d('position', np.array([len(token_ids)], dtype=np.uint32))
        \\    if any('slidingWindowSize' in launch for launch in PREFILL_LAUNCHES):
        \\        raise ValueError('prefill launches must not request sliding window state')
        \\    run_launches(runner, PREFILL_LAUNCHES)
        \\    return len(token_ids)
        \\
        \\def run_decode_step(runner, token_id, position):
        \\    """Run one decode step: stage token + position, execute, readback."""
        \\    runner.memcpy_h2d('indices', np.array([token_id], dtype=np.uint32))
        \\    runner.memcpy_h2d('position', np.array([position], dtype=np.uint32))
        \\    run_launches(runner, DECODE_LAUNCHES, current_pos=position)
        \\    logits = runner.memcpy_d2h('output', dtype=np.float32)
        \\    return int(np.argmax(logits))
        \\
        \\def decode_loop(runner, prompt_ids, max_tokens=None):
        \\    """Full autoregressive decode with position tracking and EOS detection."""
        \\    if max_tokens is None:
        \\        max_tokens = MAX_DECODE_TOKENS
        \\    generated = list(prompt_ids)
        \\    position = run_prefill(runner, prompt_ids)
        \\    start_time = time.monotonic()
        \\    for step in range(max_tokens):
        \\        elapsed_ms = (time.monotonic() - start_time) * 1000
        \\        if elapsed_ms > TIMEOUT_MS:
        \\            raise TimeoutError(
        \\                f"Decode timed out after {step} tokens ({elapsed_ms:.0f}ms > {TIMEOUT_MS}ms)"
        \\            )
        \\        next_token = run_decode_step(runner, generated[-1], position)
        \\        if EOS_TOKEN_ID is not None and next_token == EOS_TOKEN_ID:
        \\            break
        \\        generated.append(next_token)
        \\        position += 1
        \\        if position >= MAX_SEQ_LEN:
        \\            break
        \\    return generated
        \\
        \\def decode_batch(runner, prompt_batch, max_tokens=None):
        \\    """Run decode loop for each prompt in the batch sequentially."""
        \\    results = []
        \\    for prompt_ids in prompt_batch:
        \\        init_state(runner)
        \\        result = decode_loop(runner, prompt_ids, max_tokens)
        \\        results.append(result)
        \\    return results
        \\
        \\
    );
}

fn emitOutputReadback(buf: []u8, pos: *usize) EmitError!void {
    try write(buf, pos,
        \\# --- Output readback ---
        \\def readback_logits(runner, vocab_size=None):
        \\    """Read full logit vector from device for external sampling."""
        \\    if vocab_size is None:
        \\        vocab_size = VOCAB_SIZE
        \\    raw = runner.memcpy_d2h('output', dtype=np.float32)
        \\    return raw[:vocab_size]
        \\
        \\def readback_kv_cache(runner, layer_idx):
        \\    """Read KV cache state for a specific layer (debugging/validation)."""
        \\    k_buf = runner.memcpy_d2h(f'kv_cache_k_{layer_idx}', dtype=np.float16)
        \\    v_buf = runner.memcpy_d2h(f'kv_cache_v_{layer_idx}', dtype=np.float16)
        \\    return k_buf, v_buf
        \\
        \\
    );
}

fn emitErrorHandling(buf: []u8, pos: *usize) EmitError!void {
    try write(buf, pos,
        \\# --- Error handling ---
        \\def safe_run(runner, prompt_ids, max_tokens=None):
        \\    """Decode with error recovery: catches launch failures, reports context."""
        \\    try:
        \\        return decode_loop(runner, prompt_ids, max_tokens)
        \\    except TimeoutError as e:
        \\        print(f"[TIMEOUT] {e}", file=sys.stderr)
        \\        return None
        \\    except RuntimeError as e:
        \\        msg = str(e)
        \\        if 'SRAM' in msg or 'overflow' in msg:
        \\            print(f"[SRAM_OVERFLOW] {e}", file=sys.stderr)
        \\        elif 'launch' in msg.lower():
        \\            print(f"[LAUNCH_FAILURE] {e}", file=sys.stderr)
        \\        else:
        \\            print(f"[RUNTIME_ERROR] {e}", file=sys.stderr)
        \\        return None
        \\
        \\
    );
}

fn emitMainEntry(buf: []u8, pos: *usize) EmitError!void {
    try write(buf, pos,
        \\if __name__ == '__main__':
        \\    sram_pre_check()
        \\    try:
        \\        import cerebras.sdk.runtime as csl_rt
        \\        runner = csl_rt.SdkRunner()
        \\    except ImportError:
        \\        print('Cerebras SDK not available; emitted host scaffold only.')
        \\        raise SystemExit(0)
        \\    staged = load_and_stage_weights(runner, 'model_rdrr')
        \\    print(f'Staged {staged} weight mappings')
        \\    init_count = init_state(runner)
        \\    print(f'Initialized {init_count} state buffers')
        \\    result = safe_run(runner, [1])
        \\    if result is not None:
        \\        print(f'Generated {len(result)} tokens')
        \\    else:
        \\        print('Decode failed — see error above')
        \\        raise SystemExit(1)
        \\
    );
}

fn write(buf: []u8, pos: *usize, text: []const u8) EmitError!void {
    if (pos.* + text.len > buf.len) return error.OutputTooLarge;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
}

fn writeJsonString(buf: []u8, pos: *usize, text: []const u8) EmitError!void {
    try write(buf, pos, "\"");
    for (text) |c| {
        switch (c) {
            '"' => try write(buf, pos, "\\\""),
            '\\' => try write(buf, pos, "\\\\"),
            '\n' => try write(buf, pos, "\\n"),
            '\r' => try write(buf, pos, "\\r"),
            '\t' => try write(buf, pos, "\\t"),
            else => try writeByte(buf, pos, c),
        }
    }
    try write(buf, pos, "\"");
}

fn writeByte(buf: []u8, pos: *usize, byte: u8) EmitError!void {
    if (pos.* + 1 > buf.len) return error.OutputTooLarge;
    buf[pos.*] = byte;
    pos.* += 1;
}

fn defaultWeightMappingStatus(weight_mapping_count: u32) WeightMappingStatus {
    if (weight_mapping_count == 0) {
        return .{
            .status = .blocked,
            .proof_status = .not_proven,
            .reason = "execution-v1 did not provide artifact-backed weightMappings",
        };
    }
    return .{
        .status = .artifact_backed,
        .proof_status = .not_proven,
        .reason = "execution-v1 provided artifact-backed weightMappings; runtime proof remains blocked until transcript parity consumes them",
    };
}

fn writeLaunchDict(buf: []u8, pos: *usize, launch: host.LaunchSpec) EmitError!void {
    try write(buf, pos, "    {'kernelName': '");
    try write(buf, pos, launch.kernel_name);
    try write(buf, pos, "', 'repeat': ");
    try writeInt(buf, pos, launch.repeat);
    if (launch.attention_type) |attention_type| {
        try write(buf, pos, ", 'attentionType': '");
        try write(buf, pos, @tagName(attention_type));
        try write(buf, pos, "'");
    }
    if (launch.sliding_window_size) |sliding_window_size| {
        try write(buf, pos, ", 'slidingWindowSize': ");
        try writeInt(buf, pos, sliding_window_size);
    }
    if (launch.current_pos_source) |current_pos_source| {
        try write(buf, pos, ", 'currentPosSource': '");
        try write(buf, pos, @tagName(current_pos_source));
        try write(buf, pos, "'");
    }
    if (launch.kv_cache_alias) |kv_cache_alias| {
        try write(buf, pos, ", 'kvCacheAlias': '");
        try write(buf, pos, kv_cache_alias);
        try write(buf, pos, "'");
    }
    try write(buf, pos, "},\n");
}

fn writeInt(buf: []u8, pos: *usize, value: anytype) EmitError!void {
    var tmp: [32]u8 = undefined;
    const slice = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return error.OutputTooLarge;
    try write(buf, pos, slice);
}

test "runtime config JSON emits weight mappings and state buffers" {
    const kernels = [_]host.KernelSpec{
        .{ .name = "embed", .pattern = "gather" },
    };
    const prefill = [_]host.LaunchSpec{
        .{ .kernel_name = "embed" },
    };
    const decode = [_]host.LaunchSpec{
        .{ .kernel_name = "embed" },
    };
    const shape = [_]u64{ 262144, 1536 };
    const wm = [_]WeightMapping{
        .{
            .shard_name = "shard_00038.bin",
            .shard_path = "model/shard_00038.bin",
            .shard_sha256 = "6a0e8ecfb1190554392143f79434839b629ee9284a3fd643d84cb62522a0cdcd",
            .pe_buffer = "weights_embed",
            .pe_start = 0,
            .pe_end = 16,
            .dtype = .u8_q4k,
            .tensor_name = "embed_tokens.weight",
            .tensor_offset_bytes = 2550136832,
            .tensor_shape = &shape,
            .quant = .{
                .format = "Q4_K_M",
                .storage_dtype = "uint8",
                .source_dtype = "float16",
                .block_size_elements = 256,
                .block_size_bytes = 144,
                .encoding = "rdrr_int4ple",
            },
        },
    };
    const sb = [_]StateBuffer{
        .{ .name = "kv_cache_0", .kind = .kv_cache, .bytes_per_pe = 4096 },
        .{ .name = "pos_counter", .kind = .position, .bytes_per_pe = 4 },
    };
    const rt = RuntimeConfig{
        .plan = .{
            .pe_grid_width = 16,
            .kernels = &kernels,
            .prefill_launches = &prefill,
            .decode_launches = &decode,
        },
        .config = .{
            .hidden_dim = 1024,
            .num_heads = 16,
            .head_dim = 64,
            .num_layers = 24,
            .vocab_size = 151936,
            .max_seq_len = 2048,
            .quant_format = .q4k,
        },
        .weight_mappings = &wm,
        .weight_mapping_count = 1,
        .state_buffers = &sb,
        .state_buffer_count = 2,
    };

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try emitRuntimeConfigJson(&buf, &pos, rt);
    const json_str = buf[0..pos];
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"artifactKind\": \"csl_runtime_config\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"mode\": \"compile-only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"weightMappings\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"status\": \"artifact_backed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"proofStatus\": \"not_proven\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "shard_00038.bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"tensor\": \"embed_tokens.weight\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"offsetBytes\": 2550136832") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"format\": \"Q4_K_M\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"stateBuffers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "kv_cache") != null);
}

test "runtime config JSON marks empty weight mappings as blocked non proof" {
    const kernels = [_]host.KernelSpec{
        .{ .name = "embed", .pattern = "gather" },
    };
    const prefill = [_]host.LaunchSpec{
        .{ .kernel_name = "embed" },
    };
    const rt = RuntimeConfig{
        .plan = .{
            .pe_grid_width = 16,
            .kernels = &kernels,
            .prefill_launches = &prefill,
            .decode_launches = &.{},
        },
        .config = .{
            .hidden_dim = 1024,
            .num_heads = 16,
            .head_dim = 64,
            .num_layers = 24,
            .vocab_size = 151936,
            .max_seq_len = 2048,
            .quant_format = .q4k,
        },
        .weight_mappings = &.{},
        .weight_mapping_count = 0,
        .state_buffers = &.{},
        .state_buffer_count = 0,
    };

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try emitRuntimeConfigJson(&buf, &pos, rt);
    const json_str = buf[0..pos];
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"status\": \"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"proofStatus\": \"not_proven\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"syntheticWeights\": false") != null);
}

test "full Python runner emits staging, state init, and decode" {
    const kernels = [_]host.KernelSpec{
        .{ .name = "embed", .pattern = "gather" },
        .{ .name = "attn_decode", .pattern = "attention_decode" },
    };
    const prefill = [_]host.LaunchSpec{
        .{ .kernel_name = "embed" },
    };
    const decode = [_]host.LaunchSpec{
        .{
            .kernel_name = "attn_decode",
            .attention_type = .sliding,
            .sliding_window_size = 512,
            .current_pos_source = .decode_position,
        },
    };
    const shape = [_]u64{ 1024, 1024 };
    const wm = [_]WeightMapping{
        .{
            .shard_name = "embed.bin",
            .shard_path = "model/embed.bin",
            .shard_sha256 = "6a0e8ecfb1190554392143f79434839b629ee9284a3fd643d84cb62522a0cdcd",
            .pe_buffer = "weights",
            .pe_start = 0,
            .pe_end = 8,
            .dtype = .u8_q4k,
            .tensor_name = "embed.weight",
            .tensor_offset_bytes = 0,
            .tensor_shape = &shape,
            .quant = .{
                .format = "Q4_K_M",
                .storage_dtype = "uint8",
            },
        },
    };
    const sb = [_]StateBuffer{
        .{ .name = "kv_cache", .kind = .kv_cache, .bytes_per_pe = 2048 },
    };
    const rt = RuntimeConfig{
        .plan = .{
            .pe_grid_width = 8,
            .kernels = &kernels,
            .prefill_launches = &prefill,
            .decode_launches = &decode,
            .eos_token_id = 151645,
        },
        .config = .{
            .hidden_dim = 1024,
            .num_heads = 16,
            .head_dim = 64,
            .num_layers = 24,
            .vocab_size = 151936,
            .max_seq_len = 2048,
            .quant_format = .q4k,
        },
        .weight_mappings = &wm,
        .weight_mapping_count = 1,
        .state_buffers = &sb,
        .state_buffer_count = 1,
    };

    var buf: [32768]u8 = undefined;
    var pos: usize = 0;
    try emitFullPythonRunner(&buf, &pos, rt);
    const script = buf[0..pos];
    // Weight staging
    try std.testing.expect(std.mem.indexOf(u8, script, "load_and_stage_weights") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "memcpy_h2d") != null);
    // State init
    try std.testing.expect(std.mem.indexOf(u8, script, "init_state") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "STATE_BUFFERS") != null);
    // Decode orchestration
    try std.testing.expect(std.mem.indexOf(u8, script, "decode_loop") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "position") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "sliding_window") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "EOS_TOKEN_ID") != null);
    // Failure handling
    try std.testing.expect(std.mem.indexOf(u8, script, "safe_run") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "TimeoutError") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "SRAM_OVERFLOW") != null);
    // SRAM pre-check
    try std.testing.expect(std.mem.indexOf(u8, script, "sram_pre_check") != null);
}
