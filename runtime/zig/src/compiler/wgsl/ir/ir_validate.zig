const std = @import("std");
const ir = @import("ir.zig");

pub const ValidateError = error{
    InvalidIr,
};

pub fn validate(module: *const ir.Module) ValidateError!void {
    for (module.functions.items) |function| {
        if (function.root_stmt >= function.stmts.items.len) return error.InvalidIr;

        for (function.exprs.items) |expr| {
            if (expr.ty == ir.INVALID_TYPE) return error.InvalidIr;
            switch (expr.data) {
                .param_ref => |index| if (index >= function.params.items.len) return error.InvalidIr,
                .local_ref => |index| if (index >= function.locals.items.len) return error.InvalidIr,
                .global_ref => |index| if (index >= module.globals.items.len) return error.InvalidIr,
                .load => |inner| {
                    if (inner >= function.exprs.items.len) return error.InvalidIr;
                    if (function.exprs.items[inner].category != .ref) return error.InvalidIr;
                },
                .unary => |unary| if (unary.operand >= function.exprs.items.len) return error.InvalidIr,
                .binary => |binary| {
                    if (binary.lhs >= function.exprs.items.len or binary.rhs >= function.exprs.items.len) return error.InvalidIr;
                },
                .call => |call| {
                    if (call.args.start + call.args.len > function.expr_args.items.len) return error.InvalidIr;
                    if (call.kind == .user) {
                        const callee = find_function(module, call.name) orelse return error.InvalidIr;
                        if (call.args.len != callee.params.items.len) return error.InvalidIr;
                        var i: u32 = 0;
                        while (i < call.args.len) : (i += 1) {
                            const arg_id = function.expr_args.items[call.args.start + i];
                            if (arg_id >= function.exprs.items.len) return error.InvalidIr;
                            if (!type_compatible(module, callee.params.items[i].ty, function.exprs.items[arg_id].ty)) return error.InvalidIr;
                        }
                    }
                },
                .construct => |construct| {
                    if (construct.args.start + construct.args.len > function.expr_args.items.len) return error.InvalidIr;
                },
                .member => |member| if (member.base >= function.exprs.items.len) return error.InvalidIr,
                .index => |index| {
                    if (index.base >= function.exprs.items.len or index.index >= function.exprs.items.len) return error.InvalidIr;
                    if (!is_integer_type(module, function.exprs.items[index.index].ty)) return error.InvalidIr;
                },
                else => {},
            }
        }

        for (function.stmts.items) |stmt| {
            switch (stmt) {
                .block => |range| if (range.start + range.len > function.stmt_children.items.len) return error.InvalidIr,
                .local_decl => |decl| {
                    if (decl.local >= function.locals.items.len) return error.InvalidIr;
                    if (decl.initializer) |expr_id| {
                        if (expr_id >= function.exprs.items.len) return error.InvalidIr;
                        if (!type_compatible(module, function.locals.items[decl.local].ty, function.exprs.items[expr_id].ty)) return error.InvalidIr;
                    }
                },
                .expr => |expr_id| if (expr_id >= function.exprs.items.len) return error.InvalidIr,
                .assign => |assign| {
                    if (assign.lhs >= function.exprs.items.len or assign.rhs >= function.exprs.items.len) return error.InvalidIr;
                    const lhs = function.exprs.items[assign.lhs];
                    const rhs = function.exprs.items[assign.rhs];
                    if (lhs.category != .ref) return error.InvalidIr;
                    if (!type_compatible(module, lhs.ty, rhs.ty)) return error.InvalidIr;
                    if (!reference_is_mutable(module, function, assign.lhs)) return error.InvalidIr;
                },
                .return_ => |value| if (value) |expr_id| {
                    if (expr_id >= function.exprs.items.len) return error.InvalidIr;
                    if (!type_compatible(module, function.return_type, function.exprs.items[expr_id].ty)) return error.InvalidIr;
                } else if (!is_void_type(module, function.return_type)) return error.InvalidIr,
                .if_ => |if_stmt| {
                    if (if_stmt.cond >= function.exprs.items.len) return error.InvalidIr;
                    if (if_stmt.then_block >= function.stmts.items.len) return error.InvalidIr;
                    if (!is_bool_type(module, function.exprs.items[if_stmt.cond].ty)) return error.InvalidIr;
                    if (if_stmt.else_block) |stmt_id| if (stmt_id >= function.stmts.items.len) return error.InvalidIr;
                },
                .loop_ => |loop_stmt| {
                    if (loop_stmt.init) |stmt_id| if (stmt_id >= function.stmts.items.len) return error.InvalidIr;
                    if (loop_stmt.cond) |expr_id| {
                        if (expr_id >= function.exprs.items.len) return error.InvalidIr;
                        if (!is_bool_type(module, function.exprs.items[expr_id].ty)) return error.InvalidIr;
                    }
                    if (loop_stmt.continuing) |stmt_id| if (stmt_id >= function.stmts.items.len) return error.InvalidIr;
                    if (loop_stmt.body >= function.stmts.items.len) return error.InvalidIr;
                },
                .switch_ => |switch_stmt| {
                    if (switch_stmt.expr >= function.exprs.items.len) return error.InvalidIr;
                    if (switch_stmt.cases.start + switch_stmt.cases.len > function.switch_cases.items.len) return error.InvalidIr;
                },
                else => {},
            }
        }

        for (function.switch_cases.items) |case_node| {
            if (case_node.body >= function.stmts.items.len) return error.InvalidIr;
            for (case_node.selectors.items) |expr_id| {
                if (expr_id >= function.exprs.items.len) return error.InvalidIr;
            }
        }
    }
}

fn find_function(module: *const ir.Module, name: []const u8) ?*const ir.Function {
    for (module.functions.items) |*function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn is_void_type(module: *const ir.Module, ty: ir.TypeId) bool {
    return switch (module.types.get(ty)) {
        .scalar => |scalar| scalar == .void,
        else => false,
    };
}

fn is_bool_type(module: *const ir.Module, ty: ir.TypeId) bool {
    return switch (module.types.get(ty)) {
        .scalar => |scalar| scalar == .bool,
        else => false,
    };
}

fn is_integer_type(module: *const ir.Module, ty: ir.TypeId) bool {
    return switch (module.types.get(ty)) {
        .scalar => |scalar| scalar == .u32 or scalar == .i32 or scalar == .abstract_int,
        else => false,
    };
}

fn reference_is_mutable(module: *const ir.Module, function: ir.Function, expr_id: ir.ExprId) bool {
    const expr = function.exprs.items[expr_id];
    return switch (expr.data) {
        .param_ref => |index| switch (module.types.get(function.params.items[index].ty)) {
            .ref => |ref_ty| ref_ty.access != .read,
            else => true,
        },
        .local_ref => |index| switch (module.types.get(function.locals.items[index].ty)) {
            .ref => |ref_ty| ref_ty.access != .read,
            else => function.locals.items[index].mutable,
        },
        .global_ref => |index| switch (module.globals.items[index].class) {
            .var_ => true,
            else => false,
        },
        .member => |member| reference_is_mutable(module, function, member.base),
        .index => |index| reference_is_mutable(module, function, index.base),
        else => false,
    };
}

fn type_compatible(module: *const ir.Module, expected: ir.TypeId, actual: ir.TypeId) bool {
    if (expected == actual) return true;
    return switch (module.types.get(expected)) {
        .scalar => |expected_scalar| switch (module.types.get(actual)) {
            .scalar => |actual_scalar| switch (expected_scalar) {
                .abstract_int => actual_scalar == .abstract_int or actual_scalar == .i32 or actual_scalar == .u32,
                .abstract_float => actual_scalar == .abstract_float or actual_scalar == .f32 or actual_scalar == .f16,
                .i32, .u32 => actual_scalar == .abstract_int,
                .f32, .f16 => actual_scalar == .abstract_float,
                else => false,
            },
            else => false,
        },
        // Pointer param accepts matching element type.
        .ref => |ref_ty| ref_ty.elem == actual or type_compatible(module, ref_ty.elem, actual),
        else => false,
    };
}
