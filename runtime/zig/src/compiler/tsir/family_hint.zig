const std = @import("std");
const ir = @import("../wgsl/ir/ir.zig");
const ir_query = @import("../wgsl/ir/ir_query.zig");
const schema = @import("schema.zig");

const MAX_INDIRECT_LOCAL_ALIAS_DEPTH: u32 = 8;
const findGlobalBase = ir_query.findGlobalBase;

/// Infer a coarse `KernelFamilyHint` from the observable TSIR shape of one
/// function. Hints are tiebreakers only: they must not change feasibility or
/// rejection. The classifier uses structural IR evidence, not function names.
pub fn infer(
    function: *const ir.Function,
    axes: []const schema.IterationAxis,
    reductions: []const schema.ReductionRegion,
) schema.KernelFamilyHint {
    if (reductions.len > 0) {
        if (isFusedGemvShape(function, axes, reductions)) return .fused_gemv;
        return .reduction;
    }
    if (axes.len > 0) {
        if (hasIndirectBufferAccess(function)) return .gather;
        return .elementwise;
    }
    return .unknown;
}

fn isFusedGemvShape(
    function: *const ir.Function,
    axes: []const schema.IterationAxis,
    reductions: []const schema.ReductionRegion,
) bool {
    return axes.len == 2 and
        reductions.len == 1 and
        reductions[0].axis == 1 and
        reductions[0].op == .sum and
        isNontrivialBoundString(axes[0].upper_bound) and
        hasIndexedAccessCoveringAxes(function, axes[0].name, axes[1].name);
}

fn isNontrivialBoundString(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "dispatch.") or
        std.mem.startsWith(u8, s, "uniform:") or
        std.mem.startsWith(u8, s, "override:") or
        std.mem.startsWith(u8, s, "override@id:") or
        std.mem.startsWith(u8, s, "const:");
}

/// GEMV needs a matrix-like buffer read whose single indexed access depends on
/// both the output-row axis and the reduction axis: e.g. `W[i * K + k]` or
/// `W[i][k]`. RMSNorm has the same two-axis reduction shape, but its buffer
/// accesses are split (`input[i]`, then `input[d]` / `weight[d]`) and must stay
/// on the coarse `.reduction` hint until a real RMSNorm detector exists.
fn hasIndexedAccessCoveringAxes(
    function: *const ir.Function,
    outer_axis_name: []const u8,
    inner_axis_name: []const u8,
) bool {
    const outer_local = findLocalByName(function, outer_axis_name) orelse return false;
    const inner_local = findLocalByName(function, inner_axis_name) orelse return false;

    for (function.exprs.items) |expr| {
        if (expr.data != .load) continue;
        const loaded_ref = expr.data.load;
        if (!exprTreeContainsIndex(function, loaded_ref)) continue;
        if (findGlobalBase(function, loaded_ref) == null) continue;
        if (exprTreeContainsLocalRef(function, loaded_ref, outer_local) and
            exprTreeContainsLocalRef(function, loaded_ref, inner_local))
        {
            return true;
        }
    }
    return false;
}

fn findLocalByName(function: *const ir.Function, name: []const u8) ?u32 {
    for (function.locals.items, 0..) |local, index| {
        if (std.mem.eql(u8, local.name, name)) return @intCast(index);
    }
    return null;
}

fn exprTreeContainsLocalRef(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    local_index: u32,
) bool {
    const node = function.exprs.items[expr_id];
    switch (node.data) {
        .local_ref => |idx| return idx == local_index,
        .load => |inner| return exprTreeContainsLocalRef(function, inner, local_index),
        .binary => |b| return exprTreeContainsLocalRef(function, b.lhs, local_index) or
            exprTreeContainsLocalRef(function, b.rhs, local_index),
        .unary => |u| return exprTreeContainsLocalRef(function, u.operand, local_index),
        .member => |m| return exprTreeContainsLocalRef(function, m.base, local_index),
        .index => |idx| return exprTreeContainsLocalRef(function, idx.base, local_index) or
            exprTreeContainsLocalRef(function, idx.index, local_index),
        .call => |c| {
            var ai: u32 = 0;
            while (ai < c.args.len) : (ai += 1) {
                const arg_id = function.expr_args.items[c.args.start + ai];
                if (exprTreeContainsLocalRef(function, arg_id, local_index)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn exprTreeContainsIndex(function: *const ir.Function, expr_id: ir.ExprId) bool {
    const node = function.exprs.items[expr_id];
    switch (node.data) {
        .index => return true,
        .load => |inner| return exprTreeContainsIndex(function, inner),
        .binary => |b| return exprTreeContainsIndex(function, b.lhs) or
            exprTreeContainsIndex(function, b.rhs),
        .unary => |u| return exprTreeContainsIndex(function, u.operand),
        .member => |m| return exprTreeContainsIndex(function, m.base),
        .call => |c| {
            var ai: u32 = 0;
            while (ai < c.args.len) : (ai += 1) {
                const arg_id = function.expr_args.items[c.args.start + ai];
                if (exprTreeContainsIndex(function, arg_id)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn hasIndirectBufferAccess(function: *const ir.Function) bool {
    for (function.exprs.items) |expr| {
        if (expr.data != .index) continue;
        if (indexFieldContainsBufferIndex(function, expr.data.index.index)) return true;
    }
    return false;
}

fn indexFieldContainsBufferIndex(function: *const ir.Function, expr_id: ir.ExprId) bool {
    return indexFieldContainsBufferIndexDepth(function, expr_id, 0);
}

fn indexFieldContainsBufferIndexDepth(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    depth: u32,
) bool {
    const node = function.exprs.items[expr_id];
    switch (node.data) {
        .index => return true,
        .local_ref => |local| return localInitializerContainsBufferIndex(function, local, depth + 1),
        .load => |inner| return indexFieldContainsBufferIndexDepth(function, inner, depth),
        .binary => |b| return indexFieldContainsBufferIndexDepth(function, b.lhs, depth) or
            indexFieldContainsBufferIndexDepth(function, b.rhs, depth),
        .unary => |u| return indexFieldContainsBufferIndexDepth(function, u.operand, depth),
        .member => |m| return indexFieldContainsBufferIndexDepth(function, m.base, depth),
        .call => |c| {
            var ai: u32 = 0;
            while (ai < c.args.len) : (ai += 1) {
                const arg_id = function.expr_args.items[c.args.start + ai];
                if (indexFieldContainsBufferIndexDepth(function, arg_id, depth)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn localInitializerContainsBufferIndex(
    function: *const ir.Function,
    local_index: u32,
    depth: u32,
) bool {
    if (depth > MAX_INDIRECT_LOCAL_ALIAS_DEPTH) return false;
    for (function.stmts.items) |stmt| {
        if (stmt != .local_decl) continue;
        const decl = stmt.local_decl;
        if (decl.local != local_index) continue;
        const init = decl.initializer orelse return false;
        return indexFieldContainsBufferIndexDepth(function, init, depth);
    }
    return false;
}
