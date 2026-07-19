// emit_csl_reduction.zig — CSL PE program emitter for reduction kernels.
//
// Maps Doppler's reduction WGSL patterns (RMSNorm, LayerNorm, Softmax) to
// CSL PE programs. Single-PE mode: each PE holds one full token's hidden
// vector. Barriers become no-ops, shared memory becomes PE-local.
//
// Lane-preserving lowering (iteration 27): the WGSL workgroup model
// assumes workgroup_size threads run in lockstep up to the barrier,
// then thread 0 aggregates shared state. Doe's single-PE lowering
// sequentializes the pre-barrier phase into a per-lane loop so lid.x
// resolves to the loop index (not 0) and the full workgroup write is
// preserved. The post-barrier section runs once per PE with lid.x
// folded back to 0 — matching the `if (lid.x == 0u)` thread-0 guard.

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const W = @import("emit_csl_ir_walk.zig");
const walk_normal = W.Emit(.{ .skip_barriers = true, .runtime_array_size = "hidden_size", .sqrt_function = "sqrt_nr" });
const walk_lane = W.Emit(.{ .skip_barriers = true, .runtime_array_size = "hidden_size", .lane_mode = true, .sqrt_function = "sqrt_nr" });

pub const EmitError = W.EmitError;

/// Emit a CSL PE program for a reduction kernel (single-PE mode).
pub fn emit(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    entry: ir.EntryPoint,
    info: classify.ReductionInfo,
) EmitError!void {
    _ = info;
    const function = &module.functions.items[entry.function];
    const wg_size_x: u32 = entry.workgroup_size[0];

    try W.write(buf, pos, "// PE program: reduction kernel (auto-generated from WGSL)\n");
    try W.write(buf, pos, "// Single-PE mode: each PE processes one full token.\n");
    try W.write(buf, pos, "// Lane-preserving lowering: pre-barrier statements execute inside\n");
    try W.write(buf, pos, "// a per-lane for-loop (WGSL local invocation index maps to lane_idx);\n");
    try W.write(buf, pos, "// post-barrier runs once with the local index folded to 0, matching\n");
    try W.write(buf, pos, "// the `thread 0` aggregation guard in the source.\n\n");

    try W.write(buf, pos, "param memcpy_params;\n");
    try W.write(buf, pos, "param pe_id: i16;\n");
    try W.write(buf, pos, "param num_pes: i16;\n");
    try W.write(buf, pos, "param reduce_color: color;\n\n");

    try W.write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try W.write(buf, pos, "const math = @import_module(\"<math>\");\n\n");
    try W.write(buf, pos, "fn sqrt_nr(x: f32) f32 {\n");
    try W.write(buf, pos, "    const y0: f32 = math.sqrt(x);\n");
    try W.write(buf, pos, "    return 0.5 * (y0 + x / y0);\n");
    try W.write(buf, pos, "}\n\n");

    // WGSL workgroup size x-dim. Used by the lane-preserving lowering:
    // gid.x inside the pre-barrier for-loop resolves to
    //   @as(u32, pe_id) * wg_size_x + lane_idx
    // (pe_id is the workgroup index, lane_idx the lane within it).
    try W.write(buf, pos, "const wg_size_x: u32 = ");
    try W.writeInt(buf, pos, wg_size_x);
    try W.write(buf, pos, ";\n\n");

    try walk_normal.uniformParams(buf, pos, module);
    try walk_normal.storageBuffers(buf, pos, module);
    try walk_normal.workgroupBuffers(buf, pos, module);
    try walk_normal.helperFunctions(buf, pos, module);
    try emitComputeFunction(buf, pos, module, function, wg_size_x);

    // Reduction only exports storage (not uniform) in comptime block.
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

fn emitComputeFunction(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    function: *const ir.Function,
    wg_size_x: u32,
) EmitError!void {
    try W.write(buf, pos, "fn compute() void {\n");
    if (function.stmts.items.len > 0) {
        const root = function.stmts.items[function.root_stmt];
        switch (root) {
            .block => |range| try emitBarrierSplitBlock(buf, pos, module, function, range, wg_size_x),
            else => {
                // No block (rare — single-stmt bodies); fall back to the
                // normal walker. Nothing to split.
                try walk_normal.stmt(buf, pos, module, function, function.root_stmt, 1);
            },
        }
    }
    try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "}\n\n");
}

fn emitBarrierSplitBlock(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    function: *const ir.Function,
    range: ir.Range,
    wg_size_x: u32,
) EmitError!void {
    // Find the first barrier statement inside the root block; split the
    // block into three zones: pre-barrier (wrapped in a per-lane loop),
    // the barrier itself (skipped — skip_barriers=true), and post-barrier
    // (emitted unwrapped with lid.x → 0).
    //
    // If there is no barrier, the body is lane-invariant (e.g. a kernel
    // classified as reduction by the workgroup-mem heuristic but without
    // a cross-lane synchronization point); emit under lane mode so the
    // lane iteration still happens and lid.x resolves correctly.
    const start: usize = @intCast(range.start);
    const end: usize = @intCast(range.start + range.len);
    const ids = function.stmt_children.items[start..end];

    var barrier_idx: ?usize = null;
    for (ids, 0..) |cid, i| {
        if (W.isBarrierStmt(function, cid)) {
            barrier_idx = i;
            break;
        }
    }

    // Pre-barrier zone: wrap in per-lane for-loop.
    const pre_end: usize = barrier_idx orelse ids.len;
    if (pre_end > 0) {
        try W.write(buf, pos, "    for (@range(u32, ");
        try W.writeInt(buf, pos, wg_size_x);
        try W.write(buf, pos, ")) |lane_idx| {\n");
        for (ids[0..pre_end]) |cid| {
            try walk_lane.stmt(buf, pos, module, function, cid, 2);
        }
        try W.write(buf, pos, "    }\n");
    }

    // Post-barrier zone (if any). Emit with the default walker so
    // lid.x → 0 and the `if (lid.x == 0u) { ... }` thread-0 guard
    // evaluates true exactly once per PE.
    if (barrier_idx) |bi| {
        for (ids[bi + 1 ..]) |cid| {
            try walk_normal.stmt(buf, pos, module, function, cid, 1);
        }
    }
}
