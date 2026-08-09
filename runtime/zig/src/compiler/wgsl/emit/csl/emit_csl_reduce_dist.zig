// emit_csl_reduce_dist.zig — Distributed reduction mode for CSL.
//
// When hidden_dim exceeds single-PE SRAM budget, the hidden dimension is
// partitioned across a row of PEs. Each PE computes a local partial sum,
// then an allreduce via the fabric aggregates the global result, and each
// PE normalizes its local slice.
//
// Fabric topology: east→west chain using one application color.
//   PE 0: RAMP→EAST (send local partial)
//   PE i: WEST+RAMP→EAST (accumulate + forward)
//   PE N-1: WEST→RAMP (final result, then broadcast back)
//
// The broadcast-back phase reverses direction: PE N-1 sends WEST,
// intermediate PEs forward WEST, PE 0 receives from EAST.
//
// This implements the "reduce-scatter + allgather" pattern from the
// Cerebras SDK gemv-08-allreduce tutorial.

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const spec = @import("csl_spec.zig");
const text_buffer = @import("csl_text_buffer.zig");

const write = text_buffer.write;
const writeInt = text_buffer.writeInt;

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    UnsupportedBuiltin,
    UnsupportedConstruct,
};

/// Emit the layout section for distributed reduction.
/// Grid: width × 1, with reduce_color routed east→west for accumulation
/// and bcast_color routed west→east for broadcasting the result back.
pub fn emitDistributedLayout(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
) EmitError!void {
    try write(buf, pos, "// Layout: distributed reduction across a PE row.\n");
    try write(buf, pos, "// Allreduce via fabric: east→west accumulation, west→east broadcast.\n\n");

    try write(buf, pos, "param width: i16;\n");
    try write(buf, pos, "param slice_size: i16;\n\n");

    try write(buf, pos, "const memcpy = @import_module(\"<memcpy/get_params>\", .{\n");
    try write(buf, pos, "    .width = width,\n");
    try write(buf, pos, "    .height = 1,\n");
    try write(buf, pos, "});\n\n");

    // Two application colors: reduce (east→west) and broadcast (west→east).
    try write(buf, pos, "const reduce_color: color = @get_color(");
    try writeInt(buf, pos, spec.MEMCPY_RESERVED_COLORS);
    try write(buf, pos, ");\n");
    try write(buf, pos, "const bcast_color: color = @get_color(");
    try writeInt(buf, pos, spec.MEMCPY_RESERVED_COLORS + 1);
    try write(buf, pos, ");\n\n");

    try write(buf, pos, "layout {\n");
    try write(buf, pos, "    @set_rectangle(width, 1);\n\n");

    try write(buf, pos, "    for (@range(i16, width)) |pe_x| {\n");
    try write(buf, pos, "        @set_tile_code(pe_x, 0, \"");
    try write(buf, pos, spec.PE_PROGRAM_FILENAME);
    try write(buf, pos, "\", .{\n");
    try write(buf, pos, "            .memcpy_params = memcpy.get_params(pe_x),\n");
    try write(buf, pos, "            .pe_id = pe_x,\n");
    try write(buf, pos, "            .num_pes = width,\n");
    try write(buf, pos, "            .slice_size = slice_size,\n");
    try write(buf, pos, "            .reduce_color = reduce_color,\n");
    try write(buf, pos, "            .bcast_color = bcast_color,\n");
    try write(buf, pos, "        });\n\n");

    // Reduce color routing: RAMP→EAST for PE 0, WEST+RAMP→EAST for middle,
    // WEST→RAMP for last PE.
    try write(buf, pos, "        if (pe_x == 0) {\n");
    try write(buf, pos, "            @set_color_config(pe_x, 0, reduce_color, .{\n");
    try write(buf, pos, "                .routes = .{ .rx = .{RAMP}, .tx = .{EAST} },\n");
    try write(buf, pos, "            });\n");
    try write(buf, pos, "            @set_color_config(pe_x, 0, bcast_color, .{\n");
    try write(buf, pos, "                .routes = .{ .rx = .{EAST}, .tx = .{RAMP} },\n");
    try write(buf, pos, "            });\n");
    try write(buf, pos, "        } else if (pe_x == width - 1) {\n");
    try write(buf, pos, "            @set_color_config(pe_x, 0, reduce_color, .{\n");
    try write(buf, pos, "                .routes = .{ .rx = .{WEST}, .tx = .{RAMP} },\n");
    try write(buf, pos, "            });\n");
    try write(buf, pos, "            @set_color_config(pe_x, 0, bcast_color, .{\n");
    try write(buf, pos, "                .routes = .{ .rx = .{RAMP}, .tx = .{WEST} },\n");
    try write(buf, pos, "            });\n");
    try write(buf, pos, "        } else {\n");
    try write(buf, pos, "            @set_color_config(pe_x, 0, reduce_color, .{\n");
    try write(buf, pos, "                .routes = .{ .rx = .{WEST, RAMP}, .tx = .{EAST} },\n");
    try write(buf, pos, "            });\n");
    try write(buf, pos, "            @set_color_config(pe_x, 0, bcast_color, .{\n");
    try write(buf, pos, "                .routes = .{ .rx = .{EAST}, .tx = .{WEST} },\n");
    try write(buf, pos, "            });\n");
    try write(buf, pos, "        }\n");
    try write(buf, pos, "    }\n\n");

    // Exports
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage and space != .uniform) continue;
        try write(buf, pos, "    @export_name(\"");
        try write(buf, pos, global.name);
        try write(buf, pos, "\", [*]f32, true);\n");
    }
    try write(buf, pos, "    @export_name(\"compute\", fn()void);\n");
    try write(buf, pos, "}\n");
}

/// Emit the PE program for distributed reduction.
///
/// Structure:
///   1. Each PE computes local partial sum over its slice.
///   2. Send partial sum east via reduce_color (wavelet).
///   3. Receive accumulated sum from west, add local, forward east.
///   4. Last PE has global sum; broadcasts back via bcast_color.
///   5. Each PE receives global sum and normalizes its local slice.
pub fn emitDistributed(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
) EmitError!void {
    try write(buf, pos, "// PE program: distributed reduction (auto-generated from WGSL)\n");
    try write(buf, pos, "// Each PE holds a slice of the hidden dimension.\n");
    try write(buf, pos, "// Allreduce via fabric for global sum, then local normalize.\n\n");

    // Params
    try write(buf, pos, "param memcpy_params;\n");
    try write(buf, pos, "param pe_id: i16;\n");
    try write(buf, pos, "param num_pes: i16;\n");
    try write(buf, pos, "param slice_size: i16;\n");
    try write(buf, pos, "param reduce_color: color;\n");
    try write(buf, pos, "param bcast_color: color;\n\n");

    // Imports
    try write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try write(buf, pos, "const math = @import_module(\"<math>\");\n\n");
    try write(buf, pos, "fn sqrt_nr(x: f32) f32 {\n");
    try write(buf, pos, "    const y0: f32 = math.sqrt(x);\n");
    try write(buf, pos, "    return 0.5 * (y0 + x / y0);\n");
    try write(buf, pos, "}\n\n");

    // Buffers
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage) continue;
        try write(buf, pos, "var ");
        try write(buf, pos, global.name);
        try write(buf, pos, ": [slice_size]f32 = @zeros([slice_size]f32);\n");
        try write(buf, pos, "var ");
        try write(buf, pos, global.name);
        try write(buf, pos, "_ptr: [*]f32 = &");
        try write(buf, pos, global.name);
        try write(buf, pos, ";\n");
    }
    try write(buf, pos, "\n");

    // Reduction state
    try write(buf, pos, "var local_sum: f32 = 0.0;\n");
    try write(buf, pos, "var global_sum: f32 = 0.0;\n");
    try write(buf, pos, "param eps: f32 = 1e-5;\n\n");

    // DSD descriptors for fabric communication
    try write(buf, pos, "const reduce_out_q = @get_output_queue(2);\n");
    try write(buf, pos, "const reduce_in_q = @get_input_queue(2);\n");
    try write(buf, pos, "const bcast_out_q = @get_output_queue(3);\n");
    try write(buf, pos, "const bcast_in_q = @get_input_queue(3);\n");
    try write(buf, pos, "const reduce_out_dsd = @get_dsd(fabout_dsd, .{\n");
    try write(buf, pos, "    .extent = 1,\n");
    try write(buf, pos, "    .output_queue = reduce_out_q,\n");
    try write(buf, pos, "});\n");
    try write(buf, pos, "const reduce_in_dsd = @get_dsd(fabin_dsd, .{\n");
    try write(buf, pos, "    .extent = 1,\n");
    try write(buf, pos, "    .input_queue = reduce_in_q,\n");
    try write(buf, pos, "});\n");
    try write(buf, pos, "const bcast_out_dsd = @get_dsd(fabout_dsd, .{\n");
    try write(buf, pos, "    .extent = 1,\n");
    try write(buf, pos, "    .output_queue = bcast_out_q,\n");
    try write(buf, pos, "});\n");
    try write(buf, pos, "const bcast_in_dsd = @get_dsd(fabin_dsd, .{\n");
    try write(buf, pos, "    .extent = 1,\n");
    try write(buf, pos, "    .input_queue = bcast_in_q,\n");
    try write(buf, pos, "});\n\n");

    // Task IDs
    try write(buf, pos, "const reduce_task_id: local_task_id = @get_local_task_id(10);\n");
    try write(buf, pos, "const bcast_task_id: local_task_id = @get_local_task_id(11);\n");
    try write(buf, pos, "const norm_task_id: local_task_id = @get_local_task_id(12);\n\n");

    // Phase 1: local partial sum
    try write(buf, pos, "fn compute() void {\n");
    try write(buf, pos, "    local_sum = 0.0;\n");
    try write(buf, pos, "    for (@range(i16, slice_size)) |i| {\n");
    try write(buf, pos, "        const x = input[@as(u32, i)];\n");
    try write(buf, pos, "        local_sum += x * x;\n");
    try write(buf, pos, "    }\n\n");
    try write(buf, pos, "    // Send local partial sum into the reduce chain.\n");
    try write(buf, pos, "    @fmovs(reduce_out_dsd, local_sum);\n");
    try write(buf, pos, "}\n\n");

    // Phase 2: reduce task — accumulate from west, forward east
    try write(buf, pos, "task reduce_recv() void {\n");
    try write(buf, pos, "    var incoming: f32 = 0.0;\n");
    try write(buf, pos, "    @fmovs(incoming, reduce_in_dsd);\n");
    try write(buf, pos, "    local_sum += incoming;\n\n");
    try write(buf, pos, "    if (pe_id == num_pes - 1) {\n");
    try write(buf, pos, "        // Last PE has the global sum. Broadcast back.\n");
    try write(buf, pos, "        global_sum = local_sum;\n");
    try write(buf, pos, "        @fmovs(bcast_out_dsd, global_sum);\n");
    try write(buf, pos, "        @activate(norm_task_id);\n");
    try write(buf, pos, "    } else {\n");
    try write(buf, pos, "        // Forward accumulated sum eastward.\n");
    try write(buf, pos, "        @fmovs(reduce_out_dsd, local_sum);\n");
    try write(buf, pos, "    }\n");
    try write(buf, pos, "}\n\n");

    // Phase 3: broadcast receive — get global sum, then normalize
    try write(buf, pos, "task bcast_recv() void {\n");
    try write(buf, pos, "    @fmovs(global_sum, bcast_in_dsd);\n");
    try write(buf, pos, "    if (pe_id != 0) {\n");
    try write(buf, pos, "        // Forward broadcast westward.\n");
    try write(buf, pos, "        @fmovs(bcast_out_dsd, global_sum);\n");
    try write(buf, pos, "    }\n");
    try write(buf, pos, "    @activate(norm_task_id);\n");
    try write(buf, pos, "}\n\n");

    // Phase 4: normalize local slice
    try write(buf, pos, "task normalize() void {\n");
    try write(buf, pos, "    const total_size = @as(f32, num_pes) * @as(f32, slice_size);\n");
    try write(buf, pos, "    const mean_sq = global_sum / total_size;\n");
    try write(buf, pos, "    const inv_rms = 1.0 / sqrt_nr(mean_sq + eps);\n\n");
    try write(buf, pos, "    for (@range(i16, slice_size)) |i| {\n");
    try write(buf, pos, "        const idx = @as(u32, i);\n");
    try write(buf, pos, "        output[idx] = input[idx] * inv_rms * weight[idx];\n");
    try write(buf, pos, "    }\n\n");
    try write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try write(buf, pos, "}\n\n");

    // Comptime bindings
    try write(buf, pos, "comptime {\n");
    try write(buf, pos, "    @bind_local_task(reduce_recv, reduce_task_id);\n");
    try write(buf, pos, "    @bind_local_task(bcast_recv, bcast_task_id);\n");
    try write(buf, pos, "    @bind_local_task(normalize, norm_task_id);\n\n");
    try write(buf, pos, "    if (@is_arch(\"wse3\")) {\n");
    try write(buf, pos, "        @initialize_queue(reduce_out_q, .{ .color = reduce_color });\n");
    try write(buf, pos, "        @initialize_queue(reduce_in_q, .{ .color = reduce_color });\n");
    try write(buf, pos, "        @initialize_queue(bcast_out_q, .{ .color = bcast_color });\n");
    try write(buf, pos, "        @initialize_queue(bcast_in_q, .{ .color = bcast_color });\n");
    try write(buf, pos, "    }\n\n");
    try write(buf, pos, "    @set_local_color_config(reduce_color, .{ .recv_task = reduce_task_id });\n");
    try write(buf, pos, "    @set_local_color_config(bcast_color, .{ .recv_task = bcast_task_id });\n\n");

    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage) continue;
        try write(buf, pos, "    @export_symbol(");
        try write(buf, pos, global.name);
        try write(buf, pos, "_ptr, \"");
        try write(buf, pos, global.name);
        try write(buf, pos, "\");\n");
    }
    try write(buf, pos, "    @export_symbol(compute);\n");
    try write(buf, pos, "}\n");
}

// ---------------------------------------------------------------------------
// Write helpers
// ---------------------------------------------------------------------------
