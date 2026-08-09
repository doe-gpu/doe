const std = @import("std");
const ir = @import("../ir/ir.zig");
const ir_const_eval = @import("../ir/ir_const_eval.zig");
const ir_query = @import("../ir/ir_query.zig");

const expr_contains_expr = ir_query.exprContainsExpr;
const is_local_ref = ir_query.isLocalRef;
const resolve_const_local_initializer = ir_query.resolveConstLocalInitializer;
const resolve_value_alias = ir_query.resolveValueAlias;
const stmt_contains_expr = ir_query.stmtContainsExpr;
const stmt_writes_local = ir_query.stmtWritesLocal;

const MAX_U32_VALUE: u64 = std.math.maxInt(u32);

const LoopDirection = enum {
    ascending,
    descending,
};

const LoopStep = struct {
    direction: LoopDirection,
    magnitude: u64,
};

const CountedLoopBound = struct {
    init: u64,
    exclusive_limit: u64,
    step: u64,
    direction: LoopDirection,
};

pub fn find_bounded_loop_limit(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    local_idx: u32,
) ?u64 {
    return find_bounded_loop_limit_in_stmt(module, function, function.root_stmt, null, expr_id, local_idx);
}

fn find_bounded_loop_limit_in_stmt(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    previous_stmt_id: ?ir.StmtId,
    expr_id: ir.ExprId,
    local_idx: u32,
) ?u64 {
    if (stmt_id >= function.stmts.items.len) return null;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            const children = function.stmt_children.items[range.start .. range.start + range.len];
            for (children, 0..) |child_id, index| {
                const previous_child = if (index > 0) children[index - 1] else null;
                if (find_bounded_loop_limit_in_stmt(module, function, child_id, previous_child, expr_id, local_idx)) |limit| {
                    return limit;
                }
            }
            return null;
        },
        .if_ => |if_stmt| {
            if (find_bounded_loop_limit_in_stmt(module, function, if_stmt.then_block, null, expr_id, local_idx)) |limit| {
                return limit;
            }
            if (if_stmt.else_block) |else_block| {
                return find_bounded_loop_limit_in_stmt(module, function, else_block, null, expr_id, local_idx);
            }
            return null;
        },
        .loop_ => |loop_stmt| {
            if (find_bounded_loop_limit_in_stmt(module, function, loop_stmt.body, null, expr_id, local_idx)) |limit| {
                return limit;
            }
            if (!stmt_contains_expr(function, loop_stmt.body, expr_id)) return null;
            return match_canonical_counted_loop(module, function, loop_stmt, previous_stmt_id, expr_id, local_idx);
        },
        .switch_ => |switch_stmt| {
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (find_bounded_loop_limit_in_stmt(module, function, case_node.body, null, expr_id, local_idx)) |limit| {
                    return limit;
                }
            }
            return null;
        },
        else => return null,
    }
}

fn match_canonical_counted_loop(
    module: *const ir.Module,
    function: *const ir.Function,
    loop_stmt: @FieldType(ir.Stmt, "loop_"),
    previous_stmt_id: ?ir.StmtId,
    expr_id: ir.ExprId,
    local_idx: u32,
) ?u64 {
    const bound = switch (loop_stmt.kind) {
        .for_loop => match_canonical_for_loop(module, function, loop_stmt, expr_id, local_idx),
        .loop => match_canonical_guarded_loop(module, function, loop_stmt, previous_stmt_id orelse return null, expr_id, local_idx),
        .while_loop => match_canonical_while_loop(module, function, loop_stmt, previous_stmt_id orelse return null, expr_id, local_idx),
    };
    if (!validate_counted_loop_bound(bound orelse return null)) return null;
    return bound.?.exclusive_limit;
}

fn match_canonical_for_loop(
    module: *const ir.Module,
    function: *const ir.Function,
    loop_stmt: @FieldType(ir.Stmt, "loop_"),
    expr_id: ir.ExprId,
    local_idx: u32,
) ?CountedLoopBound {
    const init = loop_stmt.init orelse return null;
    const cond = loop_stmt.cond orelse return null;
    const continuing = loop_stmt.continuing orelse return null;
    if (!stmt_contains_expr(function, loop_stmt.body, expr_id)) return null;
    if (stmt_writes_local(function, loop_stmt.body, local_idx)) return null;
    const init_value = match_local_initialized_const(module, function, init, local_idx) orelse return null;
    const step = match_local_step(module, function, continuing, local_idx) orelse return null;
    return switch (step.direction) {
        .ascending => .{
            .init = init_value,
            .exclusive_limit = match_local_exclusive_limit(module, function, cond, local_idx) orelse return null,
            .step = step.magnitude,
            .direction = .ascending,
        },
        .descending => .{
            .init = init_value,
            .exclusive_limit = match_descending_exclusive_limit(module, function, cond, local_idx, init_value, step.magnitude) orelse return null,
            .step = step.magnitude,
            .direction = .descending,
        },
    };
}

fn match_canonical_guarded_loop(
    module: *const ir.Module,
    function: *const ir.Function,
    loop_stmt: @FieldType(ir.Stmt, "loop_"),
    init_stmt_id: ir.StmtId,
    expr_id: ir.ExprId,
    local_idx: u32,
) ?CountedLoopBound {
    const init_value = match_local_initialized_const(module, function, init_stmt_id, local_idx) orelse return null;

    const body = if (loop_stmt.body < function.stmts.items.len) function.stmts.items[loop_stmt.body] else return null;
    const range = switch (body) {
        .block => |value| value,
        else => return null,
    };
    if (range.len < 2) return null;

    const children = function.stmt_children.items[range.start .. range.start + range.len];
    const step_stmt = if (loop_stmt.continuing) |continuing| continuing else children[children.len - 1];
    const step = match_local_step(module, function, step_stmt, local_idx) orelse return null;
    const limit = match_break_guard_stmt(module, function, children[0], local_idx, init_value, step) orelse return null;

    if (loop_stmt.continuing != null) {
        if (!block_contains_expr_after_prefix(function, children, 1, expr_id)) return null;
        if (block_writes_local_after_prefix(function, children, 1, local_idx)) return null;
    } else {
        if (children.len < 3) return null;
        if (!block_contains_expr_between(function, children, 1, 1, expr_id)) return null;
        if (block_writes_local_between(function, children, 1, 1, local_idx)) return null;
    }

    return .{
        .init = init_value,
        .exclusive_limit = limit,
        .step = step.magnitude,
        .direction = step.direction,
    };
}

fn match_canonical_while_loop(
    module: *const ir.Module,
    function: *const ir.Function,
    loop_stmt: @FieldType(ir.Stmt, "loop_"),
    init_stmt_id: ir.StmtId,
    expr_id: ir.ExprId,
    local_idx: u32,
) ?CountedLoopBound {
    const cond = loop_stmt.cond orelse return null;
    const init_value = match_local_initialized_const(module, function, init_stmt_id, local_idx) orelse return null;
    const body = if (loop_stmt.body < function.stmts.items.len) function.stmts.items[loop_stmt.body] else return null;
    const range = switch (body) {
        .block => |value| value,
        else => return null,
    };
    if (range.len < 2) return null;

    const children = function.stmt_children.items[range.start .. range.start + range.len];
    const step_stmt = children[children.len - 1];
    const step = match_local_step(module, function, step_stmt, local_idx) orelse return null;
    if (!block_contains_expr_before_suffix(function, children, 1, expr_id)) return null;
    if (block_writes_local_before_suffix(function, children, 1, local_idx)) return null;
    return switch (step.direction) {
        .ascending => .{
            .init = init_value,
            .exclusive_limit = match_local_exclusive_limit(module, function, cond, local_idx) orelse return null,
            .step = step.magnitude,
            .direction = .ascending,
        },
        .descending => .{
            .init = init_value,
            .exclusive_limit = match_descending_exclusive_limit(module, function, cond, local_idx, init_value, step.magnitude) orelse return null,
            .step = step.magnitude,
            .direction = .descending,
        },
    };
}

fn validate_counted_loop_bound(bound: CountedLoopBound) bool {
    if (bound.step == 0 or bound.exclusive_limit == 0) return false;
    if (bound.init >= bound.exclusive_limit) return false;
    return switch (bound.direction) {
        .ascending => blk: {
            const max_body_value = bound.exclusive_limit - 1;
            const advanced = std.math.add(u64, max_body_value, bound.step) catch break :blk false;
            break :blk advanced <= MAX_U32_VALUE;
        },
        .descending => true,
    };
}

fn match_break_guard_stmt(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    local_idx: u32,
    init_value: u64,
    step: LoopStep,
) ?u64 {
    if (stmt_id >= function.stmts.items.len) return null;
    const stmt = function.stmts.items[stmt_id];
    const if_stmt = switch (stmt) {
        .if_ => |value| value,
        else => return null,
    };
    if (if_stmt.else_block != null) return null;
    const limit = match_local_break_guard(module, function, if_stmt.cond, local_idx, init_value, step) orelse return null;
    if (!is_single_break_block(function, if_stmt.then_block)) return null;
    return limit;
}

fn match_local_break_guard(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    local_idx: u32,
    init_value: u64,
    step: LoopStep,
) ?u64 {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    return switch (binary.op) {
        .logical_or => switch (step.direction) {
            .ascending => match_local_break_guard(module, function, binary.lhs, local_idx, init_value, step) orelse
                match_local_break_guard(module, function, binary.rhs, local_idx, init_value, step),
            .descending => match_local_break_guard(module, function, binary.lhs, local_idx, init_value, step) orelse
                match_local_break_guard(module, function, binary.rhs, local_idx, init_value, step),
        },
        else => switch (step.direction) {
            .ascending => match_ascending_break_guard(module, function, binary, local_idx),
            .descending => match_descending_break_guard(module, function, binary, local_idx, init_value, step.magnitude),
        },
    };
}

fn is_single_break_block(function: *const ir.Function, stmt_id: ir.StmtId) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    const stmt = function.stmts.items[stmt_id];
    const range = switch (stmt) {
        .block => |value| value,
        else => return false,
    };
    if (range.len != 1) return false;
    const child_id = function.stmt_children.items[range.start];
    if (child_id >= function.stmts.items.len) return false;
    return function.stmts.items[child_id] == .break_;
}

fn match_ascending_break_guard(
    module: *const ir.Module,
    function: *const ir.Function,
    binary: @FieldType(ir.Expr, "binary"),
    local_idx: u32,
) ?u64 {
    if (is_local_ref(function, binary.lhs, local_idx)) {
        return switch (binary.op) {
            .greater_equal => match_u32_literal_value(module, function, binary.rhs),
            .greater => exclusive_limit_from_inclusive(match_u32_literal_value(module, function, binary.rhs) orelse return null),
            else => null,
        };
    }
    if (is_local_ref(function, binary.rhs, local_idx)) {
        return switch (binary.op) {
            .less_equal => match_u32_literal_value(module, function, binary.lhs),
            .less => exclusive_limit_from_inclusive(match_u32_literal_value(module, function, binary.lhs) orelse return null),
            else => null,
        };
    }
    return null;
}

fn match_descending_break_guard(
    module: *const ir.Module,
    function: *const ir.Function,
    binary: @FieldType(ir.Expr, "binary"),
    local_idx: u32,
    init_value: u64,
    step: u64,
) ?u64 {
    const min_body_value = if (is_local_ref(function, binary.lhs, local_idx))
        switch (binary.op) {
            .less => match_u32_literal_value(module, function, binary.rhs),
            .less_equal => exclusive_limit_from_inclusive(match_u32_literal_value(module, function, binary.rhs) orelse return null),
            else => null,
        }
    else if (is_local_ref(function, binary.rhs, local_idx))
        switch (binary.op) {
            .greater => match_u32_literal_value(module, function, binary.lhs),
            .greater_equal => exclusive_limit_from_inclusive(match_u32_literal_value(module, function, binary.lhs) orelse return null),
            else => null,
        }
    else
        null;

    return descending_exclusive_limit(init_value, min_body_value orelse return null, step);
}

fn block_contains_expr_after_prefix(
    function: *const ir.Function,
    children: []const ir.StmtId,
    prefix_len: usize,
    expr_id: ir.ExprId,
) bool {
    for (children[prefix_len..]) |child_id| {
        if (stmt_contains_expr(function, child_id, expr_id)) return true;
    }
    return false;
}

fn block_writes_local_after_prefix(
    function: *const ir.Function,
    children: []const ir.StmtId,
    prefix_len: usize,
    local_idx: u32,
) bool {
    for (children[prefix_len..]) |child_id| {
        if (stmt_writes_local(function, child_id, local_idx)) return true;
    }
    return false;
}

fn block_contains_expr_between(
    function: *const ir.Function,
    children: []const ir.StmtId,
    prefix_len: usize,
    suffix_len: usize,
    expr_id: ir.ExprId,
) bool {
    if (children.len < prefix_len + suffix_len) return false;
    for (children[prefix_len .. children.len - suffix_len]) |child_id| {
        if (stmt_contains_expr(function, child_id, expr_id)) return true;
    }
    return false;
}

fn block_writes_local_between(
    function: *const ir.Function,
    children: []const ir.StmtId,
    prefix_len: usize,
    suffix_len: usize,
    local_idx: u32,
) bool {
    if (children.len < prefix_len + suffix_len) return false;
    for (children[prefix_len .. children.len - suffix_len]) |child_id| {
        if (stmt_writes_local(function, child_id, local_idx)) return true;
    }
    return false;
}

fn block_contains_expr_before_suffix(
    function: *const ir.Function,
    children: []const ir.StmtId,
    suffix_len: usize,
    expr_id: ir.ExprId,
) bool {
    if (children.len < suffix_len) return false;
    for (children[0 .. children.len - suffix_len]) |child_id| {
        if (stmt_contains_expr(function, child_id, expr_id)) return true;
    }
    return false;
}

fn block_writes_local_before_suffix(
    function: *const ir.Function,
    children: []const ir.StmtId,
    suffix_len: usize,
    local_idx: u32,
) bool {
    if (children.len < suffix_len) return false;
    for (children[0 .. children.len - suffix_len]) |child_id| {
        if (stmt_writes_local(function, child_id, local_idx)) return true;
    }
    return false;
}

fn match_local_initialized_const(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    local_idx: u32,
) ?u64 {
    if (stmt_id >= function.stmts.items.len) return null;
    const stmt = function.stmts.items[stmt_id];
    return switch (stmt) {
        .local_decl => |decl| blk: {
            if (decl.local != local_idx or decl.is_const) break :blk null;
            const init_expr = decl.initializer orelse break :blk null;
            break :blk match_u32_literal_value(module, function, init_expr);
        },
        .assign => |assign| blk: {
            if (!is_local_ref(function, assign.lhs, local_idx) or assign.op != .assign) break :blk null;
            break :blk match_u32_literal_value(module, function, assign.rhs);
        },
        else => null,
    };
}

fn match_local_exclusive_limit(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    local_idx: u32,
) ?u64 {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op == .logical_and) {
        return match_local_exclusive_limit(module, function, binary.lhs, local_idx) orelse
            match_local_exclusive_limit(module, function, binary.rhs, local_idx);
    }
    if (is_local_ref(function, binary.lhs, local_idx)) {
        return switch (binary.op) {
            .less => match_u32_literal_value(module, function, binary.rhs),
            .less_equal => exclusive_limit_from_inclusive(match_u32_literal_value(module, function, binary.rhs) orelse return null),
            else => null,
        };
    }
    if (is_local_ref(function, binary.rhs, local_idx)) {
        return switch (binary.op) {
            .greater => match_u32_literal_value(module, function, binary.lhs),
            .greater_equal => exclusive_limit_from_inclusive(match_u32_literal_value(module, function, binary.lhs) orelse return null),
            else => null,
        };
    }
    return null;
}

fn match_descending_exclusive_limit(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    local_idx: u32,
    init_value: u64,
    step: u64,
) ?u64 {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op == .logical_and) {
        return match_descending_exclusive_limit(module, function, binary.lhs, local_idx, init_value, step) orelse
            match_descending_exclusive_limit(module, function, binary.rhs, local_idx, init_value, step);
    }
    const min_body_value = if (is_local_ref(function, binary.lhs, local_idx))
        switch (binary.op) {
            .greater => exclusive_limit_from_inclusive(match_u32_literal_value(module, function, binary.rhs) orelse return null),
            .greater_equal => match_u32_literal_value(module, function, binary.rhs),
            else => null,
        }
    else if (is_local_ref(function, binary.rhs, local_idx))
        switch (binary.op) {
            .less => exclusive_limit_from_inclusive(match_u32_literal_value(module, function, binary.lhs) orelse return null),
            .less_equal => match_u32_literal_value(module, function, binary.lhs),
            else => null,
        }
    else
        null;

    return descending_exclusive_limit(init_value, min_body_value orelse return null, step);
}

fn descending_exclusive_limit(init_value: u64, min_body_value: u64, step: u64) ?u64 {
    if (step == 0) return null;
    if (step > min_body_value) return null;
    return exclusive_limit_from_inclusive(init_value);
}

fn match_local_step(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    local_idx: u32,
) ?LoopStep {
    if (stmt_id >= function.stmts.items.len) return null;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            if (range.len != 1) return null;
            return match_local_step(module, function, function.stmt_children.items[range.start], local_idx);
        },
        else => {},
    }
    const assign = switch (stmt) {
        .assign => |value| value,
        else => return null,
    };
    if (!is_local_ref(function, assign.lhs, local_idx)) return null;
    return switch (assign.op) {
        .assign => match_local_plus_or_minus_positive_literal(module, function, assign.rhs, local_idx),
        .add => .{ .direction = .ascending, .magnitude = match_positive_u32_literal(module, function, assign.rhs) orelse return null },
        .sub => .{ .direction = .descending, .magnitude = match_positive_u32_literal(module, function, assign.rhs) orelse return null },
        else => null,
    };
}

fn match_local_plus_or_minus_positive_literal(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    local_idx: u32,
) ?LoopStep {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .add and binary.op != .sub) return null;
    if (!is_local_ref(function, binary.lhs, local_idx)) return null;
    const magnitude = match_positive_u32_literal(module, function, binary.rhs) orelse return null;
    return switch (binary.op) {
        .add => .{ .direction = .ascending, .magnitude = magnitude },
        .sub => .{ .direction = .descending, .magnitude = magnitude },
        else => null,
    };
}

fn match_positive_u32_literal(module: *const ir.Module, function: *const ir.Function, expr_id: ir.ExprId) ?u64 {
    const value = match_u32_literal_value(module, function, expr_id) orelse return null;
    if (value == 0) return null;
    return value;
}

fn exclusive_limit_from_inclusive(value: u64) ?u64 {
    return std.math.add(u64, value, 1) catch null;
}

fn match_u32_literal(module: *const ir.Module, function: *const ir.Function, expr_id: ir.ExprId, expected: u32) bool {
    return match_u32_literal_value(module, function, expr_id) == expected;
}

fn match_u32_literal_value(module: *const ir.Module, function: *const ir.Function, expr_id: ir.ExprId) ?u64 {
    return ir_const_eval.resolve_constant_int(module, function, resolve_value_alias(function, expr_id));
}
