// emit_csl_mem_plan.zig — Explicit WSE-3 residency and grid planning.
//
// This module models two explicit residency strategies for transformer-class
// inference on Cerebras:
//   1. full_resident — all weights/state remain resident on-chip
//   2. layer_streaming — KV/state stay resident, high-volume weights stream
//      one working-set chunk at a time
//
// It also derives the smallest fitting PE rectangle for a model/host plan.

const std = @import("std");
const spec = @import("csl_spec.zig");
const host = @import("emit_csl_host.zig");

pub const EmitError = error{
    InvalidIr,
    OutputTooLarge,
};

pub const ResidencyMode = enum {
    full_resident,
    layer_streaming,
};

pub const BufferPlacement = enum {
    persistent,
    streamed,
    kv_cache,
};

pub const BufferKind = enum {
    embeddings,
    ple_table,
    ple_projection,
    ple_norm,
    layer_weights,
    kv_cache,
    activation_scratch,
    decode_position,
    sliding_window,
    output_logits,
};

pub const BufferPlan = struct {
    name: []const u8,
    kind: BufferKind,
    placement: BufferPlacement,
    bytes_total: u64,
    bytes_per_pe: u64,
};

pub const StreamStageKind = enum {
    embedding_rows,
    ple_rows,
    ple_projection,
    layer_weights,
};

pub const StreamStage = struct {
    name: []const u8,
    kind: StreamStageKind,
    repeat_count: u32,
    bytes_total: u64,
    bytes_per_pe: u64,
};

pub const PlacementPolicy = struct {
    max_grid_width: u32 = spec.MAX_RECT_DIM,
    max_grid_height: u32 = spec.MAX_RECT_DIM,
    prefer_square: bool = true,
};

pub const DerivedGrid = struct {
    width: u32,
    height: u32,
};

pub const MemoryPlan = struct {
    grid_width: u32,
    grid_height: u32,
    pe_count: u32,
    residency_mode: ResidencyMode,
    total_model_bytes: u64,
    total_persistent_bytes: u64,
    total_streamed_bytes: u64,
    persistent_bytes_per_pe: u64,
    streamed_working_set_bytes_per_pe: u64,
    total_sram_available: u64,
    utilization_pct: u32,
    fits: bool,
    buffers: [MAX_BUFFERS]BufferPlan,
    buffer_count: u32,
    stream_stages: [MAX_STREAM_STAGES]StreamStage,
    stream_stage_count: u32,
};

const MAX_BUFFERS: usize = 16;
const MAX_STREAM_STAGES: usize = 8;
const POSITION_STATE_BYTES: u64 = 4;
const SLIDING_WINDOW_STATE_BYTES: u64 = 4;
const OUTPUT_LOGIT_BYTES_PER_VALUE: u64 = 4;
const ACTIVATION_BYTES_PER_VALUE: u64 = 4;
const F16_BYTES_PER_VALUE: u64 = 2;
const PROJECTION_COUNT: u64 = 4;

pub fn deriveGrid(
    config: host.ModelConfig,
    plan: host.HostPlan,
    policy: PlacementPolicy,
) EmitError!DerivedGrid {
    if (policy.max_grid_width == 0 or policy.max_grid_height == 0) return error.InvalidIr;

    var best: ?MemoryPlan = null;

    var width: u32 = 1;
    while (width <= policy.max_grid_width) : (width += 1) {
        var height: u32 = 1;
        while (height <= policy.max_grid_height) : (height += 1) {
            const candidate = planForGrid(config, plan, width, height);
            if (!candidate.fits) continue;
            if (best == null or betterGrid(candidate, best.?, policy.prefer_square)) {
                best = candidate;
            }
        }
    }

    const selected = best orelse return error.InvalidIr;
    return .{
        .width = selected.grid_width,
        .height = selected.grid_height,
    };
}

pub fn planMemory(
    config: host.ModelConfig,
    plan: host.HostPlan,
    policy: PlacementPolicy,
) MemoryPlan {
    _ = policy;
    return planForGrid(config, plan, plan.pe_grid_width, plan.pe_grid_height);
}

pub fn emitPlanJson(buf: []u8, pos: *usize, plan: MemoryPlan) EmitError!void {
    try write(buf, pos, "{\n");
    try write(buf, pos, "  \"schemaVersion\": ");
    try writeInt(buf, pos, spec.MEMORY_PLAN_SCHEMA_VERSION);
    try write(buf, pos, ",\n  \"artifactKind\": ");
    try writeJsonString(buf, pos, spec.MEMORY_PLAN_ARTIFACT_KIND);
    try write(buf, pos, ",\n  \"target\": ");
    try writeJsonString(buf, pos, spec.MEMORY_PLAN_TARGET);
    try write(buf, pos, ",\n  \"contract\": ");
    try writeJsonString(buf, pos, spec.MEMORY_PLAN_CONTRACT);
    try write(buf, pos, ",\n  \"grid\": { \"width\": ");
    try writeInt(buf, pos, plan.grid_width);
    try write(buf, pos, ", \"height\": ");
    try writeInt(buf, pos, plan.grid_height);
    try write(buf, pos, " },\n");
    try write(buf, pos, "  \"peCount\": ");
    try writeInt(buf, pos, plan.pe_count);
    try write(buf, pos, ",\n  \"residencyMode\": ");
    try writeJsonString(buf, pos, @tagName(plan.residency_mode));
    try write(buf, pos, ",\n  \"totalModelBytes\": ");
    try writeInt(buf, pos, plan.total_model_bytes);
    try write(buf, pos, ",\n  \"totalPersistentBytes\": ");
    try writeInt(buf, pos, plan.total_persistent_bytes);
    try write(buf, pos, ",\n  \"totalStreamedBytes\": ");
    try writeInt(buf, pos, plan.total_streamed_bytes);
    try write(buf, pos, ",\n  \"persistentBytesPerPe\": ");
    try writeInt(buf, pos, plan.persistent_bytes_per_pe);
    try write(buf, pos, ",\n  \"streamedWorkingSetBytesPerPe\": ");
    try writeInt(buf, pos, plan.streamed_working_set_bytes_per_pe);
    try write(buf, pos, ",\n  \"totalSramAvailable\": ");
    try writeInt(buf, pos, plan.total_sram_available);
    try write(buf, pos, ",\n  \"utilizationPct\": ");
    try writeInt(buf, pos, plan.utilization_pct);
    try write(buf, pos, ",\n  \"fits\": ");
    try write(buf, pos, if (plan.fits) "true" else "false");
    try write(buf, pos, ",\n  \"buffers\": [\n");
    for (plan.buffers[0..plan.buffer_count], 0..) |buffer, idx| {
        try write(buf, pos, "    { \"name\": ");
        try writeJsonString(buf, pos, buffer.name);
        try write(buf, pos, ", \"kind\": ");
        try writeJsonString(buf, pos, @tagName(buffer.kind));
        try write(buf, pos, ", \"placement\": ");
        try writeJsonString(buf, pos, @tagName(buffer.placement));
        try write(buf, pos, ", \"bytesTotal\": ");
        try writeInt(buf, pos, buffer.bytes_total);
        try write(buf, pos, ", \"bytesPerPe\": ");
        try writeInt(buf, pos, buffer.bytes_per_pe);
        try write(buf, pos, " }");
        if (idx + 1 < plan.buffer_count) try write(buf, pos, ",");
        try write(buf, pos, "\n");
    }
    try write(buf, pos, "  ],\n  \"streamStages\": [\n");
    for (plan.stream_stages[0..plan.stream_stage_count], 0..) |stage, idx| {
        try write(buf, pos, "    { \"name\": ");
        try writeJsonString(buf, pos, stage.name);
        try write(buf, pos, ", \"kind\": ");
        try writeJsonString(buf, pos, @tagName(stage.kind));
        try write(buf, pos, ", \"repeatCount\": ");
        try writeInt(buf, pos, stage.repeat_count);
        try write(buf, pos, ", \"bytesTotal\": ");
        try writeInt(buf, pos, stage.bytes_total);
        try write(buf, pos, ", \"bytesPerPe\": ");
        try writeInt(buf, pos, stage.bytes_per_pe);
        try write(buf, pos, " }");
        if (idx + 1 < plan.stream_stage_count) try write(buf, pos, ",");
        try write(buf, pos, "\n");
    }
    try write(buf, pos, "  ]\n}\n");
}

fn planForGrid(
    config: host.ModelConfig,
    input_plan: host.HostPlan,
    width: u32,
    height: u32,
) MemoryPlan {
    const pe_count = width * height;
    const full_model_bytes = host.estimateModelSramForPlan(config, input_plan).total_estimated_bytes;
    const embed_bytes = estimateEmbeddingBytes(config);
    const ple_table_bytes = estimatePleTableBytes(config);
    const ple_projection_bytes = estimatePleProjectionBytes(config);
    const ple_norm_bytes = estimatePleNormBytes(config);
    const layer_weight_bytes = estimateLayerWeightBytes(config);
    const kv_cache_bytes = estimateKvCacheBytes(config, input_plan);
    const activation_bytes = estimateActivationScratchBytes(config);
    const output_bytes = estimateOutputBytes(config);
    const position_bytes = POSITION_STATE_BYTES;
    const sliding_window_bytes = if (hasSlidingDecodeLaunch(input_plan)) SLIDING_WINDOW_STATE_BYTES else 0;

    const total_capacity = @as(u64, pe_count) * spec.PE_SRAM_BYTES;
    const full_resident_per_pe = ceilDiv(full_model_bytes + activation_bytes + output_bytes + position_bytes + sliding_window_bytes, pe_count);
    const full_resident_total = full_model_bytes + activation_bytes + output_bytes + position_bytes + sliding_window_bytes;

    const streaming_persistent_total = kv_cache_bytes + activation_bytes + output_bytes + position_bytes + sliding_window_bytes;
    const streaming_stage_embedding = embed_bytes;
    const streaming_stage_ple_rows = if (ple_table_bytes == 0) 0 else estimatePleRowBytes(config);
    const streaming_stage_ple_projection = if (ple_projection_bytes == 0) 0 else estimatePleProjectionSliceBytes(config);
    const streaming_stage_layer_weights = layer_weight_bytes;
    const streaming_working_set_total = max4(
        streaming_stage_embedding,
        streaming_stage_ple_rows,
        streaming_stage_ple_projection,
        streaming_stage_layer_weights,
    );
    const mode: ResidencyMode = if (full_resident_total <= total_capacity and full_resident_per_pe <= spec.PE_SRAM_BYTES)
        .full_resident
    else
        .layer_streaming;
    const persistent_total = if (mode == .full_resident) full_resident_total else streaming_persistent_total;
    const streamed_total = if (mode == .full_resident) 0 else embed_bytes + ple_table_bytes + ple_projection_bytes + ple_norm_bytes + (@as(u64, config.num_layers) * layer_weight_bytes);
    const persistent_per_pe = if (mode == .full_resident) full_resident_per_pe else ceilDiv(streaming_persistent_total, pe_count);
    const working_set_per_pe = if (mode == .full_resident) 0 else ceilDiv(streaming_working_set_total, pe_count);
    const fits = if (mode == .full_resident)
        full_resident_per_pe <= spec.PE_SRAM_BYTES
    else
        (persistent_per_pe + working_set_per_pe) <= spec.PE_SRAM_BYTES;
    const utilization_base = persistent_per_pe + working_set_per_pe;
    const utilization_pct = @as(u32, @intCast(@min(
        @as(u64, 100),
        if (spec.PE_SRAM_BYTES == 0) 0 else (utilization_base * 100) / spec.PE_SRAM_BYTES,
    )));

    var buffers: [MAX_BUFFERS]BufferPlan = undefined;
    var buffer_count: u32 = 0;
    appendBuffer(&buffers, &buffer_count, .{
        .name = "kv_cache",
        .kind = .kv_cache,
        .placement = .kv_cache,
        .bytes_total = kv_cache_bytes,
        .bytes_per_pe = ceilDiv(kv_cache_bytes, pe_count),
    });
    appendBuffer(&buffers, &buffer_count, .{
        .name = "activation_scratch",
        .kind = .activation_scratch,
        .placement = .persistent,
        .bytes_total = activation_bytes,
        .bytes_per_pe = ceilDiv(activation_bytes, pe_count),
    });
    appendBuffer(&buffers, &buffer_count, .{
        .name = "decode_position",
        .kind = .decode_position,
        .placement = .persistent,
        .bytes_total = position_bytes,
        .bytes_per_pe = ceilDiv(position_bytes, pe_count),
    });
    if (sliding_window_bytes > 0) {
        appendBuffer(&buffers, &buffer_count, .{
            .name = "sliding_window",
            .kind = .sliding_window,
            .placement = .persistent,
            .bytes_total = sliding_window_bytes,
            .bytes_per_pe = ceilDiv(sliding_window_bytes, pe_count),
        });
    }
    appendBuffer(&buffers, &buffer_count, .{
        .name = "output_logits",
        .kind = .output_logits,
        .placement = .persistent,
        .bytes_total = output_bytes,
        .bytes_per_pe = ceilDiv(output_bytes, pe_count),
    });
    appendBuffer(&buffers, &buffer_count, .{
        .name = "token_embeddings",
        .kind = .embeddings,
        .placement = if (mode == .full_resident) .persistent else .streamed,
        .bytes_total = embed_bytes,
        .bytes_per_pe = ceilDiv(embed_bytes, pe_count),
    });
    if (ple_table_bytes > 0) {
        appendBuffer(&buffers, &buffer_count, .{
            .name = "ple_table",
            .kind = .ple_table,
            .placement = if (mode == .full_resident) .persistent else .streamed,
            .bytes_total = ple_table_bytes,
            .bytes_per_pe = ceilDiv(ple_table_bytes, pe_count),
        });
    }
    if (ple_projection_bytes > 0) {
        appendBuffer(&buffers, &buffer_count, .{
            .name = "ple_projection",
            .kind = .ple_projection,
            .placement = if (mode == .full_resident) .persistent else .streamed,
            .bytes_total = ple_projection_bytes,
            .bytes_per_pe = ceilDiv(ple_projection_bytes, pe_count),
        });
    }
    if (ple_norm_bytes > 0) {
        appendBuffer(&buffers, &buffer_count, .{
            .name = "ple_norm",
            .kind = .ple_norm,
            .placement = if (mode == .full_resident) .persistent else .streamed,
            .bytes_total = ple_norm_bytes,
            .bytes_per_pe = ceilDiv(ple_norm_bytes, pe_count),
        });
    }
    appendBuffer(&buffers, &buffer_count, .{
        .name = "layer_weights",
        .kind = .layer_weights,
        .placement = if (mode == .full_resident) .persistent else .streamed,
        .bytes_total = @as(u64, config.num_layers) * layer_weight_bytes,
        .bytes_per_pe = ceilDiv(layer_weight_bytes, pe_count),
    });

    var stream_stages: [MAX_STREAM_STAGES]StreamStage = undefined;
    var stage_count: u32 = 0;
    if (mode == .layer_streaming) {
        appendStreamStage(&stream_stages, &stage_count, .{
            .name = "embedding_rows",
            .kind = .embedding_rows,
            .repeat_count = 1,
            .bytes_total = streaming_stage_embedding,
            .bytes_per_pe = ceilDiv(streaming_stage_embedding, pe_count),
        });
        if (streaming_stage_ple_rows > 0) {
            appendStreamStage(&stream_stages, &stage_count, .{
                .name = "ple_rows",
                .kind = .ple_rows,
                .repeat_count = 1,
                .bytes_total = streaming_stage_ple_rows,
                .bytes_per_pe = ceilDiv(streaming_stage_ple_rows, pe_count),
            });
        }
        if (streaming_stage_ple_projection > 0) {
            appendStreamStage(&stream_stages, &stage_count, .{
                .name = "ple_projection",
                .kind = .ple_projection,
                .repeat_count = config.num_layers,
                .bytes_total = streaming_stage_ple_projection,
                .bytes_per_pe = ceilDiv(streaming_stage_ple_projection, pe_count),
            });
        }
        appendStreamStage(&stream_stages, &stage_count, .{
            .name = "layer_weights",
            .kind = .layer_weights,
            .repeat_count = config.num_layers,
            .bytes_total = streaming_stage_layer_weights,
            .bytes_per_pe = ceilDiv(streaming_stage_layer_weights, pe_count),
        });
    }

    return .{
        .grid_width = width,
        .grid_height = height,
        .pe_count = pe_count,
        .residency_mode = mode,
        .total_model_bytes = full_model_bytes,
        .total_persistent_bytes = persistent_total,
        .total_streamed_bytes = streamed_total,
        .persistent_bytes_per_pe = persistent_per_pe,
        .streamed_working_set_bytes_per_pe = working_set_per_pe,
        .total_sram_available = total_capacity,
        .utilization_pct = utilization_pct,
        .fits = fits,
        .buffers = buffers,
        .buffer_count = buffer_count,
        .stream_stages = stream_stages,
        .stream_stage_count = stage_count,
    };
}

fn betterGrid(candidate: MemoryPlan, current: MemoryPlan, prefer_square: bool) bool {
    const candidate_pes = @as(u64, candidate.grid_width) * candidate.grid_height;
    const current_pes = @as(u64, current.grid_width) * current.grid_height;
    if (candidate_pes < current_pes) return true;
    if (candidate_pes > current_pes) return false;
    if (!prefer_square) return candidate.grid_width < current.grid_width;
    const candidate_delta = absDiff(candidate.grid_width, candidate.grid_height);
    const current_delta = absDiff(current.grid_width, current.grid_height);
    if (candidate_delta < current_delta) return true;
    if (candidate_delta > current_delta) return false;
    if (candidate.grid_height < current.grid_height) return true;
    if (candidate.grid_height > current.grid_height) return false;
    return candidate.grid_width < current.grid_width;
}

fn hasSlidingDecodeLaunch(plan: host.HostPlan) bool {
    for (plan.decode_launches) |launch| {
        if (launch.attention_type == .sliding) return true;
    }
    return false;
}

fn estimateEmbeddingBytes(config: host.ModelConfig) u64 {
    return @as(u64, config.vocab_size) * config.hidden_dim * F16_BYTES_PER_VALUE;
}

fn estimatePleTableBytes(config: host.ModelConfig) u64 {
    const ple_width = config.ple_width orelse return 0;
    const ple_vocab_size = config.ple_vocab_size orelse config.vocab_size;
    return @as(u64, ple_vocab_size) * @as(u64, config.num_layers) * @as(u64, ple_width) * F16_BYTES_PER_VALUE;
}

fn estimatePleProjectionBytes(config: host.ModelConfig) u64 {
    const ple_width = config.ple_width orelse return 0;
    return @as(u64, config.hidden_dim) *
        @as(u64, config.num_layers) *
        @as(u64, ple_width) *
        bytesPerWeight(config.quant_format);
}

fn estimatePleNormBytes(config: host.ModelConfig) u64 {
    const ple_width = config.ple_width orelse return 0;
    return @as(u64, config.num_layers) * @as(u64, ple_width) * F16_BYTES_PER_VALUE;
}

fn estimatePleRowBytes(config: host.ModelConfig) u64 {
    const ple_width = config.ple_width orelse return 0;
    return @as(u64, config.num_layers) * @as(u64, ple_width) * F16_BYTES_PER_VALUE;
}

fn estimatePleProjectionSliceBytes(config: host.ModelConfig) u64 {
    const ple_width = config.ple_width orelse return 0;
    return @as(u64, config.hidden_dim) * @as(u64, ple_width) * bytesPerWeight(config.quant_format);
}

fn estimateLayerWeightBytes(config: host.ModelConfig) u64 {
    const hidden_dim = @as(u64, config.hidden_dim);
    return (PROJECTION_COUNT * hidden_dim * hidden_dim * bytesPerWeight(config.quant_format)) +
        (@as(u64, config.ffn_matrix_count) * hidden_dim * @as(u64, config.ffn_expansion_factor) * hidden_dim * bytesPerWeight(config.quant_format));
}

fn estimateKvCacheBytes(config: host.ModelConfig, plan: host.HostPlan) u64 {
    const effective_layers = host.effectiveKvCacheLayerCount(config, plan);
    return 2 *
        @as(u64, effective_layers) *
        @as(u64, config.max_seq_len) *
        @as(u64, config.hidden_dim) *
        F16_BYTES_PER_VALUE;
}

fn estimateActivationScratchBytes(config: host.ModelConfig) u64 {
    return @as(u64, config.hidden_dim) *
        @as(u64, config.ffn_expansion_factor) *
        ACTIVATION_BYTES_PER_VALUE;
}

fn estimateOutputBytes(config: host.ModelConfig) u64 {
    return @as(u64, config.vocab_size) * OUTPUT_LOGIT_BYTES_PER_VALUE;
}

fn bytesPerWeight(format: host.ModelConfig.QuantFormat) u64 {
    return switch (format) {
        .f16 => 2,
        .q4k => 1,
        .q8_0 => 1,
    };
}

fn ceilDiv(numerator: u64, denominator: u32) u64 {
    if (numerator == 0) return 0;
    return (numerator + @as(u64, denominator) - 1) / @as(u64, denominator);
}

fn max4(a: u64, b: u64, c: u64, d: u64) u64 {
    return @max(@max(a, b), @max(c, d));
}

fn absDiff(a: u32, b: u32) u32 {
    return if (a >= b) a - b else b - a;
}

fn appendBuffer(buffers: *[MAX_BUFFERS]BufferPlan, count: *u32, buffer: BufferPlan) void {
    if (count.* >= MAX_BUFFERS) @panic("too many CSL memory-plan buffers");
    buffers[count.*] = buffer;
    count.* += 1;
}

fn appendStreamStage(stages: *[MAX_STREAM_STAGES]StreamStage, count: *u32, stage: StreamStage) void {
    if (count.* >= MAX_STREAM_STAGES) @panic("too many CSL memory-plan stream stages");
    stages[count.*] = stage;
    count.* += 1;
}

fn writeJsonString(buf: []u8, pos: *usize, value: []const u8) EmitError!void {
    try write(buf, pos, "\"");
    for (value) |ch| {
        switch (ch) {
            '"' => try write(buf, pos, "\\\""),
            '\\' => try write(buf, pos, "\\\\"),
            '\n' => try write(buf, pos, "\\n"),
            '\r' => try write(buf, pos, "\\r"),
            '\t' => try write(buf, pos, "\\t"),
            else => {
                if (pos.* + 1 > buf.len) return error.OutputTooLarge;
                buf[pos.*] = ch;
                pos.* += 1;
            },
        }
    }
    try write(buf, pos, "\"");
}

fn write(buf: []u8, pos: *usize, text: []const u8) EmitError!void {
    if (pos.* + text.len > buf.len) return error.OutputTooLarge;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
}

fn writeInt(buf: []u8, pos: *usize, value: anytype) EmitError!void {
    var tmp: [32]u8 = undefined;
    const slice = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return error.OutputTooLarge;
    try write(buf, pos, slice);
}

test "memory plan picks layer streaming for Gemma 4 sized model on small grid" {
    const config = host.ModelConfig{
        .hidden_dim = 1536,
        .num_heads = 8,
        .head_dim = 512,
        .num_layers = 35,
        .vocab_size = 262144,
        .max_seq_len = 4096,
        .quant_format = .q4k,
        .ple_width = 256,
        .ple_vocab_size = 262144,
    };
    const plan = host.HostPlan{
        .pe_grid_width = 32,
        .pe_grid_height = 4,
        .kernels = &[_]host.KernelSpec{
            .{ .name = "kv_write", .pattern = "kv_write", .count = 1 },
            .{ .name = "attn_decode", .pattern = "attention_decode", .count = 1 },
        },
        .prefill_launches = &[_]host.LaunchSpec{},
        .decode_launches = &[_]host.LaunchSpec{
            .{ .kernel_name = "kv_write", .current_pos_source = .decode_position },
            .{
                .kernel_name = "attn_decode",
                .attention_type = .sliding,
                .sliding_window_size = 512,
                .current_pos_source = .decode_position,
            },
        },
    };
    const mem_plan = planMemory(config, plan, .{});
    try std.testing.expectEqual(ResidencyMode.layer_streaming, mem_plan.residency_mode);
    try std.testing.expect(mem_plan.stream_stage_count >= 2);
    try std.testing.expect(mem_plan.persistent_bytes_per_pe > 0);
}

test "deriveGrid finds a fitting rectangle for Gemma 4 layer streaming" {
    const config = host.ModelConfig{
        .hidden_dim = 1536,
        .num_heads = 8,
        .head_dim = 512,
        .num_layers = 35,
        .vocab_size = 262144,
        .max_seq_len = 4096,
        .quant_format = .q4k,
        .ple_width = 256,
        .ple_vocab_size = 262144,
    };
    const plan = host.HostPlan{
        .pe_grid_width = 1,
        .pe_grid_height = 1,
        .kernels = &[_]host.KernelSpec{
            .{ .name = "kv_write", .pattern = "kv_write", .count = 1 },
        },
        .prefill_launches = &[_]host.LaunchSpec{},
        .decode_launches = &[_]host.LaunchSpec{
            .{ .kernel_name = "kv_write", .current_pos_source = .decode_position },
        },
    };
    const derived = try deriveGrid(config, plan, .{ .max_grid_width = 256, .max_grid_height = 256 });
    try std.testing.expect(derived.width > 0);
    try std.testing.expect(derived.height > 0);
    const planned = planForGrid(config, plan, derived.width, derived.height);
    try std.testing.expect(planned.fits);
}

test "memory plan JSON emits residency and stream stages" {
    const config = host.ModelConfig{
        .hidden_dim = 1024,
        .num_heads = 16,
        .head_dim = 64,
        .num_layers = 24,
        .vocab_size = 151936,
        .max_seq_len = 2048,
        .quant_format = .q4k,
    };
    const plan = host.HostPlan{
        .pe_grid_width = 256,
        .pe_grid_height = 1,
        .kernels = &[_]host.KernelSpec{},
        .prefill_launches = &[_]host.LaunchSpec{},
        .decode_launches = &[_]host.LaunchSpec{},
    };
    const mem_plan = planMemory(config, plan, .{});
    var buf: [8192]u8 = undefined;
    var pos: usize = 0;
    try emitPlanJson(&buf, &pos, mem_plan);
    const json = buf[0..pos];
    try std.testing.expect(std.mem.indexOf(u8, json, "\"residencyMode\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"buffers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"streamStages\"") != null);
}
