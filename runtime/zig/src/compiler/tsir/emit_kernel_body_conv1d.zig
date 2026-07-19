// emit_kernel_body_conv1d.zig — CSL emit body for SemanticBodyOp
// `conv1d_depthwise`.
//
// Depthwise causal 1-D convolution along the token axis. Each channel
// runs an independent length-`kernel_size` kernel over the padded
// token sequence. DeltaNet uses kernel_size=4 with a per-channel bias
// applied immediately after the conv. Causal pad is left-only so the
// kernel cannot see future tokens.
//
// Layout:
//   input:  [num_tokens * channels]f32   row-major (token, channel)
//   weight: [channels * kernel_size]f32  row-major (channel, k)
//   bias:   [channels]f32                (when has_bias = true)
//   output: [num_tokens * channels]f32   row-major (token, channel)
//
// Math:
//   for t in 0..num_tokens:
//     for c in 0..channels:
//       acc = bias[c] (if has_bias else 0)
//       for k in 0..kernel_size:
//         t_in = t - (kernel_size - 1 - k)  // causal pad
//         if t_in >= 0:
//           acc += input[t_in * channels + c] * weight[c * kernel_size + k]
//       output[t * channels + c] = acc
//
// Single-PE bootstrap canary surface.

const std = @import("std");
const schema = @import("schema.zig");
const body_emit = @import("emit_kernel_body.zig");

pub fn emitCslConv1DDepthwise(
    writer: anytype,
    func: schema.SemanticFunction,
    config: *const body_emit.Config,
) body_emit.EmitError!void {
    const input = try body_emit.bindingForRole(func, .input);
    const weight = try body_emit.bindingForRole(func, .weight);
    const output = try body_emit.bindingForRole(func, .output);
    const elem = output.elem;
    try body_emit.requireSupportedComputeElem(elem);
    try body_emit.requireElem(input, elem);
    try body_emit.requireElem(weight, elem);
    try body_emit.requireElem(output, elem);

    const body = func.body.conv1d_depthwise orelse return error.InvalidBodyContract;
    if (body.channels == 0) return error.InvalidBodyContract;
    if (body.kernel_size == 0) return error.InvalidBodyContract;

    const bias_binding: ?schema.BufferBinding = if (body.has_bias)
        body_emit.bindingForRole(func, .bias) catch return error.InvalidBodyContract
    else
        null;
    if (bias_binding) |b| try body_emit.requireElem(b, elem);

    const p = config.var_prefix;
    const ty = body_emit.cslElemName(elem);
    try writer.writeAll("param memcpy_params;\n");
    try writer.print("const channels: i16 = {d};\n", .{body.channels});
    try writer.print("const kernel_size: i16 = {d};\n", .{body.kernel_size});
    try writer.writeAll("param num_tokens: i16;\n");
    try writer.writeAll("const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try body_emit.writeCslBufferArray(writer, p, input.name, "num_tokens * channels", ty);
    try body_emit.writeCslBufferArray(writer, p, weight.name, "channels * kernel_size", ty);
    try body_emit.writeCslBufferArray(writer, p, output.name, "num_tokens * channels", ty);
    if (bias_binding) |b| {
        try body_emit.writeCslBufferArray(writer, p, b.name, "channels", ty);
    }
    try body_emit.writeCslBufferPointer(writer, p, input.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, weight.name, ty);
    try body_emit.writeCslBufferPointer(writer, p, output.name, ty);
    if (bias_binding) |b| try body_emit.writeCslBufferPointer(writer, p, b.name, ty);
    try writer.writeAll("\n");
    try writer.writeAll("fn compute() void {\n");
    try writer.writeAll("    for (@range(i16, num_tokens)) |t| {\n");
    try writer.writeAll("        for (@range(i16, channels)) |c| {\n");
    if (bias_binding) |b| {
        try writer.print(
            "            var acc: {s} = {s}{s}[@as(u32, c)];\n",
            .{ ty, p, b.name },
        );
    } else {
        try writer.print("            var acc: {s} = 0.0;\n", .{ty});
    }
    try writer.writeAll("            for (@range(i16, kernel_size)) |k| {\n");
    // Causal pad: kernel index k contributes from token (t - (kernel_size - 1 - k)).
    try writer.writeAll("                const t_in: i16 = t - (kernel_size - 1 - k);\n");
    try writer.writeAll("                if (t_in >= 0) {\n");
    try writer.print(
        "                    acc += {s}{s}[@as(u32, t_in) * @as(u32, channels) + @as(u32, c)] * {s}{s}[@as(u32, c) * @as(u32, kernel_size) + @as(u32, k)];\n",
        .{ p, input.name, p, weight.name },
    );
    try writer.writeAll("                }\n");
    try writer.writeAll("            }\n");
    try writer.print(
        "            {s}{s}[@as(u32, t) * @as(u32, channels) + @as(u32, c)] = acc;\n",
        .{ p, output.name },
    );
    try writer.writeAll("        }\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    sys_mod.unblock_cmd_stream();\n");
    try writer.writeAll("}\n\n");
    try writer.writeAll("comptime {\n");
    try body_emit.writeCslExportSymbol(writer, p, input.name);
    try body_emit.writeCslExportSymbol(writer, p, weight.name);
    try body_emit.writeCslExportSymbol(writer, p, output.name);
    if (bias_binding) |b| try body_emit.writeCslExportSymbol(writer, p, b.name);
    try writer.writeAll("    @export_symbol(compute);\n");
    try writer.writeAll("}\n");
}
