// TSIR frontend — WGSL IR → semantic TSIR lowering.
//
// The frontend recovers per-function bindings, iteration axes, reductions,
// collectives, family hints, and typed semantic bodies. Source constructs that
// cannot be represented are recorded as typed rejections; they never survive
// as plausible placeholder values.

const std = @import("std");
const ir = @import("../wgsl/ir/ir.zig");
const ir_query = @import("../wgsl/ir/ir_query.zig");
const layout_utils = @import("../wgsl/ir/layout_utils.zig");
const family_hint = @import("family_hint.zig");
const frontend_body = @import("frontend_body.zig");
const tsir = @import("schema.zig");

const frontend_collectives = @import("frontend_collectives.zig");
const frontend_expr = @import("frontend_expr.zig");
const frontend_rejections = @import("frontend_rejections.zig");
const frontend_types = @import("frontend_types.zig");

pub const FrontendError = frontend_types.FrontendError;
const findGlobalBase = ir_query.findGlobalBase;

pub fn lowerIrToTsir(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    source_digest: [32]u8,
    frontend_version: []const u8,
) FrontendError!tsir.Semantic {
    const functions = try allocator.alloc(tsir.schema.SemanticFunction, module.functions.items.len);
    errdefer allocator.free(functions);

    var rejections = std.ArrayList(tsir.schema.RejectionEntry){};
    defer rejections.deinit(allocator);

    for (module.functions.items, 0..) |ir_func, i| {
        const name_copy = try allocator.dupe(u8, ir_func.name);
        // Binding extraction is now per-function: only keep the
        // subset of module-scope globals this function's
        // expression list actually references. Two entry points
        // that touch disjoint binding sets therefore no longer
        // collide in the semantic digest's binding portion.
        const per_fn = try extractFunctionBindings(
            allocator,
            module,
            &ir_func,
            @intCast(i),
            &rejections,
        );
        const axes = try recoverIterationAxes(allocator, module, &ir_func);
        const reductions = try recoverReductions(
            allocator,
            module,
            &ir_func,
            @intCast(i),
            &rejections,
            per_fn.global_indices,
        );
        const collectives = try frontend_collectives.collectCollectives(allocator, module, &ir_func, @intCast(i), &rejections);
        try frontend_rejections.recoverRejections(allocator, &ir_func, @intCast(i), &rejections);
        const hint = family_hint.infer(&ir_func, axes, reductions);
        const body = try frontend_body.inferSemanticBody(allocator, module, hint, axes, per_fn.bindings, reductions);
        functions[i] = .{
            .name = name_copy,
            .family_hint = hint,
            .axes = axes,
            .bindings = per_fn.bindings,
            .reductions = reductions,
            .collectives = collectives,
            .body = body,
            .source_digest = source_digest,
        };
    }

    const rejections_slice = rejections.toOwnedSlice(allocator) catch return error.OutOfMemory;

    return .{
        .contract_version = tsir.CONTRACT_VERSION,
        .frontend_version = frontend_version,
        .functions = functions,
        .rejections = rejections_slice,
    };
}

const PerFunctionBindings = struct {
    bindings: []tsir.schema.BufferBinding,
    /// Module-`globals` index corresponding to each `bindings[i]`.
    /// Held alongside `bindings` so `mapGlobalIndexToBinding` can
    /// turn a `global_ref` index into a position within the
    /// per-function filtered slice without re-walking the module.
    global_indices: []u32,
};

/// Walk `function.exprs` collecting every `global_ref`, then walk
/// `module.globals` and keep the subset that (1) carry a bound
/// `@group(…) @binding(…)` annotation AND (2) are actually
/// referenced by one of the collected `global_ref` expressions.
/// The returned `bindings` and `global_indices` slices are aligned
/// index-for-index, so `bindings[i]` is the TSIR encoding of the
/// global at `module.globals[global_indices[i]]`.
///
fn extractFunctionBindings(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    function_index: u32,
    rejections: *std.ArrayList(tsir.schema.RejectionEntry),
) FrontendError!PerFunctionBindings {
    var referenced = std.AutoHashMap(u32, void).init(allocator);
    defer referenced.deinit();
    for (function.exprs.items) |expr| {
        if (expr.data == .global_ref) {
            try referenced.put(expr.data.global_ref, {});
        }
    }

    var out = std.ArrayList(tsir.schema.BufferBinding){};
    defer out.deinit(allocator);
    var indices = std.ArrayList(u32){};
    defer indices.deinit(allocator);

    for (module.globals.items, 0..) |g, gi| {
        const bp = g.binding orelse continue;
        if (!referenced.contains(@intCast(gi))) continue;
        const shape_and_elem = try extractElemAndShape(allocator, module, g);
        if (shape_and_elem == null) {
            const node_path = try std.fmt.allocPrint(
                allocator,
                "functions[{d}].bindings[{d}:{d}]",
                .{ function_index, bp.group, bp.binding },
            );
            try rejections.append(allocator, .{
                .reason = .tsir_binding_type_unlowerable,
                .node_path = node_path,
                .detail = try bindingTypeDetail(allocator, module, g),
            });
            continue;
        }
        const resolved = shape_and_elem.?;
        const read_write = blk: {
            if (g.access) |a| break :blk (a == .read_write);
            break :blk false;
        };
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, g.name),
            .group = bp.group,
            .binding = bp.binding,
            .logical_shape = resolved.shape,
            .elem = resolved.elem,
            .read_write = read_write,
        });
        try indices.append(allocator, @intCast(gi));
    }
    return .{
        .bindings = try out.toOwnedSlice(allocator),
        .global_indices = try indices.toOwnedSlice(allocator),
    };
}

const ShapeAndElem = struct {
    shape: []const u64,
    elem: tsir.schema.ScalarKind,
};

/// Map a Doe IR binding type onto a TSIR `(logical_shape, elem)` pair.
/// Numeric aggregates are flattened without changing their scalar type.
/// Uniform structs use their exact ABI size as a u32 word view because TSIR
/// consumes their named members through separately recovered byte offsets.
/// Resource handles, atomics, and storage structs have no BufferBinding
/// representation and return null so the caller emits a typed rejection.
fn extractElemAndShape(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    global: ir.Global,
) FrontendError!?ShapeAndElem {
    var cursor = global.ty;
    // Unwrap `ref` if the global carries one.
    const maybe_ref = module.types.get(cursor);
    if (maybe_ref == .ref) cursor = maybe_ref.ref.elem;

    const t = module.types.get(cursor);
    switch (t) {
        .scalar => |s| {
            return .{ .shape = &.{}, .elem = scalarKindFromIr(s) };
        },
        .array => |arr| {
            const nested = (try extractNumericShape(allocator, module, arr.elem)) orelse return null;
            defer if (nested.shape.len > 0) allocator.free(nested.shape);
            const shape = try allocator.alloc(u64, nested.shape.len + 1);
            shape[0] = if (arr.len) |n| n else 0;
            @memcpy(shape[1..], nested.shape);
            return .{ .shape = shape, .elem = nested.elem };
        },
        .vector => |vec| {
            const nested = (try extractNumericShape(allocator, module, vec.elem)) orelse return null;
            if (nested.shape.len != 0) return null;
            const shape = try allocator.alloc(u64, 1);
            shape[0] = @as(u64, vec.len);
            return .{ .shape = shape, .elem = nested.elem };
        },
        .matrix => |mat| {
            const nested = (try extractNumericShape(allocator, module, mat.elem)) orelse return null;
            if (nested.shape.len != 0) return null;
            const shape = try allocator.alloc(u64, 2);
            shape[0] = @as(u64, mat.rows);
            shape[1] = @as(u64, mat.columns);
            return .{ .shape = shape, .elem = nested.elem };
        },
        .struct_ => {
            if (global.addr_space != .uniform) return null;
            const byte_size = layout_utils.type_size(module, cursor);
            if (byte_size == 0 or byte_size % @sizeOf(u32) != 0) return null;
            const shape = try allocator.alloc(u64, 1);
            shape[0] = byte_size / @sizeOf(u32);
            return .{ .shape = shape, .elem = .u32 };
        },
        else => return null,
    }
}

fn extractNumericShape(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    ty: ir.TypeId,
) FrontendError!?ShapeAndElem {
    const synthetic = ir.Global{
        .name = "",
        .ty = ty,
        .class = .var_,
    };
    return extractElemAndShape(allocator, module, synthetic);
}

fn bindingTypeDetail(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    global: ir.Global,
) FrontendError![]const u8 {
    var cursor = global.ty;
    const maybe_ref = module.types.get(cursor);
    if (maybe_ref == .ref) cursor = maybe_ref.ref.elem;
    const tag = @tagName(std.meta.activeTag(module.types.get(cursor)));
    if (module.types.get(cursor) == .struct_) {
        const address_space = if (global.addr_space) |space| @tagName(space) else "none";
        return std.fmt.allocPrint(allocator, "{s}_{s}", .{ address_space, tag });
    }
    return allocator.dupe(u8, tag);
}

/// Walk the function body recursively and emit one
/// `IterationAxis` per `for_loop` whose init statement is a
/// `local_decl` — the canonical `for (var i = …; …; …) {…}`
/// shape. Axes are recorded in pre-order: a `for i { for k { … } }`
/// shape emits `[i, k]`. This matches how the canonical matmul /
/// GEMV / RMSNorm nested reductions describe their iteration
/// space: the outer axis (M / rows / output index) comes first,
/// the inner axis (K / reduction dimension) second.
///
/// `while` / `loop` forms (no explicit induction variable) still
/// do not emit axes here — `recoverRejections` handles the
/// top-level non-for case by emitting
/// `tsir_dependence_unanalyzable`. Nested `while` / `loop` is
/// still silent this iteration; a future increment extends the
/// rejection pass to descend into loop bodies alongside the
/// axis walker.
fn recoverIterationAxes(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
) FrontendError![]tsir.schema.IterationAxis {
    var axes = std.ArrayList(tsir.schema.IterationAxis){};
    defer axes.deinit(allocator);

    try walkAxesInStmt(allocator, module, function, function.root_stmt, &axes);
    return axes.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// Pre-order traversal helper used by `recoverIterationAxes`.
/// Descends into `block`, `if_` (then/else), and `loop_` bodies
/// so nested for loops at arbitrary depth still produce axes.
/// The traversal is depth-first with outer-before-inner ordering:
/// when this function sees a `for_loop`, it records the axis FIRST
/// and then recurses into the body so inner axes appear after
/// their enclosing outer axis in the resulting slice.
fn walkAxesInStmt(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    axes: *std.ArrayList(tsir.schema.IterationAxis),
) FrontendError!void {
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                const child_id = function.stmt_children.items[range.start + i];
                const child = function.stmts.items[child_id];
                // Dispatch-grid axis: needs sibling context to
                // pick up the `if (i >= bound) return;` guard
                // that refines the placeholder upper bound, so
                // emission lives here in the block case rather
                // than in the recursive per-stmt switch.
                if (child == .local_decl) {
                    const d = child.local_decl;
                    if (frontend_expr.tryExtractDispatchAxisLetter(function, d.initializer)) |letter| {
                        if (d.local < function.locals.items.len) {
                            const local_name = function.locals.items[d.local].name;
                            const name_copy = try allocator.dupe(u8, local_name);
                            const lower_copy = try allocator.dupe(u8, "0");
                            const upper_copy = blk: {
                                if (try frontend_expr.scanForDispatchGuard(
                                    allocator,
                                    module,
                                    function,
                                    range,
                                    i,
                                    d.local,
                                )) |s| {
                                    break :blk s;
                                }
                                break :blk try std.fmt.allocPrint(
                                    allocator,
                                    "dispatch.{s}",
                                    .{letter},
                                );
                            };
                            const step_copy = try allocator.dupe(u8, "1");
                            try axes.append(allocator, .{
                                .name = name_copy,
                                .lower_bound = lower_copy,
                                .upper_bound = upper_copy,
                                .step = step_copy,
                            });
                        }
                        continue;
                    }
                }
                try walkAxesInStmt(allocator, module, function, child_id, axes);
            }
        },
        .if_ => |node| {
            try walkAxesInStmt(allocator, module, function, node.then_block, axes);
            if (node.else_block) |else_id| {
                try walkAxesInStmt(allocator, module, function, else_id, axes);
            }
        },
        .loop_ => |loop| {
            if (loop.kind == .for_loop) {
                if (loop.init) |init_id| {
                    const init_stmt = function.stmts.items[init_id];
                    if (init_stmt == .local_decl) {
                        const local_index = init_stmt.local_decl.local;
                        // Decreasing for-loops don't fit TSIR's
                        // half-open `[lower, upper)` iteration
                        // model; `recoverRejections` will emit a
                        // `tsir_source_not_affine` entry for
                        // them. Skip emitting an axis here so
                        // the reduction/collective walkers'
                        // axis counters stay in sync.
                        if (frontend_expr.detectStepSign(function, loop.continuing, local_index) == .negative) {
                            try walkAxesInStmt(allocator, module, function, loop.body, axes);
                            if (loop.continuing) |cont_id| {
                                try walkAxesInStmt(allocator, module, function, cont_id, axes);
                            }
                            return;
                        }
                        if (local_index < function.locals.items.len) {
                            const local_name = function.locals.items[local_index].name;
                            const name_copy = try allocator.dupe(u8, local_name);
                            const lower_copy = blk: {
                                if (try frontend_expr.extractInitBound(
                                    allocator,
                                    module,
                                    function,
                                    init_stmt.local_decl.initializer,
                                )) |s| {
                                    break :blk s;
                                }
                                break :blk try allocator.dupe(u8, "0");
                            };
                            const upper_copy = blk: {
                                if (frontend_expr.extractLiteralUpperBound(function, loop.cond, local_index)) |ub| {
                                    break :blk try std.fmt.allocPrint(allocator, "{d}", .{ub});
                                }
                                if (try frontend_expr.extractSymbolicUpperBound(
                                    allocator,
                                    module,
                                    function,
                                    loop.cond,
                                    local_index,
                                )) |s| {
                                    break :blk s;
                                }
                                break :blk try allocator.dupe(u8, "upper_bound");
                            };
                            const step_copy = blk: {
                                if (try frontend_expr.extractStep(
                                    allocator,
                                    module,
                                    function,
                                    loop.continuing,
                                    local_index,
                                )) |s| {
                                    break :blk s;
                                }
                                break :blk try allocator.dupe(u8, "1");
                            };
                            try axes.append(allocator, .{
                                .name = name_copy,
                                .lower_bound = lower_copy,
                                .upper_bound = upper_copy,
                                .step = step_copy,
                            });
                        }
                    }
                }
            }
            // Descend into the body whether or not this loop was
            // a recognized for: nested for loops inside a while /
            // bare loop should still contribute axes, and the
            // containing non-for will rejection-escalate via a
            // separate future increment that extends
            // `recoverRejections`.
            try walkAxesInStmt(allocator, module, function, loop.body, axes);
            if (loop.continuing) |cont_id| {
                try walkAxesInStmt(allocator, module, function, cont_id, axes);
            }
        },
        else => {},
    }
}

/// Walk the function body recursively and emit one
/// `ReductionRegion` for every `for_loop` whose direct body
/// contains a self-update on a local accumulator. The walk
/// mirrors `walkAxesInStmt`: for_loops are visited in pre-order,
/// with an axis counter that matches the axes slice emitted by
/// `recoverIterationAxes` — so a reduction detected inside the
/// inner loop of a canonical `for i { for k { acc += ... } }`
/// shape reports `axis = 1` (the position of `k` in the axes
/// slice), not `axis = 0`.
///
/// Writeback resolution is done against the for_loop's PARENT
/// block, not the function root: for a nested reduction, the
/// `output[i] = acc` writeback sits in the outer loop's body
/// after the inner for_loop, so the resolver needs that block's
/// range + the inner loop's position within it. The walker
/// threads `(parent_block, position_in_parent)` through
/// recursion for that purpose.
///
/// Patterns recognized are unchanged from the top-level version:
/// compound-assign (`acc += x`) and expanded self-update
/// (`acc = acc + x`), mapped through `detectReductionOp`.
/// Honest-fallback + typed rejections for unresolved writebacks
/// and non-scalar accumulators also carry over unchanged.
fn recoverReductions(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    func_index: u32,
    rejections: *std.ArrayList(tsir.schema.RejectionEntry),
    binding_global_indices: []const u32,
) FrontendError![]tsir.schema.ReductionRegion {
    var reductions = std.ArrayList(tsir.schema.ReductionRegion){};
    defer reductions.deinit(allocator);

    var ctx = ReductionWalkCtx{
        .allocator = allocator,
        .module = module,
        .function = function,
        .func_index = func_index,
        .rejections = rejections,
        .reductions = &reductions,
        .binding_global_indices = binding_global_indices,
        .axis_counter = 0,
    };
    try walkReductionsInStmt(&ctx, function.root_stmt, null, 0);
    return reductions.toOwnedSlice(allocator) catch error.OutOfMemory;
}

const ReductionWalkCtx = struct {
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *const ir.Function,
    func_index: u32,
    rejections: *std.ArrayList(tsir.schema.RejectionEntry),
    reductions: *std.ArrayList(tsir.schema.ReductionRegion),
    binding_global_indices: []const u32,
    /// Counter that increments on each for_loop entry (pre-order).
    /// Must stay in lockstep with `walkAxesInStmt`'s for_loop
    /// visit order so the `axis` field on each emitted
    /// ReductionRegion is a valid index into the axes slice.
    axis_counter: u32,
};

fn walkReductionsInStmt(
    ctx: *ReductionWalkCtx,
    stmt_id: ir.StmtId,
    parent_block: ?ir.Range,
    position_in_parent: u32,
) FrontendError!void {
    const stmt = ctx.function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                const child_id = ctx.function.stmt_children.items[range.start + i];
                try walkReductionsInStmt(ctx, child_id, range, i);
            }
        },
        .if_ => |node| {
            try walkReductionsInStmt(ctx, node.then_block, null, 0);
            if (node.else_block) |else_id| {
                try walkReductionsInStmt(ctx, else_id, null, 0);
            }
        },
        .local_decl => |d| {
            // A `let i = gid.x` declaration contributes one
            // dispatch-grid axis to the axes slice. Keep the
            // reduction walker's axis counter in lockstep so a
            // subsequent for_loop's `my_axis` matches the axes
            // slice built by `walkAxesInStmt`.
            if (frontend_expr.tryExtractDispatchAxisLetter(ctx.function, d.initializer) != null) {
                ctx.axis_counter += 1;
            }
        },
        .loop_ => |loop| {
            if (loop.kind == .for_loop and loop.init != null) {
                // Mirror the axis walker: decreasing for-loops
                // contribute no axis, so skip the counter bump
                // and the reduction scan but still descend into
                // the body so nested axes / reductions inside a
                // decreasing outer loop still get picked up.
                const init_stmt = ctx.function.stmts.items[loop.init.?];
                const decreasing = init_stmt == .local_decl and
                    frontend_expr.detectStepSign(ctx.function, loop.continuing, init_stmt.local_decl.local) == .negative;
                if (!decreasing) {
                    const my_axis = ctx.axis_counter;
                    ctx.axis_counter += 1;
                    if (parent_block) |pb| {
                        try scanDirectBodyForReduction(
                            ctx,
                            loop.body,
                            my_axis,
                            pb,
                            position_in_parent,
                        );
                    }
                }
            }
            try walkReductionsInStmt(ctx, loop.body, null, 0);
            if (loop.continuing) |cont_id| {
                try walkReductionsInStmt(ctx, cont_id, null, 0);
            }
        },
        else => {},
    }
}

/// Scan the direct (one-level) statements of a for_loop body for
/// the first assign that matches a reduction self-update; emit
/// the `ReductionRegion` and any accompanying rejections.
/// Writeback resolution uses the loop's parent block so nested
/// reductions resolve into the enclosing outer loop's body, not
/// the function root.
fn scanDirectBodyForReduction(
    ctx: *ReductionWalkCtx,
    body_stmt_id: ir.StmtId,
    my_axis: u32,
    parent_block: ir.Range,
    position_in_parent: u32,
) FrontendError!void {
    const body_stmt = ctx.function.stmts.items[body_stmt_id];
    if (body_stmt != .block) return;
    const body_range = body_stmt.block;

    var j: u32 = 0;
    while (j < body_range.len) : (j += 1) {
        const bs_id = ctx.function.stmt_children.items[body_range.start + j];
        const bs = ctx.function.stmts.items[bs_id];
        if (bs != .assign) continue;
        const assign = bs.assign;

        const recovered_op = detectReductionOp(ctx.function, assign);
        if (recovered_op) |op| {
            const lhs_node = ctx.function.exprs.items[assign.lhs];
            const acc_local = lhs_node.data.local_ref;

            const resolved = resolveTargetBinding(
                ctx.function,
                parent_block,
                position_in_parent,
                acc_local,
                ctx.binding_global_indices,
            );
            const target_binding: u32 = resolved orelse 0;
            if (resolved == null) {
                const reduction_index: u32 = @intCast(ctx.reductions.items.len);
                const path = try std.fmt.allocPrint(
                    ctx.allocator,
                    "functions[{d}].reductions[{d}]",
                    .{ ctx.func_index, reduction_index },
                );
                const detail_copy = try ctx.allocator.dupe(
                    u8,
                    "reduction accumulator has no post-loop writeback to a bound global",
                );
                try ctx.rejections.append(ctx.allocator, .{
                    .reason = .tsir_dependence_unanalyzable,
                    .node_path = path,
                    .detail = detail_copy,
                });
            }
            const resolved_kind = resolveAccumulationKind(ctx.module, ctx.function, acc_local);
            const accumulation: tsir.schema.ScalarKind = resolved_kind orelse .f32;
            if (resolved_kind == null) {
                const reduction_index: u32 = @intCast(ctx.reductions.items.len);
                const path = try std.fmt.allocPrint(
                    ctx.allocator,
                    "functions[{d}].reductions[{d}]",
                    .{ ctx.func_index, reduction_index },
                );
                const detail_copy = try ctx.allocator.dupe(
                    u8,
                    "reduction accumulator type is not representable as a single-scalar accumulation",
                );
                try ctx.rejections.append(ctx.allocator, .{
                    .reason = .tsir_dependence_unanalyzable,
                    .node_path = path,
                    .detail = detail_copy,
                });
            }
            try ctx.reductions.append(ctx.allocator, .{
                .axis = my_axis,
                .op = op,
                .contract = .{
                    .accumulation = accumulation,
                    .associativity = .strict_ordered,
                    .nan_inf = .propagate,
                },
                .target_binding = target_binding,
            });
            return;
        }
    }
}

/// Resolve the binding index a reduction's accumulator is written
/// into by scanning top-level statements that come AFTER the
/// reduction loop. Handles both the direct shape
/// `output[...] = load(acc)` and chained post-reduction epilogues
/// like `let mean = acc / n; let inv = rsqrt(mean + eps);
/// output[...] = input[...] * inv`. An alias set starts at
/// `{acc_local}` and grows each time a post-loop `local_decl`
/// initializer contains a load of an existing alias. The writeback
/// is accepted whenever its rhs contains a load of any alias
/// currently in the set.
///
/// Returns `null` when no matching writeback is found. The caller
/// handles that case by emitting a typed
/// `tsir_dependence_unanalyzable` rejection and falling back to
/// `target_binding = 0` — the rejection is the load-bearing
/// signal that downstream consumers must fail closed on, not the
/// fallback index.
fn resolveTargetBinding(
    function: *const ir.Function,
    body_range: ir.Range,
    loop_index: u32,
    acc_local: u32,
    binding_global_indices: []const u32,
) ?u32 {
    // Fixed-size alias buffer; real kernels rarely chain more than
    // one or two copies, and overflow is just "stop tracking new
    // aliases" rather than an error. Existing aliases still
    // resolve.
    var alias_buf: [8]u32 = undefined;
    alias_buf[0] = acc_local;
    var alias_len: u32 = 1;

    var k: u32 = loop_index + 1;
    while (k < body_range.len) : (k += 1) {
        const stmt_id = function.stmt_children.items[body_range.start + k];
        const stmt = function.stmts.items[stmt_id];
        switch (stmt) {
            .local_decl => |d| {
                const init_id = d.initializer orelse continue;
                if (!containsAliasLoad(function, init_id, alias_buf[0..alias_len])) continue;
                if (alias_len < alias_buf.len) {
                    alias_buf[alias_len] = d.local;
                    alias_len += 1;
                }
            },
            .assign => |assign| {
                // Accept the writeback when the rhs expression
                // tree contains a `load(local_ref(x))` of any
                // current alias — covers pure `output = acc`
                // and post-reduction epilogues like
                // `output = acc * scale`, `output = acc + bias`,
                // or intrinsics (`sqrt(acc)`) whose operand is
                // the accumulator. Attribution stays on the
                // final writeback's binding: the reduction
                // produces acc, the epilogue shapes it, the
                // binding holds the shaped result.
                if (!containsAliasLoad(function, assign.rhs, alias_buf[0..alias_len])) continue;

                const global_index = findGlobalBase(function, assign.lhs) orelse continue;
                if (mapGlobalIndexToBinding(binding_global_indices, global_index)) |bpos| return bpos;
            },
            else => {},
        }
    }
    return null;
}

/// Return true when the expression tree rooted at `expr_id`
/// contains at least one `load(local_ref(X))` where `X` is in
/// the alias set. Walks unary / binary / index / member /
/// construct / call argument trees; non-matching leaves
/// (literals, global/param refs, unrelated local refs) return
/// false. Used by `resolveTargetBinding` to accept writebacks
/// whose rhs is an arithmetic expression built from the
/// accumulator (e.g. post-reduction epilogues like
/// `output = acc * scale`).
fn containsAliasLoad(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    aliases: []const u32,
) bool {
    const node = function.exprs.items[expr_id];
    switch (node.data) {
        .load => |inner| {
            const inner_node = function.exprs.items[inner];
            if (inner_node.data == .local_ref and isInAliasSet(aliases, inner_node.data.local_ref)) {
                return true;
            }
            return containsAliasLoad(function, inner, aliases);
        },
        .unary => |u| return containsAliasLoad(function, u.operand, aliases),
        .binary => |b| {
            return containsAliasLoad(function, b.lhs, aliases) or
                containsAliasLoad(function, b.rhs, aliases);
        },
        .index => |idx| {
            return containsAliasLoad(function, idx.base, aliases) or
                containsAliasLoad(function, idx.index, aliases);
        },
        .member => |m| return containsAliasLoad(function, m.base, aliases),
        .construct => |c| {
            var i: u32 = 0;
            while (i < c.args.len) : (i += 1) {
                const arg_id = function.expr_args.items[c.args.start + i];
                if (containsAliasLoad(function, arg_id, aliases)) return true;
            }
            return false;
        },
        .call => |c| {
            var i: u32 = 0;
            while (i < c.args.len) : (i += 1) {
                const arg_id = function.expr_args.items[c.args.start + i];
                if (containsAliasLoad(function, arg_id, aliases)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn isInAliasSet(aliases: []const u32, needle: u32) bool {
    for (aliases) |a| {
        if (a == needle) return true;
    }
    return false;
}

/// Resolve the reduction accumulator's declared IR type to the
/// matching TSIR `ScalarKind`. The accumulator's `TypeId` is
/// `function.locals[acc_local].ty`; after unwrapping a `ref<…>`
/// layer (locals declared via `var` carry `ref` in the IR type
/// table), the underlying type is expected to be a scalar.
///
/// Returns `null` when the accumulator is non-scalar (vector,
/// matrix, array, struct) — the current `NumericalContract`
/// can't represent those faithfully, so the caller emits a
/// typed rejection and keeps `.f32` as the shape-preserving
/// default. A future increment either extends the contract to
/// represent vector-typed accumulators or keeps rejecting them
/// under a more specific reason.
fn resolveAccumulationKind(
    module: *const ir.Module,
    function: *const ir.Function,
    acc_local: u32,
) ?tsir.schema.ScalarKind {
    if (acc_local >= function.locals.items.len) return null;
    var cursor = function.locals.items[acc_local].ty;
    const maybe_ref = module.types.get(cursor);
    if (maybe_ref == .ref) cursor = maybe_ref.ref.elem;
    const t = module.types.get(cursor);
    return switch (t) {
        .scalar => |s| scalarKindFromIr(s),
        else => null,
    };
}

fn scalarKindFromIr(s: ir.ScalarType) tsir.schema.ScalarKind {
    return switch (s) {
        .f32 => .f32,
        .f16 => .f16,
        .i32 => .i32,
        .u32 => .u32,
        .abstract_int => .i32,
        .abstract_float => .f32,
        .bool, .void => .u32,
    };
}

/// Convert a `module.globals` index into a position within the
/// per-function filtered `bindings` slice. `binding_global_indices`
/// is held alongside `bindings`, with `bindings[i]` encoding the
/// global at `binding_global_indices[i]`, so a linear search
/// returns the aligned position directly. Returns `null` when the
/// global is not in the per-function binding set — either because
/// it has no `@binding` annotation OR because the function does
/// not reference it.
fn mapGlobalIndexToBinding(
    binding_global_indices: []const u32,
    global_index: u32,
) ?u32 {
    for (binding_global_indices, 0..) |gi, pos| {
        if (gi == global_index) return @intCast(pos);
    }
    return null;
}

fn detectReductionOp(
    function: *const ir.Function,
    assign: anytype,
) ?tsir.schema.ReductionOp {
    const lhs_node = function.exprs.items[assign.lhs];
    if (lhs_node.data != .local_ref) return null;
    const acc_local = lhs_node.data.local_ref;

    // Compound-assign path: `acc += x` / `acc *= x`.
    switch (assign.op) {
        .add => return .sum,
        .mul => return .product,
        else => {},
    }
    if (assign.op != .assign) return null;

    const rhs_node = function.exprs.items[assign.rhs];

    // Expanded-self-update path: `acc = acc <op> x`.
    if (rhs_node.data == .binary) {
        const binary = rhs_node.data.binary;
        const binary_lhs_node = function.exprs.items[binary.lhs];
        if (binary_lhs_node.data == .load) {
            const inner_ref_node = function.exprs.items[binary_lhs_node.data.load];
            if (inner_ref_node.data == .local_ref and inner_ref_node.data.local_ref == acc_local) {
                return switch (binary.op) {
                    .add => .sum,
                    .mul => .product,
                    else => null,
                };
            }
        }
    }

    // Intrinsic-call self-update: `acc = max(acc, x)` /
    // `min(acc, x)` or the commutative-swapped `max(x, acc)` /
    // `min(x, acc)`. Recognized when the rhs is a builtin call
    // to `max` / `min` and at least one argument is a load of
    // the accumulator. Since min and max are commutative, either
    // argument position counts as a valid self-update match.
    // The other argument is the per-iteration input; its shape
    // doesn't affect the reduction-region contract, so no
    // structural verification is needed.
    if (rhs_node.data == .call) {
        const c = rhs_node.data.call;
        const is_max = std.mem.eql(u8, c.name, "max");
        const is_min = std.mem.eql(u8, c.name, "min");
        if (c.kind == .builtin and (is_max or is_min) and c.args.len >= 2) {
            var ai: u32 = 0;
            while (ai < c.args.len) : (ai += 1) {
                const arg_id = function.expr_args.items[c.args.start + ai];
                const arg_node = function.exprs.items[arg_id];
                if (arg_node.data != .load) continue;
                const inner = function.exprs.items[arg_node.data.load];
                if (inner.data != .local_ref) continue;
                if (inner.data.local_ref != acc_local) continue;
                return if (is_max) .max else .min;
            }
        }
    }

    return null;
}
