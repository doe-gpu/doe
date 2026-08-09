// emit_csl_sample.zig — CSL PE program for token sampling.
//
// Maps Doppler's sample.wgsl pattern to CSL for bounded smoke execution.
// Each PE emits the local argmax for its logit chunk; host-side parity
// remains outside this kernel-level smoke.
//
// Buffer names are resolved from the IR module.

const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const W = @import("emit_csl_ir_walk.zig");
const storage_emit = @import("csl_storage_emit.zig");

const emitBuf = storage_emit.emitBuffer;
const emitPtr = storage_emit.emitPointer;
const emitExport = storage_emit.emitExport;

pub const EmitError = W.EmitError;

pub fn emit(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.SampleInfo,
) EmitError!void {
    const logits = module.globals.items[info.logits_global].name;
    const tokens = module.globals.items[info.tokens_global].name;

    try W.write(buf, pos, "// PE program: token sampling (auto-generated from WGSL)\n");
    try W.write(buf, pos, "// Bounded smoke: local argmax over each PE logit chunk.\n\n");

    try W.write(buf, pos, "param memcpy_params;\n");
    try W.write(buf, pos, "param pe_id: i16;\n");
    try W.write(buf, pos, "param num_pes: i16;\n");
    try W.write(buf, pos, "param chunk_size: i16;\n");
    try W.write(buf, pos, "param reduce_color: color;\n");
    try W.write(buf, pos, "param temperature: f32 = 1.0;\n");
    try W.write(buf, pos, "param softcap: f32 = 0.0;\n\n");

    try W.write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try W.write(buf, pos, "const math = @import_module(\"<math>\");\n\n");

    // Buffers
    try emitBuf(buf, pos, logits, "[chunk_size]f32");
    try W.write(buf, pos, "var output_token: [1]u32 = @zeros([1]u32);\n\n");
    try emitPtr(buf, pos, logits, "f32");
    try W.write(buf, pos, "var ");
    try W.write(buf, pos, tokens);
    try W.write(buf, pos, "_ptr: [*]u32 = &output_token;\n\n");

    // State
    try W.write(buf, pos, "var local_max_val: f32 = -3.4028235e+38;\n");
    try W.write(buf, pos, "var local_max_idx: u32 = 0;\n");
    try W.write(buf, pos, "\n");

    try W.write(buf, pos, "fn compute() void {\n");
    try W.write(buf, pos, "    local_max_val = -3.4028235e+38;\n");
    try W.write(buf, pos, "    local_max_idx = 0;\n");
    try W.write(buf, pos, "    const offset = @as(u32, pe_id) * @as(u32, chunk_size);\n\n");
    try W.write(buf, pos, "    for (@range(i16, chunk_size)) |i| {\n");
    try W.write(buf, pos, "        var val = ");
    try W.write(buf, pos, logits);
    try W.write(buf, pos, "[@as(u32, i)];\n");
    try W.write(buf, pos, "        if (softcap != 0.0) val = softcap * math.tanh(val / softcap);\n");
    try W.write(buf, pos, "        val /= temperature;\n");
    try W.write(buf, pos, "        if (val > local_max_val) {\n");
    try W.write(buf, pos, "            local_max_val = val;\n");
    try W.write(buf, pos, "            local_max_idx = offset + @as(u32, i);\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "    }\n\n");
    try W.write(buf, pos, "    output_token[0] = local_max_idx;\n");
    try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "}\n\n");

    try W.write(buf, pos, "comptime {\n");
    try emitExport(buf, pos, logits);
    try W.write(buf, pos, "    @export_symbol(");
    try W.write(buf, pos, tokens);
    try W.write(buf, pos, "_ptr, \"");
    try W.write(buf, pos, tokens);
    try W.write(buf, pos, "\");\n");
    try W.write(buf, pos, "    @export_symbol(compute);\n");
    try W.write(buf, pos, "}\n");
}
