const std = @import("std");
const ir = @import("ir.zig");
const workgroup = @import("emit_msl_workgroup_zero.zig");

const VisitState = struct {
    after_barrier: bool = false,
    saw_store: bool = false,
    saw_load: bool = false,
};

pub fn canRelaxWorkgroupAtomicGlobal(module: *const ir.Module, function: ir.Function, global_index: u32) bool {
    const global = module.globals.items[global_index];
    if (global.binding != null or global.class != .var_ or global.addr_space != .workgroup) return false;
    if (!isRelaxableAtomicArray(module, global.ty, function.workgroup_size)) return false;

    var state = VisitState{};
    if (!visitStmt(module, function, function.root_stmt, global_index, &state)) return false;
    return state.saw_store and state.saw_load and state.after_barrier;
}

pub fn callTargetsRelaxedAtomic(
    module: *const ir.Module,
    function: ir.Function,
    call: @FieldType(ir.Expr, "call"),
) bool {
    if (call.kind != .builtin or call.args.len == 0) return false;
    if (!std.mem.eql(u8, call.name, "atomicLoad") and !std.mem.eql(u8, call.name, "atomicStore")) return false;
    const target = function.expr_args.items[call.args.start];
    const global_index = workgroup.refRootGlobal(function, target) orelse return false;
    return canRelaxWorkgroupAtomicGlobal(module, function, global_index);
}

pub fn relaxedArrayElementType(module: *const ir.Module, ty: ir.TypeId) ?ir.TypeId {
    const arr = switch (module.types.get(ty)) {
        .array => |value| value,
        else => return null,
    };
    return switch (module.types.get(arr.elem)) {
        .atomic => |inner| inner,
        else => null,
    };
}

fn isRelaxableAtomicArray(module: *const ir.Module, ty: ir.TypeId, workgroup_size: [3]u32) bool {
    if (workgroup_size[1] != 1 or workgroup_size[2] != 1) return false;
    const arr = switch (module.types.get(ty)) {
        .array => |value| value,
        else => return false,
    };
    if (arr.len == null or arr.len.? != workgroup_size[0]) return false;
    const inner = switch (module.types.get(arr.elem)) {
        .atomic => |value| value,
        else => return false,
    };
    return switch (module.types.get(inner)) {
        .scalar => |scalar| scalar == .u32 or scalar == .i32 or scalar == .abstract_int,
        else => false,
    };
}

fn visitStmt(
    module: *const ir.Module,
    function: ir.Function,
    stmt_id: ir.StmtId,
    global_index: u32,
    state: *VisitState,
) bool {
    return switch (function.stmts.items[stmt_id]) {
        .break_, .continue_, .discard_ => true,
        .block => |range| blk: {
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                if (!visitStmt(module, function, function.stmt_children.items[range.start + i], global_index, state)) break :blk false;
            }
            break :blk true;
        },
        .local_decl => |decl| if (decl.initializer) |expr_id|
            visitExpr(module, function, expr_id, global_index, state)
        else
            true,
        .expr => |expr_id| visitExpr(module, function, expr_id, global_index, state),
        .assign => |assign| visitExpr(module, function, assign.lhs, global_index, state) and
            visitExpr(module, function, assign.rhs, global_index, state),
        .return_ => |expr_id| if (expr_id) |value|
            visitExpr(module, function, value, global_index, state)
        else
            true,
        .loop_ => |loop_stmt| (if (loop_stmt.init) |stmt|
            visitStmt(module, function, stmt, global_index, state)
        else
            true) and
            (if (loop_stmt.cond) |expr_id|
                visitExpr(module, function, expr_id, global_index, state)
            else
                true) and
            visitStmt(module, function, loop_stmt.body, global_index, state) and
            (if (loop_stmt.continuing) |stmt|
                visitStmt(module, function, stmt, global_index, state)
            else
                true),
        .if_, .switch_ => false,
    };
}

fn visitExpr(
    module: *const ir.Module,
    function: ir.Function,
    expr_id: ir.ExprId,
    global_index: u32,
    state: *VisitState,
) bool {
    const expr = function.exprs.items[expr_id];
    return switch (expr.data) {
        .bool_lit, .int_lit, .float_lit, .param_ref, .local_ref, .global_ref => true,
        .load => |inner| visitExpr(module, function, inner, global_index, state),
        .unary => |unary| visitExpr(module, function, unary.operand, global_index, state),
        .binary => |binary| visitExpr(module, function, binary.lhs, global_index, state) and
            visitExpr(module, function, binary.rhs, global_index, state),
        .construct => |construct| visitExprRange(module, function, construct.args, global_index, state),
        .member => |member| visitExpr(module, function, member.base, global_index, state),
        .index => |index| visitExpr(module, function, index.base, global_index, state) and
            visitExpr(module, function, index.index, global_index, state),
        .call => |call| visitCall(module, function, call, global_index, state),
    };
}

fn visitExprRange(
    module: *const ir.Module,
    function: ir.Function,
    range: ir.Range,
    global_index: u32,
    state: *VisitState,
) bool {
    var i: u32 = 0;
    while (i < range.len) : (i += 1) {
        if (!visitExpr(module, function, function.expr_args.items[range.start + i], global_index, state)) return false;
    }
    return true;
}

fn visitCall(
    module: *const ir.Module,
    function: ir.Function,
    call: @FieldType(ir.Expr, "call"),
    global_index: u32,
    state: *VisitState,
) bool {
    if (call.kind == .builtin and std.mem.eql(u8, call.name, "workgroupBarrier")) {
        state.after_barrier = true;
        return true;
    }
    if (call.kind != .builtin or !std.mem.startsWith(u8, call.name, "atomic")) {
        return visitExprRange(module, function, call.args, global_index, state);
    }
    if (call.args.len == 0) return false;
    const target = function.expr_args.items[call.args.start];
    if (workgroup.refRootGlobal(function, target) != global_index) return true;
    if (std.mem.eql(u8, call.name, "atomicStore")) {
        if (state.after_barrier or call.args.len != 2) return false;
        if (!storeIndexIsLocalInvocationX(function, target)) return false;
        state.saw_store = true;
        return visitExpr(module, function, function.expr_args.items[call.args.start + 1], global_index, state);
    }
    if (std.mem.eql(u8, call.name, "atomicLoad")) {
        if (!state.after_barrier or call.args.len != 1) return false;
        state.saw_load = true;
        return true;
    }
    return false;
}

fn storeIndexIsLocalInvocationX(function: ir.Function, target: ir.ExprId) bool {
    var ref_expr = target;
    while (function.exprs.items[ref_expr].data == .load) {
        ref_expr = function.exprs.items[ref_expr].data.load;
    }
    const index = switch (function.exprs.items[ref_expr].data) {
        .index => |value| value,
        else => return false,
    };
    var index_expr = index.index;
    while (function.exprs.items[index_expr].data == .load) {
        index_expr = function.exprs.items[index_expr].data.load;
    }
    const member = switch (function.exprs.items[index_expr].data) {
        .member => |value| value,
        else => return false,
    };
    if (!std.mem.eql(u8, member.field_name, "x")) return false;
    const param_index = switch (function.exprs.items[member.base].data) {
        .param_ref => |value| value,
        else => return false,
    };
    const io = function.params.items[param_index].io orelse return false;
    return io.builtin == .local_invocation_id;
}
