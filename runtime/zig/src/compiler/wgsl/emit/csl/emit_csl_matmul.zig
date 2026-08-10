// emit_csl_matmul.zig — CSL PE program template for SUMMA tiled matmul.
//
// Maps Doppler's tiled matmul WGSL pattern to the SUMMA algorithm on a
// P × P PE grid using Cerebras collectives_2d for row/column broadcasts.
//
// WGSL model:  16×16 workgroup, shared memory tiles, barrier-synchronized
//              K-loop, 4×4 register tiling per thread.
//
// CSL model:   P×P PE grid, each PE holds Mt×Kt tile of A, Kt×Nt tile of B,
//              Mt×Nt accumulator tile of C. P steps: at step i, column i
//              broadcasts A tiles along its row, row i broadcasts B tiles
//              down its column. After each broadcast, local GEMM via @fmacs.
//
// Based on: sdk.cerebras.net/csl/code-examples/benchmark-gemm-collectives

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const storage_emit = @import("csl_storage_emit.zig");
const text_buffer = @import("csl_text_buffer.zig");

const storageExportName = storage_emit.storageExportName;
const write = text_buffer.write;

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    UnsupportedBuiltin,
    UnsupportedConstruct,
};

/// Emit a CSL PE program implementing SUMMA matmul.
pub fn emit(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    entry: ir.EntryPoint,
    info: classify.MatmulInfo,
) EmitError!void {
    _ = entry;
    _ = info;

    const a_export = storageExportName(module, 0, "A");
    const b_export = storageExportName(module, 1, "B");
    const c_export = storageExportName(module, 2, "C");

    try write(buf, pos, "// PE program: SUMMA tiled matmul (auto-generated from WGSL)\n");
    try write(buf, pos, "// P×P PE grid, collectives_2d for row/column broadcasts.\n");
    try write(buf, pos, "// C[M,N] = A[M,K] * B^T[N,K]\n\n");

    // Params from layout. c2d_params is stitched per-PE by the layout
    // (emit_csl_layout::emitMatmulLayout calls c2d.get_params(Px, Py, ...)
    // with explicit x_colors / x_entrypoints / y_colors / y_entrypoints);
    // the PE receives it as an untyped compile-time param and unpacks x/y halves for
    // the two mpi_* dim-bound modules. Canonical wse3 reference:
    // csl-extras .../benchmarks/gemm-collectives_2d/pe.csl.
    try write(buf, pos, "param c2d_params;\n");
    try write(buf, pos, "param memcpy_params;\n");
    try write(buf, pos, "param Mt: i16;\n");
    try write(buf, pos, "param Kt: i16;\n");
    try write(buf, pos, "param Nt: i16;\n");
    try write(buf, pos, "param P: u16;\n\n");

    // Imports
    try write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try write(buf, pos, "const mpi_x = @import_module(\"<collectives_2d/pe>\", .{\n");
    try write(buf, pos, "    .dim_params = c2d_params.x,\n");
    try write(buf, pos, "    .queues = [2]u16{2, 4},\n");
    try write(buf, pos, "    .dest_dsr_ids = [1]u16{1},\n");
    try write(buf, pos, "    .src0_dsr_ids = [1]u16{1},\n");
    try write(buf, pos, "    .src1_dsr_ids = [1]u16{1},\n");
    try write(buf, pos, "});\n");
    try write(buf, pos, "const mpi_y = @import_module(\"<collectives_2d/pe>\", .{\n");
    try write(buf, pos, "    .dim_params = c2d_params.y,\n");
    try write(buf, pos, "    .queues = [2]u16{3, 5},\n");
    try write(buf, pos, "    .dest_dsr_ids = [1]u16{2},\n");
    try write(buf, pos, "    .src0_dsr_ids = [1]u16{2},\n");
    try write(buf, pos, "    .src1_dsr_ids = [1]u16{2},\n");
    try write(buf, pos, "});\n\n");

    // Data tiles
    try write(buf, pos, "var A_tile = @zeros([Mt * Kt]f32);\n");
    try write(buf, pos, "var B_tile = @zeros([Kt * Nt]f32);\n");
    try write(buf, pos, "var C_tile = @zeros([Mt * Nt]f32);\n");
    try write(buf, pos, "var A_buf  = @zeros([Mt * Kt]f32);\n");
    try write(buf, pos, "var B_buf  = @zeros([Kt * Nt]f32);\n\n");

    // Pointers for export
    try write(buf, pos, "var A_ptr: [*]f32 = &A_tile;\n");
    try write(buf, pos, "var B_ptr: [*]f32 = &B_tile;\n");
    try write(buf, pos, "var C_ptr: [*]f32 = &C_tile;\n\n");

    // State
    try write(buf, pos, "var step: u16 = 0;\n");
    try write(buf, pos, "var px: u16 = 0;\n");
    try write(buf, pos, "var py: u16 = 0;\n\n");

    // Task IDs. Task ids 8..11 are reserved by the collectives_2d c2d.get_params
    // call in the layout (x_entrypoints = {8,9}, y_entrypoints = {10,11}); the
    // user-defined tasks live at 12..15 to avoid colliding with them.
    try write(buf, pos, "const exit_task_id:    local_task_id = @get_local_task_id(12);\n");
    try write(buf, pos, "const compute_task_id: local_task_id = @get_local_task_id(13);\n");
    try write(buf, pos, "const x_done_id:       local_task_id = @get_local_task_id(14);\n");
    try write(buf, pos, "const y_done_id:       local_task_id = @get_local_task_id(15);\n\n");

    // Synchronization flags
    try write(buf, pos, "var x_done: bool = false;\n");
    try write(buf, pos, "var y_done: bool = false;\n\n");

    // Main entry — called by host
    try write(buf, pos, "fn compute() void {\n");
    try write(buf, pos, "    if (step == 0) {\n");
    try write(buf, pos, "        mpi_x.init();\n");
    try write(buf, pos, "        mpi_y.init();\n");
    try write(buf, pos, "        px = mpi_x.pe_id;\n");
    try write(buf, pos, "        py = mpi_y.pe_id;\n");
    try write(buf, pos, "    }\n\n");

    try write(buf, pos, "    const Ap = if (px == step) &A_tile else &A_buf;\n");
    try write(buf, pos, "    const Bp = if (py == step) &B_tile else &B_buf;\n\n");

    try write(buf, pos, "    x_done = false;\n");
    try write(buf, pos, "    y_done = false;\n\n");

    try write(buf, pos, "    mpi_x.broadcast(step, @ptrcast([*]u32, Ap), Mt * Kt, x_done_id);\n");
    try write(buf, pos, "    mpi_y.broadcast(step, @ptrcast([*]u32, Bp), Kt * Nt, y_done_id);\n");
    try write(buf, pos, "}\n\n");

    // Broadcast done handlers
    try write(buf, pos, "task x_done_task() void {\n");
    try write(buf, pos, "    x_done = true;\n");
    try write(buf, pos, "    if (y_done) @activate(compute_task_id);\n");
    try write(buf, pos, "}\n\n");

    try write(buf, pos, "task y_done_task() void {\n");
    try write(buf, pos, "    y_done = true;\n");
    try write(buf, pos, "    if (x_done) @activate(compute_task_id);\n");
    try write(buf, pos, "}\n\n");

    // Local GEMM + step advance
    try write(buf, pos, "task compute_step() void {\n");
    try write(buf, pos, "    const Ap = if (px == step) &A_tile else &A_buf;\n");
    try write(buf, pos, "    const Bp = if (py == step) &B_tile else &B_buf;\n\n");

    try write(buf, pos, "    // Local GEMM step: accumulate Ap * Bp into C_tile via @fmacs.\n");
    try write(buf, pos, "    // Matches canonical SUMMA pattern from csl-extras gemm-collectives_2d/pe.csl:\n");
    try write(buf, pos, "    // A_dsd declared outside k-loop, advanced by @increment_dsd_offset each k.\n");
    try write(buf, pos, "    var A_dsd = @get_dsd(mem1d_dsd, .{ .tensor_access = |i|{Mt} -> A_tile[i] });\n");
    try write(buf, pos, "    A_dsd = @set_dsd_base_addr(A_dsd, Ap);\n");
    try write(buf, pos, "    for (@range(i16, Kt)) |k| {\n");
    try write(buf, pos, "        var C_dsd = @get_dsd(mem1d_dsd, .{ .tensor_access = |i|{Mt} -> C_tile[i] });\n");
    try write(buf, pos, "        for (@range(i16, Nt)) |j| {\n");
    try write(buf, pos, "            const b_val = Bp.*[@as(u32, j) * @as(u32, Kt) + @as(u32, k)];\n");
    try write(buf, pos, "            @fmacs(C_dsd, C_dsd, A_dsd, b_val);\n");
    try write(buf, pos, "            C_dsd = @increment_dsd_offset(C_dsd, Mt, f32);\n");
    try write(buf, pos, "        }\n");
    try write(buf, pos, "        A_dsd = @increment_dsd_offset(A_dsd, Mt, f32);\n");
    try write(buf, pos, "    }\n\n");

    try write(buf, pos, "    step += 1;\n");
    try write(buf, pos, "    if (step != P) {\n");
    try write(buf, pos, "        compute();\n");
    try write(buf, pos, "    } else {\n");
    try write(buf, pos, "        @activate(exit_task_id);\n");
    try write(buf, pos, "    }\n");
    try write(buf, pos, "}\n\n");

    // Exit
    try write(buf, pos, "task exit_task() void {\n");
    try write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try write(buf, pos, "}\n\n");

    // Comptime bindings
    try write(buf, pos, "comptime {\n");
    try write(buf, pos, "    @bind_local_task(x_done_task, x_done_id);\n");
    try write(buf, pos, "    @bind_local_task(y_done_task, y_done_id);\n");
    try write(buf, pos, "    @bind_local_task(compute_step, compute_task_id);\n");
    try write(buf, pos, "    @bind_local_task(exit_task, exit_task_id);\n\n");

    try write(buf, pos, "    @export_symbol(A_ptr, \"");
    try write(buf, pos, a_export);
    try write(buf, pos, "\");\n");
    try write(buf, pos, "    @export_symbol(B_ptr, \"");
    try write(buf, pos, b_export);
    try write(buf, pos, "\");\n");
    try write(buf, pos, "    @export_symbol(C_ptr, \"");
    try write(buf, pos, c_export);
    try write(buf, pos, "\");\n");
    try write(buf, pos, "    @export_symbol(compute);\n");
    try write(buf, pos, "}\n");
}
