// emit_kernel_body_gated.zig — CSL emit body for the gated-activation
// `SemanticBodyOp` family (`gelu_gated`, `silu_gated`, `sigmoid_gated`).
//
// Lifted out of `emit_kernel_body.zig` so the parent file stays under the
// 999-line repo limit. The dispatch in `emit_kernel_body.zig:emitCsl`
// forwards `.gelu_gated` / `.silu_gated` / `.sigmoid_gated` here.
//
// All three variants share the same binding shape (`gate`, `input`,
// `output`) and the same outer compute kernel
// (`output[i] = act(gate[i]) * input[i]`); the only difference is the
// per-element non-linearity emitted as a CSL helper function.
//
//   .gelu    -> tanh-approximation GELU (Doppler MLP form)
//   .silu    -> `x / (1 + exp(-x))` (SwiGLU FFN inner activation)
//   .sigmoid -> `1 / (1 + exp(-x))` (Qwen `attentionOutputGate`)

const schema = @import("schema.zig");
const body_emit = @import("emit_kernel_body.zig");

pub const Kind = enum { gelu, silu, sigmoid };

pub fn emitCsl(
    writer: anytype,
    func: schema.SemanticFunction,
    config: *const body_emit.Config,
    kind: Kind,
) body_emit.EmitError!void {
    const gate = try body_emit.bindingForRole(func, .gate);
    const input = try body_emit.bindingForRole(func, .input);
    const output = try body_emit.bindingForRole(func, .output);
    const elem = output.elem;
    try body_emit.requireSupportedComputeElem(elem);
    try body_emit.requireElem(gate, elem);
    try body_emit.requireElem(input, elem);
    try body_emit.requireElem(output, elem);

    const p = config.var_prefix;
    const ty = body_emit.cslElemName(elem);
    try writer.writeAll("param memcpy_params;\n");
    if (config.chunk_size_default) |value| {
        try writer.print("param chunk_size: i16 = {d};\n", .{value});
    } else {
        try writer.writeAll("param chunk_size: i16;\n");
    }
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try writer.writeAll("const math = @import_module(\"<math>\");\n");
    if (kind == .gelu) {
        try writer.print("const GELU_A: {s} = 0.7978845608028654;\n", .{ty});
        try writer.print("const GELU_B: {s} = 0.044715;\n", .{ty});
    }
    try body_emit.writeCslBufferArray(writer, p, gate.name, "chunk_size", ty);
    try body_emit.writeCslBufferArray(writer, p, input.name, "chunk_size", ty);
    try body_emit.writeCslBufferArray(writer, p, output.name, "chunk_size", ty);
    try body_emit.writeCslBufferPointer(writer, p, gate.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, input.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, output.name, ty);
    try writer.writeAll("\n");
    // Each kind emits its own helper function name (`gelu` / `silu` /
    // `sigmoid`) rather than a generic `act`. This keeps existing
    // gelu_gated CSL byte-comparisons (tests, receipts, host-plan
    // compile-source pins) stable when sigmoid_gated and silu_gated
    // join the dispatch.
    const fn_name = switch (kind) {
        .gelu => "gelu",
        .silu => "silu",
        .sigmoid => "sigmoid",
    };
    try writer.print("fn {s}(x: {s}) {s} {{\n", .{ fn_name, ty, ty });
    switch (kind) {
        .gelu => {
            try writer.writeAll("    var inner = GELU_A * (x + GELU_B * x * x * x);\n");
            // Saturation clamping matches the hand-written
            // `emit_csl_semantic_ops.emitGeluPe` body so live HostPlan
            // numerical behavior is preserved when delegating through TSIR.
            // tanh saturates well before ±15, so the bound is conservative.
            try writer.writeAll("    if (inner < -15.0) inner = -15.0;\n");
            try writer.writeAll("    if (inner > 15.0) inner = 15.0;\n");
            try writer.writeAll("    return 0.5 * x * (1.0 + math.tanh(inner));\n");
        },
        .silu => {
            // silu(x) = x / (1 + exp(-x)). Clamp the negation to ±15 so
            // exp(-x) cannot blow up to inf for very negative x; the
            // value of 1/(1+e^15) is f16/f32-zero already.
            try writer.writeAll("    var z = -x;\n");
            try writer.writeAll("    if (z < -15.0) z = -15.0;\n");
            try writer.writeAll("    if (z > 15.0) z = 15.0;\n");
            try writer.writeAll("    return x / (1.0 + math.exp(z));\n");
        },
        .sigmoid => {
            // sigmoid(x) = 1 / (1 + exp(-x)). Same clamp as silu so the
            // exp call cannot overflow.
            try writer.writeAll("    var z = -x;\n");
            try writer.writeAll("    if (z < -15.0) z = -15.0;\n");
            try writer.writeAll("    if (z > 15.0) z = 15.0;\n");
            try writer.writeAll("    return 1.0 / (1.0 + math.exp(z));\n");
        },
    }
    try writer.writeAll("}\n\n");
    try writer.writeAll("fn compute() void {\n");
    try writer.writeAll("    for (@range(i16, chunk_size)) |i| {\n");
    try writer.writeAll("        const idx = @as(u32, i);\n");
    try writer.print(
        "        {s}{s}[idx] = {s}({s}{s}[idx]) * {s}{s}[idx];\n",
        .{ p, output.name, fn_name, p, gate.name, p, input.name },
    );
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try body_emit.writeCslExportSymbol(writer, p, gate.name);
    try body_emit.writeCslExportSymbol(writer, p, input.name);
    try body_emit.writeCslExportSymbol(writer, p, output.name);
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}
