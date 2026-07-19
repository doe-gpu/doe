// emit_kernel_body_attention.zig — CSL emit body for SemanticBodyOp
// `attention_scores`.
//
// Lifted out of `emit_kernel_body.zig` so the parent file stays under the
// 999-line repo limit. The dispatch in `emit_kernel_body.zig:emitCsl`
// forwards `.attention_scores` here; nothing else imports this module.
//
// Scope: bootstrap-canary surface only. Required body schema:
//   - softmax_mode = .two_pass_stable
//   - causal_mode  ∈ { .none, .causal, .sliding_window }
//   - has_softcap  = false
//   - scale_source = .literal_f32 (uniform scale not yet wired)
// Streaming softmax, softcap, page-table KV, and uniform scale remain
// explicit `error.InvalidBodyContract` so the canary lane fails loudly
// when those shapes are requested. Manifest-shape attention with those
// features needs a separate emit body class.
//
// Single-Q convention for the canary surface: Q is the latest query
// position, i.e. `query_pos = kv_len - 1`. Under that convention:
//   - `.causal` is mathematically a no-op (no K position is ever after
//     `query_pos`), but the conditional is emitted so the lane is
//     exercised end-to-end against the reference interpreter.
//   - `.sliding_window` masks K positions where
//     `k < kv_len - sliding_window_size` (i.e. the window covers the
//     last `sliding_window_size` slots).
// When this body is later promoted to multi-Q (causal prefill), the same
// mask emit point widens to `k > query_pos[q]` per row.
//
// Two PE-residency strategies are implemented:
//   - `.full_per_pe` (default): every PE holds the full
//     `[kv_len * head_dim]f32` K and V buffers and runs the full
//     two-pass-stable softmax to a final `[head_dim]f32` `O[d]`. Single-PE
//     canary path; used by attention_head256_f16kv (kv_len=15) and the
//     kv_len ≤ 8 attention_head512_f16kv lane that fits the WSE-3
//     per-PE 48 KiB SRAM budget.
//   - `.kv_axis_sharded`: K/V are sharded along the position axis. Each
//     PE owns `slots_per_pe` slots and emits per-PE partials
//     (`local_O[d]` un-normalized, `local_max`, `local_sum_exp`) into a
//     `[head_dim + 2]f32` output buffer. The host plan reduces partials
//     using log-sum-exp distributed softmax; same numerics as the
//     single-PE path, just stitched outside the kernel. Mirrors the
//     slot-sharded KV pattern (host-side stitch). Unblocks head_dim=512
//     at kv_len ≥ 15 — the next-tier attention-canary follow-up in
//     `docs/cerebras-model-ledgers.md`.

const std = @import("std");
const schema = @import("schema.zig");
const body_emit = @import("emit_kernel_body.zig");

/// Emit a CSL `attention_scores` kernel body. Dispatches on
/// `Config.attention_pe_strategy` to pick the single-PE or kv-axis
/// sharded variant. Both paths share the same body-contract validation
/// (softmax_mode/causal_mode/softcap/scale_source).
pub fn emitCslAttentionScores(
    writer: anytype,
    func: schema.SemanticFunction,
    config: *const body_emit.Config,
) body_emit.EmitError!void {
    const query = try body_emit.bindingForRole(func, .query);
    const key = try body_emit.bindingForRole(func, .key);
    const value = try body_emit.bindingForRole(func, .value);
    const output = try body_emit.bindingForRole(func, .output);
    const elem = output.elem;
    try body_emit.requireSupportedComputeElem(elem);
    try body_emit.requireElem(query, elem);
    try body_emit.requireElem(key, elem);
    try body_emit.requireElem(value, elem);
    try body_emit.requireElem(output, elem);

    const attn = func.body.attention_scores orelse return error.InvalidBodyContract;
    if (attn.softmax_mode != .two_pass_stable) return error.InvalidBodyContract;
    if (attn.has_softcap) return error.InvalidBodyContract;
    if (attn.scale_source != .literal_f32) return error.InvalidBodyContract;
    const scale = attn.scale_literal_f32 orelse return error.InvalidBodyContract;
    if (attn.causal_mode == .sliding_window) {
        const window = attn.sliding_window_size orelse return error.InvalidBodyContract;
        if (window == 0) return error.InvalidBodyContract;
    }

    const query_seq_len = attn.query_seq_len orelse 1;
    if (query_seq_len == 0) return error.InvalidBodyContract;

    const ctx = AttnEmitContext{
        .query = query,
        .key = key,
        .value = value,
        .output = output,
        .elem = elem,
        .head_dim = attn.head_dim,
        .scale = scale,
        .causal_mode = attn.causal_mode,
        .sliding_window_size = attn.sliding_window_size,
        .query_seq_len = query_seq_len,
        .var_prefix = config.var_prefix,
    };

    return switch (config.attention_pe_strategy) {
        .full_per_pe => emitFullPerPe(writer, ctx),
        .kv_axis_sharded => emitKvAxisSharded(writer, ctx, config),
    };
}

const AttnEmitContext = struct {
    query: schema.BufferBinding,
    key: schema.BufferBinding,
    value: schema.BufferBinding,
    output: schema.BufferBinding,
    elem: schema.ScalarKind,
    head_dim: u32,
    scale: f64,
    causal_mode: schema.CausalMode,
    sliding_window_size: ?u32,
    query_seq_len: u32,
    var_prefix: []const u8,
};

/// Mask sentinel for the elem-typed lane. f32 keeps the historical
/// `-1.0e30`. f16 uses `-65504.0` (the most-negative finite f16); a
/// larger magnitude would auto-saturate to -inf when CSL casts the
/// comptime literal, which still works for softmax but is harder to
/// reason about. -65504.0 is exactly representable and behaves
/// identically under `exp(sc - max) ≈ 0` for any non-mask score.
fn maskSentinel(elem: schema.ScalarKind) []const u8 {
    return switch (elem) {
        .f32 => "-1.0e30",
        .f16 => "-65504.0",
        else => "-1.0e30",
    };
}

/// Emit the per-slot mask conditional that runs after `dot * attn_scale`
/// has been computed. `k_global_expr` is the CSL expression that
/// resolves to the absolute K position the score corresponds to (single
/// PE: just `k`; sharded: `gk = slot_base + k`). Single-Q convention:
/// query_pos = kv_len - 1, so `.causal` is a no-op (emitted as a
/// structural conditional that never fires), and `.sliding_window`
/// masks `k_global < kv_len - sliding_window_size`.
fn emitCausalMask(
    writer: anytype,
    causal_mode: schema.CausalMode,
    sliding_window_size: ?u32,
    k_global_expr: []const u8,
    elem: schema.ScalarKind,
) body_emit.EmitError!void {
    const sent = maskSentinel(elem);
    switch (causal_mode) {
        .none => {},
        .causal => {
            try writer.writeAll("        // Single-Q canary convention: query_pos = kv_len - 1.\n");
            try writer.writeAll("        // The conditional is structural; for single-Q it never fires.\n");
            try writer.print(
                "        if ({s} > @as(u32, kv_len) - 1) {{\n",
                .{k_global_expr},
            );
            try writer.print("            sc = {s};\n", .{sent});
            try writer.writeAll("        }\n");
        },
        .sliding_window => {
            const window = sliding_window_size.?;
            try writer.print("        const window_size: u32 = {d};\n", .{window});
            try writer.print(
                "        if (@as(u32, kv_len) > window_size and {s} < @as(u32, kv_len) - window_size) {{\n",
                .{k_global_expr},
            );
            try writer.print("            sc = {s};\n", .{sent});
            try writer.writeAll("        }\n");
        },
    }
}

/// Single-PE two-pass-stable softmax:
///
///   scores[k] = (sum_d Q[d] * K[k, d]) * scale
///   m         = max_k scores[k]
///   weights[k] = exp(scores[k] - m)        ; sum_e = sum_k weights[k]
///   O[d]      = sum_k V[k, d] * (weights[k] / sum_e)
fn emitFullPerPe(writer: anytype, ctx: AttnEmitContext) body_emit.EmitError!void {
    const p = ctx.var_prefix;
    const ty = body_emit.cslElemName(ctx.elem);
    const sent = maskSentinel(ctx.elem);
    try writer.writeAll("param memcpy_params;\n");
    try writer.print("const head_dim: i16 = {d};\n", .{ctx.head_dim});
    try writer.writeAll("param kv_len: i16;\n");
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try writer.writeAll("const math = @import_module(\"<math>\");\n");
    // CSL rejects bare integer literals where the elem type is expected
    // (`expected type 'f32', got: 'comptime_int'`). Force a decimal
    // point + exponent so the literal always parses correctly — matches
    // the existing test assertion `try expectContains(csl, "const
    // attn_scale: f32 = 1");` for the f32 lane (still satisfied since
    // "1" is a prefix).
    try writer.print("const attn_scale: {s} = {e};\n", .{ ty, ctx.scale });
    try body_emit.writeCslBufferArray(writer, p, ctx.query.name, "head_dim", ty);
    try body_emit.writeCslBufferArray(writer, p, ctx.key.name, "kv_len * head_dim", ty);
    try body_emit.writeCslBufferArray(writer, p, ctx.value.name, "kv_len * head_dim", ty);
    try body_emit.writeCslBufferArray(writer, p, ctx.output.name, "head_dim", ty);
    try writer.print("var attn_scores: [kv_len]{s} = @zeros([kv_len]{s});\n", .{ ty, ty });
    try body_emit.writeCslBufferPointer(writer, p, ctx.query.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, ctx.key.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, ctx.value.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, ctx.output.name, ty);
    try writer.writeAll("\n");
    try writer.writeAll("fn compute() void {\n");
    try writer.print("    var max_score: {s} = {s};\n", .{ ty, sent });
    try writer.writeAll("    for (@range(i16, kv_len)) |k| {\n");
    try writer.print("        var dot: {s} = 0.0;\n", .{ty});
    try writer.writeAll("        for (@range(i16, head_dim)) |d| {\n");
    try writer.print(
        "            dot += {s}{s}[@as(u32, d)] * {s}{s}[@as(u32, k) * @as(u32, head_dim) + @as(u32, d)];\n",
        .{ p, ctx.query.name, p, ctx.key.name },
    );
    try writer.writeAll("        }\n");
    try writer.print("        var sc: {s} = dot * attn_scale;\n", .{ty});
    try emitCausalMask(writer, ctx.causal_mode, ctx.sliding_window_size, "@as(u32, k)", ctx.elem);
    try writer.writeAll("        attn_scores[@as(u32, k)] = sc;\n");
    try writer.writeAll("        if (sc > max_score) {\n");
    try writer.writeAll("            max_score = sc;\n");
    try writer.writeAll("        }\n");
    try writer.writeAll("    }\n");
    try writer.print("    var sum_exp: {s} = 0.0;\n", .{ty});
    try writer.writeAll("    for (@range(i16, kv_len)) |k| {\n");
    try writer.writeAll("        const e = math.exp(attn_scores[@as(u32, k)] - max_score);\n");
    try writer.writeAll("        attn_scores[@as(u32, k)] = e;\n");
    try writer.writeAll("        sum_exp += e;\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    for (@range(i16, head_dim)) |d| {\n");
    try writer.print("        var acc: {s} = 0.0;\n", .{ty});
    try writer.writeAll("        for (@range(i16, kv_len)) |k| {\n");
    try writer.print(
        "            acc += {s}{s}[@as(u32, k) * @as(u32, head_dim) + @as(u32, d)] * (attn_scores[@as(u32, k)] / sum_exp);\n",
        .{ p, ctx.value.name },
    );
    try writer.writeAll("        }\n");
    try writer.print(
        "        {s}{s}[@as(u32, d)] = acc;\n",
        .{ p, ctx.output.name },
    );
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try body_emit.writeCslExportSymbol(writer, p, ctx.query.name);
    try body_emit.writeCslExportSymbol(writer, p, ctx.key.name);
    try body_emit.writeCslExportSymbol(writer, p, ctx.value.name);
    try body_emit.writeCslExportSymbol(writer, p, ctx.output.name);
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}

/// Multi-PE kv-axis-sharded body. Per-PE state:
///
///   slot_base    = pe_id * slots_per_pe
///   local_kv_len = slots_per_pe * head_dim
///
/// Each PE owns the K/V slice [slot_base, slot_base + slots_per_pe). For
/// each local slot k where the global position `gk = slot_base + k` is
/// in [0, kv_len) the PE computes:
///
///   scores[k]  = (sum_d Q[d] * K_local[k, d]) * scale
///   local_max  = max_k scores[k]   (over valid local slots)
///   weights[k] = exp(scores[k] - local_max)
///   local_sum_exp = sum_k weights[k]
///   local_O[d] = sum_k weights[k] * V_local[k, d]   (un-normalized)
///
/// The PE writes a `[head_dim + 2]f32` partials buffer:
///   output[0..head_dim] = local_O
///   output[head_dim]    = local_max
///   output[head_dim+1]  = local_sum_exp
///
/// Host plan reduces partials across PEs via log-sum-exp distributed
/// softmax:
///   global_max     = max_i local_max_i
///   rescale_i      = exp(local_max_i - global_max)
///   global_sum_exp = sum_i rescale_i * local_sum_exp_i
///   O[d]           = (sum_i rescale_i * local_O_i[d]) / global_sum_exp
///
/// Final O[d] is bit-equivalent to the single-PE path up to f32 sum
/// reordering.
fn emitKvAxisSharded(
    writer: anytype,
    ctx: AttnEmitContext,
    config: *const body_emit.Config,
) body_emit.EmitError!void {
    const p = ctx.var_prefix;
    const multi_q = ctx.query_seq_len > 1;
    // By default, pe_id is declared by emit_csl's per-PE skeleton.
    // Large semantic wrapper layouts can instead derive pe_id from the
    // CSL layout module to avoid specializing one program per tile.
    if (config.attention_pe_id_source == .layout_coordinates) {
        try writer.writeAll("param width: u16;\n");
    }
    try writer.writeAll("param memcpy_params;\n");
    try writer.print("const head_dim: i16 = {d};\n", .{ctx.head_dim});
    try writer.writeAll("param kv_len: i16;\n");
    if (multi_q) {
        try writer.print("const query_seq_len: u32 = {d};\n", .{ctx.query_seq_len});
    }
    if (config.attention_slots_per_pe_default) |value| {
        try writer.print("param slots_per_pe: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param slots_per_pe: i16;\n");
    }
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try writer.writeAll("const math = @import_module(\"<math>\");\n");
    if (config.attention_pe_id_source == .layout_coordinates) {
        try writer.writeAll("const layout_mod = @import_module(\"<layout>\");\n");
    }
    const ty = body_emit.cslElemName(ctx.elem);
    const sent = maskSentinel(ctx.elem);
    try writer.print("const attn_scale: {s} = {e};\n", .{ ty, ctx.scale });
    try writer.writeAll("const local_kv_len: u32 = @as(u32, slots_per_pe) * @as(u32, head_dim);\n");
    try writer.writeAll("const partials_len: u32 = @as(u32, head_dim) + 2;\n");
    if (multi_q) {
        try body_emit.writeCslBufferArray(writer, p, ctx.query.name, "query_seq_len * @as(u32, head_dim)", ty);
    } else {
        try body_emit.writeCslBufferArray(writer, p, ctx.query.name, "head_dim", ty);
    }
    try body_emit.writeCslBufferArray(writer, p, ctx.key.name, "local_kv_len", ty);
    try body_emit.writeCslBufferArray(writer, p, ctx.value.name, "local_kv_len", ty);
    if (multi_q) {
        try body_emit.writeCslBufferArray(writer, p, ctx.output.name, "query_seq_len * partials_len", ty);
    } else {
        try body_emit.writeCslBufferArray(writer, p, ctx.output.name, "partials_len", ty);
    }
    try writer.print("var attn_scores: [slots_per_pe]{s} = @zeros([slots_per_pe]{s});\n", .{ ty, ty });
    try body_emit.writeCslBufferPointer(writer, p, ctx.query.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, ctx.key.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, ctx.value.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, ctx.output.name, ty);
    try writer.writeAll("\n");
    try writer.writeAll("fn compute() void {\n");
    if (config.attention_pe_id_source == .layout_coordinates) {
        try writer.writeAll("    const pe_x = layout_mod.get_x_coord();\n");
        try writer.writeAll("    const pe_y = layout_mod.get_y_coord();\n");
        try writer.writeAll("    const pe_id: u32 = @as(u32, pe_y) * @as(u32, width) + @as(u32, pe_x);\n");
    }
    try writer.writeAll("    const slot_base: u32 = @as(u32, pe_id) * @as(u32, slots_per_pe);\n");
    const indent: []const u8 = if (multi_q) "        " else "    ";
    const q_index_expr: []const u8 = if (multi_q) "q_row_offset + @as(u32, d)" else "@as(u32, d)";
    const out_d_expr: []const u8 = if (multi_q) "out_row_offset + @as(u32, d)" else "@as(u32, d)";
    const out_max_expr: []const u8 = if (multi_q) "out_row_offset + @as(u32, head_dim)" else "@as(u32, head_dim)";
    const out_sum_expr: []const u8 = if (multi_q) "out_row_offset + @as(u32, head_dim) + 1" else "@as(u32, head_dim) + 1";
    if (multi_q) {
        // Multi-Q (causal-prefill) outer loop: each query position has
        // its own (Q row, output partials triple). Query q sits at
        // absolute position `kv_len - query_seq_len + q` so causal mask
        // becomes per-row (gk > q_pos); sliding_window keeps the
        // global "gk < kv_len - window" form.
        try writer.writeAll("    for (@range(u32, query_seq_len)) |q| {\n");
        try writer.writeAll("        const q_row_offset: u32 = q * @as(u32, head_dim);\n");
        try writer.writeAll("        const out_row_offset: u32 = q * partials_len;\n");
        if (ctx.causal_mode == .causal) {
            try writer.writeAll("        const q_pos: u32 = @as(u32, kv_len) - query_seq_len + q;\n");
        }
    }
    // Local pass 1: per-slot scores + local_max. Tail slots (gk >= kv_len)
    // are masked to the negative sentinel so they cannot win the max and
    // contribute 0 weight after the exp. The sentinel is dtype-aware:
    // f32 keeps `-1.0e30`; f16 uses `-65504.0` (the largest finite
    // negative f16) so tail slots get the same value pre-exp and
    // contribute exp(sentinel - local_max) ≈ 0 after softmax.
    try writer.print("{s}var local_max: {s} = {s};\n", .{ indent, ty, sent });
    try writer.print("{s}for (@range(i16, slots_per_pe)) |k| {{\n", .{indent});
    try writer.print("{s}    const gk: u32 = slot_base + @as(u32, k);\n", .{indent});
    try writer.print("{s}    if (gk >= @as(u32, kv_len)) {{\n", .{indent});
    try writer.print("{s}        attn_scores[@as(u32, k)] = {s};\n", .{ indent, sent });
    try writer.print("{s}        continue;\n", .{indent});
    try writer.print("{s}    }}\n", .{indent});
    try writer.print("{s}    var dot: {s} = 0.0;\n", .{ indent, ty });
    try writer.print("{s}    for (@range(i16, head_dim)) |d| {{\n", .{indent});
    try writer.print(
        "{s}        dot += {s}{s}[{s}] * {s}{s}[@as(u32, k) * @as(u32, head_dim) + @as(u32, d)];\n",
        .{ indent, p, ctx.query.name, q_index_expr, p, ctx.key.name },
    );
    try writer.print("{s}    }}\n", .{indent});
    try writer.print("{s}    var sc: {s} = dot * attn_scale;\n", .{ indent, ty });
    if (multi_q and ctx.causal_mode == .causal) {
        try writer.print("{s}    if (gk > q_pos) {{\n", .{indent});
        try writer.print("{s}        sc = {s};\n", .{ indent, sent });
        try writer.print("{s}    }}\n", .{indent});
    } else if (multi_q and ctx.causal_mode == .sliding_window) {
        const window = ctx.sliding_window_size.?;
        try writer.print("{s}    const window_size: u32 = {d};\n", .{ indent, window });
        try writer.print(
            "{s}    if (@as(u32, kv_len) > window_size and gk < @as(u32, kv_len) - window_size) {{\n",
            .{indent},
        );
        try writer.print("{s}        sc = {s};\n", .{ indent, sent });
        try writer.print("{s}    }}\n", .{indent});
    } else if (!multi_q) {
        try emitCausalMask(writer, ctx.causal_mode, ctx.sliding_window_size, "gk", ctx.elem);
    }
    try writer.print("{s}    attn_scores[@as(u32, k)] = sc;\n", .{indent});
    try writer.print("{s}    if (sc > local_max) {{\n", .{indent});
    try writer.print("{s}        local_max = sc;\n", .{indent});
    try writer.print("{s}    }}\n", .{indent});
    try writer.print("{s}}}\n", .{indent});
    // Local pass 2: weights + local_sum_exp. Tail slots produce
    // weights[k] = exp(sentinel - local_max) which is dtype-zero so they
    // contribute nothing to local_sum_exp or local_O.
    try writer.print("{s}var local_sum_exp: {s} = 0.0;\n", .{ indent, ty });
    try writer.print("{s}for (@range(i16, slots_per_pe)) |k| {{\n", .{indent});
    try writer.print("{s}    const e = math.exp(attn_scores[@as(u32, k)] - local_max);\n", .{indent});
    try writer.print("{s}    attn_scores[@as(u32, k)] = e;\n", .{indent});
    try writer.print("{s}    local_sum_exp += e;\n", .{indent});
    try writer.print("{s}}}\n", .{indent});
    // Local pass 3: un-normalized local_O[d] = sum_k weights[k] * V[k,d].
    // The host stitch divides by global_sum_exp after rescaling each PE
    // by exp(local_max_i - global_max).
    try writer.print("{s}for (@range(i16, head_dim)) |d| {{\n", .{indent});
    try writer.print("{s}    var acc: {s} = 0.0;\n", .{ indent, ty });
    try writer.print("{s}    for (@range(i16, slots_per_pe)) |k| {{\n", .{indent});
    try writer.print(
        "{s}        acc += {s}{s}[@as(u32, k) * @as(u32, head_dim) + @as(u32, d)] * attn_scores[@as(u32, k)];\n",
        .{ indent, p, ctx.value.name },
    );
    try writer.print("{s}    }}\n", .{indent});
    try writer.print(
        "{s}    {s}{s}[{s}] = acc;\n",
        .{ indent, p, ctx.output.name, out_d_expr },
    );
    try writer.print("{s}}}\n", .{indent});
    try writer.print(
        "{s}{s}{s}[{s}] = local_max;\n",
        .{ indent, p, ctx.output.name, out_max_expr },
    );
    try writer.print(
        "{s}{s}{s}[{s}] = local_sum_exp;\n",
        .{ indent, p, ctx.output.name, out_sum_expr },
    );
    if (multi_q) {
        try writer.writeAll("    }\n");
    }
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try body_emit.writeCslExportSymbol(writer, p, ctx.query.name);
    try body_emit.writeCslExportSymbol(writer, p, ctx.key.name);
    try body_emit.writeCslExportSymbol(writer, p, ctx.value.name);
    try body_emit.writeCslExportSymbol(writer, p, ctx.output.name);
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}
