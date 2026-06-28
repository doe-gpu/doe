const std = @import("std");
const ir = @import("ir.zig");
const loop_match = @import("dispatch_proof_loop_match.zig");

const MAX_RECURSION_DEPTH: usize = 64;

pub fn sizedArrayIndexProvablyInBounds(
    module: *const ir.Module,
    function: *const ir.Function,
    access_expr_id: ir.ExprId,
    base_expr_id: ir.ExprId,
    index_expr_id: ir.ExprId,
    length: u32,
    allow_storage: bool,
) bool {
    const addr_space = resolve_access_address_space(module, function, base_expr_id) orelse return false;
    if (!eligible_for_static_elision(addr_space, allow_storage)) return false;

    if (upper_bound_for_expr(module, function, access_expr_id, index_expr_id, 0)) |upper_bound| {
        if (upper_bound < @as(u64, length)) return true;
    }
    return guarded_local_invocation_stride_index_in_bounds(
        function,
        access_expr_id,
        index_expr_id,
        length,
    );
}

fn eligible_for_static_elision(addr_space: ir.AddressSpace, allow_storage: bool) bool {
    return switch (addr_space) {
        .function, .private, .workgroup => true,
        .storage => allow_storage,
        else => false,
    };
}

fn resolve_access_address_space(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?ir.AddressSpace {
    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    switch (expr.data) {
        .global_ref => |global_idx| {
            if (global_idx >= module.globals.items.len) return null;
            return module.globals.items[global_idx].addr_space;
        },
        .local_ref => |local_idx| {
            if (local_idx >= function.locals.items.len) return null;
            return switch (module.types.get(function.locals.items[local_idx].ty)) {
                .ref => |ref_ty| ref_ty.addr_space,
                else => .function,
            };
        },
        .param_ref => |param_idx| {
            if (param_idx >= function.params.items.len) return null;
            return switch (module.types.get(function.params.items[param_idx].ty)) {
                .ref => |ref_ty| ref_ty.addr_space,
                else => null,
            };
        },
        .load => |inner| return resolve_access_address_space(module, function, inner),
        .member => |member| return resolve_access_address_space(module, function, member.base),
        .index => |index| return resolve_access_address_space(module, function, index.base),
        else => return null,
    }
}

fn upper_bound_for_expr(
    module: *const ir.Module,
    function: *const ir.Function,
    access_expr_id: ir.ExprId,
    expr_id: ir.ExprId,
    depth: usize,
) ?u64 {
    if (depth >= MAX_RECURSION_DEPTH) return null;

    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    switch (expr.data) {
        .int_lit => |value| return value,
        .global_ref => |global_idx| return upper_bound_for_const_global(module, global_idx),
        .load => |inner| return upper_bound_for_expr(module, function, access_expr_id, inner, depth + 1),
        .local_ref => |local_idx| return upper_bound_for_local(module, function, access_expr_id, local_idx),
        .member => return upper_bound_for_builtin_member(function, canonical),
        .binary => |binary| return upper_bound_for_binary(module, function, access_expr_id, binary, depth + 1),
        else => return null,
    }
}

fn upper_bound_for_local(
    module: *const ir.Module,
    function: *const ir.Function,
    access_expr_id: ir.ExprId,
    local_idx: u32,
) ?u64 {
    const limit = loop_match.find_bounded_loop_limit(module, function, access_expr_id, local_idx) orelse
        find_simple_for_loop_limit(module, function, function.root_stmt, access_expr_id, local_idx) orelse
        return null;
    if (limit == 0) return null;
    return limit - 1;
}

fn upper_bound_for_const_global(module: *const ir.Module, global_idx: u32) ?u64 {
    if (global_idx >= module.globals.items.len) return null;
    const global = module.globals.items[global_idx];
    if (global.class != .const_) return null;
    const initializer = global.initializer orelse return null;
    return switch (initializer) {
        .int => |value| value,
        else => null,
    };
}

fn find_simple_for_loop_limit(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    target_expr_id: ir.ExprId,
    local_idx: u32,
) ?u64 {
    if (stmt_id >= function.stmts.items.len) return null;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (find_simple_for_loop_limit(module, function, child_id, target_expr_id, local_idx)) |limit| return limit;
            }
            return null;
        },
        .if_ => |if_stmt| {
            if (find_simple_for_loop_limit(module, function, if_stmt.then_block, target_expr_id, local_idx)) |limit| return limit;
            if (if_stmt.else_block) |else_block| return find_simple_for_loop_limit(module, function, else_block, target_expr_id, local_idx);
            return null;
        },
        .loop_ => |loop_stmt| {
            if (find_simple_for_loop_limit(module, function, loop_stmt.body, target_expr_id, local_idx)) |limit| return limit;
            if (loop_stmt.kind != .for_loop) return null;
            if (!stmt_contains_expr(function, loop_stmt.body, target_expr_id)) return null;
            return match_simple_for_loop(module, function, loop_stmt, local_idx);
        },
        .switch_ => |switch_stmt| {
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (find_simple_for_loop_limit(module, function, case_node.body, target_expr_id, local_idx)) |limit| return limit;
            }
            return null;
        },
        else => return null,
    }
}

fn match_simple_for_loop(
    module: *const ir.Module,
    function: *const ir.Function,
    loop_stmt: @FieldType(ir.Stmt, "loop_"),
    local_idx: u32,
) ?u64 {
    const init_stmt = loop_stmt.init orelse return null;
    const cond_expr = loop_stmt.cond orelse return null;
    const continuing_stmt = loop_stmt.continuing orelse return null;

    if (!match_simple_local_init(function, init_stmt, local_idx)) return null;
    if (stmt_writes_local(function, loop_stmt.body, local_idx)) return null;
    if (!match_simple_local_positive_step(function, continuing_stmt, local_idx)) return null;
    return match_simple_exclusive_limit(module, function, cond_expr, local_idx);
}

fn match_simple_local_init(function: *const ir.Function, stmt_id: ir.StmtId, local_idx: u32) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    const stmt = function.stmts.items[stmt_id];
    return switch (stmt) {
        .local_decl => |decl| decl.local == local_idx and !decl.is_const and decl.initializer != null,
        .assign => |assign| is_local_ref(function, assign.lhs, local_idx) and assign.op == .assign,
        else => false,
    };
}

fn match_simple_local_positive_step(function: *const ir.Function, stmt_id: ir.StmtId, local_idx: u32) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    const stmt = function.stmts.items[stmt_id];
    const assign = switch (stmt) {
        .assign => |value| value,
        .block => |range| {
            if (range.len != 1) return false;
            return match_simple_local_positive_step(function, function.stmt_children.items[range.start], local_idx);
        },
        else => return false,
    };
    if (!is_local_ref(function, assign.lhs, local_idx)) return false;
    return switch (assign.op) {
        .add => match_positive_const_literal(function, assign.rhs),
        .assign => match_simple_plus_literal(function, assign.rhs, local_idx),
        else => false,
    };
}

fn match_simple_plus_literal(function: *const ir.Function, expr_id: ir.ExprId, local_idx: u32) bool {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.op != .add) return false;
    if (!is_local_ref(function, binary.lhs, local_idx)) return false;
    return match_positive_const_literal(function, binary.rhs);
}

fn match_positive_const_literal(function: *const ir.Function, expr_id: ir.ExprId) bool {
    const value = match_u32_literal_value(function, expr_id) orelse return false;
    return value > 0;
}

fn match_simple_exclusive_limit(
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
    if (is_local_ref(function, binary.lhs, local_idx)) {
        const rhs = upper_bound_for_expr(module, function, expr_id, binary.rhs, 0) orelse return null;
        return switch (binary.op) {
            .less => rhs,
            .less_equal => std.math.add(u64, rhs, 1) catch null,
            else => null,
        };
    }
    if (is_local_ref(function, binary.rhs, local_idx)) {
        const lhs = upper_bound_for_expr(module, function, expr_id, binary.lhs, 0) orelse return null;
        return switch (binary.op) {
            .greater => lhs,
            .greater_equal => std.math.add(u64, lhs, 1) catch null,
            else => null,
        };
    }
    return null;
}

fn is_local_ref(function: *const ir.Function, expr_id: ir.ExprId, local_idx: u32) bool {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    return switch (expr.data) {
        .local_ref => |value| value == local_idx,
        else => false,
    };
}

fn stmt_writes_local(function: *const ir.Function, stmt_id: ir.StmtId, local_idx: u32) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (stmt_writes_local(function, child_id, local_idx)) return true;
            }
            return false;
        },
        .assign => |assign| return is_local_ref(function, assign.lhs, local_idx),
        .if_ => |if_stmt| return stmt_writes_local(function, if_stmt.then_block, local_idx) or
            (if_stmt.else_block != null and stmt_writes_local(function, if_stmt.else_block.?, local_idx)),
        .loop_ => |loop_stmt| {
            if (loop_stmt.init) |init_stmt| if (stmt_writes_local(function, init_stmt, local_idx)) return true;
            if (loop_stmt.continuing) |continuing_stmt| if (stmt_writes_local(function, continuing_stmt, local_idx)) return true;
            return stmt_writes_local(function, loop_stmt.body, local_idx);
        },
        .switch_ => |switch_stmt| {
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (stmt_writes_local(function, case_node.body, local_idx)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn stmt_contains_expr(function: *const ir.Function, stmt_id: ir.StmtId, target_expr_id: ir.ExprId) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (stmt_contains_expr(function, child_id, target_expr_id)) return true;
            }
            return false;
        },
        .local_decl => |decl| {
            if (decl.initializer) |init_expr| return expr_contains_expr(function, init_expr, target_expr_id);
            return false;
        },
        .expr => |value| return expr_contains_expr(function, value, target_expr_id),
        .assign => |assign| return expr_contains_expr(function, assign.lhs, target_expr_id) or
            expr_contains_expr(function, assign.rhs, target_expr_id),
        .return_ => |value| {
            if (value) |expr_ref| return expr_contains_expr(function, expr_ref, target_expr_id);
            return false;
        },
        .if_ => |if_stmt| return expr_contains_expr(function, if_stmt.cond, target_expr_id) or
            stmt_contains_expr(function, if_stmt.then_block, target_expr_id) or
            (if_stmt.else_block != null and stmt_contains_expr(function, if_stmt.else_block.?, target_expr_id)),
        .loop_ => |loop_stmt| {
            if (loop_stmt.init) |init_stmt| if (stmt_contains_expr(function, init_stmt, target_expr_id)) return true;
            if (loop_stmt.cond) |cond_expr| if (expr_contains_expr(function, cond_expr, target_expr_id)) return true;
            if (loop_stmt.continuing) |continuing_stmt| if (stmt_contains_expr(function, continuing_stmt, target_expr_id)) return true;
            return stmt_contains_expr(function, loop_stmt.body, target_expr_id);
        },
        .switch_ => |switch_stmt| {
            if (expr_contains_expr(function, switch_stmt.expr, target_expr_id)) return true;
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (stmt_contains_expr(function, case_node.body, target_expr_id)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn expr_contains_expr(function: *const ir.Function, expr_id: ir.ExprId, target_expr_id: ir.ExprId) bool {
    if (expr_id == target_expr_id) return true;
    if (expr_id >= function.exprs.items.len) return false;
    const expr = function.exprs.items[expr_id];
    switch (expr.data) {
        .load => |inner| return expr_contains_expr(function, inner, target_expr_id),
        .unary => |unary| return expr_contains_expr(function, unary.operand, target_expr_id),
        .binary => |binary| return expr_contains_expr(function, binary.lhs, target_expr_id) or
            expr_contains_expr(function, binary.rhs, target_expr_id),
        .call => |call| {
            for (function.expr_args.items[call.args.start .. call.args.start + call.args.len]) |arg_id| {
                if (expr_contains_expr(function, arg_id, target_expr_id)) return true;
            }
            return false;
        },
        .construct => |construct| {
            for (function.expr_args.items[construct.args.start .. construct.args.start + construct.args.len]) |arg_id| {
                if (expr_contains_expr(function, arg_id, target_expr_id)) return true;
            }
            return false;
        },
        .member => |member| return expr_contains_expr(function, member.base, target_expr_id),
        .index => |index| return expr_contains_expr(function, index.base, target_expr_id) or
            expr_contains_expr(function, index.index, target_expr_id),
        else => return false,
    }
}

const LaneStrideIndex = struct {
    lane_axis: u8,
    stride_local: u32,
};

fn guarded_local_invocation_stride_index_in_bounds(
    function: *const ir.Function,
    access_expr_id: ir.ExprId,
    index_expr_id: ir.ExprId,
    length: u32,
) bool {
    const match = match_lane_plus_stride_local(function, index_expr_id) orelse return false;
    const max_stride = nonincreasing_local_upper_bound(function, match.stride_local) orelse return false;
    const max_access_plus_one = std.math.mul(u64, max_stride, 2) catch return false;
    if (max_access_plus_one > @as(u64, length)) return false;
    return access_guarded_by_lane_less_than_stride(
        function,
        function.root_stmt,
        access_expr_id,
        match.lane_axis,
        match.stride_local,
        false,
    );
}

fn match_lane_plus_stride_local(function: *const ir.Function, expr_id: ir.ExprId) ?LaneStrideIndex {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .add) return null;
    if (classify_local_invocation_axis(function, binary.lhs)) |axis| {
        if (match_plain_local_ref(function, binary.rhs)) |local_idx| {
            return .{ .lane_axis = axis, .stride_local = local_idx };
        }
    }
    if (classify_local_invocation_axis(function, binary.rhs)) |axis| {
        if (match_plain_local_ref(function, binary.lhs)) |local_idx| {
            return .{ .lane_axis = axis, .stride_local = local_idx };
        }
    }
    return null;
}

fn access_guarded_by_lane_less_than_stride(
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    target_expr_id: ir.ExprId,
    lane_axis: u8,
    stride_local: u32,
    active_guard: bool,
) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (access_guarded_by_lane_less_than_stride(
                    function,
                    child_id,
                    target_expr_id,
                    lane_axis,
                    stride_local,
                    active_guard,
                )) return true;
            }
            return false;
        },
        .if_ => |if_stmt| {
            const then_guard = active_guard or lane_less_than_stride_guard(
                function,
                if_stmt.cond,
                lane_axis,
                stride_local,
            );
            if (access_guarded_by_lane_less_than_stride(
                function,
                if_stmt.then_block,
                target_expr_id,
                lane_axis,
                stride_local,
                then_guard,
            )) return true;
            if (if_stmt.else_block) |else_block| {
                return access_guarded_by_lane_less_than_stride(
                    function,
                    else_block,
                    target_expr_id,
                    lane_axis,
                    stride_local,
                    active_guard,
                );
            }
            return false;
        },
        .loop_ => |loop_stmt| {
            if (loop_stmt.init) |init_stmt| {
                if (access_guarded_by_lane_less_than_stride(
                    function,
                    init_stmt,
                    target_expr_id,
                    lane_axis,
                    stride_local,
                    active_guard,
                )) return true;
            }
            if (access_guarded_by_lane_less_than_stride(
                function,
                loop_stmt.body,
                target_expr_id,
                lane_axis,
                stride_local,
                active_guard,
            )) return true;
            if (loop_stmt.continuing) |continuing_stmt| {
                return access_guarded_by_lane_less_than_stride(
                    function,
                    continuing_stmt,
                    target_expr_id,
                    lane_axis,
                    stride_local,
                    active_guard,
                );
            }
            return false;
        },
        .switch_ => |switch_stmt| {
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (access_guarded_by_lane_less_than_stride(
                    function,
                    case_node.body,
                    target_expr_id,
                    lane_axis,
                    stride_local,
                    active_guard,
                )) return true;
            }
            return false;
        },
        else => return active_guard and stmt_contains_expr(function, stmt_id, target_expr_id),
    }
}

fn lane_less_than_stride_guard(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    lane_axis: u8,
    stride_local: u32,
) bool {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    return switch (binary.op) {
        .less => classify_local_invocation_axis(function, binary.lhs) == lane_axis and
            match_plain_local_ref(function, binary.rhs) == stride_local,
        .greater => classify_local_invocation_axis(function, binary.rhs) == lane_axis and
            match_plain_local_ref(function, binary.lhs) == stride_local,
        else => false,
    };
}

fn nonincreasing_local_upper_bound(function: *const ir.Function, local_idx: u32) ?u64 {
    const initial = local_initializer_u64(function, local_idx) orelse return null;
    if (!local_writes_are_nonincreasing(function, function.root_stmt, local_idx)) return null;
    return initial;
}

fn local_initializer_u64(function: *const ir.Function, local_idx: u32) ?u64 {
    for (function.stmts.items) |stmt| {
        switch (stmt) {
            .local_decl => |decl| {
                if (decl.local != local_idx) continue;
                const initializer = decl.initializer orelse return null;
                return match_u32_literal_value(function, initializer);
            },
            else => {},
        }
    }
    return null;
}

fn local_writes_are_nonincreasing(
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    local_idx: u32,
) bool {
    if (stmt_id >= function.stmts.items.len) return true;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (!local_writes_are_nonincreasing(function, child_id, local_idx)) return false;
            }
            return true;
        },
        .local_decl => |decl| return decl.local != local_idx or decl.initializer != null,
        .assign => |assign| {
            if (!is_local_ref(function, assign.lhs, local_idx)) return true;
            return local_assign_is_nonincreasing(function, assign, local_idx);
        },
        .if_ => |if_stmt| {
            if (!local_writes_are_nonincreasing(function, if_stmt.then_block, local_idx)) return false;
            if (if_stmt.else_block) |else_block| {
                if (!local_writes_are_nonincreasing(function, else_block, local_idx)) return false;
            }
            return true;
        },
        .loop_ => |loop_stmt| {
            if (loop_stmt.init) |init_stmt| {
                if (!local_writes_are_nonincreasing(function, init_stmt, local_idx)) return false;
            }
            if (!local_writes_are_nonincreasing(function, loop_stmt.body, local_idx)) return false;
            if (loop_stmt.continuing) |continuing_stmt| {
                if (!local_writes_are_nonincreasing(function, continuing_stmt, local_idx)) return false;
            }
            return true;
        },
        .switch_ => |switch_stmt| {
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (!local_writes_are_nonincreasing(function, case_node.body, local_idx)) return false;
            }
            return true;
        },
        else => return true,
    }
}

fn local_assign_is_nonincreasing(
    function: *const ir.Function,
    assign: @FieldType(ir.Stmt, "assign"),
    local_idx: u32,
) bool {
    return switch (assign.op) {
        .assign => local_expr_is_nonincreasing_update(function, assign.rhs, local_idx),
        .div => match_positive_const_literal(function, assign.rhs),
        else => false,
    };
}

fn local_expr_is_nonincreasing_update(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    local_idx: u32,
) bool {
    if (is_local_ref(function, expr_id, local_idx)) return true;
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    if (!is_local_ref(function, binary.lhs, local_idx)) return false;
    return switch (binary.op) {
        .shift_right => match_positive_const_literal(function, binary.rhs),
        .div => match_positive_const_literal(function, binary.rhs),
        else => false,
    };
}

fn classify_local_invocation_axis(function: *const ir.Function, expr_id: ir.ExprId) ?u8 {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const member = switch (expr.data) {
        .member => |value| value,
        else => return null,
    };
    const base = function.exprs.items[resolve_value_alias(function, member.base)];
    const param_idx = switch (base.data) {
        .param_ref => |value| value,
        else => return null,
    };
    if (param_idx >= function.params.items.len) return null;
    const io = function.params.items[param_idx].io orelse return null;
    if (io.builtin != .local_invocation_id) return null;
    if (std.mem.eql(u8, member.field_name, "x")) return 0;
    if (std.mem.eql(u8, member.field_name, "y")) return 1;
    if (std.mem.eql(u8, member.field_name, "z")) return 2;
    return null;
}

fn match_plain_local_ref(function: *const ir.Function, expr_id: ir.ExprId) ?u32 {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    return switch (expr.data) {
        .local_ref => |value| value,
        else => null,
    };
}

fn upper_bound_for_builtin_member(function: *const ir.Function, expr_id: ir.ExprId) ?u64 {
    const expr = function.exprs.items[expr_id];
    const member = switch (expr.data) {
        .member => |value| value,
        else => return null,
    };
    const base = function.exprs.items[resolve_value_alias(function, member.base)];
    const param_idx = switch (base.data) {
        .param_ref => |value| value,
        else => return null,
    };
    if (param_idx >= function.params.items.len) return null;
    const io = function.params.items[param_idx].io orelse return null;
    switch (io.builtin) {
        .local_invocation_id => {
            const axis: usize = if (std.mem.eql(u8, member.field_name, "x"))
                0
            else if (std.mem.eql(u8, member.field_name, "y"))
                1
            else if (std.mem.eql(u8, member.field_name, "z"))
                2
            else
                return null;
            const size = function.workgroup_size[axis];
            if (size == 0) return null;
            return size - 1;
        },
        else => return null,
    }
}

fn upper_bound_for_binary(
    module: *const ir.Module,
    function: *const ir.Function,
    access_expr_id: ir.ExprId,
    binary: @FieldType(ir.Expr, "binary"),
    depth: usize,
) ?u64 {
    switch (binary.op) {
        .add => {
            const lhs = upper_bound_for_expr(module, function, access_expr_id, binary.lhs, depth) orelse return null;
            const rhs = upper_bound_for_expr(module, function, access_expr_id, binary.rhs, depth) orelse return null;
            return std.math.add(u64, lhs, rhs) catch null;
        },
        .mul => {
            const lhs = upper_bound_for_expr(module, function, access_expr_id, binary.lhs, depth) orelse return null;
            const rhs = upper_bound_for_expr(module, function, access_expr_id, binary.rhs, depth) orelse return null;
            return std.math.mul(u64, lhs, rhs) catch null;
        },
        .div => {
            const lhs = upper_bound_for_expr(module, function, access_expr_id, binary.lhs, depth) orelse return null;
            const rhs = match_u32_literal_value(function, binary.rhs) orelse return null;
            if (rhs == 0) return null;
            return @divTrunc(lhs, rhs);
        },
        .rem => {
            const lhs = upper_bound_for_expr(module, function, access_expr_id, binary.lhs, depth) orelse return null;
            const rhs = match_u32_literal_value(function, binary.rhs) orelse return null;
            if (rhs == 0) return null;
            return @min(lhs, rhs - 1);
        },
        .shift_left => {
            const lhs = upper_bound_for_expr(module, function, access_expr_id, binary.lhs, depth) orelse return null;
            const rhs = match_u32_literal_value(function, binary.rhs) orelse return null;
            if (rhs >= 64) return null;
            return lhs << @as(std.math.Log2Int(u64), @intCast(rhs));
        },
        .shift_right => {
            const lhs = upper_bound_for_expr(module, function, access_expr_id, binary.lhs, depth) orelse return null;
            const rhs = match_u32_literal_value(function, binary.rhs) orelse return null;
            if (rhs >= 64) return null;
            return lhs >> @as(std.math.Log2Int(u64), @intCast(rhs));
        },
        .bit_and => {
            const lhs = upper_bound_for_expr(module, function, access_expr_id, binary.lhs, depth);
            const rhs = upper_bound_for_expr(module, function, access_expr_id, binary.rhs, depth);
            if (lhs) |lhs_bound| {
                if (rhs) |rhs_bound| return @min(lhs_bound, rhs_bound);
                return lhs_bound;
            }
            return rhs;
        },
        else => return null,
    }
}

fn resolve_value_alias(function: *const ir.Function, expr_id: ir.ExprId) ir.ExprId {
    var current = expr_id;
    while (true) {
        const expr = function.exprs.items[current];
        switch (expr.data) {
            .load => |inner| current = inner,
            .construct => |construct| {
                if (construct.args.len != 1) return current;
                current = function.expr_args.items[construct.args.start];
            },
            .local_ref => |local_idx| {
                current = resolve_const_local_initializer(function, local_idx) orelse return current;
            },
            else => return current,
        }
    }
}

fn resolve_const_local_initializer(function: *const ir.Function, local_idx: u32) ?ir.ExprId {
    for (function.stmts.items) |stmt| {
        switch (stmt) {
            .local_decl => |decl| {
                if (decl.local == local_idx and decl.is_const) return decl.initializer;
            },
            else => {},
        }
    }
    return null;
}

fn match_u32_literal_value(function: *const ir.Function, expr_id: ir.ExprId) ?u64 {
    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    switch (expr.data) {
        .int_lit => |value| return value,
        else => return null,
    }
}
