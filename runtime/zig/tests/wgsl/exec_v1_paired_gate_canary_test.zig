// Cross-backend bootstrap canary for the Qwen-specific gated-activation
// op family.
//
// The exec-v1 opToSpec map (runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_exec_v1.zig)
// routes four paired-gate op identifiers — `gelu_gated` (Gemma GeGLU),
// `silu_gated` (SwiGLU FFN inner; Qwen 3.6 / Llama-style),
// `sigmoid_gated` (attentionOutputGate), and the alias `o_gate` (also
// sigmoid-gated). All four share the (gate, input) -> output binding
// shape and the chunk_size-axis emit pattern dispatched by
// emit_csl_semantic_ops.zig.
//
// This canary pins the op-to-pattern dispatch contract:
//   1) opToSpec returns a non-null spec for each gated op;
//   2) the spec's pattern is one the WGSL→CSL classifier recognizes;
//   3) the spec allows both prefill and decode phases (gated activations
//      ride both paths in Qwen 3.6 27B);
//   4) isPairedGateOp returns true for all four;
//   5) the o_gate alias resolves to the same `sigmoid_gated` pattern;
//   6) opToSpec returns null for an unrelated op string so the dispatch
//      table is closed (no swallow-everything default).
//
// Numeric pinning of the gated emit body lives in
// tsir_emit_kernel_body_test.zig. This file's job is the dispatch
// surface — when a smoke config says `op="silu_gated"`, the lowering
// pipeline must reach the silu_gated CSL emit and not silently fall
// back to a stand-in.

const std = @import("std");
const exec_v1 = @import("../../src/compiler/wgsl/emit/csl/emit_csl_exec_v1.zig");
const host = @import("../../src/compiler/wgsl/emit/csl/emit_csl_host.zig");
const semantic_ops = @import("../../src/compiler/wgsl/emit/csl/emit_csl_semantic_ops.zig");
const compile_source = @import("../../src/compiler/wgsl/emit/csl/emit_csl_host_compile_source.zig");

fn expectPatternByteIdentical(left_pattern: []const u8, right_pattern: []const u8) !void {
    var left_buf: [65536]u8 = undefined;
    var right_buf: [65536]u8 = undefined;
    const left = try compile_source.emitPatternSections(
        std.testing.allocator,
        left_pattern,
        &left_buf,
    );
    const right = try compile_source.emitPatternSections(
        std.testing.allocator,
        right_pattern,
        &right_buf,
    );
    try std.testing.expectEqualStrings(left.layout, right.layout);
    try std.testing.expectEqualStrings(left.pe_program, right.pe_program);
}

test "exec-v1 opToSpec routes gelu_gated to gelu_gated pattern" {
    const spec = exec_v1.opToSpec("gelu_gated") orelse return error.OpUnregistered;
    try std.testing.expectEqualStrings("gelu_gated", spec.pattern);
    try std.testing.expect(spec.allow_prefill);
    try std.testing.expect(spec.allow_decode);
    try std.testing.expect(spec.kind == .compute);
    try std.testing.expect(semantic_ops.isSemanticPattern(spec.pattern));
}

test "exec-v1 opToSpec routes silu_gated to silu_gated pattern" {
    const spec = exec_v1.opToSpec("silu_gated") orelse return error.OpUnregistered;
    try std.testing.expectEqualStrings("silu_gated", spec.pattern);
    try std.testing.expect(spec.allow_prefill);
    try std.testing.expect(spec.allow_decode);
    try std.testing.expect(spec.kind == .compute);
    try std.testing.expect(semantic_ops.isSemanticPattern(spec.pattern));
}

test "exec-v1 opToSpec routes sigmoid_gated to sigmoid_gated pattern" {
    const spec = exec_v1.opToSpec("sigmoid_gated") orelse return error.OpUnregistered;
    try std.testing.expectEqualStrings("sigmoid_gated", spec.pattern);
    try std.testing.expect(spec.allow_prefill);
    try std.testing.expect(spec.allow_decode);
    try std.testing.expect(spec.kind == .compute);
    try std.testing.expect(semantic_ops.isSemanticPattern(spec.pattern));
}

test "exec-v1 opToSpec aliases o_gate to sigmoid_gated pattern" {
    const o_gate = exec_v1.opToSpec("o_gate") orelse return error.OpUnregistered;
    const sigmoid = exec_v1.opToSpec("sigmoid_gated") orelse return error.OpUnregistered;
    try std.testing.expectEqualStrings("sigmoid_gated", o_gate.pattern);
    try std.testing.expectEqualStrings(sigmoid.pattern, o_gate.pattern);
    try std.testing.expectEqual(sigmoid.kind, o_gate.kind);
    try std.testing.expectEqual(sigmoid.allow_prefill, o_gate.allow_prefill);
    try std.testing.expectEqual(sigmoid.allow_decode, o_gate.allow_decode);
    try std.testing.expect(semantic_ops.isSemanticPattern(o_gate.pattern));
}

test "exec-v1 isPairedGateOp covers all four gated identifiers" {
    try std.testing.expect(exec_v1.isPairedGateOp("gelu_gated"));
    try std.testing.expect(exec_v1.isPairedGateOp("silu_gated"));
    try std.testing.expect(exec_v1.isPairedGateOp("sigmoid_gated"));
    try std.testing.expect(exec_v1.isPairedGateOp("o_gate"));
}

test "exec-v1 isPairedGateOp rejects non-gated ops" {
    try std.testing.expect(!exec_v1.isPairedGateOp("silu"));
    try std.testing.expect(!exec_v1.isPairedGateOp("gelu"));
    try std.testing.expect(!exec_v1.isPairedGateOp("residual"));
    try std.testing.expect(!exec_v1.isPairedGateOp("rmsnorm"));
    try std.testing.expect(!exec_v1.isPairedGateOp(""));
}

test "exec-v1 opToSpec returns null for an unrelated op so the table is closed" {
    try std.testing.expect(exec_v1.opToSpec("definitely_not_a_real_op") == null);
    try std.testing.expect(exec_v1.opToSpec("") == null);
}

test "exec-v1 opToPattern matches opToSpec.pattern for every gated op" {
    const ops = [_][]const u8{ "gelu_gated", "silu_gated", "sigmoid_gated", "o_gate" };
    for (ops) |op| {
        const spec = exec_v1.opToSpec(op) orelse return error.OpUnregistered;
        const pattern = exec_v1.opToPattern(op) orelse return error.OpUnregistered;
        try std.testing.expectEqualStrings(spec.pattern, pattern);
    }
}

test "lowerJsonToHostPlan accepts paired-gate ops with inputsFrom" {
    // Qwen 3.6 27B smoke shape: silu_gated FFN + o_gate (sigmoid_gated)
    // attention output gate. Both are paired-input ops; inputsFrom must
    // be present with two upstream step names.
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed" },
        \\    { "phase": "prefill", "op": "matmul", "kernelKey": "tiled_q", "weightsKey": "q_proj" },
        \\    { "phase": "prefill", "op": "attention_prefill", "kernelKey": "attn_prefill" },
        \\    { "phase": "prefill", "op": "o_gate", "kernelKey": "o_gate", "inputsFrom": ["tiled_q", "attn_prefill"] },
        \\    { "phase": "prefill", "op": "matmul", "kernelKey": "tiled_gate", "weightsKey": "gate_proj" },
        \\    { "phase": "prefill", "op": "matmul", "kernelKey": "tiled_up", "weightsKey": "up_proj" },
        \\    { "phase": "prefill", "op": "silu_gated", "kernelKey": "silu_gated", "inputsFrom": ["tiled_gate", "tiled_up"] },
        \\    { "phase": "decode", "op": "attention", "kernelKey": "attn_decode" },
        \\    { "phase": "decode", "op": "matmul", "kernelKey": "lm_head_prefill", "weightsKey": "lm_head" },
        \\    { "phase": "decode", "op": "sample", "kernelKey": "sampler", "kind": "sample" }
        \\  ]
        \\}
    ;

    var kernels: [32]host.KernelSpec = undefined;
    var prefill: [32]host.LaunchSpec = undefined;
    var decode: [32]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plan = try exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode);
    try std.testing.expect(plan.prefill_launches.len == 7);
    try std.testing.expect(plan.decode_launches.len == 3);

    var saw_o_gate = false;
    var saw_silu_gated = false;
    for (plan.kernels) |k| {
        if (std.mem.eql(u8, k.name, "o_gate")) {
            try std.testing.expectEqualStrings("sigmoid_gated", k.pattern);
            saw_o_gate = true;
        }
        if (std.mem.eql(u8, k.name, "silu_gated")) {
            try std.testing.expectEqualStrings("silu_gated", k.pattern);
            saw_silu_gated = true;
        }
    }
    try std.testing.expect(saw_o_gate);
    try std.testing.expect(saw_silu_gated);
}

test "lowerJsonToHostPlan rejects paired-gate op missing inputsFrom" {
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed" },
        \\    { "phase": "prefill", "op": "silu_gated", "kernelKey": "silu_gated" }
        \\  ]
        \\}
    ;

    var kernels: [4]host.KernelSpec = undefined;
    var prefill: [4]host.LaunchSpec = undefined;
    var decode: [4]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.MalformedStep,
        exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode),
    );
}

test "exec-v1 opToSpec routes attention_prefill_kv_axis_sharded to its semantic pattern" {
    // The Qwen 3.6 27B smoke config swaps the prefill attention step
    // from `attention_prefill` (which routes to attention_tiled and
    // overflows per-PE memory at head_dim=256/q_len=4096) to
    // `attention_prefill_kv_axis_sharded`. The op must dispatch to the
    // matching semantic pattern, must allow prefill (and reject decode),
    // and the pattern must be on the semantic-ops list so the host
    // compile-source path delegates to TSIR's emitKvAxisSharded body.
    const spec = exec_v1.opToSpec("attention_prefill_kv_axis_sharded") orelse return error.OpUnregistered;
    try std.testing.expectEqualStrings("attention_prefill_kv_axis_sharded", spec.pattern);
    try std.testing.expect(spec.allow_prefill);
    try std.testing.expect(!spec.allow_decode);
    try std.testing.expect(spec.kind == .compute);
    try std.testing.expect(semantic_ops.isSemanticPattern(spec.pattern));
}

test "exec-v1 opToSpec routes Qwen SSM body ops to semantic patterns" {
    const ops = [_][]const u8{ "conv1d_depthwise", "l2_normalize", "linear_attention" };
    for (ops) |op| {
        const spec = exec_v1.opToSpec(op) orelse return error.OpUnregistered;
        try std.testing.expectEqualStrings(op, spec.pattern);
        try std.testing.expect(spec.allow_prefill);
        try std.testing.expect(spec.allow_decode);
        try std.testing.expect(spec.kind == .compute);
        try std.testing.expect(semantic_ops.isSemanticPattern(spec.pattern));
        try std.testing.expect(!exec_v1.isPairedGateOp(op));
    }
}

test "Qwen SSM body op layouts export their host-plan bindings" {
    var conv_buf: [16384]u8 = undefined;
    const conv = try compile_source.emitPatternSections(
        std.testing.allocator,
        "conv1d_depthwise",
        &conv_buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, conv.layout, "param num_tokens: i16 = 4;") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.layout, "param channels: i16 = 128;") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.layout, "param kernel_size: i16 = 4;") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.layout, ".num_tokens = num_tokens") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.layout, "@export_name(\"input\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.layout, "@export_name(\"weight\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.layout, "@export_name(\"bias\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.layout, "@export_name(\"output\", [*]f32, true)") != null);

    var l2_buf: [16384]u8 = undefined;
    const l2 = try compile_source.emitPatternSections(
        std.testing.allocator,
        "l2_normalize",
        &l2_buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, l2.layout, "param hidden_size: i16 = 128;") != null);
    try std.testing.expect(std.mem.indexOf(u8, l2.layout, "@export_name(\"input\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, l2.layout, "@export_name(\"output\", [*]f32, true)") != null);

    var linear_buf: [32768]u8 = undefined;
    const linear = try compile_source.emitPatternSections(
        std.testing.allocator,
        "linear_attention",
        &linear_buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, "param key_dim: i16 = 128;") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, "param value_dim: i16 = 128;") != null);
    // value_dim is sharded across pe_y via value_dim_per_pe so per-PE
    // state fits the WSE-3 48 KiB SRAM budget; layout forwards it.
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, "param value_dim_per_pe: i16 = 64;") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, ".value_dim_per_pe = value_dim_per_pe") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, "param a_log: f32 = 0.5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, ".a_log = a_log") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, "@export_name(\"query\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, "@export_name(\"key\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, "@export_name(\"value\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, "@export_name(\"gate\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, "@export_name(\"linear_state\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.layout, "@export_name(\"output\", [*]f32, true)") != null);
}

test "Qwen SSM body op pe programs pin TSIR formulas" {
    var conv_buf: [16384]u8 = undefined;
    const conv = try compile_source.emitPatternSections(
        std.testing.allocator,
        "conv1d_depthwise",
        &conv_buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, conv.pe_program, "const channels: i16 = 128;") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.pe_program, "const kernel_size: i16 = 4;") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.pe_program, "const t_in: i16 = t - (kernel_size - 1 - k);") != null);
    try std.testing.expect(std.mem.indexOf(u8, conv.pe_program, "sys_mod.unblock_cmd_stream();") != null);

    var l2_buf: [16384]u8 = undefined;
    const l2 = try compile_source.emitPatternSections(
        std.testing.allocator,
        "l2_normalize",
        &l2_buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, l2.pe_program, "const hidden_size: i16 = 128;") != null);
    try std.testing.expect(std.mem.indexOf(u8, l2.pe_program, "fn sqrt_nr(x: f32) f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, l2.pe_program, "1.0 / sqrt_nr(sq + l2_eps)") != null);

    var linear_buf: [32768]u8 = undefined;
    const linear = try compile_source.emitPatternSections(
        std.testing.allocator,
        "linear_attention",
        &linear_buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, linear.pe_program, "const key_dim: i16 = 128;") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.pe_program, "const value_dim: i16 = 128;") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.pe_program, "param value_dim_per_pe: i16;") != null);
    // Compute loops iterate value_dim_per_pe (the per-PE d-block), not
    // the full value_dim — that's the load-bearing sharding invariant.
    try std.testing.expect(std.mem.indexOf(u8, linear.pe_program, "for (@range(i16, value_dim_per_pe))") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.pe_program, "const alpha: f32 = 1.0 - math.exp(-a_log);") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.pe_program, "linear_state") != null);
    try std.testing.expect(std.mem.indexOf(u8, linear.pe_program, "const sigmoid_g: f32 = 1.0 / (1.0 + math.exp(-g));") != null);
}

test "shared Cerebras kernels emit byte-identical CSL through direct and exec-v1 invokers" {
    const gemv = exec_v1.opToSpec("matmul_q4k") orelse return error.OpUnregistered;
    try expectPatternByteIdentical(gemv.pattern, "fused_gemv_dequant");

    const rope = exec_v1.opToSpec("rope") orelse return error.OpUnregistered;
    try expectPatternByteIdentical(rope.pattern, "rope");

    const rmsnorm = exec_v1.opToSpec("rmsnorm") orelse return error.OpUnregistered;
    try expectPatternByteIdentical(rmsnorm.pattern, "rms_norm");

    const prefill = exec_v1.opToSpec("attention_prefill_kv_axis_sharded") orelse return error.OpUnregistered;
    try expectPatternByteIdentical(prefill.pattern, "attention_prefill_kv_axis_sharded");
}

test "attention_prefill_kv_axis_sharded layout exports query/key/value/output and partials params" {
    // Layout contract expected by the host plan stitch:
    //   - 2D PE grid (width × height) so K/V can shard along pe_y while
    //     pe_x carries the per-stripe Q queries.
    //   - kv_len + slots_per_pe params so cslc can specialize per-shape.
    //   - width is passed uniformly; the PE derives flat pe_id from CSL
    //     layout coordinates so the layout does not specialize one
    //     program per tile.
    //   - exports: query, key, value, output, compute. The body writes
    //     [query_seq_len * (head_dim + 2)]f32 partials per PE; the host
    //     plan log-sum-exp stitch reduces those into final attention
    //     output. The kernel itself must NOT divide by sum_exp — that
    //     would defeat the global stitch.
    var buf: [16384]u8 = undefined;
    const sections = try compile_source.emitPatternSections(
        std.testing.allocator,
        "attention_prefill_kv_axis_sharded",
        &buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "param width: u16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "param height: u16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "param kv_len: i16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "param slots_per_pe: i16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@set_rectangle(width, height)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".width = width") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".pe_id =") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".num_pes =") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@export_name(\"query\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@export_name(\"key\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@export_name(\"value\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@export_name(\"output\", [*]f32, true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@export_name(\"compute\", fn()void)") != null);
}

test "fused_gemv_dequant uses collectives_2d reduce for width-greater-than-two rows" {
    var buf: [32768]u8 = undefined;
    const sections = try compile_source.emitPatternSections(
        std.testing.allocator,
        "fused_gemv_dequant",
        &buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "const c2d = @import_module(\"<collectives_2d/params>\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".c2d_params = c2d_tile_params") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@set_color_config") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const mpi_x = @import_module(\"<collectives_2d/pe>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "mpi_x.reduce_fadds(@as(u16, num_pes - 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "param reduce_color") == null);
}

test "attention_prefill_kv_axis_sharded pe program emits multi-Q kv-axis-sharded body" {
    // Multi-Q (causal-prefill) signals the body must emit per its
    // hardcoded query_seq_len (8) wrapped in a `for q in 0..8` loop.
    // The emit must NOT bake in /sum_exp — that's the host stitch's
    // job. tail-mask `gk >= kv_len` and partials writes at
    // (head_dim, head_dim+1) within each query stripe pin the
    // log-sum-exp interface. The pe program derives pe_id from the CSL
    // layout module so cslc can reuse tile code across the full grid.
    var buf: [16384]u8 = undefined;
    const sections = try compile_source.emitPatternSections(
        std.testing.allocator,
        "attention_prefill_kv_axis_sharded",
        &buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "param pe_id:") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "param num_pes:") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "param width: u16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const layout_mod = @import_module(\"<layout>\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "layout_mod.get_x_coord()") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "layout_mod.get_y_coord()") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const pe_id: u32 = @as(u32, pe_y) * @as(u32, width) + @as(u32, pe_x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "param kv_len: i16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "param slots_per_pe: i16") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const head_dim: i16 = 256;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const query_seq_len: u32 = 8;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const partials_len: u32 = @as(u32, head_dim) + 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "for (@range(u32, query_seq_len)) |q|") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "if (gk >= @as(u32, kv_len))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "out_row_offset + @as(u32, head_dim)") != null);
    // Causal mask per row.
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "if (gk > q_pos)") != null);
    // Sharded path defers global normalization to the host stitch.
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "/ sum_exp") == null);
}

test "lowerJsonToHostPlan rejects paired-gate op with wrong inputsFrom arity" {
    const json_payload =
        \\{
        \\  "grid": { "width": 8, "height": 1 },
        \\  "steps": [
        \\    { "phase": "prefill", "op": "embed", "kernelKey": "embed" },
        \\    { "phase": "prefill", "op": "matmul", "kernelKey": "g", "weightsKey": "w" },
        \\    { "phase": "prefill", "op": "silu_gated", "kernelKey": "silu_gated", "inputsFrom": ["g"] }
        \\  ]
        \\}
    ;

    var kernels: [4]host.KernelSpec = undefined;
    var prefill: [4]host.LaunchSpec = undefined;
    var decode: [4]host.LaunchSpec = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.MalformedStep,
        exec_v1.lowerJsonToHostPlan(arena.allocator(), json_payload, &kernels, &prefill, &decode),
    );
}
