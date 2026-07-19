const ir = @import("../../ir/ir.zig");

const SINGLE_INVOCATION_WORKGROUP_SIZE: u32 = 1;

pub fn canLowerWorkgroupGlobalToThread(
    module: *const ir.Module,
    function: ir.Function,
    global_index: u32,
) bool {
    if (function.stage != .compute) return false;
    if (!singleInvocationWorkgroup(function)) return false;
    if (moduleHasWorkgroupRefParam(module)) return false;
    const global = module.globals.items[global_index];
    if (global.binding != null or global.class != .var_ or global.addr_space != .workgroup) return false;
    return !typeContainsAtomic(module, global.ty) and !typeContainsArray(module, global.ty);
}

pub fn singleInvocationWorkgroup(function: ir.Function) bool {
    return function.workgroup_size[0] * function.workgroup_size[1] * function.workgroup_size[2] ==
        SINGLE_INVOCATION_WORKGROUP_SIZE;
}

pub fn unwrittenWorkgroupGlobal(
    module: *const ir.Module,
    function: ir.Function,
    global_index: u32,
) bool {
    const global = module.globals.items[global_index];
    if (global.binding != null or global.class != .var_ or global.addr_space != .workgroup) return false;
    for (function.stmts.items, 0..) |_, stmt_index| {
        if (stmtMutatesOrEscapesGlobal(module, function, @intCast(stmt_index), global_index)) return false;
    }
    return true;
}

pub fn refRootGlobal(function: ir.Function, expr_id: ir.ExprId) ?u32 {
    return switch (function.exprs.items[expr_id].data) {
        .global_ref => |index| index,
        .load => |inner| refRootGlobal(function, inner),
        .member => |member| refRootGlobal(function, member.base),
        .index => |index| refRootGlobal(function, index.base),
        else => null,
    };
}

fn moduleHasWorkgroupRefParam(module: *const ir.Module) bool {
    for (module.functions.items) |function| {
        for (function.params.items) |param| {
            const ref_ty = switch (module.types.get(param.ty)) {
                .ref => |value| value,
                else => continue,
            };
            if (ref_ty.addr_space == .workgroup) return true;
        }
    }
    return false;
}

fn typeContainsAtomic(module: *const ir.Module, ty: ir.TypeId) bool {
    return switch (module.types.get(ty)) {
        .atomic => true,
        .array => |arr| typeContainsAtomic(module, arr.elem),
        .struct_ => |struct_id| blk: {
            const struct_def = module.structs.items[struct_id];
            for (struct_def.fields.items) |field| {
                if (typeContainsAtomic(module, field.ty)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn typeContainsArray(module: *const ir.Module, ty: ir.TypeId) bool {
    return switch (module.types.get(ty)) {
        .array => true,
        .struct_ => |struct_id| blk: {
            const struct_def = module.structs.items[struct_id];
            for (struct_def.fields.items) |field| {
                if (typeContainsArray(module, field.ty)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn stmtMutatesOrEscapesGlobal(
    module: *const ir.Module,
    function: ir.Function,
    stmt_id: ir.StmtId,
    global_index: u32,
) bool {
    return switch (function.stmts.items[stmt_id]) {
        .break_, .continue_, .discard_ => false,
        .block => |range| blk: {
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                if (stmtMutatesOrEscapesGlobal(
                    module,
                    function,
                    function.stmt_children.items[range.start + i],
                    global_index,
                )) break :blk true;
            }
            break :blk false;
        },
        .local_decl => |decl| if (decl.initializer) |expr_id|
            exprStoresOrPassesGlobalRef(module, function, expr_id, global_index)
        else
            false,
        .expr => |expr_id| exprStoresOrPassesGlobalRef(module, function, expr_id, global_index),
        .assign => |assign| refRootGlobal(function, assign.lhs) == global_index or
            exprStoresOrPassesGlobalRef(module, function, assign.rhs, global_index),
        .return_ => |expr_id| if (expr_id) |value|
            exprStoresOrPassesGlobalRef(module, function, value, global_index)
        else
            false,
        .if_ => |if_stmt| exprStoresOrPassesGlobalRef(module, function, if_stmt.cond, global_index) or
            stmtMutatesOrEscapesGlobal(module, function, if_stmt.then_block, global_index) or
            (if (if_stmt.else_block) |else_block|
                stmtMutatesOrEscapesGlobal(module, function, else_block, global_index)
            else
                false),
        .loop_ => |loop_stmt| (if (loop_stmt.init) |stmt|
            stmtMutatesOrEscapesGlobal(module, function, stmt, global_index)
        else
            false) or
            (if (loop_stmt.cond) |expr_id|
                exprStoresOrPassesGlobalRef(module, function, expr_id, global_index)
            else
                false) or
            (if (loop_stmt.continuing) |stmt|
                stmtMutatesOrEscapesGlobal(module, function, stmt, global_index)
            else
                false) or
            stmtMutatesOrEscapesGlobal(module, function, loop_stmt.body, global_index),
        .switch_ => |switch_stmt| blk: {
            if (exprStoresOrPassesGlobalRef(module, function, switch_stmt.expr, global_index)) break :blk true;
            var case_index: u32 = 0;
            while (case_index < switch_stmt.cases.len) : (case_index += 1) {
                const case_node = function.switch_cases.items[switch_stmt.cases.start + case_index];
                for (case_node.selectors.items) |selector| {
                    if (exprStoresOrPassesGlobalRef(module, function, selector, global_index)) break :blk true;
                }
                if (stmtMutatesOrEscapesGlobal(module, function, case_node.body, global_index)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn exprStoresOrPassesGlobalRef(
    module: *const ir.Module,
    function: ir.Function,
    expr_id: ir.ExprId,
    global_index: u32,
) bool {
    const expr_node = function.exprs.items[expr_id];
    if (expr_node.category == .ref and refRootGlobal(function, expr_id) == global_index) {
        return true;
    }
    return switch (expr_node.data) {
        .bool_lit, .int_lit, .float_lit, .param_ref, .local_ref, .global_ref => false,
        .load => |inner| exprContainsEscapingGlobalRef(module, function, inner, global_index),
        .unary => |unary| exprContainsEscapingGlobalRef(module, function, unary.operand, global_index),
        .binary => |binary| exprContainsEscapingGlobalRef(module, function, binary.lhs, global_index) or
            exprContainsEscapingGlobalRef(module, function, binary.rhs, global_index),
        .call => |call| blk: {
            var i: u32 = 0;
            while (i < call.args.len) : (i += 1) {
                const arg = function.expr_args.items[call.args.start + i];
                const arg_node = function.exprs.items[arg];
                if (arg_node.category == .ref and refRootGlobal(function, arg) == global_index) break :blk true;
                if (exprContainsEscapingGlobalRef(module, function, arg, global_index)) break :blk true;
            }
            break :blk false;
        },
        .construct => |construct| blk: {
            var i: u32 = 0;
            while (i < construct.args.len) : (i += 1) {
                if (exprContainsEscapingGlobalRef(
                    module,
                    function,
                    function.expr_args.items[construct.args.start + i],
                    global_index,
                )) break :blk true;
            }
            break :blk false;
        },
        .member => |member| exprContainsEscapingGlobalRef(module, function, member.base, global_index),
        .index => |index| exprContainsEscapingGlobalRef(module, function, index.base, global_index) or
            exprContainsEscapingGlobalRef(module, function, index.index, global_index),
    };
}

fn exprContainsEscapingGlobalRef(
    module: *const ir.Module,
    function: ir.Function,
    expr_id: ir.ExprId,
    global_index: u32,
) bool {
    const expr_node = function.exprs.items[expr_id];
    return switch (expr_node.data) {
        .bool_lit, .int_lit, .float_lit, .param_ref, .local_ref, .global_ref => false,
        .load => |inner| exprContainsEscapingGlobalRef(module, function, inner, global_index),
        .unary => |unary| exprContainsEscapingGlobalRef(module, function, unary.operand, global_index),
        .binary => |binary| exprContainsEscapingGlobalRef(module, function, binary.lhs, global_index) or
            exprContainsEscapingGlobalRef(module, function, binary.rhs, global_index),
        .call => |call| blk: {
            var i: u32 = 0;
            while (i < call.args.len) : (i += 1) {
                const arg = function.expr_args.items[call.args.start + i];
                if (function.exprs.items[arg].category == .ref and refRootGlobal(function, arg) == global_index) {
                    break :blk true;
                }
                if (exprContainsEscapingGlobalRef(module, function, arg, global_index)) break :blk true;
            }
            break :blk false;
        },
        .construct => |construct| blk: {
            var i: u32 = 0;
            while (i < construct.args.len) : (i += 1) {
                if (exprContainsEscapingGlobalRef(
                    module,
                    function,
                    function.expr_args.items[construct.args.start + i],
                    global_index,
                )) break :blk true;
            }
            break :blk false;
        },
        .member => |member| exprContainsEscapingGlobalRef(module, function, member.base, global_index),
        .index => |index| exprContainsEscapingGlobalRef(module, function, index.base, global_index) or
            exprContainsEscapingGlobalRef(module, function, index.index, global_index),
    };
}
