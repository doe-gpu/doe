// emit_csl_classify_test.zig — regression tests for the CSL kernel-pattern
// classifier.
//
// Specific regression covered here: a plain 3-input FMA-shaped element-wise
// kernel (`out = a*b + c`) must NOT be classified as attention. The prior
// count-based `input_count >= 3 and output_count >= 1` fallback inside
// analyzeGlobals would blindly set has_qkv_buffers=true on any 3-read
// kernel, and the attention_linear branch would then accept it because
// linear attention explicitly has no barriers, no shared memory, and no
// exp() calls — the same shape as a 3-input element-wise kernel.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const classify = @import("../../src/compiler/wgsl/emit/csl/emit_csl_classify.zig");

const allocator = std.testing.allocator;

fn classifyWgsl(src: []const u8) !classify.KernelPattern {
    var module = try mod.analyzeToIr(allocator, src);
    defer module.deinit();
    std.debug.assert(module.entry_points.items.len >= 1);
    return classify.classify(&module, module.entry_points.items[0]);
}

const FMA_WGSL =
    "@group(0) @binding(0) var<storage, read> a: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read> b: array<f32>;\n" ++
    "@group(0) @binding(2) var<storage, read> c: array<f32>;\n" ++
    "@group(0) @binding(3) var<storage, read_write> out: array<f32>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(@builtin(global_invocation_id) gid: vec3u) {\n" ++
    "    let idx = gid.x;\n" ++
    "    if (idx < arrayLength(&a)) {\n" ++
    "        out[idx] = a[idx] * b[idx] + c[idx];\n" ++
    "    }\n" ++
    "}\n";

const RESIDUAL_WGSL =
    "@group(0) @binding(0) var<storage, read> input: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read> residual: array<f32>;\n" ++
    "@group(0) @binding(2) var<storage, read_write> output: array<f32>;\n" ++
    "\n" ++
    "@compute @workgroup_size(256)\n" ++
    "fn main(@builtin(global_invocation_id) gid: vec3u) {\n" ++
    "    let idx = gid.x;\n" ++
    "    output[idx] = input[idx] + residual[idx];\n" ++
    "}\n";

const GELU_WGSL =
    "@group(0) @binding(0) var<storage, read> input: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n" ++
    "\n" ++
    "@compute @workgroup_size(256)\n" ++
    "fn main(@builtin(global_invocation_id) gid: vec3u) {\n" ++
    "    let idx = gid.x;\n" ++
    "    let x = input[idx];\n" ++
    "    let t = 0.7978845608 * (x + 0.044715 * x * x * x);\n" ++
    "    output[idx] = 0.5 * x * (1.0 + tanh(t));\n" ++
    "}\n";

test "classify: 3-input FMA is element_wise, not attention_linear" {
    const pattern = try classifyWgsl(FMA_WGSL);
    // The prior bug: this kernel returned .attention_linear because
    // analyzeGlobals blindly assigned a/b/c as Q/K/V based on count.
    // After the fix: the attention-evidence gate (no barriers, no
    // subgroup ops, no exp calls, no attention-ish buffer names)
    // blocks the QKV fallback, and the classifier falls through to
    // element_wise.
    switch (pattern) {
        .attention_linear, .attention_streaming, .attention_tiled, .attention_decode => {
            std.debug.print("unexpected attention classification for FMA kernel: {}\n", .{@as(std.meta.Tag(classify.KernelPattern), pattern)});
            return error.FmaMisclassifiedAsAttention;
        },
        .element_wise => {},
        else => {
            std.debug.print("unexpected pattern for FMA kernel: {}\n", .{@as(std.meta.Tag(classify.KernelPattern), pattern)});
            return error.FmaUnexpectedPattern;
        },
    }
}

test "classify: residual add is element_wise, not fused_ffn" {
    const pattern = try classifyWgsl(RESIDUAL_WGSL);
    switch (pattern) {
        .fused_ffn => {
            std.debug.print("unexpected fused_ffn classification for residual kernel\n", .{});
            return error.ResidualMisclassifiedAsFusedFfn;
        },
        .element_wise => |info| {
            try std.testing.expectEqual(@as(u32, 2), info.input_count);
            try std.testing.expectEqual(@as(u32, 1), info.output_count);
        },
        else => {
            std.debug.print("unexpected pattern for residual kernel: {}\n", .{@as(std.meta.Tag(classify.KernelPattern), pattern)});
            return error.ResidualUnexpectedPattern;
        },
    }
}

test "classify: gelu tanh approximation is element_wise, not attention" {
    const pattern = try classifyWgsl(GELU_WGSL);
    switch (pattern) {
        .attention_linear, .attention_streaming, .attention_tiled, .attention_decode => {
            std.debug.print("unexpected attention classification for gelu kernel: {}\n", .{@as(std.meta.Tag(classify.KernelPattern), pattern)});
            return error.GeluMisclassifiedAsAttention;
        },
        .element_wise => |info| {
            try std.testing.expectEqual(@as(u32, 1), info.input_count);
            try std.testing.expectEqual(@as(u32, 1), info.output_count);
        },
        else => {
            std.debug.print("unexpected pattern for gelu kernel: {}\n", .{@as(std.meta.Tag(classify.KernelPattern), pattern)});
            return error.GeluUnexpectedPattern;
        },
    }
}

const EXP_SOFTMAX_WGSL =
    "@group(0) @binding(0) var<storage, read> buf_q: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read> buf_k: array<f32>;\n" ++
    "@group(0) @binding(2) var<storage, read> buf_v: array<f32>;\n" ++
    "@group(0) @binding(3) var<storage, read_write> buf_out: array<f32>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(@builtin(global_invocation_id) gid: vec3u) {\n" ++
    "    let idx = gid.x;\n" ++
    "    let score = buf_q[idx] * buf_k[idx];\n" ++
    "    buf_out[idx] = exp(score) * buf_v[idx];\n" ++
    "}\n";

test "classify: 3-input kernel with exp() triggers attention" {
    // Positive regression: a 3-input kernel that actually has attention
    // evidence (exp() call) still classifies as an attention pattern.
    // Buffer names intentionally don't match the simple K/key hint so
    // the decision rides on the exp() evidence path.
    const pattern = try classifyWgsl(EXP_SOFTMAX_WGSL);
    switch (pattern) {
        .attention_linear,
        .attention_streaming,
        .attention_tiled,
        .attention_decode,
        => {},
        else => {
            std.debug.print("expected attention pattern, got: {}\n", .{@as(std.meta.Tag(classify.KernelPattern), pattern)});
            return error.ExpectedAttentionPattern;
        },
    }
}

const NAMED_QKV_WGSL =
    "@group(0) @binding(0) var<storage, read> query: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read> key: array<f32>;\n" ++
    "@group(0) @binding(2) var<storage, read> val: array<f32>;\n" ++
    "@group(0) @binding(3) var<storage, read_write> out: array<f32>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(@builtin(global_invocation_id) gid: vec3u) {\n" ++
    "    let idx = gid.x;\n" ++
    "    out[idx] = query[idx] * key[idx] + val[idx];\n" ++
    "}\n";

test "classify: query/key/val-named buffers still get attention even without exp" {
    // The name-based hint path (not the count-based fallback) sets
    // has_qkv_buffers directly. A kernel with query/key/val naming must
    // remain attention-classified even without barriers/exp.
    const pattern = try classifyWgsl(NAMED_QKV_WGSL);
    switch (pattern) {
        .attention_linear,
        .attention_streaming,
        .attention_tiled,
        .attention_decode,
        => {},
        else => {
            std.debug.print("expected attention for named Q/K/V buffers, got: {}\n", .{@as(std.meta.Tag(classify.KernelPattern), pattern)});
            return error.NamedQkvNotAttention;
        },
    }
}
