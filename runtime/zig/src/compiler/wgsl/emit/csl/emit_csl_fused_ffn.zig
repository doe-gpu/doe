// emit_csl_fused_ffn.zig — CSL PE program for SiLU-gated FFN.
//
// Fuses gate_proj, up_proj, SiLU activation, and element-wise multiply:
//   output = silu(gate_proj(x)) * up_proj(x)
//
// Common in Qwen/Llama FFN blocks. Each PE holds a slice of the weight
// matrices and computes partial output rows. collectives_2d reduces the
// gate/up vectors before the activation is applied on the row root.

const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const storage_emit = @import("csl_storage_emit.zig");
const W = @import("emit_csl_ir_walk.zig");

pub const EmitError = W.EmitError;
const emitStorageExports = storage_emit.emitPointerExports;

pub fn emit(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.FusedFfnInfo,
) EmitError!void {
    const inp = module.globals.items[info.input_global].name;
    const gate = module.globals.items[info.gate_weight_global].name;
    const up = module.globals.items[info.up_weight_global].name;
    const out = module.globals.items[info.output_global].name;

    try W.write(buf, pos, "// PE program: fused SiLU-gated FFN (auto-generated from WGSL)\n");
    try W.write(buf, pos, "// output = silu(gate(x)) * up(x), distributed across PEs.\n\n");

    try W.write(buf, pos, "param memcpy_params;\n");
    try W.write(buf, pos, "param c2d_params;\n");
    try W.write(buf, pos, "param pe_id: i16;\n");
    try W.write(buf, pos, "param num_pes: i16;\n");
    try W.write(buf, pos, "\n");
    try W.write(buf, pos, "param in_dim: i16 = 1152;\n");
    try W.write(buf, pos, "param out_dim: i16 = 1152;\n");
    try W.write(buf, pos, "param in_per_pe: i16 = 1152;\n\n");

    try W.write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try W.write(buf, pos, "const mpi_x = @import_module(\"<collectives_2d/pe>\", .{\n");
    try W.write(buf, pos, "    .dim_params = c2d_params.x,\n");
    try W.write(buf, pos, "    .queues = [2]u16{2, 4},\n");
    try W.write(buf, pos, "    .dest_dsr_ids = [1]u16{1},\n");
    try W.write(buf, pos, "    .src0_dsr_ids = [1]u16{1},\n");
    try W.write(buf, pos, "    .src1_dsr_ids = [1]u16{1},\n");
    try W.write(buf, pos, "});\n");
    try W.write(buf, pos, "const math = @import_module(\"<math>\");\n\n");

    try emitStoragePtrs(buf, pos, module);

    try W.write(buf, pos, "var gate_partial: [out_dim]f32 = @zeros([out_dim]f32);\n");
    try W.write(buf, pos, "var up_partial: [out_dim]f32 = @zeros([out_dim]f32);\n\n");
    try W.write(buf, pos, "var gate_reduced: [out_dim]f32 = @zeros([out_dim]f32);\n");
    try W.write(buf, pos, "var up_reduced: [out_dim]f32 = @zeros([out_dim]f32);\n\n");

    try W.write(buf, pos, "const gate_reduce_done_id: local_task_id = @get_local_task_id(12);\n");
    try W.write(buf, pos, "const up_reduce_done_id: local_task_id = @get_local_task_id(13);\n\n");

    // SiLU: x * sigmoid(x) = x / (1 + exp(-x))
    try W.write(buf, pos, "fn silu(x: f32) f32 {\n");
    try W.write(buf, pos, "    return x / (1.0 + math.exp(-x));\n");
    try W.write(buf, pos, "}\n\n");

    // Phase 1: local matmul for gate and up projections
    try W.write(buf, pos, "fn compute() void {\n");
    try W.write(buf, pos, "    for (@range(i16, out_dim)) |row| {\n");
    try W.write(buf, pos, "        var gate_sum: f32 = 0.0;\n");
    try W.write(buf, pos, "        var up_sum: f32 = 0.0;\n");
    try W.write(buf, pos, "        for (@range(i16, in_per_pe)) |col| {\n");
    try W.write(buf, pos, "            const x = ");
    try W.write(buf, pos, inp);
    try W.write(buf, pos, "[@as(u32, col)];\n");
    try W.write(buf, pos, "            const widx = @as(u32, row) * @as(u32, in_per_pe) + @as(u32, col);\n");
    try W.write(buf, pos, "            gate_sum += x * ");
    try W.write(buf, pos, gate);
    try W.write(buf, pos, "[widx];\n");
    try W.write(buf, pos, "            up_sum += x * ");
    try W.write(buf, pos, up);
    try W.write(buf, pos, "[widx];\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        gate_partial[@as(u32, row)] = gate_sum;\n");
    try W.write(buf, pos, "        up_partial[@as(u32, row)] = up_sum;\n");
    try W.write(buf, pos, "    }\n\n");

    try W.write(buf, pos, "    if (num_pes == 1) {\n");
    try W.write(buf, pos, "        for (@range(i16, out_dim)) |row| {\n");
    try W.write(buf, pos, "            ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, row)] = silu(gate_partial[@as(u32, row)]) * up_partial[@as(u32, row)];\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "    } else {\n");
    try W.write(buf, pos, "        mpi_x.init();\n");
    try W.write(buf, pos, "        mpi_x.reduce_fadds(@as(u16, num_pes - 1), @ptrcast([*]f32, &gate_partial), @ptrcast([*]f32, &gate_reduced), @as(u16, out_dim), gate_reduce_done_id);\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "}\n\n");

    // Phase 2: reduce the up projection, then apply SiLU gating at the row root.
    try W.write(buf, pos, "task gate_reduce_done_task() void {\n");
    try W.write(buf, pos, "    mpi_x.reduce_fadds(@as(u16, num_pes - 1), @ptrcast([*]f32, &up_partial), @ptrcast([*]f32, &up_reduced), @as(u16, out_dim), up_reduce_done_id);\n");
    try W.write(buf, pos, "}\n\n");

    try W.write(buf, pos, "task up_reduce_done_task() void {\n");
    try W.write(buf, pos, "    if (pe_id == num_pes - 1) {\n");
    try W.write(buf, pos, "        for (@range(i16, out_dim)) |row| {\n");
    try W.write(buf, pos, "            ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, row)] = silu(gate_reduced[@as(u32, row)]) * up_reduced[@as(u32, row)];\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "}\n\n");

    try W.write(buf, pos, "comptime {\n");
    try W.write(buf, pos, "    @bind_local_task(gate_reduce_done_task, gate_reduce_done_id);\n");
    try W.write(buf, pos, "    @bind_local_task(up_reduce_done_task, up_reduce_done_id);\n");
    try emitStorageExports(buf, pos, module);
    try W.write(buf, pos, "    @export_symbol(compute);\n");
    try W.write(buf, pos, "}\n");
}

fn emitStoragePtrs(buf: []u8, pos: *usize, module: *const ir.Module) EmitError!void {
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage) continue;
        try W.write(buf, pos, "var ");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, ": [*]f32 = undefined;\n");
        try W.write(buf, pos, "var ");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, "_ptr: [*]f32 = &");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, ";\n");
    }
    try W.write(buf, pos, "\n");
}
