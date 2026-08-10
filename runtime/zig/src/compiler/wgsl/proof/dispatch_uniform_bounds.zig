const std = @import("std");
const ir = @import("../ir/ir.zig");
const ir_const_eval = @import("../ir/ir_const_eval.zig");
const ir_query = @import("../ir/ir_query.zig");

const classify_builtin_component = ir_query.classifyBuiltinComponent;
const expr_contains_expr = ir_query.exprContainsExpr;
const is_local_ref = ir_query.isLocalRef;
const match_u32_literal_value = ir_query.matchIntLiteral;
const resolve_const_local_initializer = ir_query.resolveConstLocalInitializer;
const resolve_runtime_array_element_stride = ir_query.resolveRuntimeArrayElementStride;
const resolve_value_alias = ir_query.resolveValueAlias;

const UniformField = struct {
    binding: ir.BindingPoint,
    byte_offset: u32,
    name: []const u8,
};

const LoopLimit = struct {
    field: UniformField,
    rounded_down_4: bool,
};

pub fn try_elide_uniform_validated_storage_index(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
    index_data: @FieldType(ir.Expr, "index"),
) ?ir.DispatchPrecondition {
    const storage_binding = resolve_storage_binding(module, function, index_data.base) orelse return null;
    const element_stride_bytes = resolve_runtime_array_element_stride(module, function, index_data.base) orelse return null;

    if (match_uniform_guarded_gid_access(module, function, expr_id, index_data.index)) |limit| {
        return .{
            .kind = .uniform_extent,
            .gid_axis = 0,
            .storage_binding = storage_binding,
            .element_stride_bytes = element_stride_bytes,
            .uniform_binding = limit.binding,
            .uniform_u32_offsets = .{ limit.byte_offset, 0 },
            .uniform_u32_count = 1,
        };
    }

    if (match_vector_cols_access(module, function, expr_id, index_data.index)) |cols| {
        return .{
            .kind = .uniform_extent,
            .gid_axis = 0,
            .storage_binding = storage_binding,
            .element_stride_bytes = element_stride_bytes,
            .uniform_binding = cols.binding,
            .uniform_u32_offsets = .{ cols.byte_offset, 0 },
            .uniform_u32_count = 1,
        };
    }

    if (match_matrix_rows_cols_access(module, function, function_id, expr_id, index_data.index)) |shape| {
        return .{
            .kind = .uniform_extent,
            .gid_axis = 0,
            .storage_binding = storage_binding,
            .element_stride_bytes = element_stride_bytes,
            .uniform_binding = shape.rows.binding,
            .uniform_u32_offsets = .{ shape.rows.byte_offset, shape.cols.byte_offset },
            .uniform_u32_count = 2,
        };
    }

    if (match_uniform_product_guarded_access(module, function, expr_id, index_data.index)) |shape| {
        return .{
            .kind = .uniform_extent,
            .gid_axis = 0,
            .storage_binding = storage_binding,
            .element_stride_bytes = element_stride_bytes,
            .uniform_binding = shape.major.binding,
            .uniform_u32_offsets = .{ shape.major.byte_offset, shape.stride.byte_offset },
            .uniform_u32_count = 2,
        };
    }

    return null;
}

fn match_uniform_guarded_gid_access(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    index_id: ir.ExprId,
) ?UniformField {
    if (classify_builtin_component(function, index_id, .global_invocation_id) == null) return null;
    return find_uniform_guard_before_expr(module, function, function.root_stmt, expr_id, index_id, null);
}

fn find_uniform_guard_before_expr(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    expr_id: ir.ExprId,
    index_id: ir.ExprId,
    inherited: ?UniformField,
) ?UniformField {
    if (stmt_id >= function.stmts.items.len) return null;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            var guard = inherited;
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (stmt_contains_expr(function, child_id, expr_id)) {
                    return find_uniform_guard_before_expr(module, function, child_id, expr_id, index_id, guard) orelse guard;
                }
                if (stmt_matches_uniform_return_guard(module, function, child_id, index_id)) |limit| guard = limit;
            }
            return null;
        },
        .if_ => |if_stmt| {
            if (stmt_contains_expr(function, if_stmt.then_block, expr_id)) {
                return find_uniform_guard_before_expr(module, function, if_stmt.then_block, expr_id, index_id, inherited) orelse inherited;
            }
            if (if_stmt.else_block) |else_block| {
                if (stmt_contains_expr(function, else_block, expr_id)) {
                    return find_uniform_guard_before_expr(module, function, else_block, expr_id, index_id, inherited) orelse inherited;
                }
            }
            return null;
        },
        .loop_ => |loop_stmt| {
            if (!stmt_contains_expr(function, loop_stmt.body, expr_id)) return null;
            return find_uniform_guard_before_expr(module, function, loop_stmt.body, expr_id, index_id, inherited) orelse inherited;
        },
        .switch_ => |switch_stmt| {
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (stmt_contains_expr(function, case_node.body, expr_id)) {
                    return find_uniform_guard_before_expr(module, function, case_node.body, expr_id, index_id, inherited) orelse inherited;
                }
            }
            return null;
        },
        else => return if (stmt_contains_expr(function, stmt_id, expr_id)) inherited else null,
    }
}

fn stmt_matches_uniform_return_guard(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    index_id: ir.ExprId,
) ?UniformField {
    if (stmt_id >= function.stmts.items.len) return null;
    const if_stmt = switch (function.stmts.items[stmt_id]) {
        .if_ => |value| value,
        else => return null,
    };
    if (if_stmt.else_block != null or !is_single_return_block(function, if_stmt.then_block)) return null;
    return match_index_ge_uniform(module, function, if_stmt.cond, index_id);
}

fn match_index_ge_uniform(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    index_id: ir.ExprId,
) ?UniformField {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op == .greater_equal and same_value_expr(function, binary.lhs, index_id)) {
        return match_uniform_field(module, function, binary.rhs);
    }
    if (binary.op == .less_equal and same_value_expr(function, binary.rhs, index_id)) {
        return match_uniform_field(module, function, binary.lhs);
    }
    return null;
}

fn match_vector_cols_access(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    index_id: ir.ExprId,
) ?UniformField {
    const local = match_local_plus_offset(function, index_id) orelse return null;
    const limit = find_loop_limit_for_local(module, function, expr_id, local.local_idx) orelse return null;
    if (!std.mem.eql(u8, limit.field.name, "cols")) return null;
    if (limit.rounded_down_4) {
        if (local.offset > 3) return null;
    } else if (local.offset != 0) {
        return null;
    }
    return limit.field;
}

fn match_matrix_rows_cols_access(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
    index_id: ir.ExprId,
) ?struct { rows: UniformField, cols: UniformField } {
    var state = MatrixIndexState{};
    if (!collect_matrix_index_terms(module, function, index_id, &state)) return null;
    const row_param = state.row_param orelse return null;
    const loop_local = state.loop_local orelse return null;
    const cols = state.cols orelse return null;
    if (!std.mem.eql(u8, cols.name, "cols")) return null;
    const limit = find_loop_limit_for_local(module, function, expr_id, loop_local) orelse return null;
    if (!same_uniform_field(cols, limit.field)) return null;
    if (limit.rounded_down_4) {
        if (state.offset > 3) return null;
    } else if (state.offset != 0) {
        return null;
    }
    const rows = row_param_guarded_by_uniform_rows(module, function_id, row_param) orelse return null;
    if (rows.binding.group != cols.binding.group or rows.binding.binding != cols.binding.binding) return null;
    return .{ .rows = rows, .cols = cols };
}

const MatrixIndexState = struct {
    row_param: ?u32 = null,
    loop_local: ?u32 = null,
    cols: ?UniformField = null,
    offset: u64 = 0,
};

const AffineExpr = struct {
    base: ir.ExprId,
    offset: u64 = 0,
};

fn match_uniform_product_guarded_access(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    index_id: ir.ExprId,
) ?struct { major: UniformField, stride: UniformField } {
    const product = match_uniform_product_index(module, function, index_id) orelse return null;
    const guard = find_guard_for_expr(module, function, function.root_stmt, expr_id) orelse return null;
    const extent = match_product_guard(module, function, guard, product.major, product.minor, product.stride) orelse return null;
    return .{ .major = extent.major, .stride = extent.stride };
}

fn match_uniform_product_index(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?struct { major: AffineExpr, minor: AffineExpr, stride: UniformField } {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .add) return null;

    if (match_major_stride_term(module, function, binary.lhs)) |major| {
        const minor = match_affine_expr(function, binary.rhs) orelse return null;
        return .{ .major = major.expr, .minor = minor, .stride = major.stride };
    }
    if (match_major_stride_term(module, function, binary.rhs)) |major| {
        const minor = match_affine_expr(function, binary.lhs) orelse return null;
        return .{ .major = major.expr, .minor = minor, .stride = major.stride };
    }
    if (match_u32_literal_value(function, binary.lhs)) |offset| {
        var nested = match_uniform_product_index(module, function, binary.rhs) orelse return null;
        nested.minor.offset = std.math.add(u64, nested.minor.offset, offset) catch return null;
        return nested;
    }
    if (match_u32_literal_value(function, binary.rhs)) |offset| {
        var nested = match_uniform_product_index(module, function, binary.lhs) orelse return null;
        nested.minor.offset = std.math.add(u64, nested.minor.offset, offset) catch return null;
        return nested;
    }
    return null;
}

fn match_major_stride_term(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?struct { expr: AffineExpr, stride: UniformField } {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .mul) return null;
    if (match_uniform_field(module, function, binary.lhs)) |stride| {
        const major = match_affine_expr(function, binary.rhs) orelse return null;
        return .{ .expr = major, .stride = stride };
    }
    if (match_uniform_field(module, function, binary.rhs)) |stride| {
        const major = match_affine_expr(function, binary.lhs) orelse return null;
        return .{ .expr = major, .stride = stride };
    }
    return null;
}

fn match_affine_expr(function: *const ir.Function, expr_id: ir.ExprId) ?AffineExpr {
    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return .{ .base = canonical },
    };
    if (binary.op != .add) return .{ .base = canonical };
    if (match_u32_literal_value(function, binary.lhs)) |offset| {
        return .{ .base = resolve_value_alias(function, binary.rhs), .offset = offset };
    }
    if (match_u32_literal_value(function, binary.rhs)) |offset| {
        return .{ .base = resolve_value_alias(function, binary.lhs), .offset = offset };
    }
    return .{ .base = canonical };
}

fn find_guard_for_expr(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    expr_id: ir.ExprId,
) ?ir.ExprId {
    if (stmt_id >= function.stmts.items.len) return null;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (find_guard_for_expr(module, function, child_id, expr_id)) |guard| return guard;
            }
            return null;
        },
        .if_ => |if_stmt| {
            if (stmt_contains_expr(function, if_stmt.then_block, expr_id)) return if_stmt.cond;
            if (if_stmt.else_block) |else_block| {
                if (stmt_contains_expr(function, else_block, expr_id)) return null;
            }
            return null;
        },
        .loop_ => |loop_stmt| return find_guard_for_expr(module, function, loop_stmt.body, expr_id),
        .switch_ => |switch_stmt| {
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (find_guard_for_expr(module, function, case_node.body, expr_id)) |guard| return guard;
            }
            return null;
        },
        else => return null,
    }
}

fn match_product_guard(
    module: *const ir.Module,
    function: *const ir.Function,
    guard_id: ir.ExprId,
    major: AffineExpr,
    minor: AffineExpr,
    stride: UniformField,
) ?struct { major: UniformField, stride: UniformField } {
    var state = ProductGuardState{ .major_expr = major, .minor_expr = minor, .stride = stride };
    collect_product_guard_terms(module, function, guard_id, &state);
    const major_field = state.major orelse return null;
    if (!state.minor_matches_stride) return null;
    if (major_field.binding.group != stride.binding.group or major_field.binding.binding != stride.binding.binding) return null;
    return .{ .major = major_field, .stride = stride };
}

const ProductGuardState = struct {
    major_expr: AffineExpr,
    minor_expr: AffineExpr,
    stride: UniformField,
    major: ?UniformField = null,
    minor_matches_stride: bool = false,
};

fn collect_product_guard_terms(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    state: *ProductGuardState,
) void {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return,
    };
    if (binary.op == .logical_and) {
        collect_product_guard_terms(module, function, binary.lhs, state);
        collect_product_guard_terms(module, function, binary.rhs, state);
        return;
    }
    if (binary.op != .less) return;
    const lhs = match_affine_expr(function, binary.lhs) orelse return;
    const rhs = match_uniform_field(module, function, binary.rhs) orelse return;
    if (same_affine_expr(lhs, state.major_expr)) state.major = rhs;
    if (same_affine_expr(lhs, state.minor_expr) and same_uniform_field(rhs, state.stride)) {
        state.minor_matches_stride = true;
    }
}

fn collect_matrix_index_terms(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    state: *MatrixIndexState,
) bool {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    switch (expr.data) {
        .binary => |binary| {
            if (binary.op == .add) {
                return collect_matrix_index_terms(module, function, binary.lhs, state) and
                    collect_matrix_index_terms(module, function, binary.rhs, state);
            }
            if (binary.op == .mul) {
                return collect_row_times_cols(module, function, binary.lhs, binary.rhs, state) or
                    collect_row_times_cols(module, function, binary.rhs, binary.lhs, state);
            }
            return false;
        },
        .int_lit => |value| {
            state.offset = std.math.add(u64, state.offset, value) catch return false;
            return true;
        },
        .local_ref => |local_idx| {
            if (state.loop_local) |existing| return existing == local_idx;
            state.loop_local = local_idx;
            return true;
        },
        else => return false,
    }
}

fn collect_row_times_cols(
    module: *const ir.Module,
    function: *const ir.Function,
    lhs: ir.ExprId,
    rhs: ir.ExprId,
    state: *MatrixIndexState,
) bool {
    const param_idx = match_param_ref(function, lhs) orelse return false;
    const cols = match_uniform_field(module, function, rhs) orelse return false;
    if (!std.mem.eql(u8, cols.name, "cols")) return false;
    if (state.row_param) |existing| {
        if (existing != param_idx) return false;
    } else {
        state.row_param = param_idx;
    }
    if (state.cols) |existing| {
        if (!same_uniform_field(existing, cols)) return false;
    } else {
        state.cols = cols;
    }
    return true;
}

fn match_local_plus_offset(
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?struct { local_idx: u32, offset: u64 } {
    var local_idx: ?u32 = null;
    var offset: u64 = 0;
    if (!collect_local_plus_offset(function, expr_id, &local_idx, &offset)) return null;
    return .{ .local_idx = local_idx orelse return null, .offset = offset };
}

fn collect_local_plus_offset(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    local_idx: *?u32,
    offset: *u64,
) bool {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    switch (expr.data) {
        .binary => |binary| {
            if (binary.op != .add) return false;
            return collect_local_plus_offset(function, binary.lhs, local_idx, offset) and
                collect_local_plus_offset(function, binary.rhs, local_idx, offset);
        },
        .int_lit => |value| {
            offset.* = std.math.add(u64, offset.*, value) catch return false;
            return true;
        },
        .local_ref => |value| {
            if (local_idx.*) |existing| return existing == value;
            local_idx.* = value;
            return true;
        },
        else => return false,
    }
}

fn find_loop_limit_for_local(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    local_idx: u32,
) ?LoopLimit {
    return find_loop_limit_in_stmt(module, function, function.root_stmt, expr_id, local_idx);
}

fn find_loop_limit_in_stmt(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    expr_id: ir.ExprId,
    local_idx: u32,
) ?LoopLimit {
    if (stmt_id >= function.stmts.items.len) return null;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (find_loop_limit_in_stmt(module, function, child_id, expr_id, local_idx)) |limit| return limit;
            }
            return null;
        },
        .if_ => |if_stmt| {
            if (find_loop_limit_in_stmt(module, function, if_stmt.then_block, expr_id, local_idx)) |limit| return limit;
            if (if_stmt.else_block) |else_block| {
                return find_loop_limit_in_stmt(module, function, else_block, expr_id, local_idx);
            }
            return null;
        },
        .loop_ => |loop_stmt| {
            if (match_guarded_loop_limit(module, function, loop_stmt, expr_id, local_idx)) |limit| return limit;
            return find_loop_limit_in_stmt(module, function, loop_stmt.body, expr_id, local_idx);
        },
        .switch_ => |switch_stmt| {
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (find_loop_limit_in_stmt(module, function, case_node.body, expr_id, local_idx)) |limit| return limit;
            }
            return null;
        },
        else => return null,
    }
}

fn match_guarded_loop_limit(
    module: *const ir.Module,
    function: *const ir.Function,
    loop_stmt: @FieldType(ir.Stmt, "loop_"),
    expr_id: ir.ExprId,
    local_idx: u32,
) ?LoopLimit {
    if (!stmt_contains_expr(function, loop_stmt.body, expr_id)) return null;
    const body = if (loop_stmt.body < function.stmts.items.len) function.stmts.items[loop_stmt.body] else return null;
    const range = switch (body) {
        .block => |value| value,
        else => return null,
    };
    if (range.len < 2) return null;
    const children = function.stmt_children.items[range.start .. range.start + range.len];
    const limit = match_break_guard_stmt(module, function, children[0], local_idx) orelse return null;
    if (!expr_before_first_local_write(function, children[1..], expr_id, local_idx)) return null;
    return limit;
}

fn expr_before_first_local_write(
    function: *const ir.Function,
    children: []const ir.StmtId,
    expr_id: ir.ExprId,
    local_idx: u32,
) bool {
    for (children) |child_id| {
        if (stmt_contains_expr(function, child_id, expr_id)) return true;
        if (stmt_writes_local(function, child_id, local_idx)) return false;
    }
    return false;
}

fn match_break_guard_stmt(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    local_idx: u32,
) ?LoopLimit {
    if (stmt_id >= function.stmts.items.len) return null;
    const if_stmt = switch (function.stmts.items[stmt_id]) {
        .if_ => |value| value,
        else => return null,
    };
    if (if_stmt.else_block != null) return null;
    if (!is_single_break_block(function, if_stmt.then_block)) return null;
    return match_local_ge_uniform_limit(module, function, if_stmt.cond, local_idx);
}

fn match_local_ge_uniform_limit(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    local_idx: u32,
) ?LoopLimit {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op == .greater_equal and is_local_ref(function, binary.lhs, local_idx)) {
        return match_uniform_limit(module, function, binary.rhs);
    }
    if (binary.op == .less_equal and is_local_ref(function, binary.rhs, local_idx)) {
        return match_uniform_limit(module, function, binary.lhs);
    }
    return null;
}

fn match_uniform_limit(module: *const ir.Module, function: *const ir.Function, expr_id: ir.ExprId) ?LoopLimit {
    if (match_uniform_field(module, function, expr_id)) |field| {
        return .{ .field = field, .rounded_down_4 = false };
    }
    if (match_uniform_field_masked_to_multiple_of_4(module, function, expr_id)) |field| {
        return .{ .field = field, .rounded_down_4 = true };
    }
    return null;
}

fn match_uniform_field_masked_to_multiple_of_4(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?UniformField {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .bit_and) return null;
    if (match_uniform_field(module, function, binary.lhs)) |field| {
        if (match_u32_mask_4(module, function, binary.rhs)) return field;
    }
    if (match_uniform_field(module, function, binary.rhs)) |field| {
        if (match_u32_mask_4(module, function, binary.lhs)) return field;
    }
    return null;
}

fn row_param_guarded_by_uniform_rows(
    module: *const ir.Module,
    function_id: ir.FunctionId,
    row_param: u32,
) ?UniformField {
    if (function_id >= module.functions.items.len) return null;
    const target = module.functions.items[function_id];
    var call_count: usize = 0;
    var rows: ?UniformField = null;
    for (module.functions.items) |*caller| {
        for (caller.exprs.items, 0..) |expr, expr_index| {
            const call = switch (expr.data) {
                .call => |value| value,
                else => continue,
            };
            if (call.kind != .user or !std.mem.eql(u8, call.name, target.name)) continue;
            if (row_param >= call.args.len) return null;
            const arg_id = caller.expr_args.items[call.args.start + row_param];
            const guarded_rows = call_arg_guarded_by_rows(module, caller, @intCast(expr_index), arg_id) orelse return null;
            if (rows) |existing| {
                if (!same_uniform_field(existing, guarded_rows)) return null;
            } else {
                rows = guarded_rows;
            }
            call_count += 1;
        }
    }
    if (call_count == 0) return null;
    return rows;
}

fn call_arg_guarded_by_rows(
    module: *const ir.Module,
    function: *const ir.Function,
    call_expr_id: ir.ExprId,
    arg_id: ir.ExprId,
) ?UniformField {
    const result = find_call_guard_in_stmt(module, function, function.root_stmt, call_expr_id, arg_id, null);
    return result orelse null;
}

fn find_call_guard_in_stmt(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    call_expr_id: ir.ExprId,
    arg_id: ir.ExprId,
    inherited: ?UniformField,
) ??UniformField {
    if (stmt_id >= function.stmts.items.len) return null;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            var guard = inherited;
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (stmt_matches_return_guard(module, function, child_id, arg_id)) |rows| guard = rows;
                if (stmt_contains_expr(function, child_id, call_expr_id)) return guard;
                if (find_call_guard_in_stmt(module, function, child_id, call_expr_id, arg_id, guard)) |nested| return nested;
            }
            return null;
        },
        .if_ => |if_stmt| {
            if (find_call_guard_in_stmt(module, function, if_stmt.then_block, call_expr_id, arg_id, inherited)) |nested| return nested;
            if (if_stmt.else_block) |else_block| {
                return find_call_guard_in_stmt(module, function, else_block, call_expr_id, arg_id, inherited);
            }
            return null;
        },
        .loop_ => |loop_stmt| return find_call_guard_in_stmt(module, function, loop_stmt.body, call_expr_id, arg_id, inherited),
        else => return null,
    }
}

fn stmt_matches_return_guard(
    module: *const ir.Module,
    function: *const ir.Function,
    stmt_id: ir.StmtId,
    arg_id: ir.ExprId,
) ?UniformField {
    if (stmt_id >= function.stmts.items.len) return null;
    const if_stmt = switch (function.stmts.items[stmt_id]) {
        .if_ => |value| value,
        else => return null,
    };
    if (if_stmt.else_block != null or !is_single_return_block(function, if_stmt.then_block)) return null;
    return match_arg_ge_rows(module, function, if_stmt.cond, arg_id);
}

fn match_arg_ge_rows(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    arg_id: ir.ExprId,
) ?UniformField {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op == .greater_equal and same_value_expr(function, binary.lhs, arg_id)) {
        const rows = match_uniform_field(module, function, binary.rhs) orelse return null;
        if (std.mem.eql(u8, rows.name, "rows")) return rows;
    }
    if (binary.op == .less_equal and same_value_expr(function, binary.rhs, arg_id)) {
        const rows = match_uniform_field(module, function, binary.lhs) orelse return null;
        if (std.mem.eql(u8, rows.name, "rows")) return rows;
    }
    return null;
}

fn match_uniform_field(module: *const ir.Module, function: *const ir.Function, expr_id: ir.ExprId) ?UniformField {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const member = switch (expr.data) {
        .member => |value| value,
        else => return null,
    };
    const base = function.exprs.items[resolve_value_alias(function, member.base)];
    const global_idx = switch (base.data) {
        .global_ref => |value| value,
        else => return null,
    };
    if (global_idx >= module.globals.items.len) return null;
    const global = module.globals.items[global_idx];
    if (global.addr_space != .uniform) return null;
    return .{
        .binding = global.binding orelse return null,
        .byte_offset = member.field_index * @sizeOf(u32),
        .name = member.field_name,
    };
}

fn match_param_ref(function: *const ir.Function, expr_id: ir.ExprId) ?u32 {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    return switch (expr.data) {
        .param_ref => |value| value,
        else => null,
    };
}

fn match_u32_mask_4(module: *const ir.Module, function: *const ir.Function, expr_id: ir.ExprId) bool {
    const canonical = resolve_value_alias(function, expr_id);
    if (ir_const_eval.resolve_constant_int(module, function, canonical) == 0xffff_fffc) return true;
    const expr = function.exprs.items[canonical];
    const unary = switch (expr.data) {
        .unary => |value| value,
        else => return false,
    };
    return unary.op == .bit_not and ir_const_eval.resolve_constant_int(module, function, resolve_value_alias(function, unary.operand)) == 3;
}

fn same_uniform_field(a: UniformField, b: UniformField) bool {
    return a.binding.group == b.binding.group and
        a.binding.binding == b.binding.binding and
        a.byte_offset == b.byte_offset and
        std.mem.eql(u8, a.name, b.name);
}

fn same_value_expr(function: *const ir.Function, a: ir.ExprId, b: ir.ExprId) bool {
    return resolve_value_alias(function, a) == resolve_value_alias(function, b);
}

fn same_affine_expr(a: AffineExpr, b: AffineExpr) bool {
    return a.base == b.base and a.offset == b.offset;
}

fn is_single_break_block(function: *const ir.Function, stmt_id: ir.StmtId) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    const range = switch (function.stmts.items[stmt_id]) {
        .block => |value| value,
        else => return false,
    };
    if (range.len != 1) return false;
    return function.stmts.items[function.stmt_children.items[range.start]] == .break_;
}

fn is_single_return_block(function: *const ir.Function, stmt_id: ir.StmtId) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    const range = switch (function.stmts.items[stmt_id]) {
        .block => |value| value,
        else => return false,
    };
    if (range.len != 1) return false;
    return function.stmts.items[function.stmt_children.items[range.start]] == .return_;
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
        .loop_ => |loop_stmt| return stmt_writes_local(function, loop_stmt.body, local_idx),
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
        .local_decl => |decl| return decl.initializer != null and expr_contains_expr(function, decl.initializer.?, target_expr_id),
        .expr => |value| return expr_contains_expr(function, value, target_expr_id),
        .assign => |assign| return expr_contains_expr(function, assign.lhs, target_expr_id) or
            expr_contains_expr(function, assign.rhs, target_expr_id),
        .return_ => |value| return value != null and expr_contains_expr(function, value.?, target_expr_id),
        .if_ => |if_stmt| return expr_contains_expr(function, if_stmt.cond, target_expr_id) or
            stmt_contains_expr(function, if_stmt.then_block, target_expr_id) or
            (if_stmt.else_block != null and stmt_contains_expr(function, if_stmt.else_block.?, target_expr_id)),
        .loop_ => |loop_stmt| return stmt_contains_expr(function, loop_stmt.body, target_expr_id),
        else => return false,
    }
}

fn resolve_storage_binding(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?ir.BindingPoint {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    switch (expr.data) {
        .global_ref => |global_idx| {
            if (global_idx >= module.globals.items.len) return null;
            const global = module.globals.items[global_idx];
            if (global.addr_space != .storage) return null;
            return global.binding;
        },
        .member => |member| return resolve_storage_binding(module, function, member.base),
        .index => |index| return resolve_storage_binding(module, function, index.base),
        else => return null,
    }
}
