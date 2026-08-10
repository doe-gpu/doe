const std = @import("std");
const ir = @import("../wgsl/ir/ir.zig");
const frontend_expr = @import("frontend_expr.zig");
const tsir = @import("schema.zig");
const types = @import("frontend_types.zig");

const FrontendError = types.FrontendError;

/// Walk `function.exprs` for builtin calls that correspond to
/// WGSL subgroup / workgroup collectives and emit one
/// `CollectiveSemanticNode` per call site. This is the Step 4
/// "subgroup canonicalization" pass: downstream lowering can
/// stop interpreting subgroup semantics per-emitter, because
/// the frontend already declares them as collective nodes.
///
/// Per the plan, the frontend cannot pin the full numerical
/// contract for these collectives — tree shape and fabric
/// mapping are realization decisions. So this pass records the
/// collective's existence with a deliberately pessimistic
/// default exactness (`algorithm_exact` with `reduction_order`
/// and `associativity_grouping` as required invariants) that
/// forces any downstream realization to declare those
/// properties. Step 6's collective-synthesis pass refines the
/// class and invariants when it knows the real tree shape.
///
/// `axis = -1` is the "whole-workgroup / subgroup" sentinel
/// defined in `CollectiveSemanticNode` — subgroup ops are not
/// scoped to a TSIR iteration axis.
///
/// `dtype` resolves from the call's return type through
/// `scalarKindFromIr` after a `ref<…>` unwrap. Non-scalar
/// return types (e.g. `subgroupBallot` returning `vec4<u32>`)
/// fall back to `.u32` this iteration — a future increment
/// either extends `ScalarKind` or rejection-escalates the
/// fall-back path the same way non-scalar accumulators do.
pub fn collectCollectives(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    func_index: u32,
    rejections: *std.ArrayList(tsir.schema.RejectionEntry),
) FrontendError![]tsir.schema.CollectiveSemanticNode {
    var out = std.ArrayList(tsir.schema.CollectiveSemanticNode){};
    defer out.deinit(allocator);
    var axis_stack = std.ArrayList(u32){};
    defer axis_stack.deinit(allocator);

    var ctx = CollectiveWalkCtx{
        .allocator = allocator,
        .module = module,
        .function = function,
        .func_index = func_index,
        .rejections = rejections,
        .out = &out,
        .axis_counter = 0,
        .axis_stack = &axis_stack,
    };
    try walkCollectivesInStmt(&ctx, function.root_stmt);

    return out.toOwnedSlice(allocator) catch error.OutOfMemory;
}

const CollectiveWalkCtx = struct {
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    func_index: u32,
    rejections: *std.ArrayList(tsir.schema.RejectionEntry),
    out: *std.ArrayList(tsir.schema.CollectiveSemanticNode),
    /// Counter that increments on each for_loop entry, matching the
    /// axis index each for_loop contributes to the axes slice.
    axis_counter: u32,
    /// Stack of enclosing for_loop axis indices. `axis_stack.items[top]`
    /// is the innermost scope; empty means "no enclosing for loop"
    /// which maps to the schema's `-1` whole-workgroup sentinel.
    axis_stack: *std.ArrayList(u32),
};

fn walkCollectivesInStmt(ctx: *CollectiveWalkCtx, stmt_id: ir.StmtId) FrontendError!void {
    const stmt = ctx.function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                const child = ctx.function.stmt_children.items[range.start + i];
                try walkCollectivesInStmt(ctx, child);
            }
        },
        .local_decl => |d| {
            if (frontend_expr.tryExtractDispatchAxisLetter(ctx.function, d.initializer) != null) {
                ctx.axis_counter += 1;
            }
            if (d.initializer) |e| try walkCollectivesInExpr(ctx, e);
        },
        .expr => |e| try walkCollectivesInExpr(ctx, e),
        .assign => |a| {
            try walkCollectivesInExpr(ctx, a.lhs);
            try walkCollectivesInExpr(ctx, a.rhs);
        },
        .return_ => |opt| if (opt) |e| try walkCollectivesInExpr(ctx, e),
        .if_ => |node| {
            try walkCollectivesInExpr(ctx, node.cond);
            try walkCollectivesInStmt(ctx, node.then_block);
            if (node.else_block) |e| try walkCollectivesInStmt(ctx, e);
        },
        .loop_ => |loop| {
            // Decreasing for-loops don't contribute an axis;
            // mirror the axis walker so the counter and stack
            // stay in sync with the axes slice.
            var is_recognized_for = loop.kind == .for_loop and loop.init != null;
            if (is_recognized_for) {
                const init_stmt = ctx.function.stmts.items[loop.init.?];
                if (init_stmt == .local_decl and
                    frontend_expr.detectStepSign(ctx.function, loop.continuing, init_stmt.local_decl.local) == .negative)
                {
                    is_recognized_for = false;
                }
            }
            if (is_recognized_for) {
                const my_axis = ctx.axis_counter;
                ctx.axis_counter += 1;
                try ctx.axis_stack.append(ctx.allocator, my_axis);
            }
            if (loop.init) |init_id| try walkCollectivesInStmt(ctx, init_id);
            if (loop.cond) |cond| try walkCollectivesInExpr(ctx, cond);
            try walkCollectivesInStmt(ctx, loop.body);
            if (loop.continuing) |cont| try walkCollectivesInStmt(ctx, cont);
            if (is_recognized_for) _ = ctx.axis_stack.pop();
        },
        .switch_ => |s| try walkCollectivesInExpr(ctx, s.expr),
        else => {},
    }
}

fn walkCollectivesInExpr(ctx: *CollectiveWalkCtx, expr_id: ir.ExprId) FrontendError!void {
    const expr = ctx.function.exprs.items[expr_id];
    switch (expr.data) {
        .call => |c| {
            if (c.kind == .builtin) {
                if (builtinNameToCollectiveKind(c.name)) |kind| {
                    try emitCollectiveNode(ctx, expr, kind);
                }
            }
            var ai: u32 = 0;
            while (ai < c.args.len) : (ai += 1) {
                const arg_id = ctx.function.expr_args.items[c.args.start + ai];
                try walkCollectivesInExpr(ctx, arg_id);
            }
        },
        .load => |inner| try walkCollectivesInExpr(ctx, inner),
        .unary => |u| try walkCollectivesInExpr(ctx, u.operand),
        .binary => |b| {
            try walkCollectivesInExpr(ctx, b.lhs);
            try walkCollectivesInExpr(ctx, b.rhs);
        },
        .construct => |c| {
            var ai: u32 = 0;
            while (ai < c.args.len) : (ai += 1) {
                const arg_id = ctx.function.expr_args.items[c.args.start + ai];
                try walkCollectivesInExpr(ctx, arg_id);
            }
        },
        .member => |m| try walkCollectivesInExpr(ctx, m.base),
        .index => |idx| {
            try walkCollectivesInExpr(ctx, idx.base);
            try walkCollectivesInExpr(ctx, idx.index);
        },
        else => {},
    }
}

fn emitCollectiveNode(
    ctx: *CollectiveWalkCtx,
    expr: ir.ExprNode,
    kind: tsir.schema.CollectiveKind,
) FrontendError!void {
    var dtype: tsir.schema.ScalarKind = .u32;
    if (kind != .workgroup_barrier) {
        if (collectiveDtypeFromReturn(ctx.module, expr.ty)) |t| {
            dtype = t;
        } else {
            const collective_index: u32 = @intCast(ctx.out.items.len);
            const path = try std.fmt.allocPrint(
                ctx.allocator,
                "functions[{d}].collectives[{d}]",
                .{ ctx.func_index, collective_index },
            );
            const detail_copy = try ctx.allocator.dupe(
                u8,
                "collective return type is not representable as a single-scalar dtype",
            );
            try ctx.rejections.append(ctx.allocator, .{
                .reason = .tsir_collective_not_representable,
                .node_path = path,
                .detail = detail_copy,
            });
        }
    }
    const axis: i32 = if (ctx.axis_stack.items.len > 0)
        @intCast(ctx.axis_stack.items[ctx.axis_stack.items.len - 1])
    else
        -1;
    try ctx.out.append(ctx.allocator, .{
        .kind = kind,
        .axis = axis,
        .exactness = .{
            .class = .algorithm_exact,
            .algorithm_exact_invariants = &[_]tsir.schema.AlgorithmExactInvariant{
                .reduction_order,
                .associativity_grouping,
            },
        },
        .dtype = dtype,
    });
}

fn builtinNameToCollectiveKind(name: []const u8) ?tsir.schema.CollectiveKind {
    const eq = std.mem.eql;
    if (eq(u8, name, "subgroupAdd")) return .subgroup_add;
    if (eq(u8, name, "subgroupMin")) return .subgroup_min;
    if (eq(u8, name, "subgroupMax")) return .subgroup_max;
    if (eq(u8, name, "subgroupMul")) return .subgroup_mul;
    if (eq(u8, name, "subgroupBroadcast")) return .subgroup_broadcast;
    if (eq(u8, name, "subgroupShuffle")) return .subgroup_shuffle;
    if (eq(u8, name, "subgroupBallot")) return .subgroup_ballot;
    if (eq(u8, name, "subgroupInclusiveAdd")) return .subgroup_inclusive_scan;
    if (eq(u8, name, "subgroupInclusiveMul")) return .subgroup_inclusive_scan;
    if (eq(u8, name, "subgroupExclusiveAdd")) return .subgroup_exclusive_scan;
    if (eq(u8, name, "subgroupExclusiveMul")) return .subgroup_exclusive_scan;
    if (eq(u8, name, "workgroupBarrier")) return .workgroup_barrier;
    return null;
}

fn collectiveDtypeFromReturn(
    module: *const ir.Module,
    return_ty: ir.TypeId,
) ?tsir.schema.ScalarKind {
    var cursor = return_ty;
    const maybe_ref = module.types.get(cursor);
    if (maybe_ref == .ref) cursor = maybe_ref.ref.elem;
    const t = module.types.get(cursor);
    return switch (t) {
        .scalar => |s| types.scalarKindFromIr(s),
        else => null,
    };
}
