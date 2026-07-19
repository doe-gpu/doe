// emit_csl_exec_v1.zig — Doppler execution-v1 → HostPlan lowering.
//
// Parses Doppler's execution-v1 step tuples and constructs an explicit
// HostPlan that emit_csl_host.zig can render into compilation manifests
// and Python runner scaffolds.
//
// Execution-v1 format (JSON):
//   {
//     "grid": { "width": 32, "height": 4 },
//     "eosTokenId": 1,
//     "steps": [
//       { "phase": "prefill", "op": "embed", "kernelKey": "embed_gather" },
//       { "phase": "decode", "op": "sample", "kernelKey": "sampler" }
//     ]
//   }
//
// Step tuples are also accepted for bootstrap contracts:
//   [phase, op, kernelKey, weightsKey?, kind?]
//
// This module maps op names to KernelSpec patterns and orders them
// into prefill and decode launch sequences.

const std = @import("std");
const host = @import("emit_csl_host.zig");
const mem_plan = @import("emit_csl_mem_plan.zig");
const csl_spec = @import("csl_spec.zig");

pub const LowerError = error{
    OutputTooLarge,
    InvalidIr,
    InvalidJson,
    UnknownOp,
    MalformedStep,
    SampleLogitsProducerMissing,
    OutOfMemory,
};

const INVALID_DIMENSION: u32 = 0;
const LAUNCH_REPEAT: u32 = 1;
const TEST_ARTIFACT_CAPACITY: usize = 32 * 1024;
pub const PREFILL_Q4K_GEMV_PATTERN: []const u8 = "prefill_q4k_gemv";

pub const GridDims = struct {
    width: u32,
    height: u32,
};

pub const ExecPhase = enum {
    prefill,
    decode,
};

pub const ExecStepKind = enum {
    compute,
    sample,
};

pub const AttentionType = enum {
    global,
    sliding,
};

pub const ExecStep = struct {
    phase: ExecPhase,
    kind: ExecStepKind,
    name: ?[]const u8 = null,
    op: []const u8,
    kernel_key: []const u8,
    weights_key: ?[]const u8 = null,
    attention_type: ?AttentionType = null,
    sliding_window_size: ?u32 = null,
    kv_cache_alias: ?[]const u8 = null,
    repeat: u32 = LAUNCH_REPEAT,
    /// Names of upstream steps whose outputs feed this step's input
    /// bindings. Required for paired-input ops like `silu_gated`,
    /// `sigmoid_gated`, `gelu_gated`, and the Qwen 3.6 `o_gate` alias —
    /// these consume two upstream outputs (gate, input) and produce a
    /// single output. The order matches the kernel binding order:
    /// `inputs_from[0]` → `gate`, `inputs_from[1]` → `input`. For
    /// non-paired ops the field is null and the host plan threads the
    /// previous step's output as the single input.
    inputs_from: ?[]const []const u8 = null,
};

/// Ops that consume two upstream outputs (gate, input) and emit one
/// output. The host plan needs `inputs_from = [gate_step, input_step]`
/// declared on the smoke config to bind them correctly.
pub fn isPairedGateOp(op: []const u8) bool {
    return std.mem.eql(u8, op, "silu_gated") or
        std.mem.eql(u8, op, "sigmoid_gated") or
        std.mem.eql(u8, op, "gelu_gated") or
        std.mem.eql(u8, op, "o_gate");
}

const LayerPattern = struct {
    period: u32,
    offset: u32,
};

const LowerMetadata = struct {
    layer_pattern: ?LayerPattern = null,
    num_kv_shared_layers: ?u32 = null,
    sliding_window_size: ?u32 = null,
};

const OpSpec = struct {
    pattern: []const u8,
    allow_prefill: bool,
    allow_decode: bool,
    kind: ExecStepKind,
};

/// Map a Doppler op name to a CSL kernel pattern name and execution policy.
pub fn opToSpec(op: []const u8) ?OpSpec {
    const map = [_]struct { op: []const u8, spec: OpSpec }{
        .{ .op = "embed", .spec = .{ .pattern = "gather", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "attention", .spec = .{ .pattern = "attention_decode", .allow_prefill = false, .allow_decode = true, .kind = .compute } },
        .{ .op = "attention_prefill", .spec = .{ .pattern = "attention_tiled", .allow_prefill = true, .allow_decode = false, .kind = .compute } },
        // Multi-Q causal-prefill, K/V sharded across pe_y. Used by the
        // Qwen 3.6 27B smoke config in place of `attention_prefill` to
        // sidestep the `attention_tiled` linker_pe_memory_overflow at
        // head_dim=256 / q_len=4096; per-PE working-set fits the WSE-3
        // 48 KiB budget at width=height=512 with q_len_per_pe=8 and
        // slots_per_pe=8.
        .{ .op = "attention_prefill_kv_axis_sharded", .spec = .{ .pattern = "attention_prefill_kv_axis_sharded", .allow_prefill = true, .allow_decode = false, .kind = .compute } },
        // Qwen 3.6 gated-DeltaNet SSM body ops. These route directly
        // through emit_csl_semantic_ops.zig to the TSIR CSL bodies used
        // by the reference-interpreter parity tests.
        .{ .op = "conv1d_depthwise", .spec = .{ .pattern = "conv1d_depthwise", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "l2_normalize", .spec = .{ .pattern = "l2_normalize", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "linear_attention", .spec = .{ .pattern = "linear_attention", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "attention_linear", .spec = .{ .pattern = "attention_linear", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "rope", .spec = .{ .pattern = "rope", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "rmsnorm", .spec = .{ .pattern = "rms_norm", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "layernorm", .spec = .{ .pattern = "reduction", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "softmax", .spec = .{ .pattern = "reduction", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "gelu", .spec = .{ .pattern = "gelu", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "silu", .spec = .{ .pattern = "element_wise", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        // Gated-activation family: paired (gate, input) -> output kernels.
        // gelu_gated: GeGLU (Gemma-style); silu_gated: SwiGLU FFN inner
        // (Qwen 3.6 / Llama-style); sigmoid_gated: attentionOutputGate
        // (Qwen 3.6 q-gate * attn output before O-projection). All three
        // share the same elementwise (gate, input, output) layout and
        // dispatch to emit_csl_semantic_ops emitGatedPe parameterized by
        // SemanticBodyOp; the TSIR side already routes the body op via
        // emit_kernel_body.zig + emit_kernel_body_gated.zig.
        .{ .op = "gelu_gated", .spec = .{ .pattern = "gelu_gated", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "silu_gated", .spec = .{ .pattern = "silu_gated", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "sigmoid_gated", .spec = .{ .pattern = "sigmoid_gated", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        // Qwen 3.6 attention_output_gate alias: smoke configs use
        // shorthand `o_gate` for the sigmoid-gated step that runs
        // between attention output and O-projection. Aliases to
        // sigmoid_gated; no separate emit.
        .{ .op = "o_gate", .spec = .{ .pattern = "sigmoid_gated", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "relu", .spec = .{ .pattern = "element_wise", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "scale", .spec = .{ .pattern = "element_wise", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "bias_add", .spec = .{ .pattern = "element_wise", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "residual", .spec = .{ .pattern = "residual", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "cast", .spec = .{ .pattern = "element_wise", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "dequant", .spec = .{ .pattern = "dequant", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "matmul", .spec = .{ .pattern = "tiled_matmul", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "matmul_q4k", .spec = .{ .pattern = "fused_gemv_dequant", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "ffn", .spec = .{ .pattern = "fused_ffn", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "kv_write", .spec = .{ .pattern = "kv_write", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "kv_read", .spec = .{ .pattern = "kv_read", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "sample", .spec = .{ .pattern = "sample", .allow_prefill = true, .allow_decode = true, .kind = .sample } },
        // Gemma 4: PLE composite — decomposes into gather + matmul + reduction + element_wise.
        // The host plan expands this into the four sub-steps; exec-v1 uses it as a scheduling marker.
        .{ .op = "ple_gather", .spec = .{ .pattern = "gather", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "ple_project", .spec = .{ .pattern = "tiled_matmul", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "ple_norm", .spec = .{ .pattern = "reduction", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        .{ .op = "ple_modulate", .spec = .{ .pattern = "element_wise", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
        // Gemma 4: hybrid attention — uses attention_decode with sliding window
        .{ .op = "attention_sliding", .spec = .{ .pattern = "attention_decode", .allow_prefill = false, .allow_decode = true, .kind = .compute } },
        // Gemma 4: shared KV write — same pattern as kv_write, aliased buffer resolved at host-plan level
        .{ .op = "kv_write_shared", .spec = .{ .pattern = "kv_write", .allow_prefill = true, .allow_decode = true, .kind = .compute } },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, op, entry.op)) return entry.spec;
    }
    return null;
}

/// Map a Doppler op name to a CSL kernel pattern name.
pub fn opToPattern(op: []const u8) ?[]const u8 {
    return (opToSpec(op) orelse return null).pattern;
}

fn parsePhase(text: []const u8) LowerError!ExecPhase {
    if (std.mem.eql(u8, text, "prefill")) return .prefill;
    if (std.mem.eql(u8, text, "decode")) return .decode;
    return error.InvalidJson;
}

fn parseKind(text: []const u8) LowerError!ExecStepKind {
    if (std.mem.eql(u8, text, "compute")) return .compute;
    if (std.mem.eql(u8, text, "sample")) return .sample;
    return error.InvalidJson;
}

fn parseAttentionType(text: []const u8) LowerError!AttentionType {
    if (std.mem.eql(u8, text, "global")) return .global;
    if (std.mem.eql(u8, text, "sliding")) return .sliding;
    return error.InvalidJson;
}

fn expectObject(value: std.json.Value) LowerError!std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.InvalidJson,
    };
}

fn expectArray(value: std.json.Value) LowerError!std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.InvalidJson,
    };
}

fn expectString(value: std.json.Value) LowerError![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidJson,
    };
}

fn expectU32(value: std.json.Value) LowerError!u32 {
    return switch (value) {
        .integer => |integer| std.math.cast(u32, integer) orelse error.InvalidJson,
        else => error.InvalidJson,
    };
}

fn parseGrid(value: std.json.Value) LowerError!GridDims {
    const object = try expectObject(value);
    const width_value = object.get("width") orelse return error.InvalidJson;
    const height_value = object.get("height") orelse return error.InvalidJson;
    return .{
        .width = try expectU32(width_value),
        .height = try expectU32(height_value),
    };
}

fn parseOptionalGrid(value: ?std.json.Value) LowerError!?GridDims {
    const raw = value orelse return null;
    return try parseGrid(raw);
}

fn parseLayerPattern(value: ?std.json.Value) LowerError!?LayerPattern {
    const raw = value orelse return null;
    const object = try expectObject(raw);
    const pattern_type = try expectString(object.get("type") orelse return error.InvalidJson);
    if (!std.mem.eql(u8, pattern_type, "every_n")) return error.InvalidJson;
    const period = try expectU32(object.get("period") orelse return error.InvalidJson);
    const offset = try expectU32(object.get("offset") orelse return error.InvalidJson);
    if (period == 0 or offset >= period) return error.InvalidJson;
    return .{
        .period = period,
        .offset = offset,
    };
}

fn parseOptionalU32(value: ?std.json.Value) LowerError!?u32 {
    const raw = value orelse return null;
    return switch (raw) {
        .null => null,
        else => try expectU32(raw),
    };
}

fn parseBool(value: std.json.Value) LowerError!bool {
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidJson,
    };
}

fn parseQuantFormat(text: []const u8) LowerError!host.ModelConfig.QuantFormat {
    if (std.mem.eql(u8, text, "f16")) return .f16;
    if (std.mem.eql(u8, text, "q4k")) return .q4k;
    if (std.mem.eql(u8, text, "q8_0")) return .q8_0;
    return error.InvalidJson;
}

fn parseModelConfig(value: ?std.json.Value) LowerError!?host.ModelConfig {
    const raw = value orelse return null;
    const object = try expectObject(raw);
    return .{
        .hidden_dim = try expectU32(object.get("hiddenDim") orelse return error.InvalidJson),
        .num_heads = try expectU32(object.get("numHeads") orelse return error.InvalidJson),
        .head_dim = try expectU32(object.get("headDim") orelse return error.InvalidJson),
        .linear_key_head_dim = try parseOptionalU32(object.get("linearKeyHeadDim")),
        .linear_value_head_dim = try parseOptionalU32(object.get("linearValueHeadDim")),
        .linear_conv_kernel_dim = try parseOptionalU32(object.get("linearConvKernelDim")),
        .global_head_dim = try parseOptionalU32(object.get("globalHeadDim")),
        .num_key_value_heads = try parseOptionalU32(object.get("numKeyValueHeads")),
        .num_layers = try expectU32(object.get("numLayers") orelse return error.InvalidJson),
        .vocab_size = try expectU32(object.get("vocabSize") orelse return error.InvalidJson),
        .max_seq_len = try expectU32(object.get("maxSeqLen") orelse return error.InvalidJson),
        .quant_format = try parseQuantFormat(try expectString(object.get("quantFormat") orelse return error.InvalidJson)),
        .ffn_expansion_factor = (try parseOptionalU32(object.get("ffnExpansionFactor"))) orelse 4,
        .ffn_matrix_count = (try parseOptionalU32(object.get("ffnMatrixCount"))) orelse 3,
        .ple_width = try parseOptionalU32(object.get("pleWidth")),
        .ple_vocab_size = try parseOptionalU32(object.get("pleVocabSize")),
    };
}

fn parsePlacementPolicy(value: ?std.json.Value) LowerError!mem_plan.PlacementPolicy {
    const raw = value orelse return .{};
    const object = try expectObject(raw);
    return .{
        .max_grid_width = (try parseOptionalU32(object.get("maxGridWidth"))) orelse @as(u32, csl_spec.MAX_RECT_DIM),
        .max_grid_height = (try parseOptionalU32(object.get("maxGridHeight"))) orelse @as(u32, csl_spec.MAX_RECT_DIM),
        .prefer_square = if (object.get("preferSquare")) |prefer_square|
            try parseBool(prefer_square)
        else
            true,
    };
}

fn parseNullableStringDup(allocator: std.mem.Allocator, value: ?std.json.Value) LowerError!?[]const u8 {
    const raw = value orelse return null;
    return switch (raw) {
        .null => null,
        else => try allocator.dupe(u8, try expectString(raw)),
    };
}

fn parseStepObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) LowerError!ExecStep {
    const phase_text = try expectString(object.get("phase") orelse return error.InvalidJson);
    const op = try expectString(object.get("op") orelse return error.InvalidJson);
    const name = try parseNullableStringDup(allocator, object.get("name"));
    const kernel_key = try allocator.dupe(u8, try expectString(object.get("kernelKey") orelse return error.InvalidJson));
    const op_spec = opToSpec(op) orelse return error.UnknownOp;
    const kind = if (object.get("kind")) |kind_value|
        try parseKind(try expectString(kind_value))
    else
        op_spec.kind;

    const weights_key = try parseNullableStringDup(allocator, object.get("weightsKey"));

    const attention_type: ?AttentionType = if (object.get("attentionType")) |attn_val|
        try parseAttentionType(try expectString(attn_val))
    else
        null;

    const sliding_window_size = try parseOptionalU32(object.get("slidingWindowSize"));
    const kv_cache_alias = try parseNullableStringDup(allocator, object.get("kvCacheAlias"));
    const repeat = (try parseOptionalU32(object.get("repeat"))) orelse LAUNCH_REPEAT;
    if (repeat == 0) return error.MalformedStep;

    const inputs_from = try parseInputsFrom(allocator, object.get("inputsFrom"));
    if (isPairedGateOp(op)) {
        if (inputs_from == null) return error.MalformedStep;
        if (inputs_from.?.len != 2) return error.MalformedStep;
    }

    return .{
        .phase = try parsePhase(phase_text),
        .kind = kind,
        .name = name,
        .op = op,
        .kernel_key = kernel_key,
        .weights_key = weights_key,
        .attention_type = attention_type,
        .sliding_window_size = sliding_window_size,
        .kv_cache_alias = kv_cache_alias,
        .repeat = repeat,
        .inputs_from = inputs_from,
    };
}

fn parseInputsFrom(allocator: std.mem.Allocator, value: ?std.json.Value) LowerError!?[]const []const u8 {
    const raw = value orelse return null;
    const array = try expectArray(raw);
    if (array.items.len == 0) return error.MalformedStep;
    var slice = try allocator.alloc([]const u8, array.items.len);
    var written: usize = 0;
    errdefer {
        for (slice[0..written]) |entry| allocator.free(entry);
        allocator.free(slice);
    }
    while (written < array.items.len) : (written += 1) {
        const text = try expectString(array.items[written]);
        slice[written] = try allocator.dupe(u8, text);
    }
    return slice;
}

fn parseStepTuple(allocator: std.mem.Allocator, array: std.json.Array) LowerError!ExecStep {
    if (array.items.len < 3 or array.items.len > 5) return error.InvalidJson;

    const phase = try parsePhase(try expectString(array.items[0]));
    const op = try expectString(array.items[1]);
    const kernel_key = try allocator.dupe(u8, try expectString(array.items[2]));
    const op_spec = opToSpec(op) orelse return error.UnknownOp;

    const weights_key = if (array.items.len >= 4)
        try parseNullableStringDup(allocator, array.items[3])
    else
        null;

    const kind = if (array.items.len == 5)
        try parseKind(try expectString(array.items[4]))
    else
        op_spec.kind;

    return .{
        .phase = phase,
        .kind = kind,
        .name = null,
        .op = op,
        .kernel_key = kernel_key,
        .weights_key = weights_key,
    };
}

fn parseStepValue(allocator: std.mem.Allocator, value: std.json.Value) LowerError!ExecStep {
    return switch (value) {
        .object => |object| try parseStepObject(allocator, object),
        .array => |array| try parseStepTuple(allocator, array),
        else => error.InvalidJson,
    };
}

fn kernelFileToOp(kernel_file: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kernel_file, "gather.wgsl")) return "embed";
    if (std.mem.eql(u8, kernel_file, "rmsnorm.wgsl")) return "rmsnorm";
    if (std.mem.eql(u8, kernel_file, "rope.wgsl")) return "rope";
    if (std.mem.eql(u8, kernel_file, "residual.wgsl")) return "residual";
    if (std.mem.eql(u8, kernel_file, "gelu.wgsl")) return "gelu";
    if (std.mem.eql(u8, kernel_file, "sample.wgsl")) return "sample";
    if (std.mem.eql(u8, kernel_file, "attention_decode_online_f16kv.wgsl")) return "attention";
    if (std.mem.eql(u8, kernel_file, "attention_small_f16kv.wgsl")) return "attention_prefill";
    if (std.mem.eql(u8, kernel_file, "matmul_f16w_f32a_tiled.wgsl")) return "matmul";
    if (std.mem.eql(u8, kernel_file, "matmul_gemv_subgroup.wgsl")) return "matmul_q4k";
    return null;
}

fn parseKernelOpMap(
    allocator: std.mem.Allocator,
    kernel_obj: std.json.ObjectMap,
) LowerError!std.StringHashMap([]const u8) {
    var kernel_ops = std.StringHashMap([]const u8).init(allocator);
    errdefer kernel_ops.deinit();

    var iter = kernel_obj.iterator();
    while (iter.next()) |entry| {
        const kernel_key = entry.key_ptr.*;
        const meta = try expectObject(entry.value_ptr.*);
        const kernel_file = try expectString(meta.get("kernel") orelse return error.InvalidJson);
        const op = kernelFileToOp(kernel_file) orelse return error.InvalidJson;
        try kernel_ops.put(try allocator.dupe(u8, kernel_key), op);
    }
    return kernel_ops;
}

fn parseManifestPhaseTuple(
    allocator: std.mem.Allocator,
    phase: ExecPhase,
    kernel_ops: *const std.StringHashMap([]const u8),
    value: std.json.Value,
) LowerError!ExecStep {
    const tuple = try expectArray(value);
    if (tuple.items.len < 2 or tuple.items.len > 3) return error.InvalidJson;

    const kernel_key_raw = try expectString(tuple.items[1]);
    const op = kernel_ops.get(kernel_key_raw) orelse return error.InvalidJson;
    const op_spec = opToSpec(op) orelse return error.UnknownOp;

    return .{
        .phase = phase,
        .kind = op_spec.kind,
        .name = null,
        .op = op,
        .kernel_key = try allocator.dupe(u8, kernel_key_raw),
        .weights_key = if (tuple.items.len == 3)
            try parseNullableStringDup(allocator, tuple.items[2])
        else
            null,
    };
}

fn parseManifestPhaseSteps(
    allocator: std.mem.Allocator,
    phase: ExecPhase,
    kernel_ops: *const std.StringHashMap([]const u8),
    raw_steps: std.json.Value,
    out: *std.ArrayList(ExecStep),
) LowerError!void {
    const steps = try expectArray(raw_steps);
    try out.ensureUnusedCapacity(allocator, steps.items.len);
    for (steps.items) |step_value| {
        out.appendAssumeCapacity(try parseManifestPhaseTuple(allocator, phase, kernel_ops, step_value));
    }
}

fn appendManifestPostLayerSteps(
    allocator: std.mem.Allocator,
    kernel_ops: *const std.StringHashMap([]const u8),
    raw_steps: std.json.Value,
    prefill_out: *std.ArrayList(ExecStep),
    decode_out: *std.ArrayList(ExecStep),
) LowerError!void {
    const steps = try expectArray(raw_steps);
    for (steps.items) |step_value| {
        const tuple = try expectArray(step_value);
        if (tuple.items.len < 2 or tuple.items.len > 3) return error.InvalidJson;
        const step_name = try expectString(tuple.items[0]);
        if (std.mem.eql(u8, step_name, "sample")) {
            try decode_out.append(allocator, try parseManifestPhaseTuple(allocator, .decode, kernel_ops, step_value));
            continue;
        }
        if (std.mem.eql(u8, step_name, "lm_head")) {
            try decode_out.append(allocator, try parseManifestPhaseTuple(allocator, .decode, kernel_ops, step_value));
            continue;
        }
        if (std.mem.endsWith(u8, step_name, "_prefill")) {
            try prefill_out.append(allocator, try parseManifestPhaseTuple(allocator, .prefill, kernel_ops, step_value));
            continue;
        }

        try prefill_out.append(allocator, try parseManifestPhaseTuple(allocator, .prefill, kernel_ops, step_value));
        try decode_out.append(allocator, try parseManifestPhaseTuple(allocator, .decode, kernel_ops, step_value));
    }
}

fn validateStep(step: ExecStep, op_spec: OpSpec) LowerError!void {
    if (step.op.len == 0 or step.kernel_key.len == 0) return error.MalformedStep;
    if (step.repeat == 0) return error.MalformedStep;
    if (step.weights_key) |weights_key| {
        if (weights_key.len == 0) return error.MalformedStep;
    }
    if (step.kind != op_spec.kind) return error.MalformedStep;

    switch (step.phase) {
        .prefill => {
            if (!op_spec.allow_prefill) return error.MalformedStep;
        },
        .decode => {
            if (!op_spec.allow_decode) return error.MalformedStep;
        },
    }

    if (step.kind == .sample and step.weights_key != null) return error.MalformedStep;
    if (step.attention_type != null and !std.mem.eql(u8, op_spec.pattern, "attention_decode")) return error.MalformedStep;
    if (step.sliding_window_size) |sliding_window_size| {
        if (sliding_window_size == 0 or !std.mem.eql(u8, op_spec.pattern, "attention_decode")) return error.MalformedStep;
    }
    if (std.mem.eql(u8, step.op, "attention_sliding")) {
        if (step.attention_type) |attention_type| {
            if (attention_type != .sliding) return error.MalformedStep;
        }
    }
    if (std.mem.eql(u8, step.op, "kv_write_shared")) {
        if (step.kv_cache_alias == null) return error.MalformedStep;
    } else if (step.kv_cache_alias != null) {
        return error.MalformedStep;
    }
}

fn isLmHeadName(name: []const u8) bool {
    return std.mem.eql(u8, name, "lm_head") or
        std.mem.eql(u8, name, "lm_head_prefill") or
        std.mem.startsWith(u8, name, "lm_head_");
}

fn isLmHeadKernel(kernel_key: []const u8) bool {
    return std.mem.eql(u8, kernel_key, "lm_head") or
        std.mem.startsWith(u8, kernel_key, "lm_head_");
}

fn isLogitsProducerStep(step: ExecStep, op_spec: OpSpec) bool {
    if (step.kind != .compute) return false;
    const pattern = stepPattern(step, op_spec);
    if (!std.mem.eql(u8, pattern, "fused_gemv_dequant") and
        !std.mem.eql(u8, pattern, "tiled_matmul") and
        !std.mem.eql(u8, pattern, PREFILL_Q4K_GEMV_PATTERN) and
        !std.mem.eql(u8, pattern, "dense_gemv"))
    {
        return false;
    }
    if (step.name) |name| {
        if (isLmHeadName(name)) return true;
    }
    if (isLmHeadKernel(step.kernel_key)) return true;
    if (step.weights_key) |weights_key| {
        if (std.mem.eql(u8, weights_key, "lm_head")) return true;
    }
    return false;
}

fn stepPattern(step: ExecStep, op_spec: OpSpec) []const u8 {
    if (std.mem.eql(u8, op_spec.pattern, "tiled_matmul")) {
        if (isPrefillQ4kGemvStep(step)) return PREFILL_Q4K_GEMV_PATTERN;
        if (step.name) |name| {
            if (isLmHeadName(name)) return "dense_gemv";
        }
        if (isLmHeadKernel(step.kernel_key)) return "dense_gemv";
        if (step.weights_key) |weights_key| {
            if (std.mem.eql(u8, weights_key, "lm_head")) return "dense_gemv";
        }
    }
    return op_spec.pattern;
}

fn isPrefillQ4kGemvStep(step: ExecStep) bool {
    return step.phase == .prefill and std.mem.eql(u8, step.kernel_key, "tiled_31b");
}

fn deriveAttentionTypeFromLayerPattern(layer_pattern: LayerPattern, layer_index: u32) host.LaunchAttentionType {
    if (layer_index % layer_pattern.period == layer_pattern.offset) return .global;
    return .sliding;
}

fn deriveLaunchAttentionType(
    step: ExecStep,
    metadata: LowerMetadata,
    decode_attention_index: ?u32,
) ?host.LaunchAttentionType {
    if (std.mem.eql(u8, step.op, "attention_sliding")) return .sliding;
    if (step.attention_type) |attention_type| {
        return switch (attention_type) {
            .global => .global,
            .sliding => .sliding,
        };
    }
    if (decode_attention_index) |layer_index| {
        if (metadata.layer_pattern) |layer_pattern| {
            return deriveAttentionTypeFromLayerPattern(layer_pattern, layer_index);
        }
    }
    return null;
}

fn deriveSlidingWindowSize(step: ExecStep, metadata: LowerMetadata, attention_type: ?host.LaunchAttentionType) LowerError!?u32 {
    if (attention_type != .sliding) return null;
    const sliding_window_size = step.sliding_window_size orelse metadata.sliding_window_size orelse return error.MalformedStep;
    if (sliding_window_size == 0) return error.MalformedStep;
    return sliding_window_size;
}

/// Lower a sequence of execution-v1 steps into a HostPlan.
/// The caller is responsible for providing an execution-v1 sequence with
/// explicit phase ordering and a valid grid dimension tuple.
pub fn lowerToHostPlan(
    steps: []const ExecStep,
    grid: GridDims,
    kernel_buf: []host.KernelSpec,
    prefill_buf: []host.LaunchSpec,
    decode_buf: []host.LaunchSpec,
) LowerError!host.HostPlan {
    return lowerToHostPlanWithMetadata(steps, grid, .{}, kernel_buf, prefill_buf, decode_buf);
}

fn lowerToHostPlanWithMetadata(
    steps: []const ExecStep,
    grid: GridDims,
    metadata: LowerMetadata,
    kernel_buf: []host.KernelSpec,
    prefill_buf: []host.LaunchSpec,
    decode_buf: []host.LaunchSpec,
) LowerError!host.HostPlan {
    if (grid.width == INVALID_DIMENSION or grid.height == INVALID_DIMENSION) {
        return error.MalformedStep;
    }

    var kernel_count: u32 = 0;
    var prefill_count: u32 = 0;
    var decode_count: u32 = 0;
    var saw_prefill_step = false;
    var saw_decode_step = false;
    var saw_decode_compute = false;
    var prefill_closed_by_sample = false;
    var decode_closed_by_sample = false;
    var previous_prefill_was_logits = false;
    var previous_decode_was_logits = false;
    var decode_attention_index: u32 = 0;

    for (steps) |step| {
        const op_spec = opToSpec(step.op) orelse return error.UnknownOp;
        try validateStep(step, op_spec);

        switch (step.phase) {
            .prefill => {
                if (saw_decode_step) return error.MalformedStep;
                if (prefill_closed_by_sample) return error.MalformedStep;
                if (step.kind == .sample and !previous_prefill_was_logits) {
                    return error.SampleLogitsProducerMissing;
                }
                saw_prefill_step = true;
            },
            .decode => {
                if (!saw_prefill_step) return error.MalformedStep;
                if (decode_closed_by_sample) return error.MalformedStep;
                if (step.kind == .sample and !previous_decode_was_logits) {
                    return error.SampleLogitsProducerMissing;
                }
                saw_decode_step = true;
                if (step.kind == .compute) {
                    saw_decode_compute = true;
                }
            },
        }

        const pattern = stepPattern(step, op_spec);
        const attention_layer_index: ?u32 = if (step.phase == .decode and std.mem.eql(u8, pattern, "attention_decode")) blk: {
            const index = decode_attention_index;
            decode_attention_index += 1;
            break :blk index;
        } else null;
        const attention_type = deriveLaunchAttentionType(step, metadata, attention_layer_index);
        const sliding_window_size = try deriveSlidingWindowSize(step, metadata, attention_type);
        const current_pos_source: ?host.CurrentPosSource = if (attention_type == .sliding or
            (step.phase == .decode and std.mem.eql(u8, pattern, "kv_write")))
            .decode_position
        else
            null;
        const kv_cache_alias = if (std.mem.eql(u8, step.op, "kv_write_shared")) blk: {
            if ((metadata.num_kv_shared_layers orelse 0) == 0) return error.MalformedStep;
            break :blk step.kv_cache_alias;
        } else null;

        // Add kernel if not already present.
        var found = false;
        var ki: u32 = 0;
        while (ki < kernel_count) : (ki += 1) {
            if (std.mem.eql(u8, kernel_buf[ki].name, step.kernel_key)) {
                kernel_buf[ki].count += 1;
                found = true;
                break;
            }
        }
        if (!found) {
            if (kernel_count >= kernel_buf.len) return error.OutputTooLarge;
            kernel_buf[kernel_count] = .{
                .name = step.kernel_key,
                .pattern = pattern,
                .count = step.repeat,
            };
            kernel_count += 1;
        } else {
            kernel_buf[ki].count += step.repeat - 1;
        }

        switch (step.phase) {
            .prefill => {
                if (prefill_count >= prefill_buf.len) return error.OutputTooLarge;
                prefill_buf[prefill_count] = .{
                    .kernel_name = step.kernel_key,
                    .repeat = step.repeat,
                    .attention_type = attention_type,
                    .sliding_window_size = sliding_window_size,
                    .current_pos_source = current_pos_source,
                    .kv_cache_alias = kv_cache_alias,
                };
                prefill_count += 1;
                if (step.kind == .sample) {
                    prefill_closed_by_sample = true;
                    previous_prefill_was_logits = false;
                } else {
                    previous_prefill_was_logits = isLogitsProducerStep(step, op_spec);
                }
            },
            .decode => {
                if (decode_count >= decode_buf.len) return error.OutputTooLarge;
                decode_buf[decode_count] = .{
                    .kernel_name = step.kernel_key,
                    .repeat = step.repeat,
                    .attention_type = attention_type,
                    .sliding_window_size = sliding_window_size,
                    .current_pos_source = current_pos_source,
                    .kv_cache_alias = kv_cache_alias,
                };
                decode_count += 1;
                if (step.kind == .sample) {
                    decode_closed_by_sample = true;
                    previous_decode_was_logits = false;
                } else {
                    previous_decode_was_logits = isLogitsProducerStep(step, op_spec);
                }
            },
        }
    }

    if (saw_decode_step and !saw_decode_compute) return error.MalformedStep;
    if (saw_decode_step and !saw_prefill_step) return error.MalformedStep;

    return .{
        .pe_grid_width = grid.width,
        .pe_grid_height = grid.height,
        .kernels = kernel_buf[0..kernel_count],
        .prefill_launches = prefill_buf[0..prefill_count],
        .decode_launches = decode_buf[0..decode_count],
    };
}

pub fn lowerJsonToHostPlan(
    allocator: std.mem.Allocator,
    json_payload: []const u8,
    kernel_buf: []host.KernelSpec,
    prefill_buf: []host.LaunchSpec,
    decode_buf: []host.LaunchSpec,
) LowerError!host.HostPlan {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const root = try expectObject(parsed.value);
    const grid = try parseOptionalGrid(root.get("grid"));
    const model_config = try parseModelConfig(root.get("modelConfig"));
    const placement_policy = try parsePlacementPolicy(root.get("placementPolicy"));
    const metadata = LowerMetadata{
        .layer_pattern = try parseLayerPattern(root.get("layerPattern")),
        .num_kv_shared_layers = try parseOptionalU32(root.get("numKvSharedLayers")),
        .sliding_window_size = try parseOptionalU32(root.get("slidingWindowSize")),
    };
    const steps_value = root.get("steps") orelse return error.InvalidJson;
    const steps_array = try expectArray(steps_value);

    var steps = try allocator.alloc(ExecStep, steps_array.items.len);
    defer allocator.free(steps);

    for (steps_array.items, 0..) |step_value, idx| {
        steps[idx] = try parseStepValue(allocator, step_value);
    }

    const initial_grid: GridDims = grid orelse .{ .width = 1, .height = 1 };
    var plan = try lowerToHostPlanWithMetadata(steps, initial_grid, metadata, kernel_buf, prefill_buf, decode_buf);
    if (grid == null) {
        const resolved_model_config = model_config orelse return error.InvalidJson;
        const derived_grid = try mem_plan.deriveGrid(resolved_model_config, plan, placement_policy);
        plan.pe_grid_width = derived_grid.width;
        plan.pe_grid_height = derived_grid.height;
    }
    if (root.get("eosTokenId")) |eos_value| {
        plan.eos_token_id = switch (eos_value) {
            .null => null,
            else => try expectU32(eos_value),
        };
    }
    return plan;
}

pub fn lowerManifestExecutionToHostPlan(
    allocator: std.mem.Allocator,
    json_payload: []const u8,
    kernel_buf: []host.KernelSpec,
    prefill_buf: []host.LaunchSpec,
    decode_buf: []host.LaunchSpec,
) LowerError!host.HostPlan {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const root = try expectObject(parsed.value);
    const grid = try parseOptionalGrid(root.get("grid"));
    const model_config = try parseModelConfig(root.get("modelConfig"));
    const placement_policy = try parsePlacementPolicy(root.get("placementPolicy"));
    const metadata = LowerMetadata{
        .layer_pattern = try parseLayerPattern(root.get("layerPattern")),
        .num_kv_shared_layers = try parseOptionalU32(root.get("numKvSharedLayers")),
        .sliding_window_size = try parseOptionalU32(root.get("slidingWindowSize")),
    };

    var manifest_phase_steps = try std.ArrayList(ExecStep).initCapacity(allocator, 0);
    defer manifest_phase_steps.deinit(allocator);
    if (root.get("execution")) |execution_value| {
        const execution = try expectObject(execution_value);
        const kernels = try expectObject(execution.get("kernels") orelse return error.InvalidJson);
        var kernel_ops = try parseKernelOpMap(allocator, kernels);
        defer kernel_ops.deinit();

        var prefill_steps = try std.ArrayList(ExecStep).initCapacity(allocator, 0);
        defer prefill_steps.deinit(allocator);
        var decode_steps = try std.ArrayList(ExecStep).initCapacity(allocator, 0);
        defer decode_steps.deinit(allocator);

        try parseManifestPhaseSteps(allocator, .prefill, &kernel_ops, execution.get("preLayer") orelse return error.InvalidJson, &prefill_steps);
        try parseManifestPhaseSteps(allocator, .prefill, &kernel_ops, execution.get("prefill") orelse return error.InvalidJson, &prefill_steps);
        try parseManifestPhaseSteps(allocator, .decode, &kernel_ops, execution.get("decode") orelse return error.InvalidJson, &decode_steps);
        try appendManifestPostLayerSteps(
            allocator,
            &kernel_ops,
            execution.get("postLayer") orelse return error.InvalidJson,
            &prefill_steps,
            &decode_steps,
        );

        try manifest_phase_steps.ensureUnusedCapacity(allocator, prefill_steps.items.len + decode_steps.items.len);
        manifest_phase_steps.appendSliceAssumeCapacity(prefill_steps.items);
        manifest_phase_steps.appendSliceAssumeCapacity(decode_steps.items);
    } else if (root.get("steps")) |steps_value| {
        const steps_array = try expectArray(steps_value);
        try manifest_phase_steps.ensureUnusedCapacity(allocator, steps_array.items.len);
        for (steps_array.items) |step_value| {
            manifest_phase_steps.appendAssumeCapacity(try parseStepValue(allocator, step_value));
        }
    } else {
        return error.InvalidJson;
    }

    const initial_grid: GridDims = grid orelse .{ .width = 1, .height = 1 };
    var plan = try lowerToHostPlanWithMetadata(manifest_phase_steps.items, initial_grid, metadata, kernel_buf, prefill_buf, decode_buf);
    if (grid == null) {
        const resolved_model_config = model_config orelse return error.InvalidJson;
        const derived_grid = try mem_plan.deriveGrid(resolved_model_config, plan, placement_policy);
        plan.pe_grid_width = derived_grid.width;
        plan.pe_grid_height = derived_grid.height;
    }
    if (root.get("eosTokenId")) |eos_value| {
        plan.eos_token_id = switch (eos_value) {
            .null => null,
            else => try expectU32(eos_value),
        };
    }
    return plan;
}

test "execution-v1 step repeat lowers into HostPlan launch repeat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payload =
        \\{
        \\  "grid": { "width": 2, "height": 1 },
        \\  "steps": [
        \\    {
        \\      "phase": "prefill",
        \\      "op": "embed",
        \\      "kernelKey": "embed",
        \\      "repeat": 3
        \\    }
        \\  ]
        \\}
    ;
    var kernel_buf: [4]host.KernelSpec = undefined;
    var prefill_buf: [4]host.LaunchSpec = undefined;
    var decode_buf: [4]host.LaunchSpec = undefined;
    const plan = try lowerJsonToHostPlan(
        arena.allocator(),
        payload,
        &kernel_buf,
        &prefill_buf,
        &decode_buf,
    );
    try std.testing.expectEqual(@as(usize, 1), plan.kernels.len);
    try std.testing.expectEqual(@as(u32, 3), plan.kernels[0].count);
    try std.testing.expectEqual(@as(usize, 1), plan.prefill_launches.len);
    try std.testing.expectEqual(
        @as(u32, 3),
        plan.prefill_launches[0].repeat,
    );
}

test "execution-v1 routes tiled_31b prefill matmul to canonical Q4K GEMV" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const payload =
        \\{
        \\  "grid": { "width": 2, "height": 1 },
        \\  "steps": [
        \\    {
        \\      "phase": "prefill",
        \\      "op": "matmul",
        \\      "kernelKey": "tiled_31b",
        \\      "weightsKey": "layer.0.self_attn.q_proj"
        \\    }
        \\  ]
        \\}
    ;
    var kernel_buf: [4]host.KernelSpec = undefined;
    var prefill_buf: [4]host.LaunchSpec = undefined;
    var decode_buf: [4]host.LaunchSpec = undefined;
    const plan = try lowerJsonToHostPlan(
        arena.allocator(),
        payload,
        &kernel_buf,
        &prefill_buf,
        &decode_buf,
    );
    try std.testing.expectEqual(@as(usize, 1), plan.kernels.len);
    try std.testing.expectEqualStrings("tiled_31b", plan.kernels[0].name);
    try std.testing.expectEqualStrings(PREFILL_Q4K_GEMV_PATTERN, plan.kernels[0].pattern);
}
