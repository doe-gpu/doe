// Shared executable TSIR kernel-body writers.
//
// These routines consume the semantic body contract directly. Realization-only
// skeleton emitters remain available for contract inspection, but lowering
// paths call these semantic-aware writers once the frontend has assigned
// family roles.

const std = @import("std");
const schema = @import("schema.zig");

pub const Backend = enum {
    webgpu,
    csl,
    msl,
    dxil,
    spir_v,
};

pub const EmitError = std.mem.Allocator.Error || error{
    InvalidBodyContract,
    MissingBindingRole,
    UnsupportedKernelBody,
    UnsupportedScalarKind,
};

/// Emitter configuration knobs the live HostPlan path needs to control
/// when delegating through TSIR. The defaults preserve the prior behavior
/// (var prefix `tsir_`, no param defaults, no Gemma offset), so existing
/// callers and tests are unchanged.
///
/// `var_prefix` controls the TSIR-internal variable name prefix. For the
/// live `emit_csl_semantic_ops` path the prefix is empty, which produces
/// bare `a` / `b` / `output` var names matching the symbols downstream
/// host plans expect to bind.
///
/// `chunk_size_default` controls whether the emitted `param chunk_size`
/// declaration carries a default value. The live elementwise layout
/// invokes `pe_program.csl` without forwarding `chunk_size` through the
/// `@set_tile_code` struct, so cslc raises
/// `csl_compile_uninitialized_param` unless the param has a default.
/// The live wrapper sets `chunk_size_default = 1024` to mirror the
/// prior hand-written behavior; TSIR-only callers that route through
/// the layout pass-through can leave it null.
///
/// `hidden_size_default` is the rms_norm analog of `chunk_size_default`
/// — the live rmsnorm layout doesn't forward `hidden_size` either, so
/// the live wrapper sets `hidden_size_default = 1024` to match the
/// prior hand-written body. The TSIR-only path leaves it null.
///
/// `gemma_one_plus_weight_offset` switches the rms_norm per-element
/// output from the standard `inv_rms * scale[d]` to Gemma's
/// `inv_rms * (1.0 + scale[d])` form. Doppler's RMSNorm reference
/// (`rmsnorm.wgsl`) uses the offset; non-Gemma callers leave it false.
///
/// `head_dim_default`, `max_seq_len_default`, and `read_len_default`
/// are the kv_write / kv_read analogs of `hidden_size_default`. The
/// live kv_cache layout doesn't forward these params through
/// `@set_tile_code`, so cslc raises `csl_compile_uninitialized_param`
/// unless they carry source-level defaults. The live wrapper sets
/// them; TSIR-only callers leave them null to preserve the
/// "no defaults" test expectation.
///
/// `kv_cache_pe_strategy` selects the per-PE residency layout for the
/// KV cache buffers. `.full_per_pe` (default) emits the full
/// `kv_cache_len = max_seq_len * head_dim` array on every PE — the
/// pre-existing behavior that all current tests and live wrappers
/// expect. `.slot_sharded` shards the cache by position-slot stride:
/// each PE owns `slots_per_pe = ceil(max_seq_len / num_pes)` slots,
/// allocates `[slots_per_pe * head_dim]f32` per cache, and the
/// owning PE writes/reads only when the global decode position falls
/// in its local stride. The slot-sharded path additionally requires
/// `pe_id` / `num_pes` params from the layout side.
///
/// `kv_slots_per_pe_default` is the kv_write / kv_read analog of
/// `head_dim_default`: when the live wrapper invokes the slot-sharded
/// strategy via `@set_tile_code` without forwarding `slots_per_pe`,
/// the emitted body needs a source-level default to satisfy cslc's
/// uninitialized-param check.
pub const KvCachePeStrategy = enum { full_per_pe, slot_sharded };

/// Per-PE residency layout for `attention_scores`:
///
///   - `.full_per_pe` (default) keeps the full `[kv_len * head_dim]f32`
///     K and V buffers replicated on every PE. Single-PE canary path;
///     used by `attention_head256_f16kv` (kv_len=15) and the kv_len≤8
///     `attention_head512_f16kv` lane that already fits the WSE-3
///     48 KiB per-PE SRAM budget.
///
///   - `.kv_axis_sharded` shards the K/V buffers along the position
///     axis: each PE owns `slots_per_pe = ceil(kv_len_max / num_pes)`
///     slots, allocates `[slots_per_pe * head_dim]f32` per K/V buffer,
///     and emits a partials-only kernel that writes a per-PE
///     `local_O[d]` (un-normalized output contribution),
///     `local_max`, and `local_sum_exp`. The host plan stitches the
///     PE partials into the final `O[d]` using the standard
///     distributed log-sum-exp recipe (mirrors the slot-sharded KV
///     pattern: kernel emits per-PE pieces, host does the cross-PE
///     reduce). This unblocks `head_dim=512` at `kv_len ≥ 15`, which
///     the single-PE path cannot fit (see
///     `docs/cerebras-model-ledgers.md` attention-canary follow-up).
pub const AttentionPeStrategy = enum { full_per_pe, kv_axis_sharded };
pub const AttentionPeIdSource = enum { tile_param, layout_coordinates };

pub const Config = struct {
    var_prefix: []const u8 = "tsir_",
    chunk_size_default: ?u32 = null,
    hidden_size_default: ?u32 = null,
    gemma_one_plus_weight_offset: bool = false,
    head_dim_default: ?u32 = null,
    max_seq_len_default: ?u32 = null,
    read_len_default: ?u32 = null,
    kv_cache_pe_strategy: KvCachePeStrategy = .full_per_pe,
    kv_slots_per_pe_default: ?u32 = null,
    attention_pe_strategy: AttentionPeStrategy = .full_per_pe,
    /// `.tile_param` expects the wrapper layout to provide `pe_id`.
    /// `.layout_coordinates` derives it from CSL `<layout>` coordinates,
    /// which avoids per-tile code specialization for large 2-D grids.
    attention_pe_id_source: AttentionPeIdSource = .tile_param,
    /// Compile-time default for `slots_per_pe` in the kv-axis-sharded
    /// attention path. `slots_per_pe = ceil(kv_len_max / num_pes)`.
    /// The live wrapper computes this from the manifest-shape kv_len
    /// budget; TSIR-only callers leave it null and accept the
    /// `csl_compile_uninitialized_param` failure.
    attention_slots_per_pe_default: ?u32 = null,
};

pub const default_config: Config = .{};

// Track 2 dtype-routing helpers live in `emit_dtype_routing.zig` so
// emit_kernel_body.zig stays under the 999-line cap. Re-exported here
// for backward-compat callers that referenced them via this module.
const dtype_routing = @import("emit_dtype_routing.zig");
const csl_f16_pack = @import("emit_csl_f16_pack.zig");
pub const cslElemName = dtype_routing.cslElemName;
pub const wgslElemName = dtype_routing.wgslElemName;
pub const isSupportedComputeElem = dtype_routing.isSupportedComputeElem;
pub const writeWgslF16Enable = dtype_routing.writeWgslF16Enable;

/// Reject compute dtypes the lowering does not yet support. Per-op
/// emit functions call this with the lane dtype (derived from a
/// canonical binding) before producing any source bytes. Returns
/// `EmitError.UnsupportedScalarKind` so emit-body callers don't have
/// to widen their error sets.
pub fn requireSupportedComputeElem(elem: schema.ScalarKind) EmitError!void {
    if (!dtype_routing.isSupportedComputeElem(elem)) return error.UnsupportedScalarKind;
}

pub fn emit(writer: anytype, func: schema.SemanticFunction, backend: Backend) EmitError!void {
    return emitWithConfig(writer, func, backend, &default_config);
}

pub fn emitWithConfig(
    writer: anytype,
    func: schema.SemanticFunction,
    backend: Backend,
    config: *const Config,
) EmitError!void {
    return switch (backend) {
        .webgpu => emitWebGpu(writer, func),
        .csl => emitCsl(writer, func, config),
        .msl => emitMsl(writer, func),
        .dxil => emitDxil(writer, func),
        .spir_v => emitSpirV(writer, func),
    };
}

fn emitWebGpu(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    return switch (func.body.op) {
        .fused_gemv => emitWebGpuFusedGemv(writer, func),
        .rms_norm => emitWebGpuRmsNorm(writer, func),
        .gather => emitWebGpuGather(writer, func),
        // attention_scores lowering is fixture-only under Move 4 D3;
        // see runtime/zig/tests/tsir/real/attention_head256_f16kv/.
        // Add executable body emission when attention moves out of
        // the typed-rejection phase.
        .unknown, .attention_scores, .residual_add, .gelu_gated, .silu_gated, .sigmoid_gated, .kv_write, .kv_read, .conv1d_depthwise, .l2_normalize, .linear_attention => error.UnsupportedKernelBody,
    };
}

fn emitCsl(writer: anytype, func: schema.SemanticFunction, config: *const Config) EmitError!void {
    return switch (func.body.op) {
        .fused_gemv => emitCslFusedGemv(writer, func),
        .rms_norm => emitCslRmsNorm(writer, func, config),
        .gather => emitCslGather(writer, func),
        .residual_add => emitCslResidualAdd(writer, func, config),
        .gelu_gated => @import("emit_kernel_body_gated.zig").emitCsl(writer, func, config, .gelu),
        .silu_gated => @import("emit_kernel_body_gated.zig").emitCsl(writer, func, config, .silu),
        .sigmoid_gated => @import("emit_kernel_body_gated.zig").emitCsl(writer, func, config, .sigmoid),
        .kv_write => emitCslKvWrite(writer, func, config),
        .kv_read => emitCslKvRead(writer, func, config),
        .attention_scores => @import("emit_kernel_body_attention.zig").emitCslAttentionScores(writer, func, config),
        .conv1d_depthwise => @import("emit_kernel_body_conv1d.zig").emitCslConv1DDepthwise(writer, func, config),
        .l2_normalize => @import("emit_kernel_body_l2_normalize.zig").emitCslL2Normalize(writer, func, config),
        .linear_attention => @import("emit_kernel_body_linear_attention.zig").emitCslLinearAttention(writer, func, config),
        .unknown => error.UnsupportedKernelBody,
    };
}

fn emitMsl(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    return switch (func.body.op) {
        .fused_gemv => emitMslFusedGemv(writer, func),
        .rms_norm => emitMslRmsNorm(writer, func),
        .gather => emitMslGather(writer, func),
        // attention_scores lowering is fixture-only under Move 4 D3;
        // see runtime/zig/tests/tsir/real/attention_head256_f16kv/.
        // Add executable body emission when attention moves out of
        // the typed-rejection phase.
        .unknown, .attention_scores, .residual_add, .gelu_gated, .silu_gated, .sigmoid_gated, .kv_write, .kv_read, .conv1d_depthwise, .l2_normalize, .linear_attention => error.UnsupportedKernelBody,
    };
}

fn emitDxil(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    return switch (func.body.op) {
        .fused_gemv => emitDxilFusedGemv(writer, func),
        .rms_norm => emitDxilRmsNorm(writer, func),
        .gather => emitDxilGather(writer, func),
        // attention_scores lowering is fixture-only under Move 4 D3;
        // see runtime/zig/tests/tsir/real/attention_head256_f16kv/.
        // Add executable body emission when attention moves out of
        // the typed-rejection phase.
        .unknown, .attention_scores, .residual_add, .gelu_gated, .silu_gated, .sigmoid_gated, .kv_write, .kv_read, .conv1d_depthwise, .l2_normalize, .linear_attention => error.UnsupportedKernelBody,
    };
}

fn emitSpirV(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    return switch (func.body.op) {
        .fused_gemv => emitSpirVFusedGemv(writer, func),
        .rms_norm => emitSpirVRmsNorm(writer, func),
        .gather => emitSpirVGather(writer, func),
        // attention_scores lowering is fixture-only under Move 4 D3;
        // see runtime/zig/tests/tsir/real/attention_head256_f16kv/.
        // Add executable body emission when attention moves out of
        // the typed-rejection phase.
        .unknown, .attention_scores, .residual_add, .gelu_gated, .silu_gated, .sigmoid_gated, .kv_write, .kv_read, .conv1d_depthwise, .l2_normalize, .linear_attention => error.UnsupportedKernelBody,
    };
}

fn emitWebGpuFusedGemv(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    const matrix = try bindingForRole(func, .matrix);
    const vector = try bindingForRole(func, .vector);
    const output = try bindingForRole(func, .output);
    try requireElem(matrix, .f32);
    try requireElem(vector, .f32);
    try requireElem(output, .f32);

    try writer.print("@group({d}) @binding({d}) var<storage, read> tsir_matrix: array<f32>;\n", .{ matrix.group, matrix.binding });
    try writer.print("@group({d}) @binding({d}) var<storage, read> tsir_vector: array<f32>;\n", .{ vector.group, vector.binding });
    try writer.print("@group({d}) @binding({d}) var<storage, read_write> tsir_output: array<f32>;\n\n", .{ output.group, output.binding });
    try writer.writeAll("@compute @workgroup_size(1, 1, 1)\n");
    try writer.writeAll("fn main(@builtin(global_invocation_id) gid: vec3<u32>) {\n");
    try writer.writeAll("    let row = gid.x;\n");
    try writer.writeAll("    let rows = arrayLength(&tsir_output);\n");
    try writer.writeAll("    let cols = arrayLength(&tsir_vector);\n");
    try writer.writeAll("    if (row >= rows) {\n");
    try writer.writeAll("        return;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    var acc: f32 = 0.0;\n");
    try writer.writeAll("    for (var k = 0u; k < cols; k = k + 1u) {\n");
    try writer.writeAll("        acc = acc + tsir_matrix[row * cols + k] * tsir_vector[k];\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    tsir_output[row] = acc;\n");
    try writer.writeAll("}\n");
}

fn emitWebGpuRmsNorm(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    const input = try bindingForRole(func, .input);
    const scale = try bindingForRole(func, .scale);
    const output = try bindingForRole(func, .output);
    try requireElem(input, .f32);
    try requireElem(scale, .f32);
    try requireElem(output, .f32);

    const rms = try rmsNormBody(func);
    switch (rms.epsilon.source) {
        .uniform_field => {
            if (rms.epsilon.byte_offset != 4) return error.InvalidBodyContract;
            try writer.writeAll("struct TsirRmsNormUniforms {\n");
            try writer.writeAll("    hidden_size: u32,\n");
            try writer.writeAll("    epsilon: f32,\n");
            try writer.writeAll("};\n\n");
        },
        .literal_f32 => {},
    }
    try writer.print("@group({d}) @binding({d}) var<storage, read> tsir_input: array<f32>;\n", .{ input.group, input.binding });
    try writer.print("@group({d}) @binding({d}) var<storage, read> tsir_scale: array<f32>;\n", .{ scale.group, scale.binding });
    try writer.print("@group({d}) @binding({d}) var<storage, read_write> tsir_output: array<f32>;\n", .{ output.group, output.binding });
    switch (rms.epsilon.source) {
        .uniform_field => {
            const uniform_index = rms.epsilon.binding_index orelse return error.InvalidBodyContract;
            const uniform = try bindingForIndex(func, uniform_index);
            try writer.print("@group({d}) @binding({d}) var<uniform> tsir_dims: TsirRmsNormUniforms;\n\n", .{ uniform.group, uniform.binding });
        },
        .literal_f32 => try writer.writeAll("\n"),
    }
    try writer.writeAll("@compute @workgroup_size(1, 1, 1)\n");
    try writer.writeAll("fn main(@builtin(global_invocation_id) gid: vec3<u32>) {\n");
    try writer.writeAll("    let d = gid.x;\n");
    switch (rms.epsilon.source) {
        .uniform_field => try writer.writeAll("    let hidden_size = tsir_dims.hidden_size;\n"),
        .literal_f32 => try writer.writeAll("    let hidden_size = arrayLength(&tsir_output);\n"),
    }
    try writer.writeAll("    if (d >= hidden_size) {\n");
    try writer.writeAll("        return;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    var sum_sq: f32 = 0.0;\n");
    try writer.writeAll("    for (var i = 0u; i < hidden_size; i = i + 1u) {\n");
    try writer.writeAll("        let v = tsir_input[i];\n");
    try writer.writeAll("        sum_sq = sum_sq + v * v;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    let mean_sq = sum_sq / f32(hidden_size);\n");
    try writer.writeAll("    let inv_rms = inverseSqrt(mean_sq + ");
    try writeWebGpuEpsilon(writer, rms.epsilon);
    try writer.writeAll(");\n");
    try writer.writeAll("    tsir_output[d] = tsir_input[d] * inv_rms * tsir_scale[d];\n");
    try writer.writeAll("}\n");
}

fn emitWebGpuGather(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    const indices = try bindingForRole(func, .indices);
    const table = try bindingForRole(func, .table);
    const output = try bindingForRole(func, .output);
    try requireElem(indices, .u32);
    try requireElem(table, .f32);
    try requireElem(output, .f32);

    try writer.print("@group({d}) @binding({d}) var<storage, read> tsir_indices: array<u32>;\n", .{ indices.group, indices.binding });
    try writer.print("@group({d}) @binding({d}) var<storage, read> tsir_table: array<f32>;\n", .{ table.group, table.binding });
    try writer.print("@group({d}) @binding({d}) var<storage, read_write> tsir_output: array<f32>;\n\n", .{ output.group, output.binding });
    try writer.writeAll("@compute @workgroup_size(1, 1, 1)\n");
    try writer.writeAll("fn main(@builtin(global_invocation_id) gid: vec3<u32>) {\n");
    try writer.writeAll("    let h = gid.x;\n");
    try writer.writeAll("    let token = gid.y;\n");
    try writer.writeAll("    let tokens = arrayLength(&tsir_indices);\n");
    try writer.writeAll("    let hidden = arrayLength(&tsir_output) / tokens;\n");
    try writer.writeAll("    if (token >= tokens || h >= hidden) {\n");
    try writer.writeAll("        return;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    let row = tsir_indices[token];\n");
    try writer.writeAll("    let vocab = arrayLength(&tsir_table) / hidden;\n");
    try writer.writeAll("    if (row >= vocab) {\n");
    try writer.writeAll("        tsir_output[token * hidden + h] = 0.0;\n");
    try writer.writeAll("        return;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    tsir_output[token * hidden + h] = tsir_table[row * hidden + h];\n");
    try writer.writeAll("}\n");
}

fn emitCslFusedGemv(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    const matrix = try bindingForRole(func, .matrix);
    const vector = try bindingForRole(func, .vector);
    const output = try bindingForRole(func, .output);
    const elem = output.elem;
    try requireSupportedComputeElem(elem);
    try requireElem(matrix, elem);
    try requireElem(vector, elem);
    try requireElem(output, elem);
    const ty = cslElemName(elem);

    try writer.writeAll("param memcpy_params;\n");
    try writer.writeAll("param M: i16;\n");
    try writer.writeAll("param K: i16;\n");
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try writer.print("var tsir_matrix: [M * K]{s} = @zeros([M * K]{s});\n", .{ ty, ty });
    try writer.print("var tsir_vector: [K]{s} = @zeros([K]{s});\n", .{ ty, ty });
    try writer.print("var tsir_output: [M]{s} = @zeros([M]{s});\n", .{ ty, ty });
    try writer.print("var tsir_matrix_ptr: [*]{s} = &tsir_matrix;\n", .{ty});
    try writer.print("var tsir_vector_ptr: [*]{s} = &tsir_vector;\n", .{ty});
    try writer.print("var tsir_output_ptr: [*]{s} = &tsir_output;\n\n", .{ty});
    try writer.writeAll("fn compute() void {\n");
    try writer.writeAll("    for (@range(i16, M)) |row| {\n");
    try writer.print("        var acc: {s} = 0.0;\n", .{ty});
    try writer.writeAll("        for (@range(i16, K)) |k| {\n");
    try writer.writeAll("            acc += tsir_matrix[@as(u32, row) * @as(u32, K) + @as(u32, k)] * tsir_vector[@as(u32, k)];\n");
    try writer.writeAll("        }\n");
    try writer.writeAll("        tsir_output[@as(u32, row)] = acc;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writeCslFusedGemvExports(writer);
}

fn emitCslRmsNorm(
    writer: anytype,
    func: schema.SemanticFunction,
    config: *const Config,
) EmitError!void {
    const input = try bindingForRole(func, .input);
    const scale = try bindingForRole(func, .scale);
    const output = try bindingForRole(func, .output);
    const elem = output.elem;
    try requireSupportedComputeElem(elem);
    try requireElem(input, elem);
    try requireElem(scale, elem);
    try requireElem(output, elem);
    const rms = try rmsNormBody(func);

    const p = config.var_prefix;
    const ty = cslElemName(elem);
    try writer.writeAll("param memcpy_params;\n");
    try writeCslHiddenSizeParam(writer, config);
    if (rms.epsilon.source == .uniform_field) {
        if (rms.epsilon.byte_offset != 4) return error.InvalidBodyContract;
        // Epsilon is always carried as f32 in the uniform layout (4-byte
        // wire format pinned by the kernel-body contract). Emit as f32
        // and cast at use to preserve the compute-elem flow.
        try writer.writeAll("param epsilon: f32;\n");
    }
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try writer.writeAll("const math = @import_module(\"<math>\");\n");
    try writeCslSqrtNr(writer, elem);
    try writeCslBufferArray(writer, p, input.name, "hidden_size", ty);
    try writeCslBufferArray(writer, p, scale.name, "hidden_size", ty);
    try writeCslBufferArray(writer, p, output.name, "hidden_size", ty);
    if (elem == .f16) try csl_f16_pack.writeBufferArray(writer, p, output.name, "hidden_size");
    try writeCslBufferPointer(writer, p, input.name, ty);
    try writeCslBufferPointer(writer, p, scale.name, ty);
    try writeCslBufferPointer(writer, p, output.name, ty);
    if (elem == .f16) try csl_f16_pack.writeBufferPointer(writer, p, output.name);
    try writer.writeAll("\n");
    try writer.writeAll("fn compute() void {\n");
    try writer.print("    var sum_sq: {s} = 0.0;\n", .{ty});
    try writer.writeAll("    for (@range(i16, hidden_size)) |i| {\n");
    try writer.print(
        "        const v = {s}{s}[@as(u32, i)];\n",
        .{ p, input.name },
    );
    try writer.writeAll("        sum_sq += v * v;\n");
    try writer.writeAll("    }\n");
    try writer.print("    const mean_sq = sum_sq / @as({s}, hidden_size);\n", .{ty});
    try writer.writeAll("    const inv_rms = 1.0 / sqrt_nr(mean_sq + ");
    try writeCslEpsilon(writer, rms.epsilon);
    try writer.writeAll(");\n");
    try writer.writeAll("    for (@range(i16, hidden_size)) |d| {\n");
    if (config.gemma_one_plus_weight_offset) {
        try writer.print(
            "        {s}{s}[@as(u32, d)] = {s}{s}[@as(u32, d)] * inv_rms * (1.0 + {s}{s}[@as(u32, d)]);\n",
            .{ p, output.name, p, input.name, p, scale.name },
        );
    } else {
        try writer.print(
            "        {s}{s}[@as(u32, d)] = {s}{s}[@as(u32, d)] * inv_rms * {s}{s}[@as(u32, d)];\n",
            .{ p, output.name, p, input.name, p, scale.name },
        );
    }
    try writer.writeAll("    }\n");
    if (elem == .f16) try csl_f16_pack.writePackLoop(writer, p, output.name, "hidden_size");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try writeCslExportSymbol(writer, p, input.name);
    try writeCslExportSymbol(writer, p, scale.name);
    if (elem == .f16) {
        try csl_f16_pack.writeExportSymbol(writer, p, output.name);
    } else {
        try writeCslExportSymbol(writer, p, output.name);
    }
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}

fn writeCslHiddenSizeParam(writer: anytype, config: *const Config) !void {
    if (config.hidden_size_default) |value| {
        try writer.print("param hidden_size: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param hidden_size: i16;\n");
    }
}

pub fn writeCslSqrtNr(writer: anytype, elem: schema.ScalarKind) !void {
    const ty = cslElemName(elem);
    if (elem == .f32) {
        // Preserve byte-identical f32 output: same line shape as before
        // the dtype widening so the f32 lane keeps its byte-identity
        // canary green.
        try writer.writeAll("fn sqrt_nr(x: f32) f32 {\n");
        try writer.writeAll("    const y0: f32 = math.sqrt(x);\n");
        try writer.writeAll("    return 0.5 * (y0 + x / y0);\n");
        try writer.writeAll("}\n\n");
        return;
    }
    // For non-f32 lanes (f16 today) up-cast to f32 for the math.sqrt
    // libm call and the Newton-Raphson refinement, then narrow back.
    // Tensors stay in `elem`; this carve-out is the libm coverage
    // detail flagged in the Track-2 design notes.
    try writer.print("fn sqrt_nr(x: {s}) {s} {{\n", .{ ty, ty });
    try writer.writeAll("    const x32: f32 = @as(f32, x);\n");
    try writer.writeAll("    const y0: f32 = math.sqrt(x32);\n");
    try writer.writeAll("    const refined: f32 = 0.5 * (y0 + x32 / y0);\n");
    try writer.print("    return @as({s}, refined);\n", .{ty});
    try writer.writeAll("}\n\n");
}

fn emitCslGather(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    const indices = try bindingForRole(func, .indices);
    const table = try bindingForRole(func, .table);
    const output = try bindingForRole(func, .output);
    const elem = output.elem;
    try requireSupportedComputeElem(elem);
    try requireElem(indices, .u32);
    try requireElem(table, elem);
    try requireElem(output, elem);
    const ty = cslElemName(elem);

    try writer.writeAll("param memcpy_params;\n");
    try writer.writeAll("param num_tokens: i16;\n");
    try writer.writeAll("param hidden: i16;\n");
    try writer.writeAll("param vocab: i16;\n");
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try writer.writeAll("var tsir_indices: [num_tokens]u32 = @zeros([num_tokens]u32);\n");
    try writer.print("var tsir_table: [vocab * hidden]{s} = @zeros([vocab * hidden]{s});\n", .{ ty, ty });
    try writer.print("var tsir_output: [num_tokens * hidden]{s} = @zeros([num_tokens * hidden]{s});\n", .{ ty, ty });
    try writer.writeAll("var tsir_indices_ptr: [*]u32 = &tsir_indices;\n");
    try writer.print("var tsir_table_ptr: [*]{s} = &tsir_table;\n", .{ty});
    try writer.print("var tsir_output_ptr: [*]{s} = &tsir_output;\n\n", .{ty});
    try writer.writeAll("fn compute() void {\n");
    try writer.writeAll("    for (@range(i16, num_tokens)) |token| {\n");
    try writer.writeAll("        const row = tsir_indices[@as(u32, token)];\n");
    try writer.writeAll("        for (@range(i16, hidden)) |h| {\n");
    try writer.writeAll("            const dst = @as(u32, token) * @as(u32, hidden) + @as(u32, h);\n");
    try writer.writeAll("            if (row >= @as(u32, vocab)) {\n");
    try writer.writeAll("                tsir_output[dst] = 0.0;\n");
    try writer.writeAll("            } else {\n");
    try writer.writeAll("                tsir_output[dst] = tsir_table[row * @as(u32, hidden) + @as(u32, h)];\n");
    try writer.writeAll("            }\n");
    try writer.writeAll("        }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writeCslGatherExports(writer);
}

fn emitCslResidualAdd(
    writer: anytype,
    func: schema.SemanticFunction,
    config: *const Config,
) EmitError!void {
    const summand_a = try bindingForRole(func, .summand_a);
    const summand_b = try bindingForRole(func, .summand_b);
    const output = try bindingForRole(func, .output);
    const elem = output.elem;
    try requireSupportedComputeElem(elem);
    try requireElem(summand_a, elem);
    try requireElem(summand_b, elem);
    try requireElem(output, elem);

    const p = config.var_prefix;
    const ty = cslElemName(elem);
    try writer.writeAll("param memcpy_params;\n");
    try writeCslChunkSizeParam(writer, config);
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try writeCslBufferArray(writer, p, summand_a.name, "chunk_size", ty);
    try writeCslBufferArray(writer, p, summand_b.name, "chunk_size", ty);
    try writeCslBufferArray(writer, p, output.name, "chunk_size", ty);
    try writeCslBufferPointer(writer, p, summand_a.name, ty);
    try writeCslBufferPointer(writer, p, summand_b.name, ty);
    try writeCslBufferPointer(writer, p, output.name, ty);
    try writer.writeAll("\n");
    try writer.writeAll("fn compute() void {\n");
    try writer.writeAll("    for (@range(i16, chunk_size)) |i| {\n");
    try writer.writeAll("        const idx = @as(u32, i);\n");
    try writer.print(
        "        {s}{s}[idx] = {s}{s}[idx] + {s}{s}[idx];\n",
        .{ p, output.name, p, summand_a.name, p, summand_b.name },
    );
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try writeCslExportSymbol(writer, p, summand_a.name);
    try writeCslExportSymbol(writer, p, summand_b.name);
    try writeCslExportSymbol(writer, p, output.name);
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}

pub fn writeCslBufferArray(
    writer: anytype,
    prefix: []const u8,
    name: []const u8,
    extent: []const u8,
    elem_type: []const u8,
) !void {
    try writer.print(
        "var {s}{s}: [{s}]{s} = @zeros([{s}]{s});\n",
        .{ prefix, name, extent, elem_type, extent, elem_type },
    );
}

pub fn writeCslBufferPointer(
    writer: anytype,
    prefix: []const u8,
    name: []const u8,
    elem_type: []const u8,
) !void {
    try writer.print(
        "var {s}{s}_ptr: [*]{s} = &{s}{s};\n",
        .{ prefix, name, elem_type, prefix, name },
    );
}

pub fn writeCslExportSymbol(writer: anytype, prefix: []const u8, name: []const u8) !void {
    try writer.print(
        "    @export_symbol({s}{s}_ptr, \"{s}\");\n",
        .{ prefix, name, name },
    );
}

fn writeCslChunkSizeParam(writer: anytype, config: *const Config) !void {
    if (config.chunk_size_default) |value| {
        try writer.print("param chunk_size: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param chunk_size: i16;\n");
    }
}

fn emitCslKvWrite(
    writer: anytype,
    func: schema.SemanticFunction,
    config: *const Config,
) EmitError!void {
    if (config.kv_cache_pe_strategy == .slot_sharded) {
        return @import("emit_kernel_body_kv.zig").emitCslKvWriteSlotSharded(writer, func, config);
    }
    const key_proj = try bindingForRole(func, .key_projection);
    const val_proj = try bindingForRole(func, .value_projection);
    const key_cache = try bindingForRole(func, .key_cache);
    const val_cache = try bindingForRole(func, .value_cache);
    const position = try bindingForRole(func, .decode_position);
    const elem = key_cache.elem;
    try requireSupportedComputeElem(elem);
    try requireElem(key_proj, elem);
    try requireElem(val_proj, elem);
    try requireElem(key_cache, elem);
    try requireElem(val_cache, elem);
    try requireElem(position, .u32);

    const p = config.var_prefix;
    const ty = cslElemName(elem);
    try writer.writeAll("param memcpy_params;\n");
    if (config.head_dim_default) |value| {
        try writer.print("param head_dim: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param head_dim: i16;\n");
    }
    if (config.max_seq_len_default) |value| {
        try writer.print("param max_seq_len: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param max_seq_len: i16;\n");
    }
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try writer.writeAll("const kv_cache_len: u32 = @as(u32, max_seq_len) * @as(u32, head_dim);\n");
    try writeCslBufferArray(writer, p, key_proj.name, "head_dim", ty);
    try writeCslBufferArray(writer, p, val_proj.name, "head_dim", ty);
    try writeCslBufferArray(writer, p, key_cache.name, "kv_cache_len", ty);
    try writeCslBufferArray(writer, p, val_cache.name, "kv_cache_len", ty);
    try writeCslBufferArray(writer, p, position.name, "1", "u32");
    try writeCslBufferPointer(writer, p, key_proj.name, ty);
    try writeCslBufferPointer(writer, p, val_proj.name, ty);
    try writeCslBufferPointer(writer, p, key_cache.name, ty);
    try writeCslBufferPointer(writer, p, val_cache.name, ty);
    try writeCslBufferPointer(writer, p, position.name, "u32");
    try writer.writeAll("\n");
    try writer.writeAll("fn compute() void {\n");
    try writer.print(
        "    const base = {s}{s}[0] * @as(u32, head_dim);\n",
        .{ p, position.name },
    );
    try writer.writeAll("    for (@range(i16, head_dim)) |d| {\n");
    try writer.writeAll("        const idx = base + @as(u32, d);\n");
    try writer.print(
        "        {s}{s}[idx] = {s}{s}[@as(u32, d)];\n",
        .{ p, key_cache.name, p, key_proj.name },
    );
    try writer.print(
        "        {s}{s}[idx] = {s}{s}[@as(u32, d)];\n",
        .{ p, val_cache.name, p, val_proj.name },
    );
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try writeCslExportSymbol(writer, p, key_proj.name);
    try writeCslExportSymbol(writer, p, val_proj.name);
    try writeCslExportSymbol(writer, p, key_cache.name);
    try writeCslExportSymbol(writer, p, val_cache.name);
    try writeCslExportSymbol(writer, p, position.name);
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}

fn emitCslKvRead(
    writer: anytype,
    func: schema.SemanticFunction,
    config: *const Config,
) EmitError!void {
    if (config.kv_cache_pe_strategy == .slot_sharded) {
        return @import("emit_kernel_body_kv.zig").emitCslKvReadSlotSharded(writer, func, config);
    }
    const key_cache = try bindingForRole(func, .key_cache);
    const val_cache = try bindingForRole(func, .value_cache);
    const key_output = try bindingForRole(func, .key_output);
    const val_output = try bindingForRole(func, .value_output);
    const elem = key_cache.elem;
    try requireSupportedComputeElem(elem);
    try requireElem(key_cache, elem);
    try requireElem(val_cache, elem);
    try requireElem(key_output, elem);
    try requireElem(val_output, elem);

    const p = config.var_prefix;
    const ty = cslElemName(elem);
    try writer.writeAll("param memcpy_params;\n");
    if (config.head_dim_default) |value| {
        try writer.print("param head_dim: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param head_dim: i16;\n");
    }
    if (config.max_seq_len_default) |value| {
        try writer.print("param max_seq_len: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param max_seq_len: i16;\n");
    }
    try writer.writeAll("param read_start: i16 = 0;\n");
    if (config.read_len_default) |value| {
        try writer.print("param read_len: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param read_len: i16;\n");
    }
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try writer.writeAll("const kv_cache_len: u32 = @as(u32, max_seq_len) * @as(u32, head_dim);\n");
    try writeCslBufferArray(writer, p, key_cache.name, "kv_cache_len", ty);
    try writeCslBufferArray(writer, p, val_cache.name, "kv_cache_len", ty);
    try writeCslBufferArray(writer, p, key_output.name, "read_len * head_dim", ty);
    try writeCslBufferArray(writer, p, val_output.name, "read_len * head_dim", ty);
    try writeCslBufferPointer(writer, p, key_cache.name, ty);
    try writeCslBufferPointer(writer, p, val_cache.name, ty);
    try writeCslBufferPointer(writer, p, key_output.name, ty);
    try writeCslBufferPointer(writer, p, val_output.name, ty);
    try writer.writeAll("\n");
    try writer.writeAll("fn compute() void {\n");
    try writer.writeAll("    for (@range(i16, read_len)) |i| {\n");
    try writer.writeAll("        const src_base = @as(u32, read_start + i) * @as(u32, head_dim);\n");
    try writer.writeAll("        const dst_base = @as(u32, i) * @as(u32, head_dim);\n");
    try writer.writeAll("        for (@range(i16, head_dim)) |d| {\n");
    try writer.print(
        "            {s}{s}[dst_base + @as(u32, d)] = {s}{s}[src_base + @as(u32, d)];\n",
        .{ p, key_output.name, p, key_cache.name },
    );
    try writer.print(
        "            {s}{s}[dst_base + @as(u32, d)] = {s}{s}[src_base + @as(u32, d)];\n",
        .{ p, val_output.name, p, val_cache.name },
    );
    try writer.writeAll("        }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try writeCslExportSymbol(writer, p, key_cache.name);
    try writeCslExportSymbol(writer, p, val_cache.name);
    try writeCslExportSymbol(writer, p, key_output.name);
    try writeCslExportSymbol(writer, p, val_output.name);
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}

fn emitMslFusedGemv(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    try requireFusedGemvF32(func);
    try writer.writeAll("#include <metal_stdlib>\nusing namespace metal;\n");
    try writer.writeAll("constant uint tsir_M [[function_constant(0)]];\n");
    try writer.writeAll("constant uint tsir_K [[function_constant(1)]];\n");
    try writer.writeAll("kernel void main0(const device float* tsir_matrix [[buffer(0)]], const device float* tsir_vector [[buffer(1)]], device float* tsir_output [[buffer(2)]], uint row [[thread_position_in_grid]]) {\n");
    try writer.writeAll("    if (row >= tsir_M) return;\n");
    try writer.writeAll("    float acc = 0.0f;\n");
    try writer.writeAll("    for (uint k = 0; k < tsir_K; k++) acc += tsir_matrix[row * tsir_K + k] * tsir_vector[k];\n");
    try writer.writeAll("    tsir_output[row] = acc;\n");
    try writer.writeAll("}\n");
}

fn emitMslRmsNorm(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    const rms = try requireRmsNormF32(func);
    try writer.writeAll("#include <metal_stdlib>\nusing namespace metal;\n");
    try writer.writeAll("constant uint tsir_hidden_size [[function_constant(0)]];\n");
    try writer.writeAll("constant float tsir_epsilon [[function_constant(1)]];\n");
    try writer.writeAll("kernel void main0(const device float* tsir_input [[buffer(0)]], const device float* tsir_scale [[buffer(1)]], device float* tsir_output [[buffer(2)]], uint d [[thread_position_in_grid]]) {\n");
    try writer.writeAll("    if (d >= tsir_hidden_size) return;\n");
    try writer.writeAll("    float sum_sq = 0.0f;\n");
    try writer.writeAll("    for (uint i = 0; i < tsir_hidden_size; i++) { float v = tsir_input[i]; sum_sq += v * v; }\n");
    try writer.writeAll("    float inv_rms = rsqrt((sum_sq / float(tsir_hidden_size)) + ");
    try writeCFloatEpsilon(writer, rms.epsilon, "tsir_epsilon");
    try writer.writeAll(");\n");
    try writer.writeAll("    tsir_output[d] = tsir_input[d] * inv_rms * tsir_scale[d];\n");
    try writer.writeAll("}\n");
}

fn emitMslGather(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    try requireGatherF32(func);
    try writer.writeAll("#include <metal_stdlib>\nusing namespace metal;\n");
    try writer.writeAll("constant uint tsir_num_tokens [[function_constant(0)]];\n");
    try writer.writeAll("constant uint tsir_hidden [[function_constant(1)]];\n");
    try writer.writeAll("constant uint tsir_vocab [[function_constant(2)]];\n");
    try writer.writeAll("kernel void main0(const device uint* tsir_indices [[buffer(0)]], const device float* tsir_table [[buffer(1)]], device float* tsir_output [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {\n");
    try writer.writeAll("    uint h = gid.x; uint token = gid.y;\n");
    try writer.writeAll("    if (token >= tsir_num_tokens || h >= tsir_hidden) return;\n");
    try writer.writeAll("    uint row = tsir_indices[token];\n");
    try writer.writeAll("    uint dst = token * tsir_hidden + h;\n");
    try writer.writeAll("    tsir_output[dst] = (row >= tsir_vocab) ? 0.0f : tsir_table[row * tsir_hidden + h];\n");
    try writer.writeAll("}\n");
}

fn emitDxilFusedGemv(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    try requireFusedGemvF32(func);
    try writer.writeAll("StructuredBuffer<float> tsir_matrix : register(t0);\n");
    try writer.writeAll("StructuredBuffer<float> tsir_vector : register(t1);\n");
    try writer.writeAll("RWStructuredBuffer<float> tsir_output : register(u2);\n");
    try writer.writeAll("cbuffer TsirDims : register(b0) { uint tsir_M; uint tsir_K; };\n");
    try writer.writeAll("[numthreads(1, 1, 1)] void main(uint3 gid : SV_DispatchThreadID) {\n");
    try writer.writeAll("    uint row = gid.x; if (row >= tsir_M) return;\n");
    try writer.writeAll("    float acc = 0.0f;\n");
    try writer.writeAll("    for (uint k = 0; k < tsir_K; k++) acc += tsir_matrix[row * tsir_K + k] * tsir_vector[k];\n");
    try writer.writeAll("    tsir_output[row] = acc;\n");
    try writer.writeAll("}\n");
}

fn emitDxilRmsNorm(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    const rms = try requireRmsNormF32(func);
    try writer.writeAll("StructuredBuffer<float> tsir_input : register(t0);\n");
    try writer.writeAll("StructuredBuffer<float> tsir_scale : register(t1);\n");
    try writer.writeAll("RWStructuredBuffer<float> tsir_output : register(u2);\n");
    try writer.writeAll("cbuffer TsirDims : register(b0) { uint tsir_hidden_size; float tsir_epsilon; };\n");
    try writer.writeAll("[numthreads(1, 1, 1)] void main(uint3 gid : SV_DispatchThreadID) {\n");
    try writer.writeAll("    uint d = gid.x; if (d >= tsir_hidden_size) return;\n");
    try writer.writeAll("    float sum_sq = 0.0f;\n");
    try writer.writeAll("    for (uint i = 0; i < tsir_hidden_size; i++) { float v = tsir_input[i]; sum_sq += v * v; }\n");
    try writer.writeAll("    float inv_rms = rsqrt((sum_sq / float(tsir_hidden_size)) + ");
    try writeCFloatEpsilon(writer, rms.epsilon, "tsir_epsilon");
    try writer.writeAll(");\n");
    try writer.writeAll("    tsir_output[d] = tsir_input[d] * inv_rms * tsir_scale[d];\n");
    try writer.writeAll("}\n");
}

fn emitDxilGather(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    try requireGatherF32(func);
    try writer.writeAll("StructuredBuffer<uint> tsir_indices : register(t0);\n");
    try writer.writeAll("StructuredBuffer<float> tsir_table : register(t1);\n");
    try writer.writeAll("RWStructuredBuffer<float> tsir_output : register(u2);\n");
    try writer.writeAll("cbuffer TsirDims : register(b0) { uint tsir_num_tokens; uint tsir_hidden; uint tsir_vocab; };\n");
    try writer.writeAll("[numthreads(1, 1, 1)] void main(uint3 gid : SV_DispatchThreadID) {\n");
    try writer.writeAll("    uint h = gid.x; uint token = gid.y;\n");
    try writer.writeAll("    if (token >= tsir_num_tokens || h >= tsir_hidden) return;\n");
    try writer.writeAll("    uint row = tsir_indices[token]; uint dst = token * tsir_hidden + h;\n");
    try writer.writeAll("    tsir_output[dst] = (row >= tsir_vocab) ? 0.0f : tsir_table[row * tsir_hidden + h];\n");
    try writer.writeAll("}\n");
}

fn emitSpirVFusedGemv(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    try requireFusedGemvF32(func);
    try writer.writeAll("#version 450\nlayout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;\n");
    try writer.writeAll("layout(set = 0, binding = 0) readonly buffer TsirMatrix { float tsir_matrix[]; };\n");
    try writer.writeAll("layout(set = 0, binding = 1) readonly buffer TsirVector { float tsir_vector[]; };\n");
    try writer.writeAll("layout(set = 0, binding = 2) buffer TsirOutput { float tsir_output[]; };\n");
    try writer.writeAll("layout(set = 0, binding = 3) uniform TsirDims { uint tsir_M; uint tsir_K; };\n");
    try writer.writeAll("void main() { uint row = gl_GlobalInvocationID.x; if (row >= tsir_M) return; float acc = 0.0; for (uint k = 0; k < tsir_K; k++) acc += tsir_matrix[row * tsir_K + k] * tsir_vector[k]; tsir_output[row] = acc; }\n");
}

fn emitSpirVRmsNorm(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    const rms = try requireRmsNormF32(func);
    try writer.writeAll("#version 450\nlayout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;\n");
    try writer.writeAll("layout(set = 0, binding = 0) readonly buffer TsirInput { float tsir_input[]; };\n");
    try writer.writeAll("layout(set = 0, binding = 1) readonly buffer TsirScale { float tsir_scale[]; };\n");
    try writer.writeAll("layout(set = 0, binding = 2) buffer TsirOutput { float tsir_output[]; };\n");
    try writer.writeAll("layout(set = 0, binding = 3) uniform TsirDims { uint tsir_hidden_size; float tsir_epsilon; };\n");
    try writer.writeAll("void main() { uint d = gl_GlobalInvocationID.x; if (d >= tsir_hidden_size) return; float sum_sq = 0.0; for (uint i = 0; i < tsir_hidden_size; i++) { float v = tsir_input[i]; sum_sq += v * v; } float inv_rms = inversesqrt((sum_sq / float(tsir_hidden_size)) + ");
    try writeCFloatEpsilon(writer, rms.epsilon, "tsir_epsilon");
    try writer.writeAll("); tsir_output[d] = tsir_input[d] * inv_rms * tsir_scale[d]; }\n");
}

fn emitSpirVGather(writer: anytype, func: schema.SemanticFunction) EmitError!void {
    try requireGatherF32(func);
    try writer.writeAll("#version 450\nlayout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;\n");
    try writer.writeAll("layout(set = 0, binding = 0) readonly buffer TsirIndices { uint tsir_indices[]; };\n");
    try writer.writeAll("layout(set = 0, binding = 1) readonly buffer TsirTable { float tsir_table[]; };\n");
    try writer.writeAll("layout(set = 0, binding = 2) buffer TsirOutput { float tsir_output[]; };\n");
    try writer.writeAll("layout(set = 0, binding = 3) uniform TsirDims { uint tsir_num_tokens; uint tsir_hidden; uint tsir_vocab; };\n");
    try writer.writeAll("void main() { uint h = gl_GlobalInvocationID.x; uint token = gl_GlobalInvocationID.y; if (token >= tsir_num_tokens || h >= tsir_hidden) return; uint row = tsir_indices[token]; uint dst = token * tsir_hidden + h; tsir_output[dst] = (row >= tsir_vocab) ? 0.0 : tsir_table[row * tsir_hidden + h]; }\n");
}

pub fn bindingForRole(func: schema.SemanticFunction, role: schema.SemanticBindingRole) EmitError!schema.BufferBinding {
    for (func.body.binding_roles) |binding_role| {
        if (binding_role.role == role) return bindingForIndex(func, binding_role.binding_index);
    }
    return error.MissingBindingRole;
}

fn bindingForIndex(func: schema.SemanticFunction, binding_index: u32) EmitError!schema.BufferBinding {
    if (binding_index >= func.bindings.len) return error.InvalidBodyContract;
    return func.bindings[@intCast(binding_index)];
}

fn rmsNormBody(func: schema.SemanticFunction) EmitError!schema.RmsNormBody {
    const rms = func.body.rms_norm orelse return error.InvalidBodyContract;
    if (rms.formula != .sum_squares_mean_epsilon_rsqrt_scale) return error.UnsupportedKernelBody;
    if (rms.reduction_target != .intermediate_scalar) return error.UnsupportedKernelBody;
    return rms;
}

pub fn requireElem(binding: schema.BufferBinding, elem: schema.ScalarKind) EmitError!void {
    if (binding.elem != elem) return error.UnsupportedScalarKind;
}

fn requireFusedGemvF32(func: schema.SemanticFunction) EmitError!void {
    try requireElem(try bindingForRole(func, .matrix), .f32);
    try requireElem(try bindingForRole(func, .vector), .f32);
    try requireElem(try bindingForRole(func, .output), .f32);
}

fn requireRmsNormF32(func: schema.SemanticFunction) EmitError!schema.RmsNormBody {
    try requireElem(try bindingForRole(func, .input), .f32);
    try requireElem(try bindingForRole(func, .scale), .f32);
    try requireElem(try bindingForRole(func, .output), .f32);
    return rmsNormBody(func);
}

fn requireGatherF32(func: schema.SemanticFunction) EmitError!void {
    try requireElem(try bindingForRole(func, .indices), .u32);
    try requireElem(try bindingForRole(func, .table), .f32);
    try requireElem(try bindingForRole(func, .output), .f32);
}

fn writeWebGpuEpsilon(writer: anytype, epsilon: schema.RmsNormEpsilon) EmitError!void {
    switch (epsilon.source) {
        .uniform_field => try writer.writeAll("tsir_dims.epsilon"),
        .literal_f32 => {
            const value = epsilon.literal_f32 orelse return error.InvalidBodyContract;
            try writer.print("{d}", .{value});
        },
    }
}

fn writeCslEpsilon(writer: anytype, epsilon: schema.RmsNormEpsilon) EmitError!void {
    switch (epsilon.source) {
        .uniform_field => try writer.writeAll("epsilon"),
        .literal_f32 => {
            const value = epsilon.literal_f32 orelse return error.InvalidBodyContract;
            try writer.print("{d}", .{value});
        },
    }
}

fn writeCFloatEpsilon(writer: anytype, epsilon: schema.RmsNormEpsilon, uniform_name: []const u8) EmitError!void {
    switch (epsilon.source) {
        .uniform_field => try writer.writeAll(uniform_name),
        .literal_f32 => {
            const value = epsilon.literal_f32 orelse return error.InvalidBodyContract;
            try writer.print("{d}f", .{value});
        },
    }
}

fn writeCslFusedGemvExports(writer: anytype) EmitError!void {
    try writer.writeAll("comptime {\n");
    try writer.writeAll("    @export_symbol(tsir_matrix_ptr, \"tsir_matrix\");\n");
    try writer.writeAll("    @export_symbol(tsir_vector_ptr, \"tsir_vector\");\n");
    try writer.writeAll("    @export_symbol(tsir_output_ptr, \"tsir_output\");\n");
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}

fn writeCslRmsNormExports(writer: anytype) EmitError!void {
    try writer.writeAll("comptime {\n");
    try writer.writeAll("    @export_symbol(tsir_input_ptr, \"tsir_input\");\n");
    try writer.writeAll("    @export_symbol(tsir_scale_ptr, \"tsir_scale\");\n");
    try writer.writeAll("    @export_symbol(tsir_output_ptr, \"tsir_output\");\n");
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}

fn writeCslGatherExports(writer: anytype) EmitError!void {
    try writer.writeAll("comptime {\n");
    try writer.writeAll("    @export_symbol(tsir_indices_ptr, \"tsir_indices\");\n");
    try writer.writeAll("    @export_symbol(tsir_table_ptr, \"tsir_table\");\n");
    try writer.writeAll("    @export_symbol(tsir_output_ptr, \"tsir_output\");\n");
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}
