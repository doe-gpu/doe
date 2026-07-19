// emit_csl_linear_attn.zig — CSL PE program for linear attention.
//
// Linear attention: scaled dot-product without softmax normalization.
// Used by Qwen's 18 linear attention layers. Each PE handles one
// (query_pos, head) pair — no fabric needed.
//
// output[d] = sum_k( Q[d] * K[k,d] * V[k,d] ) * scale

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const W = @import("emit_csl_ir_walk.zig");

pub const EmitError = W.EmitError;

pub fn emit(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.AttentionLinearInfo,
) EmitError!void {
    const q = module.globals.items[info.q_global].name;
    const k = module.globals.items[info.k_global].name;
    const v = module.globals.items[info.v_global].name;
    const out = module.globals.items[info.output_global].name;

    try W.write(buf, pos, "// PE program: linear attention (auto-generated from WGSL)\n");
    try W.write(buf, pos, "// Scaled dot-product without softmax. Each PE = one (query, head).\n\n");

    try W.write(buf, pos, "param memcpy_params;\n");
    try W.write(buf, pos, "param pe_id: i16;\n");
    try W.write(buf, pos, "param num_pes: i16;\n\n");
    try W.write(buf, pos, "param head_dim: i16;\n");
    try W.write(buf, pos, "param kv_len: i16;\n");
    try W.write(buf, pos, "param scale: f32 = 0.125;\n\n");

    try W.write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n\n");

    // Storage pointers
    try emitStoragePtrs(buf, pos, module);

    // Linear attention: no exp, no normalization
    try W.write(buf, pos, "fn compute() void {\n");
    try W.write(buf, pos, "    // Zero output accumulator\n");
    try W.write(buf, pos, "    for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "        ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, d)] = 0.0;\n");
    try W.write(buf, pos, "    }\n\n");

    try W.write(buf, pos, "    // Accumulate Q * K * V for each KV position\n");
    try W.write(buf, pos, "    for (@range(i16, kv_len)) |kv_i| {\n");
    try W.write(buf, pos, "        var score: f32 = 0.0;\n");
    try W.write(buf, pos, "        for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "            score += ");
    try W.write(buf, pos, q);
    try W.write(buf, pos, "[@as(u32, d)] * ");
    try W.write(buf, pos, k);
    try W.write(buf, pos, "[@as(u32, kv_i) * @as(u32, head_dim) + @as(u32, d)];\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        score *= scale;\n");
    try W.write(buf, pos, "        for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "            ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, d)] += score * ");
    try W.write(buf, pos, v);
    try W.write(buf, pos, "[@as(u32, kv_i) * @as(u32, head_dim) + @as(u32, d)];\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "    }\n\n");

    try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "}\n\n");

    try emitComptime(buf, pos, module);
}

fn emitStoragePtrs(buf: []u8, pos: *usize, module: *const ir.Module) EmitError!void {
    // CSL doesn't accept `var x: [*]f32 = undefined;` (nor does `&x` yield
    // [*]f32 when x is itself a pointer). Use the same sized-array +
    // aliased pointer pattern the elementwise / rope / gather emitters
    // use. Size heuristic by name: K and V store kv_len * head_dim
    // entries, Q / output store a single head. Names outside that set
    // fall back to the larger kv-sized buffer so the body indexing
    // stays in-bounds.
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage) continue;
        const size_expr: []const u8 = if (isKvScaledName(global.name)) "kv_len * head_dim" else "head_dim";
        try W.write(buf, pos, "var ");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, ": [");
        try W.write(buf, pos, size_expr);
        try W.write(buf, pos, "]f32 = @zeros([");
        try W.write(buf, pos, size_expr);
        try W.write(buf, pos, "]f32);\n");
        try W.write(buf, pos, "var ");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, "_ptr: [*]f32 = &");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, ";\n");
    }
    try W.write(buf, pos, "\n");
}

fn isKvScaledName(name: []const u8) bool {
    // True when the buffer stores the full K or V matrix (kv_len rows of
    // head_dim each). Conservative — matches common naming conventions
    // and defaults to not-scaled for unrecognized names.
    return std.mem.indexOf(u8, name, "key") != null or
        std.mem.indexOf(u8, name, "val") != null or
        std.mem.indexOf(u8, name, "_k") != null or
        std.mem.indexOf(u8, name, "_v") != null;
}

fn emitComptime(buf: []u8, pos: *usize, module: *const ir.Module) EmitError!void {
    try W.write(buf, pos, "comptime {\n");
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage) continue;
        try W.write(buf, pos, "    @export_symbol(");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, "_ptr, \"");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, "\");\n");
    }
    try W.write(buf, pos, "    @export_symbol(compute);\n");
    try W.write(buf, pos, "}\n");
}
