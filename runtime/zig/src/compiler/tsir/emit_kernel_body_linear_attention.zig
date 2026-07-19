// emit_kernel_body_linear_attention.zig — CSL emit body for
// SemanticBodyOp `linear_attention` (gated DeltaNet).
//
// Per-token recurrent state update + readout. Single-Q (decode-shape)
// canary surface; multi-Q prefill is a follow-up that reuses this body
// inside an outer query-row loop the same way attention_scores does.
//
// State buffer: linear_state has shape [value_dim_per_pe * key_dim]f32
// per PE. value_dim is sharded across pe_y so the per-PE state fits
// the WSE-3 48 KiB SRAM budget (at value_dim=128, key_dim=128, two PEs
// per head pair: 64 * 128 * 4 = 32 KiB per PE). output[d] only reduces
// over k, so each PE owns its d-block end-to-end with no cross-PE
// reduction. Q, gate, and output stream are also sharded by d to match.
// K and V are broadcast (every PE needs the full key/value vector).
//
// The bootstrap canary covers `norm_mode = .shared` (one A_log scalar
// per head pair, no dt_bias) because that's the simplest closed form to
// oracle. `.per_head` with time-varying dt_bias is an explicit
// `error.InvalidBodyContract` until the conv1d → A_log decay path
// lands as a separate composition.
//
// Math (shared-norm form, per PE owning d-block):
//   alpha = 1 - exp(-A_log_shared)              // per-head scalar in (0, 1)
//   beta  = sigmoid(gate)                       // per-d gate
//   for d in d-block:
//     delta[d, k] = alpha * (q[d] - dot(state[d, :], k_in)) * k_in[k]
//     state[d, k] = (1 - alpha) * state[d, k] + delta[d, k]
//     output[d]   = sum_k state[d, k] * v[k] + beta[d] * q[d]
//
// Bindings: query, key, value, gate (β stream), linear_state (R/W),
// output. Body params declared on `LinearAttentionBody`. Layout passes
// value_dim_per_pe via @set_tile_code; key_dim and full value_dim are
// emitted as compile-time consts from the body.

const std = @import("std");
const schema = @import("schema.zig");
const body_emit = @import("emit_kernel_body.zig");

pub fn emitCslLinearAttention(
    writer: anytype,
    func: schema.SemanticFunction,
    config: *const body_emit.Config,
) body_emit.EmitError!void {
    const query = try body_emit.bindingForRole(func, .query);
    const key = try body_emit.bindingForRole(func, .key);
    const value = try body_emit.bindingForRole(func, .value);
    const gate = try body_emit.bindingForRole(func, .gate);
    const linear_state = try body_emit.bindingForRole(func, .linear_state);
    const output = try body_emit.bindingForRole(func, .output);
    const elem = output.elem;
    try body_emit.requireSupportedComputeElem(elem);
    try body_emit.requireElem(query, elem);
    try body_emit.requireElem(key, elem);
    try body_emit.requireElem(value, elem);
    try body_emit.requireElem(gate, elem);
    try body_emit.requireElem(linear_state, elem);
    try body_emit.requireElem(output, elem);
    if (!linear_state.read_write) return error.InvalidBodyContract;

    const body = func.body.linear_attention orelse return error.InvalidBodyContract;
    if (body.key_dim == 0 or body.value_dim == 0) return error.InvalidBodyContract;
    if (body.key_heads == 0 or body.value_heads == 0) return error.InvalidBodyContract;
    if (body.norm_mode != .shared) return error.InvalidBodyContract;
    if (body.has_dt_bias) return error.InvalidBodyContract;

    const p = config.var_prefix;
    const ty = body_emit.cslElemName(elem);
    try writer.writeAll("param memcpy_params;\n");
    try writer.print("const key_dim: i16 = {d};\n", .{body.key_dim});
    try writer.print("const value_dim: i16 = {d};\n", .{body.value_dim});
    // value_dim_per_pe is supplied by the layout via @set_tile_code; each
    // PE owns value_dim_per_pe rows of the state matrix and the matching
    // slice of query/gate/output. Keeping it as a layout-provided param
    // (rather than a body const) lets the host plan choose a sharding
    // factor without re-emitting the kernel.
    try writer.writeAll("param value_dim_per_pe: i16;\n");
    try writer.print("param a_log: {s};\n", .{ty});
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try writer.writeAll("const math = @import_module(\"<math>\");\n");
    try body_emit.writeCslBufferArray(writer, p, query.name, "value_dim_per_pe", ty);
    try body_emit.writeCslBufferArray(writer, p, key.name, "key_dim", ty);
    try body_emit.writeCslBufferArray(writer, p, value.name, "key_dim", ty);
    try body_emit.writeCslBufferArray(writer, p, gate.name, "value_dim_per_pe", ty);
    try body_emit.writeCslBufferArray(writer, p, linear_state.name, "value_dim_per_pe * key_dim", ty);
    try body_emit.writeCslBufferArray(writer, p, output.name, "value_dim_per_pe", ty);
    try body_emit.writeCslBufferPointer(writer, p, query.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, key.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, value.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, gate.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, linear_state.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, output.name, ty);
    try writer.writeAll("\n");
    try writer.writeAll("fn compute() void {\n");
    // alpha = 1 - exp(-A_log) clamped to (0, 1) by the host's a_log >= 0
    // contract. exp(-A_log) is the per-step state retention; alpha is
    // the new-information weight in the SSM update.
    try writer.print("    const alpha: {s} = 1.0 - math.exp(-a_log);\n", .{ty});
    try writer.print("    const decay: {s} = 1.0 - alpha;\n", .{ty});
    // Pass 1: for each value-dim row d this PE owns, compute scalar
    //   prev_dot = sum_k state[d, k] * k_in[k]
    // and the per-(d, k) delta and updated state.
    try writer.writeAll("    for (@range(i16, value_dim_per_pe)) |d| {\n");
    try writer.print("        var prev_dot: {s} = 0.0;\n", .{ty});
    try writer.writeAll("        for (@range(i16, key_dim)) |k| {\n");
    try writer.print(
        "            prev_dot += {s}{s}[@as(u32, d) * @as(u32, key_dim) + @as(u32, k)] * {s}{s}[@as(u32, k)];\n",
        .{ p, linear_state.name, p, key.name },
    );
    try writer.writeAll("        }\n");
    try writer.print(
        "        const q_d: {s} = {s}{s}[@as(u32, d)];\n",
        .{ ty, p, query.name },
    );
    try writer.print("        const correction: {s} = q_d - prev_dot;\n", .{ty});
    try writer.print("        const scaled_correction: {s} = alpha * correction;\n", .{ty});
    try writer.writeAll("        for (@range(i16, key_dim)) |k| {\n");
    try writer.print(
        "            const k_in: {s} = {s}{s}[@as(u32, k)];\n",
        .{ ty, p, key.name },
    );
    try writer.print(
        "            const idx: u32 = @as(u32, d) * @as(u32, key_dim) + @as(u32, k);\n",
        .{},
    );
    try writer.print(
        "            const prev_state: {s} = {s}{s}[idx];\n",
        .{ ty, p, linear_state.name },
    );
    try writer.print("            const delta: {s} = scaled_correction * k_in;\n", .{ty});
    try writer.print(
        "            {s}{s}[idx] = decay * prev_state + delta;\n",
        .{ p, linear_state.name },
    );
    try writer.writeAll("        }\n");
    try writer.writeAll("    }\n");
    // Pass 2: output[d] = sum_k state[d, k] * v[k] + sigmoid(gate[d]) * q[d].
    // The gate stream provides the residual mix-in; sigmoid here matches
    // the DeltaNet `attentionOutputGate=sigmoid` form. The query value
    // is the residual carrier (input to FFN if the SSM were a no-op).
    try writer.writeAll("    for (@range(i16, value_dim_per_pe)) |d| {\n");
    try writer.print("        var acc: {s} = 0.0;\n", .{ty});
    try writer.writeAll("        for (@range(i16, key_dim)) |k| {\n");
    try writer.print(
        "            acc += {s}{s}[@as(u32, d) * @as(u32, key_dim) + @as(u32, k)] * {s}{s}[@as(u32, k)];\n",
        .{ p, linear_state.name, p, value.name },
    );
    try writer.writeAll("        }\n");
    try writer.print(
        "        const g: {s} = {s}{s}[@as(u32, d)];\n",
        .{ ty, p, gate.name },
    );
    try writer.print("        const sigmoid_g: {s} = 1.0 / (1.0 + math.exp(-g));\n", .{ty});
    try writer.print(
        "        {s}{s}[@as(u32, d)] = acc + sigmoid_g * {s}{s}[@as(u32, d)];\n",
        .{ p, output.name, p, query.name },
    );
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try body_emit.writeCslExportSymbol(writer, p, query.name);
    try body_emit.writeCslExportSymbol(writer, p, key.name);
    try body_emit.writeCslExportSymbol(writer, p, value.name);
    try body_emit.writeCslExportSymbol(writer, p, gate.name);
    try body_emit.writeCslExportSymbol(writer, p, linear_state.name);
    try body_emit.writeCslExportSymbol(writer, p, output.name);
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}
