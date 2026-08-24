const std = @import("std");

const ir = @import("ir.zig");
const layout_utils = @import("layout_utils.zig");

pub fn resolveValueAlias(function: *const ir.Function, expr_id: ir.ExprId) ir.ExprId {
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
                current = resolveConstLocalInitializer(function, local_idx) orelse return current;
            },
            else => return current,
        }
    }
}

pub fn resolveConstLocalInitializer(function: *const ir.Function, local_idx: u32) ?ir.ExprId {
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

pub fn resolveIndexableType(types: *const ir.TypeStore, ty: ir.TypeId) ir.TypeId {
    var current = ty;
    while (true) {
        switch (types.get(current)) {
            .ref => |ref_ty| current = ref_ty.elem,
            else => return current,
        }
    }
}

pub fn classifyBuiltinComponent(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?u8 {
    const expr = function.exprs.items[resolveValueAlias(function, expr_id)];
    const member = switch (expr.data) {
        .member => |value| value,
        else => return null,
    };
    const base = function.exprs.items[resolveValueAlias(function, member.base)];
    const param_idx = switch (base.data) {
        .param_ref => |value| value,
        else => return null,
    };
    if (param_idx >= function.params.items.len) return null;
    const io = function.params.items[param_idx].io orelse return null;
    if (io.builtin != builtin) return null;
    if (std.mem.eql(u8, member.field_name, "x")) return 0;
    if (std.mem.eql(u8, member.field_name, "y")) return 1;
    if (std.mem.eql(u8, member.field_name, "z")) return 2;
    return null;
}

pub fn matchIntLiteral(function: *const ir.Function, expr_id: ir.ExprId) ?u64 {
    const expr = function.exprs.items[resolveValueAlias(function, expr_id)];
    return switch (expr.data) {
        .int_lit => |value| value,
        else => null,
    };
}

pub fn matchesIntLiteral(function: *const ir.Function, expr_id: ir.ExprId, expected: u64) bool {
    return matchIntLiteral(function, expr_id) == expected;
}

pub const RuntimeArrayWriteGuard = struct {
    unclamped_index: ir.ExprId,
    array_length: ir.ExprId,
};

/// Recognize the compiler-generated runtime-array clamp on an assignment
/// target. Reads retain the in-bounds clamp, while writes need an outer guard
/// so an out-of-bounds store is discarded instead of aliasing the last element.
pub fn runtimeArrayWriteGuard(
    function: *const ir.Function,
    lhs_expr_id: ir.ExprId,
) ?RuntimeArrayWriteGuard {
    var current = lhs_expr_id;
    while (true) {
        const expression = function.exprs.items[current];
        const index = switch (expression.data) {
            .index => |value| value,
            .member => |member| {
                current = member.base;
                continue;
            },
            else => return null,
        };
        const clamp = function.exprs.items[index.index];
        const call = switch (clamp.data) {
            .call => |value| value,
            else => return null,
        };
        if (!call.robustness_generated or
            call.kind != .builtin or
            !std.mem.eql(u8, call.name, "min") or
            call.args.len != 2)
        {
            current = index.base;
            continue;
        }
        const unclamped_index = function.expr_args.items[call.args.start];
        const maximum = function.exprs.items[function.expr_args.items[call.args.start + 1]];
        const subtraction = switch (maximum.data) {
            .binary => |value| value,
            else => return null,
        };
        if (subtraction.op != .sub or !matchesIntLiteral(function, subtraction.rhs, 1)) return null;
        const array_length = function.exprs.items[subtraction.lhs];
        const length_call = switch (array_length.data) {
            .call => |value| value,
            else => return null,
        };
        if (length_call.kind != .builtin or
            !std.mem.eql(u8, length_call.name, "arrayLength") or
            length_call.args.len != 1)
        {
            return null;
        }
        return .{
            .unclamped_index = unclamped_index,
            .array_length = subtraction.lhs,
        };
    }
}

pub fn typeHasIoStructField(module: *const ir.Module, ty: ir.TypeId) bool {
    return switch (module.types.get(ty)) {
        .struct_ => |struct_id| {
            for (module.structs.items[struct_id].fields.items) |field| {
                if (field.io != null) return true;
            }
            return false;
        },
        else => false,
    };
}

pub fn exprIsTexture1D(module: *const ir.Module, function: *const ir.Function, expr_id: ir.ExprId) bool {
    return switch (module.types.get(function.exprs.items[expr_id].ty)) {
        .texture_1d => true,
        else => false,
    };
}

pub fn resolveRuntimeArrayElementStride(
    module: *const ir.Module,
    function: *const ir.Function,
    base_id: ir.ExprId,
) ?u64 {
    const base_ty = resolveIndexableType(&module.types, function.exprs.items[base_id].ty);
    const array = switch (module.types.get(base_ty)) {
        .array => |value| value,
        else => return null,
    };
    if (array.len != null) return null;
    const elem_size = layout_utils.type_size(module, array.elem);
    const elem_align = layout_utils.type_alignment(module, array.elem);
    return layout_utils.round_up(elem_size, elem_align);
}

pub fn findGlobalBase(function: *const ir.Function, expr_id: ir.ExprId) ?u32 {
    var cursor = expr_id;
    while (true) {
        const node = function.exprs.items[cursor];
        switch (node.data) {
            .global_ref => |index| return index,
            .index => |index_expr| cursor = index_expr.base,
            .member => |member| cursor = member.base,
            .load => |inner| cursor = inner,
            else => return null,
        }
    }
}

pub fn isLocalRef(function: *const ir.Function, expr_id: ir.ExprId, local_idx: u32) bool {
    const expr = function.exprs.items[resolveValueAlias(function, expr_id)];
    return switch (expr.data) {
        .local_ref => |value| value == local_idx,
        else => false,
    };
}

pub fn stmtWritesLocal(function: *const ir.Function, stmt_id: ir.StmtId, local_idx: u32) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (stmtWritesLocal(function, child_id, local_idx)) return true;
            }
            return false;
        },
        .assign => |assign| return isLocalRef(function, assign.lhs, local_idx),
        .if_ => |if_stmt| return stmtWritesLocal(function, if_stmt.then_block, local_idx) or
            (if_stmt.else_block != null and stmtWritesLocal(function, if_stmt.else_block.?, local_idx)),
        .loop_ => |loop_stmt| {
            if (loop_stmt.init) |init_stmt| if (stmtWritesLocal(function, init_stmt, local_idx)) return true;
            if (loop_stmt.continuing) |continuing_stmt| if (stmtWritesLocal(function, continuing_stmt, local_idx)) return true;
            return stmtWritesLocal(function, loop_stmt.body, local_idx);
        },
        .switch_ => |switch_stmt| {
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (stmtWritesLocal(function, case_node.body, local_idx)) return true;
            }
            return false;
        },
        else => return false,
    }
}

pub fn stmtContainsExpr(function: *const ir.Function, stmt_id: ir.StmtId, target_expr_id: ir.ExprId) bool {
    if (stmt_id >= function.stmts.items.len) return false;
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            for (function.stmt_children.items[range.start .. range.start + range.len]) |child_id| {
                if (stmtContainsExpr(function, child_id, target_expr_id)) return true;
            }
            return false;
        },
        .local_decl => |decl| {
            if (decl.initializer) |init_expr| return exprContainsExpr(function, init_expr, target_expr_id);
            return false;
        },
        .expr => |value| return exprContainsExpr(function, value, target_expr_id),
        .assign => |assign| return exprContainsExpr(function, assign.lhs, target_expr_id) or
            exprContainsExpr(function, assign.rhs, target_expr_id),
        .return_ => |value| {
            if (value) |expr_ref| return exprContainsExpr(function, expr_ref, target_expr_id);
            return false;
        },
        .if_ => |if_stmt| return exprContainsExpr(function, if_stmt.cond, target_expr_id) or
            stmtContainsExpr(function, if_stmt.then_block, target_expr_id) or
            (if_stmt.else_block != null and stmtContainsExpr(function, if_stmt.else_block.?, target_expr_id)),
        .loop_ => |loop_stmt| {
            if (loop_stmt.init) |init_stmt| if (stmtContainsExpr(function, init_stmt, target_expr_id)) return true;
            if (loop_stmt.cond) |cond_expr| if (exprContainsExpr(function, cond_expr, target_expr_id)) return true;
            if (loop_stmt.continuing) |continuing_stmt| if (stmtContainsExpr(function, continuing_stmt, target_expr_id)) return true;
            return stmtContainsExpr(function, loop_stmt.body, target_expr_id);
        },
        .switch_ => |switch_stmt| {
            if (exprContainsExpr(function, switch_stmt.expr, target_expr_id)) return true;
            for (function.switch_cases.items[switch_stmt.cases.start .. switch_stmt.cases.start + switch_stmt.cases.len]) |case_node| {
                if (stmtContainsExpr(function, case_node.body, target_expr_id)) return true;
            }
            return false;
        },
        else => return false,
    }
}

pub fn exprContainsExpr(function: *const ir.Function, expr_id: ir.ExprId, target_expr_id: ir.ExprId) bool {
    if (expr_id == target_expr_id) return true;
    if (expr_id >= function.exprs.items.len) return false;
    const expr = function.exprs.items[expr_id];
    switch (expr.data) {
        .load => |inner| return exprContainsExpr(function, inner, target_expr_id),
        .unary => |unary| return exprContainsExpr(function, unary.operand, target_expr_id),
        .binary => |binary| return exprContainsExpr(function, binary.lhs, target_expr_id) or
            exprContainsExpr(function, binary.rhs, target_expr_id),
        .call => |call| {
            for (function.expr_args.items[call.args.start .. call.args.start + call.args.len]) |arg_id| {
                if (exprContainsExpr(function, arg_id, target_expr_id)) return true;
            }
            return false;
        },
        .construct => |construct| {
            for (function.expr_args.items[construct.args.start .. construct.args.start + construct.args.len]) |arg_id| {
                if (exprContainsExpr(function, arg_id, target_expr_id)) return true;
            }
            return false;
        },
        .member => |member| return exprContainsExpr(function, member.base, target_expr_id),
        .index => |index| return exprContainsExpr(function, index.base, target_expr_id) or
            exprContainsExpr(function, index.index, target_expr_id),
        else => return false,
    }
}

test "canonical IR queries resolve builtin, literal, global base, and runtime stride" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const scalar_type = try module.types.intern(.{ .scalar = .f32 });
    const runtime_array_type = try module.types.intern(.{ .array = .{
        .elem = scalar_type,
        .len = null,
    } });
    const texture_1d_type = try module.types.intern(.{ .texture_1d = scalar_type });
    {
        var io_struct = ir.StructDef{ .name = try ir.dup_string(allocator, "StageOutput") };
        errdefer io_struct.deinit(allocator);
        try io_struct.fields.append(allocator, .{
            .name = try ir.dup_string(allocator, "position"),
            .ty = scalar_type,
            .io = .{ .builtin = .position },
        });
        try module.structs.append(allocator, io_struct);
    }
    const io_struct_type = try module.types.intern(.{ .struct_ = 0 });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "main"),
        .return_type = ir.INVALID_TYPE,
    };
    defer function.deinit(allocator);
    try function.params.append(allocator, .{
        .name = try ir.dup_string(allocator, "gid"),
        .ty = ir.INVALID_TYPE,
        .io = .{ .builtin = .global_invocation_id },
    });

    const param_id = try function.append_expr(allocator, .{
        .ty = ir.INVALID_TYPE,
        .category = .value,
        .data = .{ .param_ref = 0 },
    });
    const component_id = try function.append_expr(allocator, .{
        .ty = ir.INVALID_TYPE,
        .category = .value,
        .data = .{ .member = .{
            .base = param_id,
            .field_name = try ir.dup_string(allocator, "y"),
            .field_index = 1,
        } },
    });
    const literal_id = try function.append_expr(allocator, .{
        .ty = ir.INVALID_TYPE,
        .category = .value,
        .data = .{ .int_lit = 7 },
    });
    const texture_id = try function.append_expr(allocator, .{
        .ty = texture_1d_type,
        .category = .value,
        .data = .{ .global_ref = 4 },
    });
    const global_id = try function.append_expr(allocator, .{
        .ty = runtime_array_type,
        .category = .ref,
        .data = .{ .global_ref = 3 },
    });
    const index_id = try function.append_expr(allocator, .{
        .ty = scalar_type,
        .category = .ref,
        .data = .{ .index = .{ .base = global_id, .index = literal_id } },
    });
    const load_id = try function.append_expr(allocator, .{
        .ty = scalar_type,
        .category = .value,
        .data = .{ .load = index_id },
    });

    try std.testing.expectEqual(@as(?u8, 1), classifyBuiltinComponent(&function, component_id, .global_invocation_id));
    try std.testing.expectEqual(@as(?u64, 7), matchIntLiteral(&function, literal_id));
    try std.testing.expect(matchesIntLiteral(&function, literal_id, 7));
    try std.testing.expect(typeHasIoStructField(&module, io_struct_type));
    try std.testing.expect(exprIsTexture1D(&module, &function, texture_id));
    try std.testing.expectEqual(@as(?u32, 3), findGlobalBase(&function, load_id));
    try std.testing.expectEqual(@as(?u64, 4), resolveRuntimeArrayElementStride(&module, &function, global_id));
}
