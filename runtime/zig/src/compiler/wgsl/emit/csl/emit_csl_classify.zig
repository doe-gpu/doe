// emit_csl_classify.zig — Kernel pattern classifier for the CSL backend.
//
// Walks the IR to determine which CSL emission template to use. GPU backends
// can translate any IR mechanically because they share the SIMT execution
// model. CSL requires pattern-specific templates because the WSE execution
// model (PE-local memory, fabric routing, wavelet-triggered tasks) has no
// shared-memory or barrier primitives.
//
// Classification is conservative: unknown patterns return .unsupported so
// the caller can reject them with an explicit error rather than emitting
// broken CSL.
//
// Pattern families (mapped from Doppler's kernel inventory):
//   element_wise       — gelu, silu, relu, scale, bias_add, residual, cast, modulate
//   reduction          — rmsnorm, layernorm, softmax (workgroup reductions)
//   tiled_matmul       — matmul_f16_tiled, matmul_f32 (shared-memory tiled GEMM)
//   gather             — embedding lookup (indices → table → output)
//   rope               — rotary position embeddings (sin/cos paired-dim)
//   attention_streaming — per-thread online softmax, no shared mem (Qwen linear attn)
//   attention_decode    — chunked KV with workgroup/subgroup reductions
//   attention_tiled     — Flash Attention tiling for prefill
//   dequant            — Q4K/Q6K/Q8 block dequantization
//   sample             — top-k + softmax + multinomial sampling
//   fused_gemv_dequant — on-the-fly dequant + matrix-vector product

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const maps = @import("emit_csl_maps.zig");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const ElementWiseInfo = struct {
    input_count: u32,
    output_count: u32,
    has_size_guard: bool,
};

pub const ReductionInfo = struct {
    shared_global_index: u32,
    input_count: u32,
    output_count: u32,
    has_apply_phase: bool,
    distributed: bool = false,
};

pub const MatmulInfo = struct {
    tile_a_global: u32,
    tile_b_global: u32,
    tile_m: u32,
    tile_n: u32,
    tile_k: u32,
};

pub const GatherInfo = struct {
    /// Index of the indices buffer (array<u32>).
    indices_global: u32,
    /// Index of the embedding table buffer.
    table_global: u32,
    /// Index of the output buffer.
    output_global: u32,
};

pub const RoPEInfo = struct {
    /// Index of the input/output buffer (read_write for in-place).
    input_global: u32,
    /// Indices of cos/sin frequency table buffers.
    cos_global: u32,
    sin_global: u32,
};

pub const AttentionStreamingInfo = struct {
    q_global: u32,
    k_global: u32,
    v_global: u32,
    output_global: u32,
    input_count: u32,
    output_count: u32,
};

pub const AttentionDecodeInfo = struct {
    q_global: u32,
    k_global: u32,
    v_global: u32,
    output_global: u32,
    shared_count: u32,
    input_count: u32,
    output_count: u32,
};

pub const AttentionTiledInfo = struct {
    q_global: u32,
    k_global: u32,
    v_global: u32,
    output_global: u32,
    shared_k_global: u32,
    shared_v_global: u32,
    input_count: u32,
    output_count: u32,
};

pub const DequantInfo = struct {
    /// Index of the quantized input buffer (struct-typed).
    quant_global: u32,
    /// Index of the f32 output buffer.
    output_global: u32,
    input_count: u32,
    output_count: u32,
};

pub const SampleInfo = struct {
    /// Index of the logits input buffer.
    logits_global: u32,
    /// Index of the u32 token output buffer.
    tokens_global: u32,
    input_count: u32,
    output_count: u32,
};

pub const FusedGemvDequantInfo = struct {
    /// Index of the activation input buffer.
    activation_global: u32,
    /// Index of the quantized weight buffer (struct-typed).
    weight_global: u32,
    /// Index of the output buffer.
    output_global: u32,
    input_count: u32,
    output_count: u32,
};

pub const AttentionLinearInfo = struct {
    q_global: u32,
    k_global: u32,
    v_global: u32,
    output_global: u32,
    input_count: u32,
    output_count: u32,
};

pub const KvWriteInfo = struct {
    /// Projected key/value inputs to write.
    key_proj_global: u32,
    val_proj_global: u32,
    /// Cache buffers (read_write) to append to.
    key_cache_global: u32,
    val_cache_global: u32,
};

pub const KvReadInfo = struct {
    /// Cache buffers to read from.
    key_cache_global: u32,
    val_cache_global: u32,
    /// Output buffers for the slice read.
    key_out_global: u32,
    val_out_global: u32,
};

pub const FusedFfnInfo = struct {
    input_global: u32,
    gate_weight_global: u32,
    up_weight_global: u32,
    output_global: u32,
    input_count: u32,
    output_count: u32,
};

pub const KernelPattern = union(enum) {
    element_wise: ElementWiseInfo,
    reduction: ReductionInfo,
    tiled_matmul: MatmulInfo,
    /// SUMMA tiled matmul where the B operand is a Q4_K_M-quantized
    /// byte stream rather than f32; the PE program runs a dequant
    /// prologue per broadcast step. Same MatmulInfo shape as
    /// `tiled_matmul` (tile_a/tile_b/tile_m/tile_n/tile_k); the
    /// distinguishing feature is dispatch (PE program: emit_csl_matmul_q4k).
    /// Wedge 3: variant is registered and switch sites are exhaustive,
    /// but classifier never emits this variant yet — that arrives in
    /// Wedge 4 (classifier extension).
    tiled_matmul_q4k_dequant_b: MatmulInfo,
    gather: GatherInfo,
    rope: RoPEInfo,
    attention_streaming: AttentionStreamingInfo,
    attention_decode: AttentionDecodeInfo,
    attention_tiled: AttentionTiledInfo,
    dequant: DequantInfo,
    sample: SampleInfo,
    fused_gemv_dequant: FusedGemvDequantInfo,
    attention_linear: AttentionLinearInfo,
    kv_write: KvWriteInfo,
    kv_read: KvReadInfo,
    fused_ffn: FusedFfnInfo,
    unsupported: []const u8,
};

pub fn patternContractValid(pattern: KernelPattern) bool {
    return switch (pattern) {
        .element_wise => |info| info.input_count > 0 and info.output_count > 0 and info.has_size_guard,
        .reduction => |info| info.input_count > 0 and info.output_count > 0 and info.has_apply_phase,
        .tiled_matmul => |info| info.tile_m > 0 and info.tile_n > 0 and info.tile_k > 0,
        // Q4K block alignment (Kt % 256 == 0) is a host-plan concern at
        // SUMMA dispatch time (Kt = 2560 for Gemma 4 31B), not a
        // classifier-derived MatmulInfo invariant. The classifier's
        // tile_k reflects the WGSL inner K-loop shape and is not the
        // SUMMA Kt. The 256-alignment check belongs in the host plan.
        .tiled_matmul_q4k_dequant_b => |info| info.tile_m > 0 and info.tile_n > 0 and info.tile_k > 0,
        .gather => |info| info.indices_global != info.table_global and
            info.output_global != info.indices_global and
            info.output_global != info.table_global,
        .rope => |info| info.input_global != info.cos_global and
            info.input_global != info.sin_global and
            info.cos_global != info.sin_global,
        .attention_streaming => |info| info.input_count > 0 and info.output_count > 0,
        .attention_decode => |info| info.shared_count > 0 and info.input_count > 0 and info.output_count > 0,
        .attention_tiled => |info| info.shared_k_global != info.shared_v_global and
            info.input_count > 0 and
            info.output_count > 0,
        .dequant => |info| info.input_count > 0 and info.output_count > 0,
        .sample => |info| info.input_count > 0 and info.output_count > 0,
        .fused_gemv_dequant => |info| info.input_count > 0 and info.output_count > 0,
        .attention_linear => |info| info.input_count > 0 and info.output_count > 0,
        .kv_write => |info| info.key_proj_global != info.key_cache_global and
            info.val_proj_global != info.val_cache_global and
            info.key_cache_global != info.val_cache_global,
        .kv_read => |info| info.key_cache_global != info.key_out_global and
            info.val_cache_global != info.val_out_global and
            info.key_out_global != info.val_out_global,
        .fused_ffn => |info| info.input_count > 0 and info.output_count > 0,
        .unsupported => false,
    };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn classify(module: *const ir.Module, entry: ir.EntryPoint) KernelPattern {
    if (entry.stage != .compute) {
        return .{ .unsupported = "only compute shaders can target CSL" };
    }

    const function = &module.functions.items[entry.function];

    // Collect structural properties.
    var props = AnalysisProps{};
    analyzeGlobals(module, &props);
    props.has_barriers = hasBarrierCalls(function);
    props.has_subgroup_ops = hasSubgroupOps(function);
    props.has_size_guard = hasSizeGuard(function);
    props.loop_count = countLoops(function);

    // Check for unsupported builtins (textures, atomics, derivatives).
    if (hasUnsupportedBuiltins(function)) {
        return .{ .unsupported = "kernel uses builtins with no CSL equivalent" };
    }

    // Attention-evidence-gated QKV fallback. The name-based hints in
    // analyzeGlobals already set has_qkv_buffers when a buffer name
    // contains "K" or "key" etc; only run the count-based fallback when
    // there's actual attention evidence, so 3-input FMA kernels don't
    // land in the attention_linear branch below.
    if (!props.has_qkv_buffers and hasAttentionEvidence(module, function, &props)) {
        applyQkvFallback(module, &props);
    }

    // --- Specific pattern matching (most specific first) ---

    // Gather: has u32 indices buffer + table buffer, no shared mem, no barriers
    if (props.has_u32_indices and props.workgroup_globals == 0 and !props.has_barriers) {
        return .{ .gather = .{
            .indices_global = props.indices_global,
            .table_global = props.table_global,
            .output_global = props.first_rw_global,
        } };
    }

    // RoPE: has read_write input + cos/sin frequency buffers, no shared mem
    if (props.has_freq_buffers and props.workgroup_globals == 0 and !props.has_barriers) {
        return .{ .rope = .{
            .input_global = props.first_rw_global,
            .cos_global = props.cos_global,
            .sin_global = props.sin_global,
        } };
    }

    // Tiled matmul with Q4K-quantized B input: struct storage (Q4K block
    // weight buffer) + 2 workgroup-shared tiles (A tile + dequanted B
    // tile) + barriers + at least one tiling loop. This must come before
    // the generic dequant/fused_gemv_dequant branch below — without the
    // earlier short-circuit, a Q4K-input tiled matmul would land in
    // fused_gemv_dequant (which targets vector output, not full GEMM).
    if (props.has_struct_storage and !props.has_qkv_buffers and
        props.workgroup_globals == 2 and props.has_barriers and
        props.loop_count >= 1)
    {
        return .{
            .tiled_matmul_q4k_dequant_b = extractMatmulInfo(module, props.wg_indices[0..2]),
        };
    }

    // Dequant: has struct-typed input buffer (Q4K block), no attention buffers
    if (props.has_struct_storage and !props.has_qkv_buffers and props.workgroup_globals <= 4) {
        if (props.has_barriers or props.workgroup_globals > 0) {
            // Fused GEMV + dequant: struct weights + activation input + barriers
            if (props.input_count >= 2) {
                return .{ .fused_gemv_dequant = .{
                    .activation_global = props.first_read_global,
                    .weight_global = props.struct_storage_global,
                    .output_global = props.first_rw_global,
                    .input_count = props.input_count,
                    .output_count = props.output_count,
                } };
            }
        }
        return .{ .dequant = .{
            .quant_global = props.struct_storage_global,
            .output_global = props.first_rw_global,
            .input_count = props.input_count,
            .output_count = props.output_count,
        } };
    }

    // Sample: has u32 output buffer (token IDs) + logits input
    if (props.has_u32_output and props.workgroup_globals <= 2) {
        return .{ .sample = .{
            .logits_global = props.first_read_global,
            .tokens_global = props.u32_output_global,
            .input_count = props.input_count,
            .output_count = props.output_count,
        } };
    }

    // KV cache write: has cache-named read_write buffers + read inputs, no barriers
    if (props.has_cache_buffers and props.cache_rw_count >= 2 and props.input_count >= 2 and
        props.workgroup_globals == 0 and !props.has_barriers)
    {
        return .{ .kv_write = .{
            .key_proj_global = props.read_global_indices[0],
            .val_proj_global = if (props.total_read_globals > 1) props.read_global_indices[1] else props.read_global_indices[0],
            .key_cache_global = props.cache_rw_globals[0],
            .val_cache_global = if (props.cache_rw_count > 1) props.cache_rw_globals[1] else props.cache_rw_globals[0],
        } };
    }

    // KV cache read: has cache-named read buffers + read_write outputs, no barriers
    if (props.has_cache_buffers and props.cache_read_count >= 2 and props.output_count >= 2 and
        props.workgroup_globals == 0 and !props.has_barriers)
    {
        return .{ .kv_read = .{
            .key_cache_global = props.cache_read_globals[0],
            .val_cache_global = if (props.cache_read_count > 1) props.cache_read_globals[1] else props.cache_read_globals[0],
            .key_out_global = props.first_rw_global,
            .val_out_global = props.first_rw_global,
        } };
    }

    // Attention patterns: ≥4 storage buffers with Q/K/V/output naming
    if (props.has_qkv_buffers) {
        // Linear attention: no shared mem, no barriers, no exp() calls
        if (props.workgroup_globals == 0 and !props.has_barriers and !hasExpCalls(function)) {
            return .{ .attention_linear = .{
                .q_global = props.q_global,
                .k_global = props.k_global,
                .v_global = props.v_global,
                .output_global = props.first_rw_global,
                .input_count = props.input_count,
                .output_count = props.output_count,
            } };
        }
        // Streaming: no shared mem, no barriers (per-thread online softmax)
        if (props.workgroup_globals == 0 and !props.has_barriers) {
            return .{ .attention_streaming = .{
                .q_global = props.q_global,
                .k_global = props.k_global,
                .v_global = props.v_global,
                .output_global = props.first_rw_global,
                .input_count = props.input_count,
                .output_count = props.output_count,
            } };
        }
        // Tiled prefill: shared K/V tiles (≥3 workgroup arrays, 2+ barriers)
        if (props.workgroup_globals >= 3 and props.has_barriers) {
            return .{ .attention_tiled = .{
                .q_global = props.q_global,
                .k_global = props.k_global,
                .v_global = props.v_global,
                .output_global = props.first_rw_global,
                .shared_k_global = if (props.workgroup_globals > 0) props.wg_indices[0] else 0,
                .shared_v_global = if (props.workgroup_globals > 1) props.wg_indices[1] else 0,
                .input_count = props.input_count,
                .output_count = props.output_count,
            } };
        }
        // Decode: shared mem for reductions (≤6 workgroup arrays, barriers)
        if (props.has_barriers) {
            return .{ .attention_decode = .{
                .q_global = props.q_global,
                .k_global = props.k_global,
                .v_global = props.v_global,
                .output_global = props.first_rw_global,
                .shared_count = props.workgroup_globals,
                .input_count = props.input_count,
                .output_count = props.output_count,
            } };
        }
    }

    // --- Generic patterns (less specific) ---

    // No shared memory, no barriers, no subgroup reductions → element-wise.
    // Subgroup ops (subgroupAdd, subgroupMax, ...) mean the kernel is doing
    // a cross-lane reduction; classifying it as element_wise would silently
    // drop the reduction semantics. Gate element_wise on !has_subgroup_ops
    // so subgroup-only kernels fall into the reduction branch below even
    // without workgroup-shared memory.
    if (props.workgroup_globals == 0 and !props.has_barriers and !props.has_subgroup_ops) {
        return .{ .element_wise = .{
            .input_count = props.input_count,
            .output_count = props.output_count,
            .has_size_guard = props.has_size_guard,
        } };
    }

    // Fused FFN: ≥3 read buffers + barriers + no QKV → SiLU-gated FFN
    if (!props.has_qkv_buffers and props.total_read_globals >= 3 and props.has_barriers and props.output_count >= 1) {
        return .{ .fused_ffn = .{
            .input_global = props.read_global_indices[0],
            .gate_weight_global = props.read_global_indices[1],
            .up_weight_global = props.read_global_indices[2],
            .output_global = props.first_rw_global,
            .input_count = props.input_count,
            .output_count = props.output_count,
        } };
    }

    // 2 workgroup arrays + barriers + loops → tiled matmul
    if (props.workgroup_globals == 2 and props.has_barriers and props.loop_count >= 1) {
        return .{
            .tiled_matmul = extractMatmulInfo(module, props.wg_indices[0..2]),
        };
    }

    // Reduction: three admissible shapes map to the same pattern —
    //   (a) workgroup-shared partial sums + barriers (classic rmsnorm)
    //   (b) barriers without workgroup memory (tree reduction over
    //       storage that still needs synchronization between phases)
    //   (c) subgroup ops as the reduction mechanism (decode-stage gemv
    //       that relies on subgroupAdd/subgroupMax/...).
    // The first workgroup array (if any) is the preferred reduction
    // scratchpad; when none exists, 0 is a sentinel consumed by the
    // emitter as "no shared scratchpad declared — use subgroup or direct".
    if (props.workgroup_globals >= 1 and props.has_barriers) {
        return .{ .reduction = .{
            .shared_global_index = props.wg_indices[0],
            .input_count = props.input_count,
            .output_count = props.output_count,
            .has_apply_phase = true,
        } };
    }
    if (props.has_subgroup_ops or (props.workgroup_globals == 0 and props.has_barriers)) {
        return .{ .reduction = .{
            .shared_global_index = 0,
            .input_count = props.input_count,
            .output_count = props.output_count,
            .has_apply_phase = true,
        } };
    }

    return .{ .unsupported = "unrecognized compute pattern for CSL emission" };
}

// ---------------------------------------------------------------------------
// Analysis structures
// ---------------------------------------------------------------------------

const AnalysisProps = struct {
    workgroup_globals: u32 = 0,
    wg_indices: [8]u32 = undefined,
    input_count: u32 = 0,
    output_count: u32 = 0,
    has_barriers: bool = false,
    has_subgroup_ops: bool = false,
    has_size_guard: bool = false,
    loop_count: u32 = 0,
    // Buffer pattern flags
    has_u32_indices: bool = false,
    indices_global: u32 = 0,
    table_global: u32 = 0,
    has_freq_buffers: bool = false,
    cos_global: u32 = 0,
    sin_global: u32 = 0,
    has_struct_storage: bool = false,
    struct_storage_global: u32 = 0,
    has_u32_output: bool = false,
    u32_output_global: u32 = 0,
    has_qkv_buffers: bool = false,
    q_global: u32 = 0,
    k_global: u32 = 0,
    v_global: u32 = 0,
    first_rw_global: u32 = 0,
    first_read_global: u32 = 0,
    // KV cache detection
    has_cache_buffers: bool = false,
    cache_rw_globals: [4]u32 = undefined,
    cache_rw_count: u32 = 0,
    cache_read_globals: [4]u32 = undefined,
    cache_read_count: u32 = 0,
    // FFN detection
    read_global_indices: [8]u32 = undefined,
    total_read_globals: u32 = 0,
};

fn analyzeGlobals(module: *const ir.Module, props: *AnalysisProps) void {
    var found_rw = false;
    var found_read = false;
    for (module.globals.items, 0..) |global, idx| {
        const space = global.addr_space orelse continue;
        const gi: u32 = @intCast(idx);

        if (space == .workgroup) {
            if (props.workgroup_globals < 8) {
                props.wg_indices[props.workgroup_globals] = gi;
            }
            props.workgroup_globals += 1;
            continue;
        }

        if (space != .storage or global.binding == null) continue;

        const is_rw = if (global.access) |a| (a == .read_write or a == .write) else false;
        if (is_rw) {
            props.output_count += 1;
            if (!found_rw) {
                props.first_rw_global = gi;
                found_rw = true;
            }
            // Track cache-like read_write buffers
            if (nameContains(global.name, "cache") or nameContains(global.name, "kv_")) {
                if (props.cache_rw_count < 4) {
                    props.cache_rw_globals[props.cache_rw_count] = gi;
                    props.cache_rw_count += 1;
                    props.has_cache_buffers = true;
                }
            }
        } else {
            props.input_count += 1;
            if (!found_read) {
                props.first_read_global = gi;
                found_read = true;
            }
            // Track all read globals for FFN detection
            if (props.total_read_globals < 8) {
                props.read_global_indices[props.total_read_globals] = gi;
                props.total_read_globals += 1;
            }
            // Track cache-like read buffers
            if (nameContains(global.name, "cache") or nameContains(global.name, "kv_")) {
                if (props.cache_read_count < 4) {
                    props.cache_read_globals[props.cache_read_count] = gi;
                    props.cache_read_count += 1;
                    props.has_cache_buffers = true;
                }
            }
        }

        // Check for struct-typed storage (Q4K blocks, etc.)
        switch (module.types.get(global.ty)) {
            .array => |arr| {
                switch (module.types.get(arr.elem)) {
                    .struct_ => {
                        props.has_struct_storage = true;
                        props.struct_storage_global = gi;
                    },
                    else => {},
                }
            },
            .struct_ => {
                props.has_struct_storage = true;
                props.struct_storage_global = gi;
            },
            else => {},
        }

        // Check for u32 array outputs (sample token IDs)
        if (is_rw) {
            if (isU32ArrayType(module, global.ty)) {
                props.has_u32_output = true;
                props.u32_output_global = gi;
            }
        }

        // Check for u32 array inputs (gather indices)
        if (!is_rw and isU32ArrayType(module, global.ty)) {
            props.has_u32_indices = true;
            props.indices_global = gi;
            // Next read buffer after indices is likely the table
            props.table_global = gi + 1;
        }

        // Name-based hints for attention Q/K/V buffers
        if (nameContains(global.name, "Q") or nameContains(global.name, "query")) {
            props.q_global = gi;
        }
        if (nameContains(global.name, "K") or nameContains(global.name, "key")) {
            props.k_global = gi;
            props.has_qkv_buffers = true;
        }
        if (nameContains(global.name, "V") or nameContains(global.name, "val")) {
            props.v_global = gi;
        }

        // Frequency buffers (RoPE)
        if (nameContains(global.name, "cos") or nameContains(global.name, "freq_cos")) {
            props.cos_global = gi;
            props.has_freq_buffers = true;
        }
        if (nameContains(global.name, "sin") or nameContains(global.name, "freq_sin")) {
            props.sin_global = gi;
        }
    }

    // Count-based QKV fallback moved to applyQkvFallback() in classify(),
    // where we also have the Function AST for an exp()-call check. A pure
    // 3-input count check over-matches plain FMA-shaped element-wise kernels
    // (out = a*b + c); gating on attention evidence (barriers, subgroup ops,
    // exp calls, or a buffer name like k/key/v/val/attn) keeps the fallback
    // targeted at actual attention kernels that happen to miss the name hints.
}

// Count-based QKV assignment fallback. Only call after analyzeGlobals and
// after attention-evidence has been confirmed by the caller. Leaves props
// unchanged when there are fewer than 3 read inputs.
fn applyQkvFallback(module: *const ir.Module, props: *AnalysisProps) void {
    if (props.has_qkv_buffers) return;
    if (props.input_count < 3 or props.output_count < 1) return;
    var read_idx: u32 = 0;
    for (module.globals.items, 0..) |global, idx| {
        const sp = global.addr_space orelse continue;
        if (sp != .storage or global.binding == null) continue;
        const is_rw = if (global.access) |a| (a == .read_write or a == .write) else false;
        if (is_rw) continue;
        switch (read_idx) {
            0 => props.q_global = @intCast(idx),
            1 => props.k_global = @intCast(idx),
            2 => {
                props.v_global = @intCast(idx);
                props.has_qkv_buffers = true;
            },
            else => {},
        }
        read_idx += 1;
    }
}

// Attention-evidence filter for the count-based fallback. A kernel that is
// REALLY attention (but happens to miss the name-based Q/K/V hints) will
// almost always carry at least one of: barriers (tiled / decode), subgroup
// ops (decode), exp() calls (softmax), or a buffer name containing a
// known attention token (k/key/v/val/attn/attention). A plain FMA-shaped
// element-wise kernel — `out = a * b + c` — has 3 read inputs + 1 write
// and none of the above, so it no longer trips the fallback.
fn hasAttentionEvidence(module: *const ir.Module, function: *const ir.Function, props: *const AnalysisProps) bool {
    if (props.has_barriers) return true;
    if (props.has_subgroup_ops) return true;
    if (hasExpCalls(function)) return true;
    for (module.globals.items) |global| {
        const sp = global.addr_space orelse continue;
        if (sp != .storage) continue;
        if (nameContains(global.name, "key") or nameContains(global.name, "val") or
            nameContains(global.name, "attn") or nameContains(global.name, "attention"))
        {
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Analysis helpers
// ---------------------------------------------------------------------------

fn nameContains(name: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, name, needle) != null;
}

fn isU32ArrayType(module: *const ir.Module, ty: ir.TypeId) bool {
    switch (module.types.get(ty)) {
        .array => |arr| return ir.is_scalar(&module.types, arr.elem, .u32),
        else => return ir.is_scalar(&module.types, ty, .u32),
    }
}

fn hasUnsupportedBuiltins(function: *const ir.Function) bool {
    for (function.exprs.items) |expr_node| {
        switch (expr_node.data) {
            .call => |call| {
                if (call.kind == .builtin and maps.isUnsupportedBuiltin(call.name))
                    return true;
            },
            else => {},
        }
    }
    return false;
}

fn hasBarrierCalls(function: *const ir.Function) bool {
    for (function.exprs.items) |expr_node| {
        switch (expr_node.data) {
            .call => |call| {
                if (call.kind == .builtin) {
                    if (std.mem.eql(u8, call.name, "workgroupBarrier") or
                        std.mem.eql(u8, call.name, "storageBarrier") or
                        std.mem.eql(u8, call.name, "textureBarrier"))
                        return true;
                }
            },
            else => {},
        }
    }
    return false;
}

fn hasSubgroupOps(function: *const ir.Function) bool {
    // Match on the "subgroup" prefix regardless of CallKind. The WGSL
    // parser recognizes a limited subset of subgroup names as builtins
    // (subgroup_size, subgroup_invocation_id); reduction-shaped calls
    // like subgroupAdd/subgroupMax can land as CallKind.user but are
    // still a classifier signal — the pattern is "this kernel does a
    // cross-lane reduction" regardless of how the parser categorized it.
    for (function.exprs.items) |expr_node| {
        switch (expr_node.data) {
            .call => |call| {
                if (std.mem.startsWith(u8, call.name, "subgroup")) return true;
            },
            else => {},
        }
    }
    return false;
}

fn hasSizeGuard(function: *const ir.Function) bool {
    for (function.params.items) |param| {
        if (param.io) |io| {
            if (io.builtin == .global_invocation_id) return true;
        }
    }
    return false;
}

fn countLoops(function: *const ir.Function) u32 {
    var count: u32 = 0;
    for (function.stmts.items) |stmt| {
        switch (stmt) {
            .loop_ => count += 1,
            else => {},
        }
    }
    return count;
}

fn hasExpCalls(function: *const ir.Function) bool {
    for (function.exprs.items) |expr_node| {
        switch (expr_node.data) {
            .call => |call| {
                if (call.kind == .builtin and std.mem.eql(u8, call.name, "exp")) return true;
            },
            else => {},
        }
    }
    return false;
}

fn extractMatmulInfo(module: *const ir.Module, wg_indices: []const u32) MatmulInfo {
    var tile_m: u32 = 64;
    var tile_n: u32 = 64;
    const tile_k: u32 = 16;

    for (wg_indices) |gi| {
        const global = module.globals.items[gi];
        const arr_len = switch (module.types.get(global.ty)) {
            .array => |arr| arr.len orelse 0,
            else => 0,
        };
        if (arr_len == 0 or arr_len == 1024) continue;
        const inferred_dim = arr_len / tile_k;
        if (gi == wg_indices[0]) {
            tile_m = inferred_dim;
        } else {
            tile_n = inferred_dim;
        }
    }

    return .{
        .tile_a_global = wg_indices[0],
        .tile_b_global = if (wg_indices.len > 1) wg_indices[1] else wg_indices[0],
        .tile_m = tile_m,
        .tile_n = tile_n,
        .tile_k = tile_k,
    };
}
