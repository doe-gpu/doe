// emit_csl_semantic_ops.zig — direct CSL for model-semantic scalar kernels.
//
// These kernels are small enough that lowering through a toy WGSL fixture
// loses the semantic contract. Emit them directly so the HostPlan source
// matches the reference interpreter formulas.

const std = @import("std");
const spec = @import("csl_spec.zig");
const tsir_kernel_body = @import("../../../tsir/emit_kernel_body.zig");
const tsir_schema = @import("../../../tsir/schema.zig");

pub const EmitError = error{
    OutputTooLarge,
    UnsupportedPattern,
};

const RMS_EPS: []const u8 = "0.000001";

pub fn isSemanticPattern(pattern: []const u8) bool {
    return std.mem.eql(u8, pattern, "rms_norm") or
        std.mem.eql(u8, pattern, "residual_add") or
        std.mem.eql(u8, pattern, "gelu_gated") or
        std.mem.eql(u8, pattern, "silu_gated") or
        std.mem.eql(u8, pattern, "sigmoid_gated") or
        std.mem.eql(u8, pattern, "conv1d_depthwise") or
        std.mem.eql(u8, pattern, "l2_normalize") or
        std.mem.eql(u8, pattern, "linear_attention") or
        std.mem.eql(u8, pattern, "attention_prefill_kv_axis_sharded");
}

pub fn emitLayout(buf: []u8, pos: *usize, pattern: []const u8) EmitError!void {
    if (std.mem.eql(u8, pattern, "rms_norm")) return emitRmsNormLayout(buf, pos);
    if (std.mem.eql(u8, pattern, "residual_add")) return emitElementwiseLayout(buf, pos, .residual);
    if (std.mem.eql(u8, pattern, "gelu_gated")) return emitElementwiseLayout(buf, pos, .gated);
    if (std.mem.eql(u8, pattern, "silu_gated")) return emitElementwiseLayout(buf, pos, .gated);
    if (std.mem.eql(u8, pattern, "sigmoid_gated")) return emitElementwiseLayout(buf, pos, .gated);
    if (std.mem.eql(u8, pattern, "conv1d_depthwise")) return emitSsmLayout(buf, pos, .conv1d_depthwise);
    if (std.mem.eql(u8, pattern, "l2_normalize")) return emitSsmLayout(buf, pos, .l2_normalize);
    if (std.mem.eql(u8, pattern, "linear_attention")) return emitSsmLayout(buf, pos, .linear_attention);
    if (std.mem.eql(u8, pattern, "attention_prefill_kv_axis_sharded"))
        return emitAttnPrefillKvAxisShardedLayout(buf, pos);
    return error.UnsupportedPattern;
}

pub fn emitPeProgram(buf: []u8, pos: *usize, pattern: []const u8) EmitError!void {
    if (std.mem.eql(u8, pattern, "rms_norm")) return emitRmsNormPe(buf, pos);
    if (std.mem.eql(u8, pattern, "residual_add")) return emitResidualPe(buf, pos);
    if (std.mem.eql(u8, pattern, "gelu_gated")) return emitGatedPe(buf, pos, .gelu_gated);
    if (std.mem.eql(u8, pattern, "silu_gated")) return emitGatedPe(buf, pos, .silu_gated);
    if (std.mem.eql(u8, pattern, "sigmoid_gated")) return emitGatedPe(buf, pos, .sigmoid_gated);
    if (std.mem.eql(u8, pattern, "conv1d_depthwise")) return emitConv1DDepthwisePe(buf, pos);
    if (std.mem.eql(u8, pattern, "l2_normalize")) return emitL2NormalizePe(buf, pos);
    if (std.mem.eql(u8, pattern, "linear_attention")) return emitLinearAttentionPe(buf, pos);
    if (std.mem.eql(u8, pattern, "attention_prefill_kv_axis_sharded"))
        return emitAttnPrefillKvAxisShardedPe(buf, pos);
    return error.UnsupportedPattern;
}

fn emitRmsNormLayout(buf: []u8, pos: *usize) EmitError!void {
    try write(buf, pos, "// Layout: RMSNorm, one token per PE.\n\n");
    try write(buf, pos, "param width: i16 = 1;\n\n");
    try write(buf, pos, "const memcpy = @import_module(\"<memcpy/get_params>\", .{\n");
    try write(buf, pos, "    .width = width,\n");
    try write(buf, pos, "    .height = 1,\n");
    try write(buf, pos, "});\n\n");
    try write(buf, pos, "layout {\n");
    try write(buf, pos, "    @set_rectangle(width, 1);\n\n");
    try write(buf, pos, "    for (@range(i16, width)) |pe_x| {\n");
    try write(buf, pos, "        @set_tile_code(pe_x, 0, \"");
    try write(buf, pos, spec.PE_PROGRAM_FILENAME);
    try write(buf, pos, "\", .{\n");
    try write(buf, pos, "            .memcpy_params = memcpy.get_params(pe_x),\n");
    try write(buf, pos, "        });\n");
    try write(buf, pos, "    }\n\n");
    try write(buf, pos, "    @export_name(\"input\", [*]f32, true);\n");
    try write(buf, pos, "    @export_name(\"weight\", [*]f32, true);\n");
    try write(buf, pos, "    @export_name(\"output\", [*]f32, true);\n");
    try write(buf, pos, "    @export_name(\"compute\", fn()void);\n");
    try write(buf, pos, "}\n");
}

const ElementwiseKind = enum { residual, gated };

fn emitElementwiseLayout(buf: []u8, pos: *usize, kind: ElementwiseKind) EmitError!void {
    const title = switch (kind) {
        .residual => "residual add",
        .gated => "gated activation (gelu/silu/sigmoid)",
    };
    try write(buf, pos, "// Layout: ");
    try write(buf, pos, title);
    try write(buf, pos, ", one activation vector per PE.\n\n");
    try write(buf, pos, "param width: u16;\n");
    try write(buf, pos, "param height: u16;\n\n");
    try write(buf, pos, "const memcpy = @import_module(\"<memcpy/get_params>\", .{\n");
    try write(buf, pos, "    .width = width,\n");
    try write(buf, pos, "    .height = height,\n");
    try write(buf, pos, "});\n\n");
    try write(buf, pos, "layout {\n");
    try write(buf, pos, "    @set_rectangle(width, height);\n\n");
    try write(buf, pos, "    for (@range(u16, height)) |pe_y| {\n");
    try write(buf, pos, "        for (@range(u16, width)) |pe_x| {\n");
    try write(buf, pos, "            @set_tile_code(pe_x, pe_y, \"");
    try write(buf, pos, spec.PE_PROGRAM_FILENAME);
    try write(buf, pos, "\", .{\n");
    try write(buf, pos, "                .memcpy_params = memcpy.get_params(pe_x),\n");
    try write(buf, pos, "            });\n");
    try write(buf, pos, "        }\n");
    try write(buf, pos, "    }\n\n");
    switch (kind) {
        .residual => {
            try write(buf, pos, "    @export_name(\"input\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"residual\", [*]f32, true);\n");
        },
        .gated => {
            try write(buf, pos, "    @export_name(\"input\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"gate\", [*]f32, true);\n");
        },
    }
    try write(buf, pos, "    @export_name(\"output\", [*]f32, true);\n");
    try write(buf, pos, "    @export_name(\"compute\", fn()void);\n");
    try write(buf, pos, "}\n");
}

fn emitRmsNormPe(buf: []u8, pos: *usize) EmitError!void {
    // Delegate to TSIR. Same wrapper recipe as residual / gelu, with
    // two extra Config knobs the rmsnorm kernel needs:
    //   - hidden_size_default: 1024 (the live elementwise layout doesn't
    //     forward hidden_size through @set_tile_code, same reason
    //     residual needs chunk_size_default).
    //   - gemma_one_plus_weight_offset: true (Doppler's reference
    //     rmsnorm emits `output[d] = input[d] * inv_rms * (1.0 + weight[d])`
    //     instead of the standard `inv_rms * scale[d]`).
    // The literal epsilon value (RMS_EPS = 0.000001) is supplied via
    // the SemanticFunction's RmsNormBody.epsilon.literal_f32 path, so
    // TSIR emits `+ 0.000001` inline rather than the live's named
    // `const rms_eps: f32 = 0.000001;` const. Both compute the same
    // value; cslc accepts both.
    const axes = [_]tsir_schema.IterationAxis{
        .{ .name = "d", .lower_bound = "0", .upper_bound = "hidden_size", .step = "1" },
        .{ .name = "i", .lower_bound = "0", .upper_bound = "hidden_size", .step = "1" },
    };
    const bindings = [_]tsir_schema.BufferBinding{
        .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "weight", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir_schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .input },
        .{ .binding_index = 1, .role = .scale },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]tsir_schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
        .{ .axis_index = 1, .role = .reduction },
    };
    const semantic = tsir_schema.SemanticFunction{
        .name = "main",
        .family_hint = .rms_norm,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .rms_norm,
            .binding_roles = &body_bindings,
            .axis_roles = &body_axes,
            .rms_norm = .{
                .formula = .sum_squares_mean_epsilon_rsqrt_scale,
                .epsilon = .{
                    .source = .literal_f32,
                    .literal_f32 = 0.000001,
                },
                .hidden_extent_axis = 0,
                .reduction_target = .intermediate_scalar,
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
    const config = tsir_kernel_body.Config{
        .var_prefix = "",
        .hidden_size_default = 1024,
        .gemma_one_plus_weight_offset = true,
    };
    var fixed: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed);
    var sink = std.ArrayList(u8){};
    defer sink.deinit(fba.allocator());
    tsir_kernel_body.emitWithConfig(sink.writer(fba.allocator()), semantic, .csl, &config) catch |err| switch (err) {
        error.OutOfMemory => return error.OutputTooLarge,
        error.InvalidBodyContract,
        error.MissingBindingRole,
        error.UnsupportedKernelBody,
        error.UnsupportedScalarKind,
        => return error.UnsupportedPattern,
    };
    try write(buf, pos, sink.items);
}

fn emitResidualPe(buf: []u8, pos: *usize) EmitError!void {
    // Delegate to TSIR. The semantic kernel truth lives in the
    // tsir/emit_kernel_body emitCslResidualAdd path; this wrapper
    // builds the SemanticFunction with bindings named to match the
    // symbols the live HostPlan binding map already expects
    // (`input`, `residual`, `output`) and asks TSIR to emit with no `tsir_`
    // var prefix so the output is byte-equivalent in the
    // load-bearing places (`output[idx] = input[idx] + residual[idx];` and
    // `@export_symbol(input_ptr, "input");` etc.).
    const axes = [_]tsir_schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "chunk_size", .step = "1" },
    };
    const bindings = [_]tsir_schema.BufferBinding{
        .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "residual", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir_schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .summand_a },
        .{ .binding_index = 1, .role = .summand_b },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]tsir_schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
    };
    const semantic = tsir_schema.SemanticFunction{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .residual_add,
            .binding_roles = &body_bindings,
            .axis_roles = &body_axes,
        },
        .source_digest = [_]u8{0} ** 32,
    };
    const config = tsir_kernel_body.Config{
        .var_prefix = "",
        // The live elementwise layout doesn't forward chunk_size through
        // `@set_tile_code`, so the pe_program needs a compile-time default
        // or cslc raises csl_compile_uninitialized_param. 1024 mirrors
        // the prior hand-written value.
        .chunk_size_default = 1024,
    };
    // The TSIR emitter's helpers (`writer.print`) return only
    // `Allocator.Error`-shaped errors; that means we need an
    // `ArrayList` writer (OutOfMemory) rather than a fixed-buffer
    // writer (NoSpaceLeft). A small stack-fallback allocator keeps
    // this off the heap for the typical kernel.
    var fixed: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed);
    var sink = std.ArrayList(u8){};
    defer sink.deinit(fba.allocator());
    tsir_kernel_body.emitWithConfig(sink.writer(fba.allocator()), semantic, .csl, &config) catch |err| switch (err) {
        // Buffer overflow surfaces the existing OutputTooLarge code so
        // the caller doesn't have to learn TSIR's allocator failures.
        error.OutOfMemory => return error.OutputTooLarge,
        // The other TSIR errors signal a malformed SemanticFunction —
        // a bug in this wrapper, not a runtime input. Map them to
        // UnsupportedPattern so the existing caller surface stays
        // unchanged; the build will catch the wrapper bug at test time.
        error.InvalidBodyContract,
        error.MissingBindingRole,
        error.UnsupportedKernelBody,
        error.UnsupportedScalarKind,
        => return error.UnsupportedPattern,
    };
    try write(buf, pos, sink.items);
}

fn emitGatedPe(buf: []u8, pos: *usize, op: tsir_schema.SemanticBodyOp) EmitError!void {
    // Delegate to TSIR. Single emit body parameterized by activation
    // kind (.gelu_gated, .silu_gated, .sigmoid_gated) — TSIR's
    // emit_kernel_body_gated.zig dispatches on the op via the shared
    // clamp form `z = clamp(-x, -15, 15)` so all three kinds share
    // the saturation behavior. Same wrapper recipe as `emitResidualPe`
    // (cycle 16): build a SemanticFunction with bindings named to
    // match the symbols the live HostPlan binding map expects.
    const axes = [_]tsir_schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "chunk_size", .step = "1" },
    };
    const bindings = [_]tsir_schema.BufferBinding{
        .{ .name = "gate", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "input", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir_schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .gate },
        .{ .binding_index = 1, .role = .input },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]tsir_schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
    };
    const semantic = tsir_schema.SemanticFunction{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = op,
            .binding_roles = &body_bindings,
            .axis_roles = &body_axes,
        },
        .source_digest = [_]u8{0} ** 32,
    };
    const config = tsir_kernel_body.Config{
        .var_prefix = "",
        .chunk_size_default = 1024,
    };
    var fixed: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed);
    var sink = std.ArrayList(u8){};
    defer sink.deinit(fba.allocator());
    tsir_kernel_body.emitWithConfig(sink.writer(fba.allocator()), semantic, .csl, &config) catch |err| switch (err) {
        error.OutOfMemory => return error.OutputTooLarge,
        error.InvalidBodyContract,
        error.MissingBindingRole,
        error.UnsupportedKernelBody,
        error.UnsupportedScalarKind,
        => return error.UnsupportedPattern,
    };
    try write(buf, pos, sink.items);
}

const SsmKind = enum {
    conv1d_depthwise,
    l2_normalize,
    linear_attention,
};

fn emitSsmLayout(buf: []u8, pos: *usize, kind: SsmKind) EmitError!void {
    try write(buf, pos, "// Layout: Qwen 3.6 gated-DeltaNet SSM body op.\n\n");
    try write(buf, pos, "param width: u16;\n");
    try write(buf, pos, "param height: u16;\n");
    switch (kind) {
        .conv1d_depthwise => {
            try write(buf, pos, "param num_tokens: i16 = 4;\n");
            try write(buf, pos, "param channels: i16 = 128;\n");
            try write(buf, pos, "param kernel_size: i16 = 4;\n");
        },
        .l2_normalize => try write(buf, pos, "param hidden_size: i16 = 128;\n"),
        .linear_attention => {
            try write(buf, pos, "param key_dim: i16 = 128;\n");
            try write(buf, pos, "param value_dim: i16 = 128;\n");
            // value_dim is sharded across pe_y; each PE owns
            // value_dim_per_pe rows of the per-head linear_state matrix.
            try write(buf, pos, "param value_dim_per_pe: i16 = 64;\n");
            try write(buf, pos, "param a_log: f32 = 0.5;\n");
        },
    }
    try write(buf, pos, "\n");
    try write(buf, pos, "const memcpy = @import_module(\"<memcpy/get_params>\", .{\n");
    try write(buf, pos, "    .width = width,\n");
    try write(buf, pos, "    .height = height,\n");
    try write(buf, pos, "});\n\n");
    try write(buf, pos, "layout {\n");
    try write(buf, pos, "    @set_rectangle(width, height);\n\n");
    try write(buf, pos, "    for (@range(u16, height)) |pe_y| {\n");
    try write(buf, pos, "        for (@range(u16, width)) |pe_x| {\n");
    try write(buf, pos, "            @set_tile_code(pe_x, pe_y, \"");
    try write(buf, pos, spec.PE_PROGRAM_FILENAME);
    try write(buf, pos, "\", .{\n");
    try write(buf, pos, "                .memcpy_params = memcpy.get_params(pe_x),\n");
    switch (kind) {
        .conv1d_depthwise => try write(buf, pos, "                .num_tokens = num_tokens,\n"),
        .linear_attention => {
            try write(buf, pos, "                .value_dim_per_pe = value_dim_per_pe,\n");
            try write(buf, pos, "                .a_log = a_log,\n");
        },
        .l2_normalize => {},
    }
    try write(buf, pos, "            });\n");
    try write(buf, pos, "        }\n");
    try write(buf, pos, "    }\n\n");
    switch (kind) {
        .conv1d_depthwise => {
            try write(buf, pos, "    @export_name(\"input\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"weight\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"bias\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"output\", [*]f32, true);\n");
        },
        .l2_normalize => {
            try write(buf, pos, "    @export_name(\"input\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"output\", [*]f32, true);\n");
        },
        .linear_attention => {
            try write(buf, pos, "    @export_name(\"query\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"key\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"value\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"gate\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"linear_state\", [*]f32, true);\n");
            try write(buf, pos, "    @export_name(\"output\", [*]f32, true);\n");
        },
    }
    try write(buf, pos, "    @export_name(\"compute\", fn()void);\n");
    try write(buf, pos, "}\n");
}

fn emitL2NormalizePe(buf: []u8, pos: *usize) EmitError!void {
    const axes = [_]tsir_schema.IterationAxis{
        .{ .name = "d", .lower_bound = "0", .upper_bound = "hidden_size", .step = "1" },
    };
    const bindings = [_]tsir_schema.BufferBinding{
        .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir_schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .input },
        .{ .binding_index = 1, .role = .output },
    };
    const semantic = tsir_schema.SemanticFunction{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .l2_normalize,
            .binding_roles = &body_bindings,
            .axis_roles = &.{},
            .l2_normalize = .{
                .hidden = 128,
                .eps = 0.000001,
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
    const config = tsir_kernel_body.Config{ .var_prefix = "" };
    var fixed: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed);
    var sink = std.ArrayList(u8){};
    defer sink.deinit(fba.allocator());
    tsir_kernel_body.emitWithConfig(sink.writer(fba.allocator()), semantic, .csl, &config) catch |err| switch (err) {
        error.OutOfMemory => return error.OutputTooLarge,
        error.InvalidBodyContract,
        error.MissingBindingRole,
        error.UnsupportedKernelBody,
        error.UnsupportedScalarKind,
        => return error.UnsupportedPattern,
    };
    try write(buf, pos, sink.items);
}

fn emitConv1DDepthwisePe(buf: []u8, pos: *usize) EmitError!void {
    const axes = [_]tsir_schema.IterationAxis{
        .{ .name = "t", .lower_bound = "0", .upper_bound = "num_tokens", .step = "1" },
        .{ .name = "c", .lower_bound = "0", .upper_bound = "channels", .step = "1" },
    };
    const bindings = [_]tsir_schema.BufferBinding{
        .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
        .{ .name = "weight", .group = 0, .binding = 1, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
        .{ .name = "bias", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 3, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir_schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .input },
        .{ .binding_index = 1, .role = .weight },
        .{ .binding_index = 2, .role = .bias },
        .{ .binding_index = 3, .role = .output },
    };
    const semantic = tsir_schema.SemanticFunction{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .conv1d_depthwise,
            .binding_roles = &body_bindings,
            .axis_roles = &.{},
            .conv1d_depthwise = .{
                .channels = 128,
                .kernel_size = 4,
                .has_bias = true,
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
    const config = tsir_kernel_body.Config{ .var_prefix = "" };
    var fixed: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed);
    var sink = std.ArrayList(u8){};
    defer sink.deinit(fba.allocator());
    tsir_kernel_body.emitWithConfig(sink.writer(fba.allocator()), semantic, .csl, &config) catch |err| switch (err) {
        error.OutOfMemory => return error.OutputTooLarge,
        error.InvalidBodyContract,
        error.MissingBindingRole,
        error.UnsupportedKernelBody,
        error.UnsupportedScalarKind,
        => return error.UnsupportedPattern,
    };
    try write(buf, pos, sink.items);
}

fn emitLinearAttentionPe(buf: []u8, pos: *usize) EmitError!void {
    const axes = [_]tsir_schema.IterationAxis{
        .{ .name = "d", .lower_bound = "0", .upper_bound = "value_dim", .step = "1" },
        .{ .name = "k", .lower_bound = "0", .upper_bound = "key_dim", .step = "1" },
    };
    const bindings = [_]tsir_schema.BufferBinding{
        .{ .name = "query", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "key", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "value", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "gate", .group = 0, .binding = 3, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "linear_state", .group = 0, .binding = 4, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
        .{ .name = "output", .group = 0, .binding = 5, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir_schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .query },
        .{ .binding_index = 1, .role = .key },
        .{ .binding_index = 2, .role = .value },
        .{ .binding_index = 3, .role = .gate },
        .{ .binding_index = 4, .role = .linear_state },
        .{ .binding_index = 5, .role = .output },
    };
    const semantic = tsir_schema.SemanticFunction{
        .name = "main",
        .family_hint = .attention_decode,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .linear_attention,
            .binding_roles = &body_bindings,
            .axis_roles = &.{},
            .linear_attention = .{
                .key_dim = 128,
                .value_dim = 128,
                .key_heads = 16,
                .value_heads = 48,
                .norm_mode = .shared,
                .has_dt_bias = false,
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
    const config = tsir_kernel_body.Config{ .var_prefix = "" };
    var fixed: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed);
    var sink = std.ArrayList(u8){};
    defer sink.deinit(fba.allocator());
    tsir_kernel_body.emitWithConfig(sink.writer(fba.allocator()), semantic, .csl, &config) catch |err| switch (err) {
        error.OutOfMemory => return error.OutputTooLarge,
        error.InvalidBodyContract,
        error.MissingBindingRole,
        error.UnsupportedKernelBody,
        error.UnsupportedScalarKind,
        => return error.UnsupportedPattern,
    };
    try write(buf, pos, sink.items);
}

// Hardcoded query stripe for the `attention_prefill_kv_axis_sharded`
// pattern. The host plan stripes Q across pe_x in chunks of this size,
// so width must equal `q_len / ATTN_PREFILL_QUERY_SEQ_LEN`. With
// head_dim=256 and slots_per_pe=8 (kv stripe), per-PE working-set is:
//   Q (8 * 256 * 4 = 8 KiB)
// + K (8 * 256 * 4 = 8 KiB)
// + V (8 * 256 * 4 = 8 KiB)
// + partials (8 * 258 * 4 ≈ 8 KiB)
// + scores (8 * 4 = 32 B)
// ≈ 32 KiB, comfortably under WSE-3's 48 KiB per-PE SRAM budget.
const ATTN_PREFILL_HEAD_DIM: u32 = 256;
const ATTN_PREFILL_QUERY_SEQ_LEN: u32 = 8;
// 1 / sqrt(256) = 0.0625; the smoke kernel emits this as a literal_f32.
const ATTN_PREFILL_SCALE: f64 = 0.0625;

fn emitAttnPrefillKvAxisShardedLayout(buf: []u8, pos: *usize) EmitError!void {
    // 2D PE grid: pe_x shards Q (each column owns a per-PE Q stripe of
    // ATTN_PREFILL_QUERY_SEQ_LEN queries), pe_y shards K/V (each row
    // owns slots_per_pe positions). The host plan log-sum-exp stitches
    // partials across pe_y after the PE program writes its
    // `[query_seq_len * (head_dim + 2)]f32` partials buffer.
    try write(buf, pos, "param width: u16;\n");
    try write(buf, pos, "param height: u16;\n");
    try write(buf, pos, "param kv_len: i16;\n");
    try write(buf, pos, "param slots_per_pe: i16;\n\n");
    try write(buf, pos, "const memcpy = @import_module(\"<memcpy/get_params>\", .{\n");
    try write(buf, pos, "    .width = width,\n");
    try write(buf, pos, "    .height = height,\n");
    try write(buf, pos, "});\n\n");
    try write(buf, pos, "layout {\n");
    try write(buf, pos, "    @set_rectangle(width, height);\n\n");
    try write(buf, pos, "    for (@range(u16, height)) |pe_y| {\n");
    try write(buf, pos, "        for (@range(u16, width)) |pe_x| {\n");
    try write(buf, pos, "            @set_tile_code(pe_x, pe_y, \"");
    try write(buf, pos, spec.PE_PROGRAM_FILENAME);
    try write(buf, pos, "\", .{\n");
    try write(buf, pos, "                .memcpy_params = memcpy.get_params(pe_x),\n");
    try write(buf, pos, "                .width = width,\n");
    try write(buf, pos, "                .kv_len = kv_len,\n");
    try write(buf, pos, "                .slots_per_pe = slots_per_pe,\n");
    try write(buf, pos, "            });\n");
    try write(buf, pos, "        }\n");
    try write(buf, pos, "    }\n\n");
    try write(buf, pos, "    @export_name(\"query\", [*]f32, true);\n");
    try write(buf, pos, "    @export_name(\"key\", [*]f32, true);\n");
    try write(buf, pos, "    @export_name(\"value\", [*]f32, true);\n");
    try write(buf, pos, "    @export_name(\"output\", [*]f32, true);\n");
    try write(buf, pos, "    @export_name(\"compute\", fn()void);\n");
    try write(buf, pos, "}\n");
}

fn emitAttnPrefillKvAxisShardedPe(buf: []u8, pos: *usize) EmitError!void {
    // Build a SemanticFunction that drives
    // emit_kernel_body_attention.zig::emitKvAxisSharded with multi-Q
    // (causal-prefill). The PE derives its tile identity from the CSL
    // layout module so the layout does not specialize a distinct
    // pe_program for each tile in the manifest-shape grid.
    const axes = [_]tsir_schema.IterationAxis{
        .{ .name = "k", .lower_bound = "0", .upper_bound = "kv_len", .step = "1" },
        .{ .name = "d", .lower_bound = "0", .upper_bound = "head_dim", .step = "1" },
    };
    const bindings = [_]tsir_schema.BufferBinding{
        .{ .name = "query", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
        .{ .name = "key", .group = 0, .binding = 1, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
        .{ .name = "value", .group = 0, .binding = 2, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 3, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir_schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .query },
        .{ .binding_index = 1, .role = .key },
        .{ .binding_index = 2, .role = .value },
        .{ .binding_index = 3, .role = .output },
    };
    const body_axes = [_]tsir_schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .token },
        .{ .axis_index = 1, .role = .hidden },
    };
    const semantic = tsir_schema.SemanticFunction{
        .name = "main",
        .family_hint = .attention_decode,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .attention_scores,
            .binding_roles = &body_bindings,
            .axis_roles = &body_axes,
            .attention_scores = .{
                .softmax_mode = .two_pass_stable,
                .head_dim = ATTN_PREFILL_HEAD_DIM,
                .key_sequence_axis = 0,
                .scale_source = .literal_f32,
                .scale_literal_f32 = ATTN_PREFILL_SCALE,
                .has_softcap = false,
                .causal_mode = .causal,
                .query_seq_len = ATTN_PREFILL_QUERY_SEQ_LEN,
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
    const config = tsir_kernel_body.Config{
        .var_prefix = "",
        .attention_pe_strategy = .kv_axis_sharded,
        .attention_pe_id_source = .layout_coordinates,
    };
    var fixed: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&fixed);
    var sink = std.ArrayList(u8){};
    defer sink.deinit(fba.allocator());
    tsir_kernel_body.emitWithConfig(sink.writer(fba.allocator()), semantic, .csl, &config) catch |err| switch (err) {
        error.OutOfMemory => return error.OutputTooLarge,
        error.InvalidBodyContract,
        error.MissingBindingRole,
        error.UnsupportedKernelBody,
        error.UnsupportedScalarKind,
        => return error.UnsupportedPattern,
    };
    try write(buf, pos, sink.items);
}

fn emitBuf(buf: []u8, pos: *usize, name: []const u8, ty: []const u8) EmitError!void {
    try write(buf, pos, "var ");
    try write(buf, pos, name);
    try write(buf, pos, ": ");
    try write(buf, pos, ty);
    try write(buf, pos, " = @zeros(");
    try write(buf, pos, ty);
    try write(buf, pos, ");\n");
}

fn emitPtr(buf: []u8, pos: *usize, name: []const u8, elem: []const u8) EmitError!void {
    try write(buf, pos, "var ");
    try write(buf, pos, name);
    try write(buf, pos, "_ptr: [*]");
    try write(buf, pos, elem);
    try write(buf, pos, " = &");
    try write(buf, pos, name);
    try write(buf, pos, ";\n");
}

fn emitComptime(buf: []u8, pos: *usize, names: []const []const u8) EmitError!void {
    try write(buf, pos, "comptime {\n");
    for (names) |name| {
        try write(buf, pos, "    @export_symbol(");
        try write(buf, pos, name);
        try write(buf, pos, "_ptr, \"");
        try write(buf, pos, name);
        try write(buf, pos, "\");\n");
    }
    try write(buf, pos, "    @export_symbol(compute);\n");
    try write(buf, pos, "}\n");
}

fn write(buf: []u8, pos: *usize, text: []const u8) EmitError!void {
    if (pos.* + text.len > buf.len) return error.OutputTooLarge;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
}
