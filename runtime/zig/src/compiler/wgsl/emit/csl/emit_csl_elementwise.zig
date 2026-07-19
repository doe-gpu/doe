// emit_csl_elementwise.zig — CSL PE program template for element-wise kernels.
//
// Maps Doppler's element-wise WGSL pattern (GELU, SiLU, scale, bias_add,
// embed) to a CSL PE program where each PE processes a contiguous chunk of
// the input/output arrays with no inter-PE communication.
//
// WGSL model:  256 threads, each does output[gid.x] = f(input[gid.x])
// CSL model:   N PEs, each does output[i] = f(input[i]) for i in local chunk

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const W = @import("emit_csl_ir_walk.zig");
const walk = W.Emit(.{ .skip_barriers = false, .runtime_array_size = "chunk_size" });

pub const EmitError = W.EmitError;

/// Emit a complete CSL PE program for an element-wise kernel.
pub fn emit(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    entry: ir.EntryPoint,
    info: classify.ElementWiseInfo,
) EmitError!void {
    _ = info;
    const function = &module.functions.items[entry.function];

    try W.write(buf, pos, "// PE program: element-wise kernel (auto-generated from WGSL)\n");
    try W.write(buf, pos, "// Each PE processes chunk_size elements with no fabric routing.\n\n");

    try W.write(buf, pos, "param memcpy_params;\n");
    try W.write(buf, pos, "param width: u16;\n");
    try W.write(buf, pos, "param height: u16;\n\n");

    try W.write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try W.write(buf, pos, "const layout_mod = @import_module(\"<layout>\");\n");
    try W.write(buf, pos, "const math = @import_module(\"<math>\");\n\n");

    try walk.uniformParams(buf, pos, module);
    try walk.storageBuffers(buf, pos, module);
    try walk.helperFunctions(buf, pos, module);
    try emitComputeFunction(buf, pos, module, function);
    try walk.comptimeExports(buf, pos, module);
}

fn emitComputeFunction(buf: []u8, pos: *usize, module: *const ir.Module, function: *const ir.Function) EmitError!void {
    try W.write(buf, pos, "fn compute() void {\n");
    try W.write(buf, pos, "    const pe_x = layout_mod.get_x_coord();\n");
    try W.write(buf, pos, "    const pe_y = layout_mod.get_y_coord();\n");
    try W.write(buf, pos, "    const pe_id = @as(u16, pe_y) * width + @as(u16, pe_x);\n");
    try W.write(buf, pos, "    const num_pes = width * height;\n");
    try W.write(buf, pos, "    for (@range(i16, chunk_size)) |_idx| {\n");
    try W.write(buf, pos, "        const idx = @as(u32, _idx);\n");
    try emitElementWiseBody(buf, pos, module, function);
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "}\n\n");
}

/// Walk the entry function body, skipping the `let idx = gid.x` binding
/// and the `if (idx >= u.size) { return; }` size guard (the CSL loop
/// already bounds the iteration).
fn emitElementWiseBody(buf: []u8, pos: *usize, module: *const ir.Module, function: *const ir.Function) EmitError!void {
    if (function.stmts.items.len == 0) return;
    const root = function.stmts.items[function.root_stmt];
    switch (root) {
        .block => |range| {
            var i: u32 = 0;
            // The `while (..) : (i += 1)` post-step advances i every iteration.
            // An earlier revision added a second `i += 1` before `continue`
            // on filter matches, producing a double-advance that silently
            // skipped the statement after any filtered one. That happened to
            // look correct on the canonical gelu kernel only because a
            // size-guard statement immediately followed the gid let-binding
            // — the double-skip collapsed into what looked like "skip both".
            // On other elementwise WGSL (gid let-binding followed directly
            // by the compute assignment), the double-advance ate the body
            // and emitted an empty `for` loop. Drop the manual increment so
            // only the matched statement is filtered.
            while (i < range.len) : (i += 1) {
                const child_id = function.stmt_children.items[range.start + i];
                if (isSizeGuard(function, child_id)) continue;
                if (isGidLetBinding(function, child_id)) continue;
                try walk.stmt(buf, pos, module, function, child_id, 2);
            }
        },
        else => try walk.stmt(buf, pos, module, function, function.root_stmt, 2),
    }
}

/// Check if a statement is `let <name> = gid.x;` (global_invocation_id binding).
/// The WGSL→IR lowering can produce either `.member(.load(.param_ref(gid)), "x")`
/// or `.load(.member(.param_ref(gid), "x"))` depending on whether the member
/// access wraps a loaded vec or a pointer-to-member. Both shapes resolve to
/// the same logical gid.x read, so unwrap any top-level load before checking
/// for the member pattern.
fn isGidLetBinding(function: *const ir.Function, stmt_id: ir.StmtId) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    switch (function.stmts.items[stmt_id]) {
        .local_decl => |decl| {
            var init = decl.initializer orelse return false;
            if (init >= function.exprs.items.len) return false;
            if (function.exprs.items[init].data == .load) {
                const inner = function.exprs.items[init].data.load;
                if (inner >= function.exprs.items.len) return false;
                init = inner;
            }
            switch (function.exprs.items[init].data) {
                .member => |member| {
                    if (!std.mem.eql(u8, member.field_name, "x")) return false;
                    if (member.base >= function.exprs.items.len) return false;
                    return isGidRef(function, function.exprs.items[member.base].data);
                },
                else => return false,
            }
        },
        else => return false,
    }
}

fn isGidRef(function: *const ir.Function, data: ir.Expr) bool {
    switch (data) {
        .param_ref => |idx| {
            if (idx < function.params.items.len) {
                if (function.params.items[idx].io) |io| return io.builtin == .global_invocation_id;
            }
            return false;
        },
        .load => |inner| {
            if (inner >= function.exprs.items.len) return false;
            return isGidRef(function, function.exprs.items[inner].data);
        },
        else => return false,
    }
}

/// Check if a statement is the size guard `if (idx >= u.size) { return; }`.
fn isSizeGuard(function: *const ir.Function, stmt_id: ir.StmtId) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    switch (function.stmts.items[stmt_id]) {
        .if_ => |if_stmt| {
            if (if_stmt.cond >= function.exprs.items.len) return false;
            switch (function.exprs.items[if_stmt.cond].data) {
                .binary => |binary| {
                    if (binary.op != .greater_equal) return false;
                    if (if_stmt.then_block >= function.stmts.items.len) return false;
                    return stmtContainsReturn(function, if_stmt.then_block);
                },
                else => return false,
            }
        },
        else => return false,
    }
}

fn stmtContainsReturn(function: *const ir.Function, stmt_id: ir.StmtId) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    switch (function.stmts.items[stmt_id]) {
        .return_ => return true,
        .block => |range| {
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                if (stmtContainsReturn(function, function.stmt_children.items[range.start + i])) return true;
            }
            return false;
        },
        else => return false,
    }
}
