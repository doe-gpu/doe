const ir = @import("ir.zig");

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
