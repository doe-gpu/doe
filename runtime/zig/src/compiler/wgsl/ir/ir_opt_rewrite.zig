// Shared WGSL IR rewrite optimization pass.
//
// Moves backend-local integer/bool identity rewrites into the typed IR pipeline
// so all emitters see the same simplified expression graph. This pass rewrites
// expression references to existing operands when the replacement preserves the
// expression type/category and required dynamic operand evaluation.

const std = @import("std");
const ir = @import("ir.zig");
const ir_const_eval = @import("ir_const_eval.zig");

const ZERO_INT: u64 = 0;
const ONE_INT: u64 = 1;

const OperandSlot = enum {
    lhs,
    rhs,
};

pub const RewriteError = error{
    OutOfMemory,
};

pub const Config = struct {
    integer_identities: bool = true,
    bool_identities: bool = true,
};

pub const Stats = struct {
    const_integer_unary_folds: u32 = 0,
    const_integer_folds: u32 = 0,
    integer_identities: u32 = 0,
    bool_identities: u32 = 0,
    expr_refs_rewritten: u32 = 0,

    pub fn total(self: Stats) u32 {
        return self.const_integer_unary_folds + self.const_integer_folds + self.integer_identities + self.bool_identities;
    }
};

/// Apply backend-independent integer/bool identity rewrites to every function.
pub fn apply(allocator: std.mem.Allocator, module: *ir.Module) RewriteError!Stats {
    return applyWithConfig(allocator, module, .{});
}

pub fn applyWithConfig(
    allocator: std.mem.Allocator,
    module: *ir.Module,
    config: Config,
) RewriteError!Stats {
    var stats = Stats{};
    for (module.functions.items) |*function| {
        try rewriteFunction(allocator, module, function, config, &stats);
    }
    return stats;
}

fn rewriteFunction(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    function: *ir.Function,
    config: Config,
    stats: *Stats,
) RewriteError!void {
    const expr_count = function.exprs.items.len;
    const replacements = try allocator.alloc(ir.ExprId, expr_count);
    defer allocator.free(replacements);

    for (replacements, 0..) |*replacement, index| {
        replacement.* = @intCast(index);
    }

    var expr_index: usize = 0;
    while (expr_index < expr_count) : (expr_index += 1) {
        const expr_id: ir.ExprId = @intCast(expr_index);
        rewriteExprRefs(function, replacements, expr_id, stats);
        const expr = &function.exprs.items[expr_id];
        switch (expr.data) {
            .binary => |binary| {
                if (config.integer_identities) {
                    if (tryFoldConstIntegerBinary(module, function, expr_id, binary, stats)) continue;
                    if (tryRewriteIntegerIdentity(module, function, replacements, expr_id, binary, stats)) continue;
                }
                if (config.bool_identities) {
                    if (tryRewriteBoolIdentity(module, function, replacements, expr_id, binary, stats)) continue;
                }
            },
            .unary => |unary| {
                if (config.integer_identities) {
                    if (tryFoldConstIntegerUnary(module, function, expr_id, unary, stats)) continue;
                }
            },
            else => {},
        }
    }

    rewriteStmtExprRefs(function, replacements, stats);
    rewriteSwitchSelectorRefs(function, replacements, stats);
}

fn rewriteExprRefs(
    function: *ir.Function,
    replacements: []const ir.ExprId,
    expr_id: ir.ExprId,
    stats: *Stats,
) void {
    const expr = &function.exprs.items[expr_id];
    switch (expr.data) {
        .load => |inner| {
            const replacement = replaceExprRef(replacements, inner, stats);
            if (replacement != inner) expr.data = .{ .load = replacement };
        },
        .unary => |unary| {
            const operand = replaceExprRef(replacements, unary.operand, stats);
            if (operand != unary.operand) {
                expr.data = .{ .unary = .{
                    .op = unary.op,
                    .operand = operand,
                } };
            }
        },
        .binary => |binary| {
            const lhs = replaceExprRef(replacements, binary.lhs, stats);
            const rhs = replaceExprRef(replacements, binary.rhs, stats);
            if (lhs != binary.lhs or rhs != binary.rhs) {
                expr.data = .{ .binary = .{
                    .op = binary.op,
                    .lhs = lhs,
                    .rhs = rhs,
                } };
            }
        },
        .call => |call| rewriteExprRange(function, replacements, call.args, stats),
        .construct => |construct| rewriteExprRange(function, replacements, construct.args, stats),
        .member => |member| {
            const base = replaceExprRef(replacements, member.base, stats);
            if (base != member.base) {
                expr.data = .{ .member = .{
                    .base = base,
                    .field_name = member.field_name,
                    .field_index = member.field_index,
                } };
            }
        },
        .index => |index| {
            const base = replaceExprRef(replacements, index.base, stats);
            const index_expr = replaceExprRef(replacements, index.index, stats);
            if (base != index.base or index_expr != index.index) {
                expr.data = .{ .index = .{
                    .base = base,
                    .index = index_expr,
                } };
            }
        },
        else => {},
    }
}

fn rewriteExprRange(
    function: *ir.Function,
    replacements: []const ir.ExprId,
    range: ir.Range,
    stats: *Stats,
) void {
    var offset: u32 = 0;
    while (offset < range.len) : (offset += 1) {
        const arg_index = range.start + offset;
        function.expr_args.items[arg_index] = replaceExprRef(replacements, function.expr_args.items[arg_index], stats);
    }
}

fn rewriteStmtExprRefs(function: *ir.Function, replacements: []const ir.ExprId, stats: *Stats) void {
    for (function.stmts.items) |*stmt| {
        switch (stmt.*) {
            .local_decl => |decl| {
                if (decl.initializer) |initializer| {
                    const replacement = replaceExprRef(replacements, initializer, stats);
                    if (replacement != initializer) {
                        stmt.* = .{ .local_decl = .{
                            .local = decl.local,
                            .initializer = replacement,
                            .is_const = decl.is_const,
                        } };
                    }
                }
            },
            .expr => |expr_id| {
                const replacement = replaceExprRef(replacements, expr_id, stats);
                if (replacement != expr_id) stmt.* = .{ .expr = replacement };
            },
            .assign => |assign| {
                const lhs = replaceExprRef(replacements, assign.lhs, stats);
                const rhs = replaceExprRef(replacements, assign.rhs, stats);
                if (lhs != assign.lhs or rhs != assign.rhs) {
                    stmt.* = .{ .assign = .{
                        .op = assign.op,
                        .lhs = lhs,
                        .rhs = rhs,
                    } };
                }
            },
            .return_ => |maybe_expr| {
                if (maybe_expr) |expr_id| {
                    const replacement = replaceExprRef(replacements, expr_id, stats);
                    if (replacement != expr_id) stmt.* = .{ .return_ = replacement };
                }
            },
            .if_ => |if_stmt| {
                const cond = replaceExprRef(replacements, if_stmt.cond, stats);
                if (cond != if_stmt.cond) {
                    stmt.* = .{ .if_ = .{
                        .cond = cond,
                        .then_block = if_stmt.then_block,
                        .else_block = if_stmt.else_block,
                    } };
                }
            },
            .loop_ => |loop| {
                if (loop.cond) |cond| {
                    const replacement = replaceExprRef(replacements, cond, stats);
                    if (replacement != cond) {
                        stmt.* = .{ .loop_ = .{
                            .kind = loop.kind,
                            .init = loop.init,
                            .cond = replacement,
                            .continuing = loop.continuing,
                            .body = loop.body,
                        } };
                    }
                }
            },
            .switch_ => |switch_stmt| {
                const expr_id = replaceExprRef(replacements, switch_stmt.expr, stats);
                if (expr_id != switch_stmt.expr) {
                    stmt.* = .{ .switch_ = .{
                        .expr = expr_id,
                        .cases = switch_stmt.cases,
                    } };
                }
            },
            .block, .break_, .continue_, .discard_ => {},
        }
    }
}

fn rewriteSwitchSelectorRefs(function: *ir.Function, replacements: []const ir.ExprId, stats: *Stats) void {
    for (function.switch_cases.items) |*case_node| {
        for (case_node.selectors.items) |*selector| {
            selector.* = replaceExprRef(replacements, selector.*, stats);
        }
    }
}

fn tryFoldConstIntegerBinary(
    module: *const ir.Module,
    function: *ir.Function,
    expr_id: ir.ExprId,
    binary: @FieldType(ir.Expr, "binary"),
    stats: *Stats,
) bool {
    const result_scalar = scalarKind(module, function.exprs.items[expr_id].ty) orelse return false;
    if (!isIntegerScalar(result_scalar)) return false;

    const lhs_raw = ir_const_eval.resolve_constant_int(module, function, binary.lhs) orelse return false;
    const rhs_raw = ir_const_eval.resolve_constant_int(module, function, binary.rhs) orelse return false;
    const folded = foldIntegerBinary(binary.op, result_scalar, lhs_raw, rhs_raw) orelse return false;
    function.exprs.items[expr_id].data = .{ .int_lit = folded };
    stats.const_integer_folds += 1;
    return true;
}

fn tryFoldConstIntegerUnary(
    module: *const ir.Module,
    function: *ir.Function,
    expr_id: ir.ExprId,
    unary: @FieldType(ir.Expr, "unary"),
    stats: *Stats,
) bool {
    const result_scalar = scalarKind(module, function.exprs.items[expr_id].ty) orelse return false;
    if (!isIntegerScalar(result_scalar)) return false;

    const operand_raw = ir_const_eval.resolve_constant_int(module, function, unary.operand) orelse return false;
    const folded = foldIntegerUnary(unary.op, result_scalar, operand_raw) orelse return false;
    function.exprs.items[expr_id].data = .{ .int_lit = folded };
    stats.const_integer_unary_folds += 1;
    return true;
}

fn foldIntegerUnary(op: ir.UnaryOp, result_scalar: ir.ScalarType, operand_raw: u64) ?u64 {
    const operand_u32: u32 = @truncate(operand_raw);
    const operand_i32: i32 = @bitCast(operand_u32);
    const folded_u32: u32 = switch (op) {
        .bit_not => ~operand_u32,
        .neg => switch (result_scalar) {
            .i32, .abstract_int => @bitCast(-%operand_i32),
            else => return null,
        },
        else => return null,
    };
    return folded_u32;
}

fn foldIntegerBinary(op: ir.BinaryOp, result_scalar: ir.ScalarType, lhs_raw: u64, rhs_raw: u64) ?u64 {
    const unsigned = result_scalar == .u32;
    const lhs_u32: u32 = @truncate(lhs_raw);
    const rhs_u32: u32 = @truncate(rhs_raw);
    const lhs_i32: i32 = @bitCast(lhs_u32);
    const rhs_i32: i32 = @bitCast(rhs_u32);
    const folded_u32: u32 = switch (op) {
        .add => lhs_u32 +% rhs_u32,
        .sub => lhs_u32 -% rhs_u32,
        .mul => lhs_u32 *% rhs_u32,
        .div => blk: {
            if (rhs_u32 == 0) return null;
            if (unsigned) break :blk lhs_u32 / rhs_u32;
            if (lhs_i32 == std.math.minInt(i32) and rhs_i32 == -1) return null;
            break :blk @bitCast(@divTrunc(lhs_i32, rhs_i32));
        },
        .rem => blk: {
            if (rhs_u32 == 0) return null;
            if (unsigned) break :blk lhs_u32 % rhs_u32;
            if (lhs_i32 == std.math.minInt(i32) and rhs_i32 == -1) return null;
            break :blk @bitCast(@rem(lhs_i32, rhs_i32));
        },
        .bit_and => lhs_u32 & rhs_u32,
        .bit_or => lhs_u32 | rhs_u32,
        .bit_xor => lhs_u32 ^ rhs_u32,
        .shift_left => if (rhs_u32 >= 32) 0 else lhs_u32 << @intCast(rhs_u32),
        .shift_right => if (unsigned)
            (if (rhs_u32 >= 32) 0 else lhs_u32 >> @intCast(rhs_u32))
        else
            @bitCast(if (rhs_u32 >= 32) @as(i32, if (lhs_i32 < 0) -1 else 0) else lhs_i32 >> @intCast(rhs_u32)),
        else => return null,
    };
    return folded_u32;
}

fn tryRewriteIntegerIdentity(
    module: *const ir.Module,
    function: *const ir.Function,
    replacements: []ir.ExprId,
    expr_id: ir.ExprId,
    binary: @FieldType(ir.Expr, "binary"),
    stats: *Stats,
) bool {
    const result_scalar = scalarKind(module, function.exprs.items[expr_id].ty) orelse return false;
    if (!isIntegerScalar(result_scalar)) return false;

    if (ir_const_eval.resolve_constant_int(module, function, binary.lhs)) |constant| {
        if (integerIdentityReplacementFromLeftConstant(binary.op, constant)) |slot| {
            if (canReplaceWith(function, expr_id, slot)) {
                replacements[expr_id] = replacementExprId(function, expr_id, slot);
                stats.integer_identities += 1;
                return true;
            }
        }
    }

    if (ir_const_eval.resolve_constant_int(module, function, binary.rhs)) |constant| {
        if (integerIdentityReplacementFromRightConstant(binary.op, constant)) |slot| {
            if (canReplaceWith(function, expr_id, slot)) {
                replacements[expr_id] = replacementExprId(function, expr_id, slot);
                stats.integer_identities += 1;
                return true;
            }
        }
    }

    return false;
}

fn integerIdentityReplacementFromLeftConstant(op: ir.BinaryOp, constant: u64) ?OperandSlot {
    return switch (op) {
        .add, .bit_or, .bit_xor => if (constant == ZERO_INT) .rhs else null,
        .mul => if (constant == ZERO_INT) .lhs else if (constant == ONE_INT) .rhs else null,
        .bit_and => if (constant == ZERO_INT) .lhs else null,
        else => null,
    };
}

fn integerIdentityReplacementFromRightConstant(op: ir.BinaryOp, constant: u64) ?OperandSlot {
    return switch (op) {
        .add, .sub, .bit_or, .bit_xor, .shift_left, .shift_right => if (constant == ZERO_INT) .lhs else null,
        .mul => if (constant == ZERO_INT) .rhs else if (constant == ONE_INT) .lhs else null,
        .div => if (constant == ONE_INT) .lhs else null,
        .bit_and => if (constant == ZERO_INT) .rhs else null,
        else => null,
    };
}

fn tryRewriteBoolIdentity(
    module: *const ir.Module,
    function: *const ir.Function,
    replacements: []ir.ExprId,
    expr_id: ir.ExprId,
    binary: @FieldType(ir.Expr, "binary"),
    stats: *Stats,
) bool {
    const result_scalar = scalarKind(module, function.exprs.items[expr_id].ty) orelse return false;
    if (result_scalar != .bool) return false;

    if (ir_const_eval.resolve_constant_bool(module, function, binary.lhs)) |constant| {
        if (boolIdentityReplacementFromLeftConstant(binary.op, constant)) |slot| {
            if (canReplaceWith(function, expr_id, slot)) {
                replacements[expr_id] = replacementExprId(function, expr_id, slot);
                stats.bool_identities += 1;
                return true;
            }
        }
    }

    if (ir_const_eval.resolve_constant_bool(module, function, binary.rhs)) |constant| {
        if (boolIdentityReplacementFromRightConstant(binary.op, constant)) |slot| {
            if (canReplaceWith(function, expr_id, slot)) {
                replacements[expr_id] = replacementExprId(function, expr_id, slot);
                stats.bool_identities += 1;
                return true;
            }
        }
    }

    return false;
}

fn boolIdentityReplacementFromLeftConstant(op: ir.BinaryOp, constant: bool) ?OperandSlot {
    return switch (op) {
        .logical_and => if (constant) .rhs else null,
        .logical_or => if (!constant) .rhs else null,
        else => null,
    };
}

fn boolIdentityReplacementFromRightConstant(op: ir.BinaryOp, constant: bool) ?OperandSlot {
    return switch (op) {
        .logical_and => if (constant) .lhs else null,
        .logical_or => if (!constant) .lhs else null,
        else => null,
    };
}

fn canReplaceWith(function: *const ir.Function, expr_id: ir.ExprId, operand_slot: OperandSlot) bool {
    const expr = function.exprs.items[expr_id];
    const replacement_id = replacementExprId(function, expr_id, operand_slot);
    const replacement = function.exprs.items[replacement_id];
    return replacement.ty == expr.ty and replacement.category == expr.category;
}

fn replacementExprId(function: *const ir.Function, expr_id: ir.ExprId, operand_slot: OperandSlot) ir.ExprId {
    const binary = function.exprs.items[expr_id].data.binary;
    return switch (operand_slot) {
        .lhs => binary.lhs,
        .rhs => binary.rhs,
    };
}

fn replaceExprRef(replacements: []const ir.ExprId, expr_id: ir.ExprId, stats: *Stats) ir.ExprId {
    const replacement = canonicalReplacement(replacements, expr_id);
    if (replacement != expr_id) stats.expr_refs_rewritten += 1;
    return replacement;
}

fn canonicalReplacement(replacements: []const ir.ExprId, expr_id: ir.ExprId) ir.ExprId {
    var current = expr_id;
    while (true) {
        const next = replacements[current];
        if (next == current) return current;
        current = next;
    }
}

fn scalarKind(module: *const ir.Module, ty: ir.TypeId) ?ir.ScalarType {
    return switch (module.types.get(ty)) {
        .scalar => |scalar| scalar,
        else => null,
    };
}

fn isIntegerScalar(scalar: ir.ScalarType) bool {
    return switch (scalar) {
        .abstract_int, .i32, .u32 => true,
        else => false,
    };
}

fn appendTestFunction(module: *ir.Module, name: []const u8, return_type: ir.TypeId) !*ir.Function {
    const owned_name = try ir.dup_string(module.allocator, name);
    errdefer module.allocator.free(owned_name);
    try module.functions.append(module.allocator, .{
        .name = owned_name,
        .return_type = return_type,
    });
    return &module.functions.items[module.functions.items.len - 1];
}

fn appendTestParam(function: *ir.Function, allocator: std.mem.Allocator, name: []const u8, ty: ir.TypeId) !u32 {
    const owned_name = try ir.dup_string(allocator, name);
    errdefer allocator.free(owned_name);
    const index: u32 = @intCast(function.params.items.len);
    try function.params.append(allocator, .{
        .name = owned_name,
        .ty = ty,
    });
    return index;
}

fn appendTestLocal(function: *ir.Function, allocator: std.mem.Allocator, name: []const u8, ty: ir.TypeId, mutable: bool) !u32 {
    const owned_name = try ir.dup_string(allocator, name);
    errdefer allocator.free(owned_name);
    const index: u32 = @intCast(function.locals.items.len);
    try function.locals.append(allocator, .{
        .name = owned_name,
        .ty = ty,
        .mutable = mutable,
    });
    return index;
}

test "integer identity rewrites return expression to dynamic operand" {
    var module = ir.Module.init(std.testing.allocator);
    defer module.deinit();

    const u32_ty = try module.types.intern(.{ .scalar = .u32 });
    const function = try appendTestFunction(&module, "main", u32_ty);
    const param_x = try appendTestParam(function, module.allocator, "x", u32_ty);

    const x_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .param_ref = param_x },
    });
    const zero_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = ZERO_INT },
    });
    const add_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .binary = .{
            .op = .add,
            .lhs = x_id,
            .rhs = zero_id,
        } },
    });
    function.root_stmt = try function.append_stmt(module.allocator, .{ .return_ = add_id });

    const stats = try apply(module.allocator, &module);
    try std.testing.expectEqual(@as(u32, 1), stats.integer_identities);
    try std.testing.expectEqual(x_id, module.functions.items[0].stmts.items[function.root_stmt].return_.?);
}

test "integer identity rewrites transitive expression users" {
    var module = ir.Module.init(std.testing.allocator);
    defer module.deinit();

    const i32_ty = try module.types.intern(.{ .scalar = .i32 });
    const function = try appendTestFunction(&module, "main", i32_ty);
    const param_x = try appendTestParam(function, module.allocator, "x", i32_ty);

    const x_id = try function.append_expr(module.allocator, .{
        .ty = i32_ty,
        .category = .value,
        .data = .{ .param_ref = param_x },
    });
    const zero_id = try function.append_expr(module.allocator, .{
        .ty = i32_ty,
        .category = .value,
        .data = .{ .int_lit = ZERO_INT },
    });
    const add_id = try function.append_expr(module.allocator, .{
        .ty = i32_ty,
        .category = .value,
        .data = .{ .binary = .{
            .op = .add,
            .lhs = zero_id,
            .rhs = x_id,
        } },
    });
    const one_id = try function.append_expr(module.allocator, .{
        .ty = i32_ty,
        .category = .value,
        .data = .{ .int_lit = ONE_INT },
    });
    const mul_id = try function.append_expr(module.allocator, .{
        .ty = i32_ty,
        .category = .value,
        .data = .{ .binary = .{
            .op = .mul,
            .lhs = add_id,
            .rhs = one_id,
        } },
    });
    function.root_stmt = try function.append_stmt(module.allocator, .{ .return_ = mul_id });

    const stats = try apply(module.allocator, &module);
    try std.testing.expectEqual(@as(u32, 2), stats.integer_identities);
    try std.testing.expectEqual(x_id, module.functions.items[0].stmts.items[function.root_stmt].return_.?);
}

test "integer const binary folds mutate expression to literal" {
    var module = ir.Module.init(std.testing.allocator);
    defer module.deinit();

    const u32_ty = try module.types.intern(.{ .scalar = .u32 });
    const function = try appendTestFunction(&module, "main", u32_ty);

    const lhs_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 6 },
    });
    const rhs_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 7 },
    });
    const mul_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .binary = .{
            .op = .mul,
            .lhs = lhs_id,
            .rhs = rhs_id,
        } },
    });
    function.root_stmt = try function.append_stmt(module.allocator, .{ .return_ = mul_id });

    const stats = try apply(module.allocator, &module);
    try std.testing.expectEqual(@as(u32, 1), stats.const_integer_folds);
    try std.testing.expectEqual(@as(u64, 42), module.functions.items[0].exprs.items[mul_id].data.int_lit);
}

test "integer const binary folds through local let aliases" {
    var module = ir.Module.init(std.testing.allocator);
    defer module.deinit();

    const u32_ty = try module.types.intern(.{ .scalar = .u32 });
    const function = try appendTestFunction(&module, "main", u32_ty);
    const local_lane_width = try appendTestLocal(function, module.allocator, "lane_width", u32_ty, false);

    const lane_width_value_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 64 },
    });
    const lane_width_decl = try function.append_stmt(module.allocator, .{ .local_decl = .{
        .local = local_lane_width,
        .initializer = lane_width_value_id,
        .is_const = true,
    } });
    const lane_width_ref_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .ref,
        .data = .{ .local_ref = local_lane_width },
    });
    const lane_width_load_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .load = lane_width_ref_id },
    });
    const four_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 4 },
    });
    const mul_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .binary = .{
            .op = .mul,
            .lhs = lane_width_load_id,
            .rhs = four_id,
        } },
    });
    const return_stmt = try function.append_stmt(module.allocator, .{ .return_ = mul_id });
    function.root_stmt = try function.append_stmt(module.allocator, .{
        .block = try function.append_stmt_children(module.allocator, &.{ lane_width_decl, return_stmt }),
    });

    const stats = try apply(module.allocator, &module);
    try std.testing.expectEqual(@as(u32, 1), stats.const_integer_folds);
    try std.testing.expectEqual(@as(u64, 256), module.functions.items[0].exprs.items[mul_id].data.int_lit);
}

test "integer const unary folds through local let aliases" {
    var module = ir.Module.init(std.testing.allocator);
    defer module.deinit();

    const u32_ty = try module.types.intern(.{ .scalar = .u32 });
    const function = try appendTestFunction(&module, "main", u32_ty);
    const local_mask_bits = try appendTestLocal(function, module.allocator, "mask_bits", u32_ty, false);

    const mask_bits_value_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 3 },
    });
    const mask_bits_decl = try function.append_stmt(module.allocator, .{ .local_decl = .{
        .local = local_mask_bits,
        .initializer = mask_bits_value_id,
        .is_const = true,
    } });
    const mask_bits_ref_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .ref,
        .data = .{ .local_ref = local_mask_bits },
    });
    const mask_bits_load_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .load = mask_bits_ref_id },
    });
    const not_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .unary = .{
            .op = .bit_not,
            .operand = mask_bits_load_id,
        } },
    });
    const return_stmt = try function.append_stmt(module.allocator, .{ .return_ = not_id });
    function.root_stmt = try function.append_stmt(module.allocator, .{
        .block = try function.append_stmt_children(module.allocator, &.{ mask_bits_decl, return_stmt }),
    });

    const stats = try apply(module.allocator, &module);
    try std.testing.expectEqual(@as(u32, 1), stats.const_integer_unary_folds);
    try std.testing.expectEqual(@as(u64, 0xffff_fffc), module.functions.items[0].exprs.items[not_id].data.int_lit);
}

test "absorbing integer identities preserve zero operand" {
    var module = ir.Module.init(std.testing.allocator);
    defer module.deinit();

    const u32_ty = try module.types.intern(.{ .scalar = .u32 });
    const function = try appendTestFunction(&module, "main", u32_ty);
    const param_x = try appendTestParam(function, module.allocator, "x", u32_ty);

    const x_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .param_ref = param_x },
    });
    const zero_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = ZERO_INT },
    });
    const mul_id = try function.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .binary = .{
            .op = .mul,
            .lhs = x_id,
            .rhs = zero_id,
        } },
    });
    function.root_stmt = try function.append_stmt(module.allocator, .{ .return_ = mul_id });

    const stats = try apply(module.allocator, &module);
    try std.testing.expectEqual(@as(u32, 1), stats.integer_identities);
    try std.testing.expectEqual(zero_id, module.functions.items[0].stmts.items[function.root_stmt].return_.?);
}

test "bool identity rewrites logical expression roots" {
    var module = ir.Module.init(std.testing.allocator);
    defer module.deinit();

    const bool_ty = try module.types.intern(.{ .scalar = .bool });
    const function = try appendTestFunction(&module, "main", bool_ty);
    const param_flag = try appendTestParam(function, module.allocator, "flag", bool_ty);

    const flag_id = try function.append_expr(module.allocator, .{
        .ty = bool_ty,
        .category = .value,
        .data = .{ .param_ref = param_flag },
    });
    const true_id = try function.append_expr(module.allocator, .{
        .ty = bool_ty,
        .category = .value,
        .data = .{ .bool_lit = true },
    });
    const and_id = try function.append_expr(module.allocator, .{
        .ty = bool_ty,
        .category = .value,
        .data = .{ .binary = .{
            .op = .logical_and,
            .lhs = true_id,
            .rhs = flag_id,
        } },
    });
    function.root_stmt = try function.append_stmt(module.allocator, .{ .return_ = and_id });

    const stats = try apply(module.allocator, &module);
    try std.testing.expectEqual(@as(u32, 1), stats.bool_identities);
    try std.testing.expectEqual(flag_id, module.functions.items[0].stmts.items[function.root_stmt].return_.?);
}
