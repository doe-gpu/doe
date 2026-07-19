// emit_csl_fused.zig — CSL PE program for fused GEMV + Q4K dequant.
//
// On-the-fly dequantization during matrix-vector multiply. Each PE(pe_x,
// pe_y) holds an (in_dim_shard x out_dim_shard) slice of the quantized
// weight matrix, dequants it and computes partial dot products, then a
// collectives_2d reduce per row folds the partial sums. Host
// D2H reads from each row's sink PE (pe_x=width-1) at every pe_y and
// concatenates along the out_dim axis to reassemble the full output
// vector.
//
// Maps from Doppler's fused_matmul_q4.wgsl. Buffer names from IR.
//
// The kernel parameterizes the per-PE output slice as `out_dim_per_pe`
// (equal to ceil(out_dim_total / height)) instead of the full
// vocab-sized `out_dim`. See
// `bench/out/cslc-lmhead-2d-probe/probe-result.json` for the feasibility
// evidence: at Gemma 4 E2B manifest shape (out_dim_total=1331,
// num_blocks_per_row=2, grid=197x84) the probe-verified
// `out_dim_per_pe=16` gives a per-PE weight footprint of
// `16 * 2 * 144 = 4608 B` (vs 383 KiB pre-shard), which fits under the
// ~48 KiB per-PE `.data.hi` budget. The pre-shard weight array
// `[out_dim_total * num_blocks_per_row * Q4K_BLOCK_BYTES_I16]u8`
// triggered the `integer value 383328 cannot be coerced to type 'i16'`
// overflow.
//
// When `height=1` the kernel collapses to the pre-shard 1-D shape: the
// layout still shards in_dim across width and reduces east-west; each
// PE holds the full output (out_dim_per_pe = out_dim_total). Defaults
// in `emit_csl_layout.zig:emitFusedGemvLayout` preserve that behaviour
// so older callers that don't plumb `height` / `out_dim_per_pe` through
// HostPlan keep compiling.
//
// Silent-divergence hazard: calling the kernel with `out_dim_per_pe <
// out_dim_total` WITHOUT an accompanying `height > 1` layout is
// undefined — each row produces the same `out_dim_per_pe` slice and
// host D2H reassembly would duplicate that slice across the full
// out_dim axis. The layout-level `height` + `out_dim_per_pe` pair is
// the contract.

const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const W = @import("emit_csl_ir_walk.zig");

pub const EmitError = W.EmitError;

pub fn emit(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.FusedGemvDequantInfo,
) EmitError!void {
    return emitForElem(buf, pos, module, info, .f32);
}

pub fn emitForElem(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.FusedGemvDequantInfo,
    elem: ir.ScalarType,
) EmitError!void {
    const elem_name = try elemName(elem);
    const is_f16 = elem == .f16;
    const act = module.globals.items[info.activation_global].name;
    const wgt = module.globals.items[info.weight_global].name;
    const out = module.globals.items[info.output_global].name;

    try W.write(buf, pos, "// PE program: fused GEMV + Q4K dequant (auto-generated from WGSL)\n");
    try W.write(buf, pos, "// Each PE dequants its weight slice and computes partial dot products.\n");
    if (is_f16) {
        try W.write(buf, pos, "// collectives_2d reduce_fadds accumulates f32 partials; the sink stores f16 output.\n\n");
    } else {
        try W.write(buf, pos, "// collectives_2d reduce_fadds accumulates the final output vector.\n\n");
    }

    try W.write(buf, pos, "param c2d_params;\n");
    try W.write(buf, pos, "param memcpy_params;\n");
    try W.write(buf, pos, "param pe_id: i16;\n");
    try W.write(buf, pos, "param num_pes: i16;\n");
    try W.write(buf, pos, "\n");

    try W.write(buf, pos, "param out_dim_per_pe: i16;\n");
    try W.write(buf, pos, "param in_dim_per_pe: i16;\n");
    try W.write(buf, pos, "param num_blocks_per_row: i16;\n");
    try W.write(buf, pos, "param host_reduce: i16 = 0;\n\n");

    try W.write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try W.write(buf, pos, "const mpi_x = @import_module(\"<collectives_2d/pe>\", .{\n");
    try W.write(buf, pos, "    .dim_params = c2d_params.x,\n");
    try W.write(buf, pos, "    .queues = [2]u16{2, 4},\n");
    try W.write(buf, pos, "    .dest_dsr_ids = [1]u16{1},\n");
    try W.write(buf, pos, "    .src0_dsr_ids = [1]u16{1},\n");
    try W.write(buf, pos, "    .src1_dsr_ids = [1]u16{1},\n");
    try W.write(buf, pos, "});\n");
    try W.write(buf, pos, "const math = @import_module(\"<math>\");\n\n");

    // Q4K constants
    // Expose i16 aliases for the byte-count constants so array
    // dimensions type-check (CSL array dims are i16). The u32 form is
    // still used for body byte-arithmetic. Same pattern as dequant.
    try W.write(buf, pos, "const QK_K: u32 = 256;\n");
    try W.write(buf, pos, "const QK_K_I16: i16 = 256;\n");
    try W.write(buf, pos, "const Q4K_BLOCK_BYTES: u32 = 144;\n");
    try W.write(buf, pos, "const Q4K_BLOCK_BYTES_I16: i16 = 144;\n\n");

    // Buffers
    try emitBufForElem(buf, pos, act, "[in_dim_per_pe]", elem_name);
    try W.write(buf, pos, "var ");
    try W.write(buf, pos, wgt);
    try W.write(buf, pos, ": [out_dim_per_pe * num_blocks_per_row * Q4K_BLOCK_BYTES_I16]u8 = @zeros([out_dim_per_pe * num_blocks_per_row * Q4K_BLOCK_BYTES_I16]u8);\n");
    try emitBufForElem(buf, pos, out, "[out_dim_per_pe]", elem_name);
    if (is_f16) {
        try W.write(buf, pos, "var partial: [out_dim_per_pe]f32 = @zeros([out_dim_per_pe]f32);\n");
        try W.write(buf, pos, "var reduced: [out_dim_per_pe]f32 = @zeros([out_dim_per_pe]f32);\n");
    } else {
        try emitBufForElem(buf, pos, "partial", "[out_dim_per_pe]", elem_name);
    }
    try W.write(buf, pos, "var weight_col: [out_dim_per_pe]f32 = @zeros([out_dim_per_pe]f32);\n");
    try W.write(buf, pos, "\n");

    try emitPtr(buf, pos, act, elem_name);
    if (is_f16) {
        try W.write(buf, pos, "var partial_ptr: [*]f32 = &partial;\n");
    }
    try W.write(buf, pos, "var ");
    try W.write(buf, pos, wgt);
    try W.write(buf, pos, "_ptr: [*]u8 = &");
    try W.write(buf, pos, wgt);
    try W.write(buf, pos, ";\n");
    try emitPtr(buf, pos, out, elem_name);
    if (is_f16) {
        try W.write(buf, pos, "var reduced_ptr: [*]f32 = &reduced;\n");
    }
    try W.write(buf, pos, "\n");

    try W.write(buf, pos, "const reduce_done_id: local_task_id = @get_local_task_id(12);\n\n");

    // Phase 1: local partial dot products with on-the-fly dequant
    try W.write(buf, pos, "fn compute() void {\n");
    try W.write(buf, pos, "    for (@range(i16, out_dim_per_pe)) |row| {\n");
    try W.write(buf, pos, "        partial[@as(u32, row)] = 0.0;\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "    var partial_dsd = @get_dsd(mem1d_dsd, .{ .tensor_access = |i|{out_dim_per_pe} -> partial[i] });\n");
    try W.write(buf, pos, "    var weight_col_dsd = @get_dsd(mem1d_dsd, .{ .tensor_access = |i|{out_dim_per_pe} -> weight_col[i] });\n\n");
    try W.write(buf, pos, "    for (@range(i16, num_blocks_per_row)) |blk| {\n");
    try W.write(buf, pos, "        const act_off = @as(u32, blk) * QK_K;\n");
    try W.write(buf, pos, "        for (@range(u32, 128)) |i| {\n");
    try W.write(buf, pos, "            for (@range(i16, out_dim_per_pe)) |row| {\n");
    try W.write(buf, pos, "                const row_base = @as(u32, row) * @as(u32, num_blocks_per_row) * Q4K_BLOCK_BYTES;\n");
    try W.write(buf, pos, "                const blk_base = row_base + @as(u32, blk) * Q4K_BLOCK_BYTES;\n");
    try W.write(buf, pos, "                const d_bits = @as(u16, ");
    try W.write(buf, pos, wgt);
    try W.write(buf, pos, "[blk_base]) | (@as(u16, ");
    try W.write(buf, pos, wgt);
    try W.write(buf, pos, "[blk_base + 1]) << 8);\n");
    try W.write(buf, pos, "                const d = @as(f32, @bitcast(f16, d_bits));\n");
    try W.write(buf, pos, "                const byte = ");
    try W.write(buf, pos, wgt);
    try W.write(buf, pos, "[blk_base + 16 + i];\n");
    try W.write(buf, pos, "                weight_col[@as(u32, row)] = @as(f32, byte & 0x0F) * d;\n");
    try W.write(buf, pos, "            }\n");
    try W.write(buf, pos, "            const x_lo = @as(f32, ");
    try W.write(buf, pos, act);
    try W.write(buf, pos, "[act_off + i * 2]);\n");
    try W.write(buf, pos, "            @fmacs(partial_dsd, partial_dsd, weight_col_dsd, x_lo);\n");
    try W.write(buf, pos, "            for (@range(i16, out_dim_per_pe)) |row| {\n");
    try W.write(buf, pos, "                const row_base = @as(u32, row) * @as(u32, num_blocks_per_row) * Q4K_BLOCK_BYTES;\n");
    try W.write(buf, pos, "                const blk_base = row_base + @as(u32, blk) * Q4K_BLOCK_BYTES;\n");
    try W.write(buf, pos, "                const d_bits = @as(u16, ");
    try W.write(buf, pos, wgt);
    try W.write(buf, pos, "[blk_base]) | (@as(u16, ");
    try W.write(buf, pos, wgt);
    try W.write(buf, pos, "[blk_base + 1]) << 8);\n");
    try W.write(buf, pos, "                const d = @as(f32, @bitcast(f16, d_bits));\n");
    try W.write(buf, pos, "                const byte = ");
    try W.write(buf, pos, wgt);
    try W.write(buf, pos, "[blk_base + 16 + i];\n");
    try W.write(buf, pos, "                weight_col[@as(u32, row)] = @as(f32, byte >> 4) * d;\n");
    try W.write(buf, pos, "            }\n");
    try W.write(buf, pos, "            const x_hi = @as(f32, ");
    try W.write(buf, pos, act);
    try W.write(buf, pos, "[act_off + i * 2 + 1]);\n");
    try W.write(buf, pos, "            @fmacs(partial_dsd, partial_dsd, weight_col_dsd, x_hi);\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "    }\n\n");

    try W.write(buf, pos, "    if (host_reduce != 0) {\n");
    try W.write(buf, pos, "        sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "        return;\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "    mpi_x.init();\n");
    if (is_f16) {
        try W.write(buf, pos, "    mpi_x.reduce_fadds(@as(u16, num_pes - 1), @ptrcast([*]f32, &partial), @ptrcast([*]f32, &reduced), @as(u16, out_dim_per_pe), reduce_done_id);\n");
    } else {
        try W.write(buf, pos, "    mpi_x.reduce_fadds(@as(u16, num_pes - 1), @ptrcast([*]f32, &partial), @ptrcast([*]f32, &");
        try W.write(buf, pos, out);
        try W.write(buf, pos, "), @as(u16, out_dim_per_pe), reduce_done_id);\n");
    }
    try W.write(buf, pos, "}\n\n");

    if (is_f16) {
        try W.write(buf, pos, "task reduce_done_task() void {\n");
        try W.write(buf, pos, "    if (pe_id == num_pes - 1) {\n");
        try W.write(buf, pos, "        for (@range(i16, out_dim_per_pe)) |row| {\n");
        try W.write(buf, pos, "            ");
        try W.write(buf, pos, out);
        try W.write(buf, pos, "[@as(u32, row)] = @as(f16, reduced[@as(u32, row)]);\n");
        try W.write(buf, pos, "        }\n");
        try W.write(buf, pos, "    }\n");
        try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
        try W.write(buf, pos, "}\n\n");
    } else {
        try W.write(buf, pos, "task reduce_done_task() void {\n");
        try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
        try W.write(buf, pos, "}\n\n");
    }

    try W.write(buf, pos, "comptime {\n");
    try W.write(buf, pos, "    @bind_local_task(reduce_done_task, reduce_done_id);\n");
    try emitExport(buf, pos, act);
    if (is_f16) {
        try W.write(buf, pos, "    @export_symbol(partial_ptr, \"partial\");\n");
    }
    try emitExportTyped(buf, pos, wgt);
    try emitExport(buf, pos, out);
    if (is_f16) {
        try W.write(buf, pos, "    @export_symbol(reduced_ptr, \"reduced\");\n");
    }
    try W.write(buf, pos, "    @export_symbol(compute);\n");
    try W.write(buf, pos, "}\n");
}

fn elemName(elem: ir.ScalarType) EmitError![]const u8 {
    return switch (elem) {
        .f32 => "f32",
        .f16 => "f16",
        else => error.InvalidIr,
    };
}

fn emitBuf(buf: []u8, pos: *usize, name: []const u8, ty: []const u8) EmitError!void {
    try W.write(buf, pos, "var ");
    try W.write(buf, pos, name);
    try W.write(buf, pos, ": ");
    try W.write(buf, pos, ty);
    try W.write(buf, pos, " = @zeros(");
    try W.write(buf, pos, ty);
    try W.write(buf, pos, ");\n");
}

fn emitBufForElem(buf: []u8, pos: *usize, name: []const u8, prefix: []const u8, elem: []const u8) EmitError!void {
    try W.write(buf, pos, "var ");
    try W.write(buf, pos, name);
    try W.write(buf, pos, ": ");
    try W.write(buf, pos, prefix);
    try W.write(buf, pos, elem);
    try W.write(buf, pos, " = @zeros(");
    try W.write(buf, pos, prefix);
    try W.write(buf, pos, elem);
    try W.write(buf, pos, ");\n");
}

fn emitPtr(buf: []u8, pos: *usize, name: []const u8, elem: []const u8) EmitError!void {
    try W.write(buf, pos, "var ");
    try W.write(buf, pos, name);
    try W.write(buf, pos, "_ptr: [*]");
    try W.write(buf, pos, elem);
    try W.write(buf, pos, " = &");
    try W.write(buf, pos, name);
    try W.write(buf, pos, ";\n");
}

fn emitExport(buf: []u8, pos: *usize, name: []const u8) EmitError!void {
    try W.write(buf, pos, "    @export_symbol(");
    try W.write(buf, pos, name);
    try W.write(buf, pos, "_ptr, \"");
    try W.write(buf, pos, name);
    try W.write(buf, pos, "\");\n");
}

fn emitExportTyped(buf: []u8, pos: *usize, name: []const u8) EmitError!void {
    try W.write(buf, pos, "    @export_symbol(");
    try W.write(buf, pos, name);
    try W.write(buf, pos, "_ptr, \"");
    try W.write(buf, pos, name);
    try W.write(buf, pos, "\");\n");
}
