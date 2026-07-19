// TSIR executable kernel-body emitter tests.

const std = @import("std");
const tsir = @import("../../src/compiler/tsir/mod.zig");
const targets = @import("../../src/compiler/targets/mod.zig");

test "tsir emitters produce executable fused_gemv bodies" {
    const allocator = std.testing.allocator;
    const semantic = fusedGemvSemantic();

    const webgpu = try tsir.emit_webgpu.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(webgpu);
    try expectContains(webgpu, "acc = acc + tsir_matrix[row * cols + k] * tsir_vector[k];");
    try expectContains(webgpu, "tsir_output[row] = acc;");
    try expectNotContains(webgpu, "mechanical skeleton");

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "for (@range(i16, M)) |row|");
    try expectContains(csl, "sys_mod.unblock_cmd_stream();");
    try expectNotContains(csl, "mechanical skeleton");

    const msl = try tsir.emit_msl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(msl);
    try expectContains(msl, "kernel void main0");
    try expectContains(msl, "tsir_output[row] = acc;");

    const dxil = try tsir.emit_dxil.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(dxil);
    try expectContains(dxil, "[numthreads(1, 1, 1)]");
    try expectContains(dxil, "RWStructuredBuffer<float> tsir_output");

    const spir_v = try tsir.emit_spir_v.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(spir_v);
    try expectContains(spir_v, "#version 450");
    try expectContains(spir_v, "gl_GlobalInvocationID.x");
}

test "tsir emitters produce executable rms_norm bodies" {
    const allocator = std.testing.allocator;
    const semantic = rmsNormSemantic();

    const webgpu = try tsir.emit_webgpu.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(webgpu);
    try expectContains(webgpu, "struct TsirRmsNormUniforms");
    try expectContains(webgpu, "inverseSqrt(mean_sq + tsir_dims.epsilon)");
    try expectContains(webgpu, "tsir_output[d] = tsir_input[d] * inv_rms * tsir_scale[d];");

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "fn sqrt_nr(x: f32) f32");
    try expectContains(csl, "const y0: f32 = math.sqrt(x);");
    try expectContains(csl, "const inv_rms = 1.0 / sqrt_nr(mean_sq + epsilon);");

    const msl = try tsir.emit_msl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(msl);
    try expectContains(msl, "float inv_rms = rsqrt");

    const dxil = try tsir.emit_dxil.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(dxil);
    try expectContains(dxil, "float inv_rms = rsqrt");

    const spir_v = try tsir.emit_spir_v.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(spir_v);
    try expectContains(spir_v, "inversesqrt");
}

test "tsir csl residual_add emitWithConfig var_prefix='' produces bare names" {
    // The live emit_csl_semantic_ops.emitResidualPe path expects bare
    // `a` / `b` / `output` var names (no `tsir_` prefix). The Config
    // hook lets a TSIR-driven swap of that path strip the prefix while
    // existing default-prefix callers keep their output unchanged.
    const allocator = std.testing.allocator;
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "i", .lower_bound = "0", .upper_bound = "chunk_size", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "a", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "b", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .summand_a },
            .{ .binding_index = 1, .role = .summand_b },
            .{ .binding_index = 2, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .hidden },
        };
    };
    const semantic = tsir.schema.SemanticFunction{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .residual_add,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
        },
        .source_digest = [_]u8{0} ** 32,
    };

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const config = tsir.emit_kernel_body.Config{ .var_prefix = "" };
    try tsir.emit_kernel_body.emitWithConfig(buf.writer(allocator), semantic, .csl, &config);
    const csl = buf.items;
    // Bare var names — exactly what the live emit_csl_semantic_ops path
    // emits today (`var a: ...`, `var b: ...`, `var output: ...`).
    try expectContains(csl, "var a: [chunk_size]f32 = @zeros([chunk_size]f32);");
    try expectContains(csl, "var b: [chunk_size]f32 = @zeros([chunk_size]f32);");
    try expectContains(csl, "var output: [chunk_size]f32 = @zeros([chunk_size]f32);");
    try expectContains(csl, "output[idx] = a[idx] + b[idx];");
    try expectContains(csl, "@export_symbol(a_ptr, \"a\");");
    try expectContains(csl, "@export_symbol(b_ptr, \"b\");");
    try expectContains(csl, "@export_symbol(output_ptr, \"output\");");
    // No `tsir_` leakage in the bare-prefix path.
    try expectNotContains(csl, "tsir_a");
    try expectNotContains(csl, "tsir_output");
}

test "tsir csl residual_add honors binding.name for var + export naming" {
    // The TSIR emitter parameterizes variable / export names via
    // `binding.name` rather than hardcoding the role string. This is the
    // hook the live HostPlan path needs to swap through TSIR without
    // changing downstream symbol bindings — bindings can be named to
    // match whatever the live emitter exports today (e.g. `a`, `b`,
    // `output`) and the TSIR output will use those names.
    const allocator = std.testing.allocator;
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "i", .lower_bound = "0", .upper_bound = "chunk_size", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "a", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "b", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .summand_a },
            .{ .binding_index = 1, .role = .summand_b },
            .{ .binding_index = 2, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .hidden },
        };
    };
    const semantic = tsir.schema.SemanticFunction{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .residual_add,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
        },
        .source_digest = [_]u8{0} ** 32,
    };

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    // Custom binding.name flows through to var declarations.
    try expectContains(csl, "tsir_a: [chunk_size]f32");
    try expectContains(csl, "tsir_b: [chunk_size]f32");
    try expectContains(csl, "tsir_output: [chunk_size]f32");
    // And to the loop body.
    try expectContains(csl, "tsir_output[idx] = tsir_a[idx] + tsir_b[idx];");
    // And — the load-bearing piece — to the exported symbol names.
    try expectContains(csl, "@export_symbol(tsir_a_ptr, \"a\");");
    try expectContains(csl, "@export_symbol(tsir_b_ptr, \"b\");");
    try expectContains(csl, "@export_symbol(tsir_output_ptr, \"output\");");
    // Default role-named symbols must NOT appear (proves the emitter is
    // not falling back to hardcoded role strings).
    try expectNotContains(csl, "summand_a");
    try expectNotContains(csl, "summand_b");
}

test "tsir csl emitter produces executable residual_add body" {
    const allocator = std.testing.allocator;
    const semantic = residualAddSemantic();

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "param chunk_size: i16;");
    try expectContains(csl, "tsir_summand_a: [chunk_size]f32");
    try expectContains(csl, "tsir_summand_b: [chunk_size]f32");
    try expectContains(csl, "tsir_output[idx] = tsir_summand_a[idx] + tsir_summand_b[idx];");
    try expectContains(csl, "@export_symbol(tsir_summand_a_ptr, \"summand_a\");");
    try expectContains(csl, "@export_symbol(tsir_summand_b_ptr, \"summand_b\");");
    try expectContains(csl, "@export_symbol(tsir_output_ptr, \"output\");");
    try expectContains(csl, "sys_mod.unblock_cmd_stream();");
    try expectNotContains(csl, "mechanical skeleton");

    // Other backends remain typed-rejection until residual_add lowering
    // is wired through them; mirrors the attention_scores precedent.
    try std.testing.expectError(
        error.UnsupportedKernelBody,
        tsir.emit_webgpu.emitSemanticFunction(
            allocator,
            semantic,
            fixtureFunction(targets.webgpu_generic.descriptor),
            targets.webgpu_generic.descriptor,
        ),
    );
}

test "tsir csl emitter produces executable gelu_gated body" {
    const allocator = std.testing.allocator;
    const semantic = geluGatedSemantic();

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "param chunk_size: i16;");
    try expectContains(csl, "tsir_gate: [chunk_size]f32");
    try expectContains(csl, "tsir_input: [chunk_size]f32");
    try expectContains(csl, "fn gelu(x: f32) f32");
    try expectContains(csl, "if (inner < -15.0) inner = -15.0;");
    try expectContains(csl, "if (inner > 15.0) inner = 15.0;");
    try expectContains(csl, "math.tanh(inner)");
    try expectContains(csl, "tsir_output[idx] = gelu(tsir_gate[idx]) * tsir_input[idx];");
    try expectContains(csl, "@export_symbol(tsir_gate_ptr, \"gate\");");
    try expectContains(csl, "@export_symbol(tsir_input_ptr, \"input\");");
    try expectContains(csl, "@export_symbol(tsir_output_ptr, \"output\");");
    try expectContains(csl, "sys_mod.unblock_cmd_stream();");
    try expectNotContains(csl, "mechanical skeleton");

    // Other backends: typed rejection (matches attention_scores precedent).
    try std.testing.expectError(
        error.UnsupportedKernelBody,
        tsir.emit_webgpu.emitSemanticFunction(
            allocator,
            semantic,
            fixtureFunction(targets.webgpu_generic.descriptor),
            targets.webgpu_generic.descriptor,
        ),
    );
}

test "tsir csl emitter produces executable silu_gated body" {
    const allocator = std.testing.allocator;
    const semantic = siluGatedSemantic();

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "param chunk_size: i16;");
    try expectContains(csl, "tsir_gate: [chunk_size]f32");
    try expectContains(csl, "tsir_input: [chunk_size]f32");
    try expectContains(csl, "fn silu(x: f32) f32");
    try expectContains(csl, "var z = -x;");
    try expectContains(csl, "if (z < -15.0) z = -15.0;");
    try expectContains(csl, "if (z > 15.0) z = 15.0;");
    try expectContains(csl, "return x / (1.0 + math.exp(z));");
    try expectContains(csl, "tsir_output[idx] = silu(tsir_gate[idx]) * tsir_input[idx];");
    try expectContains(csl, "@export_symbol(tsir_gate_ptr, \"gate\");");
    try expectContains(csl, "@export_symbol(tsir_input_ptr, \"input\");");
    try expectContains(csl, "@export_symbol(tsir_output_ptr, \"output\");");
    try expectContains(csl, "sys_mod.unblock_cmd_stream();");
    try expectNotContains(csl, "mechanical skeleton");
    // GELU's polynomial constants must not appear in a silu body.
    try expectNotContains(csl, "GELU_A");
    try expectNotContains(csl, "math.tanh");

    try std.testing.expectError(
        error.UnsupportedKernelBody,
        tsir.emit_webgpu.emitSemanticFunction(
            allocator,
            semantic,
            fixtureFunction(targets.webgpu_generic.descriptor),
            targets.webgpu_generic.descriptor,
        ),
    );
}

test "tsir csl emitter produces executable sigmoid_gated body" {
    const allocator = std.testing.allocator;
    const semantic = sigmoidGatedSemantic();

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "param chunk_size: i16;");
    try expectContains(csl, "tsir_gate: [chunk_size]f32");
    try expectContains(csl, "tsir_input: [chunk_size]f32");
    try expectContains(csl, "fn sigmoid(x: f32) f32");
    try expectContains(csl, "var z = -x;");
    try expectContains(csl, "if (z < -15.0) z = -15.0;");
    try expectContains(csl, "if (z > 15.0) z = 15.0;");
    try expectContains(csl, "return 1.0 / (1.0 + math.exp(z));");
    try expectContains(csl, "tsir_output[idx] = sigmoid(tsir_gate[idx]) * tsir_input[idx];");
    try expectContains(csl, "@export_symbol(tsir_gate_ptr, \"gate\");");
    try expectContains(csl, "@export_symbol(tsir_input_ptr, \"input\");");
    try expectContains(csl, "@export_symbol(tsir_output_ptr, \"output\");");
    try expectContains(csl, "sys_mod.unblock_cmd_stream();");
    try expectNotContains(csl, "mechanical skeleton");
    try expectNotContains(csl, "GELU_A");
    try expectNotContains(csl, "math.tanh");
    // sigmoid divides 1.0, not x, distinguishing it from silu.
    try expectNotContains(csl, "return x / (1.0 + math.exp(z));");

    try std.testing.expectError(
        error.UnsupportedKernelBody,
        tsir.emit_webgpu.emitSemanticFunction(
            allocator,
            semantic,
            fixtureFunction(targets.webgpu_generic.descriptor),
            targets.webgpu_generic.descriptor,
        ),
    );
}

test "tsir csl emitter produces executable kv_write body" {
    const allocator = std.testing.allocator;
    const semantic = kvWriteSemantic();

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "param head_dim: i16;");
    try expectContains(csl, "param max_seq_len: i16;");
    try expectContains(csl, "const kv_cache_len: u32 = @as(u32, max_seq_len) * @as(u32, head_dim);");
    try expectContains(csl, "tsir_key_cache: [kv_cache_len]f32");
    try expectContains(csl, "tsir_value_cache: [kv_cache_len]f32");
    try expectContains(csl, "const base = tsir_decode_position[0] * @as(u32, head_dim);");
    try expectContains(csl, "tsir_key_cache[idx] = tsir_key_projection[@as(u32, d)];");
    try expectContains(csl, "tsir_value_cache[idx] = tsir_value_projection[@as(u32, d)];");
    try expectContains(csl, "@export_symbol(tsir_decode_position_ptr, \"decode_position\");");
    try expectContains(csl, "sys_mod.unblock_cmd_stream();");
    try expectNotContains(csl, "mechanical skeleton");

    // Other backends: typed rejection.
    try std.testing.expectError(
        error.UnsupportedKernelBody,
        tsir.emit_webgpu.emitSemanticFunction(
            allocator,
            semantic,
            fixtureFunction(targets.webgpu_generic.descriptor),
            targets.webgpu_generic.descriptor,
        ),
    );
}

test "tsir csl emitter produces executable kv_read body" {
    const allocator = std.testing.allocator;
    const semantic = kvReadSemantic();

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "param read_start: i16 = 0;");
    try expectContains(csl, "param read_len: i16;");
    try expectContains(csl, "const kv_cache_len: u32 = @as(u32, max_seq_len) * @as(u32, head_dim);");
    try expectContains(csl, "tsir_key_cache: [kv_cache_len]f32");
    try expectContains(csl, "tsir_value_cache: [kv_cache_len]f32");
    try expectContains(csl, "tsir_key_output: [read_len * head_dim]f32");
    try expectContains(csl, "tsir_value_output: [read_len * head_dim]f32");
    try expectContains(csl, "const src_base = @as(u32, read_start + i) * @as(u32, head_dim);");
    try expectContains(csl, "tsir_key_output[dst_base + @as(u32, d)] = tsir_key_cache[src_base + @as(u32, d)];");
    try expectContains(csl, "@export_symbol(tsir_key_output_ptr, \"key_output\");");
    try expectContains(csl, "@export_symbol(tsir_value_output_ptr, \"value_output\");");
    try expectContains(csl, "sys_mod.unblock_cmd_stream();");
    try expectNotContains(csl, "mechanical skeleton");

    try std.testing.expectError(
        error.UnsupportedKernelBody,
        tsir.emit_webgpu.emitSemanticFunction(
            allocator,
            semantic,
            fixtureFunction(targets.webgpu_generic.descriptor),
            targets.webgpu_generic.descriptor,
        ),
    );
}

test "tsir csl emitter produces executable attention_scores body" {
    // Bootstrap-shape canary fingerprint: head_dim=256, kv_len bound by
    // param so the same compiled artifact runs across canary-shape
    // inputs, two-pass-stable softmax, no causal masking, no softcap,
    // literal scale source. Mirrors the contract enforced by
    // runtime/zig/src/compiler/tsir/emit_kernel_body_attention.zig and the
    // matching host-side oracle at
    // runtime/zig/src/compiler/tsir/reference_interpreter.zig:tryAttentionScores.
    const allocator = std.testing.allocator;
    const semantic = attentionScoresSemantic();

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "const head_dim: i16 = 256;");
    try expectContains(csl, "param kv_len: i16;");
    try expectContains(csl, "const attn_scale: f32 = 1");
    try expectContains(csl, "var attn_scores: [kv_len]f32 = @zeros([kv_len]f32);");
    try expectContains(csl, "tsir_query: [head_dim]f32");
    try expectContains(csl, "tsir_key: [kv_len * head_dim]f32");
    try expectContains(csl, "tsir_value: [kv_len * head_dim]f32");
    try expectContains(csl, "tsir_output: [head_dim]f32");
    try expectContains(csl, "var max_score: f32 = -1.0e30;");
    try expectContains(csl, "const e = math.exp(attn_scores[@as(u32, k)] - max_score);");
    try expectContains(csl, "@export_symbol(tsir_query_ptr, \"query\");");
    try expectContains(csl, "@export_symbol(tsir_key_ptr, \"key\");");
    try expectContains(csl, "@export_symbol(tsir_value_ptr, \"value\");");
    try expectContains(csl, "@export_symbol(tsir_output_ptr, \"output\");");
    try expectContains(csl, "sys_mod.unblock_cmd_stream();");
    try expectNotContains(csl, "mechanical skeleton");

    // Other backends remain typed-rejection: emit_kernel_body.zig:123
    // gates webgpu/msl/dxil/spir-v at `error.UnsupportedKernelBody`
    // for `attention_scores` until the per-backend lowering lands.
    try std.testing.expectError(
        error.UnsupportedKernelBody,
        tsir.emit_webgpu.emitSemanticFunction(
            allocator,
            semantic,
            fixtureFunction(targets.webgpu_generic.descriptor),
            targets.webgpu_generic.descriptor,
        ),
    );
    try std.testing.expectError(
        error.UnsupportedKernelBody,
        tsir.emit_msl.emitSemanticFunction(
            allocator,
            semantic,
            fixtureFunction(targets.webgpu_generic.descriptor),
            targets.webgpu_generic.descriptor,
        ),
    );
}

test "tsir csl attention_scores rejects out-of-contract bodies" {
    // The bootstrap canary contract: softmax_mode=.two_pass_stable, no
    // softcap, literal scale. Causal mask (.causal / .sliding_window)
    // is now accepted; only streaming softmax, softcap, sliding window
    // missing its size, and uniform scale are rejected.
    const allocator = std.testing.allocator;

    var streaming = attentionScoresSemantic();
    var streaming_body = streaming.body.attention_scores.?;
    streaming_body.softmax_mode = .streaming_online;
    streaming.body.attention_scores = streaming_body;
    try std.testing.expectError(
        error.InvalidBodyContract,
        tsir.emit_csl.emitSemanticFunction(
            allocator,
            streaming,
            fixtureFunction(targets.wse3.descriptor),
            targets.wse3.descriptor,
        ),
    );

    // sliding_window without an explicit window size is invalid.
    var sliding_no_size = attentionScoresSemantic();
    var sliding_no_size_body = sliding_no_size.body.attention_scores.?;
    sliding_no_size_body.causal_mode = .sliding_window;
    sliding_no_size_body.sliding_window_size = null;
    sliding_no_size.body.attention_scores = sliding_no_size_body;
    try std.testing.expectError(
        error.InvalidBodyContract,
        tsir.emit_csl.emitSemanticFunction(
            allocator,
            sliding_no_size,
            fixtureFunction(targets.wse3.descriptor),
            targets.wse3.descriptor,
        ),
    );

    var softcap = attentionScoresSemantic();
    var softcap_body = softcap.body.attention_scores.?;
    softcap_body.has_softcap = true;
    softcap.body.attention_scores = softcap_body;
    try std.testing.expectError(
        error.InvalidBodyContract,
        tsir.emit_csl.emitSemanticFunction(
            allocator,
            softcap,
            fixtureFunction(targets.wse3.descriptor),
            targets.wse3.descriptor,
        ),
    );

    var uniform = attentionScoresSemantic();
    var uniform_body = uniform.body.attention_scores.?;
    uniform_body.scale_source = .uniform_field;
    uniform_body.scale_literal_f32 = null;
    uniform.body.attention_scores = uniform_body;
    try std.testing.expectError(
        error.InvalidBodyContract,
        tsir.emit_csl.emitSemanticFunction(
            allocator,
            uniform,
            fixtureFunction(targets.wse3.descriptor),
            targets.wse3.descriptor,
        ),
    );
}

test "tsir csl attention_scores kv_axis_sharded emits per-PE partials shape" {
    // Multi-PE kv-axis-sharded body: K/V are sliced along the position
    // axis and each PE writes a `[head_dim + 2]f32` partials buffer
    // (`local_O[d]` un-normalized + `local_max` + `local_sum_exp`).
    // Asserts the shape signals the host plan needs to stitch:
    //   - param pe_id / num_pes / slots_per_pe
    //   - local_kv_len + partials_len declarations
    //   - tail-mask guard (gk >= kv_len)
    //   - partials writes at indices head_dim and head_dim+1
    // Bypass the public `emit_csl.emitSemanticFunction` entry (which
    // pins the default Config) and route through `emit_kernel_body
    // .emitWithConfig` so the strategy can be flipped to
    // `.kv_axis_sharded`. This mirrors the slot_sharded KV unit test
    // pattern in `emit_kernel_body_kv.zig`.
    const allocator = std.testing.allocator;
    const semantic = attentionScoresSemantic();
    const config = tsir.emit_kernel_body.Config{
        .var_prefix = "tsir_",
        .attention_pe_strategy = .kv_axis_sharded,
        .attention_slots_per_pe_default = 8,
    };
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try tsir.emit_kernel_body.emitWithConfig(
        buf.writer(allocator),
        semantic,
        .csl,
        &config,
    );
    const csl = buf.items;
    // pe_id / num_pes are declared by emit_csl's per-PE skeleton (as
    // u32); the body must not redeclare them, otherwise the bundled
    // CSL would have a duplicate `param` and cslc would reject it.
    // The full-bundle regression test below pins this end-to-end.
    try expectNotContains(csl, "param pe_id:");
    try expectNotContains(csl, "param num_pes:");
    try expectContains(csl, "param slots_per_pe: i16 = 8;");
    try expectContains(csl, "const head_dim: i16 = 256;");
    try expectContains(csl, "const local_kv_len: u32 = @as(u32, slots_per_pe) * @as(u32, head_dim);");
    try expectContains(csl, "const partials_len: u32 = @as(u32, head_dim) + 2;");
    try expectContains(csl, "tsir_key: [local_kv_len]f32");
    try expectContains(csl, "tsir_value: [local_kv_len]f32");
    try expectContains(csl, "tsir_output: [partials_len]f32");
    try expectContains(csl, "var attn_scores: [slots_per_pe]f32");
    try expectContains(csl, "const slot_base: u32 = @as(u32, pe_id) * @as(u32, slots_per_pe);");
    try expectContains(csl, "if (gk >= @as(u32, kv_len))");
    try expectContains(csl, "tsir_output[@as(u32, head_dim)] = local_max;");
    try expectContains(csl, "tsir_output[@as(u32, head_dim) + 1] = local_sum_exp;");
    // Sharded path must NOT divide by sum_exp inside the kernel — the
    // host stitch does the global normalization. Catch a regression
    // where someone copies the single-PE final pass.
    try expectNotContains(csl, "/ sum_exp");
    // Default `.full_per_pe` strategy must not bleed into the sharded
    // path: no full-cache `[kv_len * head_dim]f32` allocations.
    try expectNotContains(csl, "[kv_len * head_dim]f32");
}

test "tsir csl attention_scores kv_axis_sharded full-bundle has no duplicate pe_id" {
    // Regression for the redeclaration bug: emit_csl's per-PE skeleton
    // already declares `param pe_id: u32; param num_pes: u32;`. If the
    // sharded body redeclares them as `i16`, the bundled CSL has two
    // `param pe_id` lines and cslc rejects it. This test routes through
    // `emitSemanticFunctionWithConfig` (the full skeleton + body bundle)
    // so the assertion catches anything the body-only test misses.
    const allocator = std.testing.allocator;
    const semantic = attentionScoresSemantic();
    const config = tsir.emit_kernel_body.Config{
        .var_prefix = "tsir_",
        .attention_pe_strategy = .kv_axis_sharded,
        .attention_slots_per_pe_default = 8,
    };
    const csl = try tsir.emit_csl.emitSemanticFunctionWithConfig(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
        &config,
    );
    defer allocator.free(csl);
    // Skeleton declares pe_id once as u32; body must not redeclare it.
    var pe_id_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, csl, search_from, "param pe_id")) |idx| {
        pe_id_count += 1;
        search_from = idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), pe_id_count);
    var num_pes_count: usize = 0;
    search_from = 0;
    while (std.mem.indexOfPos(u8, csl, search_from, "param num_pes")) |idx| {
        num_pes_count += 1;
        search_from = idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), num_pes_count);
    // Body must still declare slots_per_pe and the partials shape so
    // the host stitch contract is intact.
    try expectContains(csl, "param slots_per_pe: i16 = 8;");
    try expectContains(csl, "tsir_output: [partials_len]f32");
}

test "tsir csl attention_scores emits causal mask conditional" {
    // `.causal` is a structural no-op for the single-Q canary surface
    // (query_pos = kv_len - 1 means no K position is ever after Q), but
    // the conditional is emitted so the lane is exercised end-to-end.
    // Manifest-shape promotion to multi-Q reuses the same emit point.
    const allocator = std.testing.allocator;
    var semantic = attentionScoresSemantic();
    var body = semantic.body.attention_scores.?;
    body.causal_mode = .causal;
    semantic.body.attention_scores = body;

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "if (@as(u32, k) > @as(u32, kv_len) - 1)");
    try expectContains(csl, "sc = -1.0e30;");
}

test "tsir csl attention_scores emits sliding-window mask with declared size" {
    // sliding_window_size=4: any K position before
    // `kv_len - 4` must be masked to -1e30. Both the kernel and the
    // reference interpreter at runtime/zig/src/compiler/tsir/reference_interpreter.zig
    // use the same threshold so canary parity holds.
    const allocator = std.testing.allocator;
    var semantic = attentionScoresSemantic();
    var body = semantic.body.attention_scores.?;
    body.causal_mode = .sliding_window;
    body.sliding_window_size = 4;
    semantic.body.attention_scores = body;

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "const window_size: u32 = 4;");
    try expectContains(csl, "if (@as(u32, kv_len) > window_size and @as(u32, k) < @as(u32, kv_len) - window_size)");
    try expectContains(csl, "sc = -1.0e30;");
}

test "tsir csl attention_scores kv_axis_sharded multi-Q widens Q and output buffers" {
    // Causal-prefill body: query_seq_len > 1 emits the kv-axis-sharded
    // body wrapped in a per-query loop. Q widens to
    // [query_seq_len * head_dim]; output widens to
    // [query_seq_len * (head_dim + 2)] so each query position carries
    // its own (local_O, local_max, local_sum_exp) triple. The host
    // plan stitches each query's partials independently. This is the
    // path that unblocks `attn_prefill` per-PE memory at the 27B
    // manifest shape (Doe-gated north-star item; see
    // docs/cerebras-model-ledgers.md).
    const allocator = std.testing.allocator;
    var semantic = attentionScoresSemantic();
    var body = semantic.body.attention_scores.?;
    body.query_seq_len = 4;
    body.causal_mode = .causal;
    semantic.body.attention_scores = body;

    const config = tsir.emit_kernel_body.Config{
        .var_prefix = "tsir_",
        .attention_pe_strategy = .kv_axis_sharded,
        .attention_slots_per_pe_default = 8,
    };
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try tsir.emit_kernel_body.emitWithConfig(
        buf.writer(allocator),
        semantic,
        .csl,
        &config,
    );
    const csl = buf.items;
    try expectContains(csl, "const query_seq_len: u32 = 4;");
    try expectContains(csl, "tsir_query: [query_seq_len * @as(u32, head_dim)]f32");
    try expectContains(csl, "tsir_output: [query_seq_len * partials_len]f32");
    try expectContains(csl, "for (@range(u32, query_seq_len)) |q|");
    try expectContains(csl, "const q_row_offset: u32 = q * @as(u32, head_dim);");
    try expectContains(csl, "const out_row_offset: u32 = q * partials_len;");
    // Per-row causal mask: query q sits at kv_len - query_seq_len + q.
    try expectContains(csl, "const q_pos: u32 = @as(u32, kv_len) - query_seq_len + q;");
    try expectContains(csl, "if (gk > q_pos)");
    // Output writes hit the per-row offsets, not the single-Q form.
    try expectContains(csl, "tsir_output[out_row_offset + @as(u32, d)] = acc;");
    try expectContains(csl, "tsir_output[out_row_offset + @as(u32, head_dim)] = local_max;");
    try expectContains(csl, "tsir_output[out_row_offset + @as(u32, head_dim) + 1] = local_sum_exp;");
}

test "tsir csl emitter produces executable l2_normalize body" {
    // DeltaNet Q/K pre-attention L2 normalize. Two-pass body: compute
    // squared sum, then divide each element by sqrt(sum + eps). Same
    // var-prefix / export-symbol contract as rms_norm.
    const allocator = std.testing.allocator;
    const semantic = l2NormalizeSemantic();

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "const hidden_size: i16 = 8;");
    try expectContains(csl, "const l2_eps: f32 = 1");
    try expectContains(csl, "tsir_input: [hidden_size]f32");
    try expectContains(csl, "tsir_output: [hidden_size]f32");
    try expectContains(csl, "var sq: f32 = 0.0;");
    try expectContains(csl, "fn sqrt_nr(x: f32) f32");
    try expectContains(csl, "const inv_norm = 1.0 / sqrt_nr(sq + l2_eps);");
    try expectContains(csl, "@export_symbol(tsir_input_ptr");
    try expectContains(csl, "@export_symbol(tsir_output_ptr");
    try expectContains(csl, "sys_mod.unblock_cmd_stream();");
}

test "tsir csl emitter produces executable conv1d_depthwise body" {
    // DeltaNet conv1d kernel_size=4 depthwise with bias. Causal pad
    // (left-only) so the kernel cannot see future tokens. Per-channel
    // bias is added before the conv accumulator.
    const allocator = std.testing.allocator;
    const semantic = conv1dDepthwiseSemantic();

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "const channels: i16 = 16;");
    try expectContains(csl, "const kernel_size: i16 = 4;");
    try expectContains(csl, "param num_tokens: i16;");
    try expectContains(csl, "tsir_input: [num_tokens * channels]f32");
    try expectContains(csl, "tsir_weight: [channels * kernel_size]f32");
    try expectContains(csl, "tsir_bias: [channels]f32");
    try expectContains(csl, "var acc: f32 = tsir_bias[@as(u32, c)];");
    try expectContains(csl, "const t_in: i16 = t - (kernel_size - 1 - k);");
    try expectContains(csl, "if (t_in >= 0)");
}

test "tsir csl emitter produces executable linear_attention body" {
    // Gated DeltaNet single-token update + readout. Shared-norm form
    // (one A_log scalar per head pair, no dt_bias). Sigmoid-gated
    // residual carries the query stream through to the output.
    const allocator = std.testing.allocator;
    const semantic = linearAttentionSemantic();

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "const key_dim: i16 = 8;");
    try expectContains(csl, "const value_dim: i16 = 8;");
    // value_dim is sharded across pe_y; layout passes value_dim_per_pe
    // through @set_tile_code so per-PE state fits the per-PE SRAM budget.
    try expectContains(csl, "param value_dim_per_pe: i16;");
    try expectContains(csl, "param a_log: f32;");
    try expectContains(csl, "tsir_linear_state: [value_dim_per_pe * key_dim]f32");
    try expectContains(csl, "for (@range(i16, value_dim_per_pe))");
    try expectContains(csl, "const alpha: f32 = 1.0 - math.exp(-a_log);");
    try expectContains(csl, "const decay: f32 = 1.0 - alpha;");
    try expectContains(csl, "const sigmoid_g: f32 = 1.0 / (1.0 + math.exp(-g));");
    try expectContains(csl, "@export_symbol(tsir_linear_state_ptr");
}

test "tsir csl attention_scores defaults to full_per_pe single-PE shape" {
    // Regression guard: with the default Config, the emit must still
    // produce the single-PE body. Mirrors the existing canary contract
    // (no pe_id / num_pes / slots_per_pe params, full kv_len * head_dim
    // K/V buffers, normalized output).
    const allocator = std.testing.allocator;
    const semantic = attentionScoresSemantic();
    const config = tsir.emit_kernel_body.Config{ .var_prefix = "tsir_" };
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try tsir.emit_kernel_body.emitWithConfig(
        buf.writer(allocator),
        semantic,
        .csl,
        &config,
    );
    const csl = buf.items;
    try expectContains(csl, "tsir_key: [kv_len * head_dim]f32");
    try expectContains(csl, "tsir_value: [kv_len * head_dim]f32");
    try expectContains(csl, "tsir_output: [head_dim]f32");
    try expectContains(csl, "/ sum_exp");
    try expectNotContains(csl, "param pe_id: i16;");
    try expectNotContains(csl, "param slots_per_pe");
    try expectNotContains(csl, "local_kv_len");
    try expectNotContains(csl, "partials_len");
}

test "tsir emitters produce executable gather bodies" {
    const allocator = std.testing.allocator;
    const semantic = gatherSemantic();

    const webgpu = try tsir.emit_webgpu.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(webgpu);
    try expectContains(webgpu, "let row = tsir_indices[token];");
    try expectContains(webgpu, "tsir_output[token * hidden + h] = tsir_table[row * hidden + h];");

    const csl = try tsir.emit_csl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.wse3.descriptor),
        targets.wse3.descriptor,
    );
    defer allocator.free(csl);
    try expectContains(csl, "param num_tokens: i16;");
    try expectContains(csl, "tsir_output[dst] = tsir_table[row * @as(u32, hidden) + @as(u32, h)];");

    const msl = try tsir.emit_msl.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(msl);
    try expectContains(msl, "uint2 gid [[thread_position_in_grid]]");

    const dxil = try tsir.emit_dxil.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(dxil);
    try expectContains(dxil, "StructuredBuffer<uint> tsir_indices");

    const spir_v = try tsir.emit_spir_v.emitSemanticFunction(
        allocator,
        semantic,
        fixtureFunction(targets.webgpu_generic.descriptor),
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(spir_v);
    try expectContains(spir_v, "uint token = gl_GlobalInvocationID.y");
}

fn fusedGemvSemantic() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "i", .lower_bound = "0", .upper_bound = "M", .step = "1" },
            .{ .name = "k", .lower_bound = "0", .upper_bound = "K", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "W", .group = 0, .binding = 0, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
            .{ .name = "x", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "y", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .matrix },
            .{ .binding_index = 1, .role = .vector },
            .{ .binding_index = 2, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .output },
            .{ .axis_index = 1, .role = .reduction },
        };
    };
    return .{
        .name = "main",
        .family_hint = .fused_gemv,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{ .op = .fused_gemv, .binding_roles = &data.body_bindings, .axis_roles = &data.body_axes },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn rmsNormSemantic() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "d", .lower_bound = "0", .upper_bound = "hidden_size", .step = "1" },
            .{ .name = "i", .lower_bound = "0", .upper_bound = "hidden_size", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "weight", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
            .{ .name = "u", .group = 0, .binding = 3, .logical_shape = &.{2}, .elem = .u32, .read_write = false },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .input },
            .{ .binding_index = 1, .role = .scale },
            .{ .binding_index = 2, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .hidden },
            .{ .axis_index = 1, .role = .reduction },
        };
    };
    return .{
        .name = "main",
        .family_hint = .rms_norm,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .rms_norm,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
            .rms_norm = .{
                .formula = .sum_squares_mean_epsilon_rsqrt_scale,
                .epsilon = .{
                    .source = .uniform_field,
                    .path = "uniform:u.eps",
                    .binding_index = 3,
                    .byte_offset = 4,
                },
                .hidden_extent_axis = 0,
                .reduction_target = .intermediate_scalar,
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn residualAddSemantic() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "i", .lower_bound = "0", .upper_bound = "chunk_size", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "summand_a", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "summand_b", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .summand_a },
            .{ .binding_index = 1, .role = .summand_b },
            .{ .binding_index = 2, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .hidden },
        };
    };
    return .{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .residual_add,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn geluGatedSemantic() tsir.schema.SemanticFunction {
    return gatedSemantic(.gelu_gated);
}

fn siluGatedSemantic() tsir.schema.SemanticFunction {
    return gatedSemantic(.silu_gated);
}

fn sigmoidGatedSemantic() tsir.schema.SemanticFunction {
    return gatedSemantic(.sigmoid_gated);
}

fn gatedSemantic(op: tsir.schema.SemanticBodyOp) tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "i", .lower_bound = "0", .upper_bound = "chunk_size", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "gate", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "input", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .gate },
            .{ .binding_index = 1, .role = .input },
            .{ .binding_index = 2, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .hidden },
        };
    };
    return .{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = op,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn l2NormalizeSemantic() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "d", .lower_bound = "0", .upper_bound = "hidden_size", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "output", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .input },
            .{ .binding_index = 1, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .hidden },
        };
    };
    return .{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .l2_normalize,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
            .l2_normalize = .{ .hidden = 8, .eps = 1.0e-6 },
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn conv1dDepthwiseSemantic() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "t", .lower_bound = "0", .upper_bound = "num_tokens", .step = "1" },
            .{ .name = "c", .lower_bound = "0", .upper_bound = "channels", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
            .{ .name = "weight", .group = 0, .binding = 1, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
            .{ .name = "bias", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "output", .group = 0, .binding = 3, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .input },
            .{ .binding_index = 1, .role = .weight },
            .{ .binding_index = 2, .role = .bias },
            .{ .binding_index = 3, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .token },
            .{ .axis_index = 1, .role = .hidden },
        };
    };
    return .{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .conv1d_depthwise,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
            .conv1d_depthwise = .{
                .channels = 16,
                .kernel_size = 4,
                .has_bias = true,
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn linearAttentionSemantic() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "d", .lower_bound = "0", .upper_bound = "value_dim", .step = "1" },
            .{ .name = "k", .lower_bound = "0", .upper_bound = "key_dim", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "query", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "key", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "value", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "gate", .group = 0, .binding = 3, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "linear_state", .group = 0, .binding = 4, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
            .{ .name = "output", .group = 0, .binding = 5, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .query },
            .{ .binding_index = 1, .role = .key },
            .{ .binding_index = 2, .role = .value },
            .{ .binding_index = 3, .role = .gate },
            .{ .binding_index = 4, .role = .linear_state },
            .{ .binding_index = 5, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .hidden },
            .{ .axis_index = 1, .role = .reduction },
        };
    };
    return .{
        .name = "main",
        .family_hint = .attention_decode,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .linear_attention,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
            .linear_attention = .{
                .key_dim = 8,
                .value_dim = 8,
                .key_heads = 1,
                .value_heads = 1,
                .norm_mode = .shared,
                .has_dt_bias = false,
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn kvWriteSemantic() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "d", .lower_bound = "0", .upper_bound = "head_dim", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "key_projection", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "value_projection", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "key_cache", .group = 0, .binding = 2, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
            .{ .name = "value_cache", .group = 0, .binding = 3, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
            .{ .name = "decode_position", .group = 0, .binding = 4, .logical_shape = &.{1}, .elem = .u32, .read_write = false },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .key_projection },
            .{ .binding_index = 1, .role = .value_projection },
            .{ .binding_index = 2, .role = .key_cache },
            .{ .binding_index = 3, .role = .value_cache },
            .{ .binding_index = 4, .role = .decode_position },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .hidden },
        };
    };
    return .{
        .name = "main",
        .family_hint = .elementwise,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .kv_write,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn kvReadSemantic() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "i", .lower_bound = "0", .upper_bound = "read_len", .step = "1" },
            .{ .name = "d", .lower_bound = "0", .upper_bound = "head_dim", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "key_cache", .group = 0, .binding = 0, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
            .{ .name = "value_cache", .group = 0, .binding = 1, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
            .{ .name = "key_output", .group = 0, .binding = 2, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
            .{ .name = "value_output", .group = 0, .binding = 3, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .key_cache },
            .{ .binding_index = 1, .role = .value_cache },
            .{ .binding_index = 2, .role = .key_output },
            .{ .binding_index = 3, .role = .value_output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .token },
            .{ .axis_index = 1, .role = .hidden },
        };
    };
    return .{
        .name = "main",
        .family_hint = .gather,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .kv_read,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn attentionScoresSemantic() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "k", .lower_bound = "0", .upper_bound = "kv_len", .step = "1" },
            .{ .name = "d", .lower_bound = "0", .upper_bound = "head_dim", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "query", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f32, .read_write = false },
            .{ .name = "key", .group = 0, .binding = 1, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
            .{ .name = "value", .group = 0, .binding = 2, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
            .{ .name = "output", .group = 0, .binding = 3, .logical_shape = &.{0}, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .query },
            .{ .binding_index = 1, .role = .key },
            .{ .binding_index = 2, .role = .value },
            .{ .binding_index = 3, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .token },
            .{ .axis_index = 1, .role = .hidden },
        };
    };
    return .{
        .name = "main",
        .family_hint = .attention_decode,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .attention_scores,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
            .attention_scores = .{
                .softmax_mode = .two_pass_stable,
                .head_dim = 256,
                .key_sequence_axis = 0,
                .scale_source = .literal_f32,
                .scale_literal_f32 = 1.0,
                .has_softcap = false,
                .causal_mode = .none,
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn gatherSemantic() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "t", .lower_bound = "0", .upper_bound = "num_tokens", .step = "1" },
            .{ .name = "h", .lower_bound = "0", .upper_bound = "hidden", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "indices", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .u32, .read_write = false },
            .{ .name = "table", .group = 0, .binding = 1, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = false },
            .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{ 0, 0 }, .elem = .f32, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .indices },
            .{ .binding_index = 1, .role = .table },
            .{ .binding_index = 2, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .token },
            .{ .axis_index = 1, .role = .hidden },
        };
    };
    return .{
        .name = "main",
        .family_hint = .gather,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{ .op = .gather, .binding_roles = &data.body_bindings, .axis_roles = &data.body_axes },
        .source_digest = [_]u8{0} ** 32,
    };
}

fn fixtureFunction(descriptor: targets.TargetDescriptor) tsir.schema.RealizationFunction {
    return .{
        .semantic_index = 0,
        .tiles = .{ .per_axis = &.{ 1, 1 } },
        .pe_grid = .{ .width = 1, .height = 1 },
        .residency = &.{},
        .collectives = &.{},
        .reductions = &.{},
        .emitter_params_json = "{}",
        .target_descriptor_hash = targets.descriptorHash(descriptor),
    };
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing expected fragment:\n{s}\nfull output:\n{s}\n", .{ needle, haystack });
        return error.ExpectedFragmentMissing;
    }
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("unexpected fragment:\n{s}\nfull output:\n{s}\n", .{ needle, haystack });
        return error.UnexpectedFragmentPresent;
    }
}

// ====================================================================
// Track 2 — f16 lane emit coverage
//
// These tests pin the dtype-routing widening of the CSL emit modules
// added 2026-04-29. Each test uses an f16-typed binding set and asserts
// that the emitted CSL declares its buffers/pointers/accumulators as
// `f16`, and that no stray `f32` typed declarations leak into the
// output. f32 lane regression coverage is preserved by the existing
// tests above; this block only proves the f16 lane works.
// ====================================================================

fn fusedGemvSemanticF16() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "i", .lower_bound = "0", .upper_bound = "M", .step = "1" },
            .{ .name = "k", .lower_bound = "0", .upper_bound = "K", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "W", .group = 0, .binding = 0, .logical_shape = &.{ 0, 0 }, .elem = .f16, .read_write = false },
            .{ .name = "x", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f16, .read_write = false },
            .{ .name = "y", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f16, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .matrix },
            .{ .binding_index = 1, .role = .vector },
            .{ .binding_index = 2, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .output },
            .{ .axis_index = 1, .role = .reduction },
        };
    };
    return .{
        .name = "main",
        .family_hint = .fused_gemv,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{ .op = .fused_gemv, .binding_roles = &data.body_bindings, .axis_roles = &data.body_axes },
        .source_digest = [_]u8{0} ** 32,
    };
}

test "tsir csl fused_gemv emits f16 buffers/accum when bindings are f16" {
    const allocator = std.testing.allocator;
    const semantic = fusedGemvSemanticF16();
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const config = tsir.emit_kernel_body.Config{ .var_prefix = "tsir_" };
    try tsir.emit_kernel_body.emitWithConfig(buf.writer(allocator), semantic, .csl, &config);
    const csl = buf.items;
    try expectContains(csl, "var tsir_matrix: [M * K]f16 = @zeros([M * K]f16);");
    try expectContains(csl, "var tsir_vector: [K]f16 = @zeros([K]f16);");
    try expectContains(csl, "var tsir_output: [M]f16 = @zeros([M]f16);");
    try expectContains(csl, "var tsir_matrix_ptr: [*]f16 = &tsir_matrix;");
    try expectContains(csl, "var acc: f16 = 0.0;");
    // No f32 declarations in the f16 lane output for this op.
    try expectNotContains(csl, "[M * K]f32");
    try expectNotContains(csl, "[K]f32");
    try expectNotContains(csl, "[M]f32");
    try expectNotContains(csl, "var acc: f32");
}

fn rmsNormSemanticF16() tsir.schema.SemanticFunction {
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "d", .lower_bound = "0", .upper_bound = "hidden_size", .step = "1" },
            .{ .name = "i", .lower_bound = "0", .upper_bound = "hidden_size", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &.{0}, .elem = .f16, .read_write = false },
            .{ .name = "weight", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .f16, .read_write = false },
            .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .f16, .read_write = true },
            .{ .name = "u", .group = 0, .binding = 3, .logical_shape = &.{2}, .elem = .u32, .read_write = false },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .input },
            .{ .binding_index = 1, .role = .scale },
            .{ .binding_index = 2, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .output },
            .{ .axis_index = 1, .role = .reduction },
        };
    };
    return .{
        .name = "main",
        .family_hint = .rms_norm,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{
            .op = .rms_norm,
            .binding_roles = &data.body_bindings,
            .axis_roles = &data.body_axes,
            .rms_norm = .{
                .formula = .sum_squares_mean_epsilon_rsqrt_scale,
                .reduction_target = .intermediate_scalar,
                .hidden_extent_axis = 0,
                .epsilon = .{ .source = .uniform_field, .binding_index = 3, .byte_offset = 4, .literal_f32 = null },
            },
        },
        .source_digest = [_]u8{0} ** 32,
    };
}

test "tsir csl rms_norm emits f16 sum_sq + sqrt_nr up-cast for f16 lane" {
    const allocator = std.testing.allocator;
    const semantic = rmsNormSemanticF16();
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const config = tsir.emit_kernel_body.Config{ .var_prefix = "tsir_" };
    try tsir.emit_kernel_body.emitWithConfig(buf.writer(allocator), semantic, .csl, &config);
    const csl = buf.items;
    try expectContains(csl, "var tsir_input: [hidden_size]f16");
    try expectContains(csl, "var tsir_output: [hidden_size]f16");
    try expectContains(csl, "var sum_sq: f16 = 0.0;");
    // sqrt_nr generated for the f16 lane: signature f16, internal f32
    // libm call, narrow back to f16 — the only carve-out in the f16
    // design (libm coverage detail).
    try expectContains(csl, "fn sqrt_nr(x: f16) f16");
    try expectContains(csl, "const x32: f32 = @as(f32, x);");
    try expectContains(csl, "const y0: f32 = math.sqrt(x32);");
    try expectContains(csl, "return @as(f16, refined);");
    // mean_sq cast is f16
    try expectContains(csl, "@as(f16, hidden_size)");
    try expectNotContains(csl, "var sum_sq: f32");
}

test "tsir csl unsupported activation dtype rejected at compute-elem gate" {
    // bf16 / int8 / etc. are not admitted today. Door admission in
    // csl_host_plan_tool.zig only accepts f32 + f16; the emit-side
    // gate is requireSupportedComputeElem, exercised here via a
    // bf16 binding (intentionally invalid for current Track 2 scope).
    const allocator = std.testing.allocator;
    const data = struct {
        const axes = [_]tsir.schema.IterationAxis{
            .{ .name = "i", .lower_bound = "0", .upper_bound = "M", .step = "1" },
            .{ .name = "k", .lower_bound = "0", .upper_bound = "K", .step = "1" },
        };
        const bindings = [_]tsir.schema.BufferBinding{
            .{ .name = "W", .group = 0, .binding = 0, .logical_shape = &.{ 0, 0 }, .elem = .bf16, .read_write = false },
            .{ .name = "x", .group = 0, .binding = 1, .logical_shape = &.{0}, .elem = .bf16, .read_write = false },
            .{ .name = "y", .group = 0, .binding = 2, .logical_shape = &.{0}, .elem = .bf16, .read_write = true },
        };
        const body_bindings = [_]tsir.schema.SemanticBodyBinding{
            .{ .binding_index = 0, .role = .matrix },
            .{ .binding_index = 1, .role = .vector },
            .{ .binding_index = 2, .role = .output },
        };
        const body_axes = [_]tsir.schema.SemanticBodyAxis{
            .{ .axis_index = 0, .role = .output },
            .{ .axis_index = 1, .role = .reduction },
        };
    };
    const semantic = tsir.schema.SemanticFunction{
        .name = "main",
        .family_hint = .fused_gemv,
        .axes = &data.axes,
        .bindings = &data.bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = .{ .op = .fused_gemv, .binding_roles = &data.body_bindings, .axis_roles = &data.body_axes },
        .source_digest = [_]u8{0} ** 32,
    };
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const config = tsir.emit_kernel_body.Config{ .var_prefix = "tsir_" };
    try std.testing.expectError(
        error.UnsupportedScalarKind,
        tsir.emit_kernel_body.emitWithConfig(buf.writer(allocator), semantic, .csl, &config),
    );
}
