// Shared IR-level compile-time constant evaluation helpers.
//
// Complements `ir_builder.scalar_constant_from_node`, which folds WGSL's
// module-scope `const` initializers against the AST before IR building.
// These helpers operate on the finished IR, so they work for expressions
// inside function bodies where the AST-level pass does not reach. Returning
// an `ir.ConstantValue` keeps the API emitter-agnostic: SPIR-V, DXIL native,
// CSL, and source-text emitters can all consume the evaluated value without
// each rebuilding the walk logic.

const std = @import("std");
const ir = @import("ir.zig");

const MAX_CONST_ALIAS_DEPTH: u32 = 64;

pub const FoldError = error{
    DivideByZero,
    ShiftOverflow,
    UnsupportedOperation,
    TypeMismatch,
};

/// Resolve `expr_id` to a concrete `u64` if it is (transitively) a WGSL
/// integer constant. Returns null for expressions whose value depends on
/// dynamic inputs (function params, locals that get reassigned, loaded
/// uniforms, etc.). Peeks through `.load` wrappers, immutable local aliases,
/// and `.global_ref` onto `const` globals with an `int` initializer. Does not
/// traverse into non-trivial binary/unary chains -- that responsibility sits
/// with the IR-level constant-folding pass.
pub fn resolve_constant_int(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?u64 {
    return resolve_constant_int_depth(module, function, expr_id, MAX_CONST_ALIAS_DEPTH);
}

fn resolve_constant_int_depth(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    depth: u32,
) ?u64 {
    if (depth == 0) return null;
    const expr = function.exprs.items[expr_id];
    return switch (expr.data) {
        .int_lit => |value| value,
        .load => |inner| resolve_constant_int_depth(module, function, inner, depth - 1),
        .construct => |construct| blk: {
            if (construct.args.len != 1) break :blk null;
            break :blk resolve_constant_int_depth(module, function, function.expr_args.items[construct.args.start], depth - 1);
        },
        .local_ref => |index| blk: {
            const initializer = resolve_const_local_initializer(function, index) orelse break :blk null;
            break :blk resolve_constant_int_depth(module, function, initializer, depth - 1);
        },
        .global_ref => |index| blk: {
            const global = module.globals.items[index];
            if (global.class != .const_) break :blk null;
            const init_value = global.initializer orelse break :blk null;
            break :blk switch (init_value) {
                .int => |v| v,
                else => null,
            };
        },
        else => null,
    };
}

/// Fold a binary operation over two `ir.ConstantValue` operands into a
/// single `ir.ConstantValue` result. Uses wrapping integer arithmetic
/// (`+%`, `-%`, `*%`) to match WGSL runtime semantics, and `@divTrunc` /
/// `@mod` for signed int division/remainder. Shifts that would exceed the
/// bit-width error out rather than silently producing zero, mirroring the
/// existing `ir_builder.fold_scalar_binary` behavior. Returns `FoldError`
/// on unsupported (type, op) combinations so callers can distinguish a
/// policy failure from a successful non-zero fold.
pub fn fold_scalar_binary(op: ir.BinaryOp, lhs: ir.ConstantValue, rhs: ir.ConstantValue) FoldError!ir.ConstantValue {
    return switch (lhs) {
        .bool => |lhs_bool| switch (rhs) {
            .bool => |rhs_bool| switch (op) {
                .equal => ir.ConstantValue{ .bool = lhs_bool == rhs_bool },
                .not_equal => ir.ConstantValue{ .bool = lhs_bool != rhs_bool },
                .logical_and => ir.ConstantValue{ .bool = lhs_bool and rhs_bool },
                .logical_or => ir.ConstantValue{ .bool = lhs_bool or rhs_bool },
                else => error.UnsupportedOperation,
            },
            else => error.TypeMismatch,
        },
        .int => |lhs_int| switch (rhs) {
            .int => |rhs_int| switch (op) {
                .add => ir.ConstantValue{ .int = lhs_int +% rhs_int },
                .sub => ir.ConstantValue{ .int = lhs_int -% rhs_int },
                .mul => ir.ConstantValue{ .int = lhs_int *% rhs_int },
                .div => if (rhs_int == 0) error.DivideByZero else ir.ConstantValue{ .int = @divTrunc(lhs_int, rhs_int) },
                .rem => if (rhs_int == 0) error.DivideByZero else ir.ConstantValue{ .int = @mod(lhs_int, rhs_int) },
                .bit_and => ir.ConstantValue{ .int = lhs_int & rhs_int },
                .bit_or => ir.ConstantValue{ .int = lhs_int | rhs_int },
                .bit_xor => ir.ConstantValue{ .int = lhs_int ^ rhs_int },
                .shift_left => if (rhs_int >= 64) error.ShiftOverflow else ir.ConstantValue{ .int = lhs_int << @as(std.math.Log2Int(u64), @intCast(rhs_int)) },
                .shift_right => if (rhs_int >= 64) error.ShiftOverflow else ir.ConstantValue{ .int = lhs_int >> @as(std.math.Log2Int(u64), @intCast(rhs_int)) },
                .equal => ir.ConstantValue{ .bool = lhs_int == rhs_int },
                .not_equal => ir.ConstantValue{ .bool = lhs_int != rhs_int },
                .less => ir.ConstantValue{ .bool = lhs_int < rhs_int },
                .less_equal => ir.ConstantValue{ .bool = lhs_int <= rhs_int },
                .greater => ir.ConstantValue{ .bool = lhs_int > rhs_int },
                .greater_equal => ir.ConstantValue{ .bool = lhs_int >= rhs_int },
                else => error.UnsupportedOperation,
            },
            else => error.TypeMismatch,
        },
        .float => |lhs_float| switch (rhs) {
            .float => |rhs_float| switch (op) {
                .add => ir.ConstantValue{ .float = lhs_float + rhs_float },
                .sub => ir.ConstantValue{ .float = lhs_float - rhs_float },
                .mul => ir.ConstantValue{ .float = lhs_float * rhs_float },
                .div => ir.ConstantValue{ .float = lhs_float / rhs_float },
                .rem => ir.ConstantValue{ .float = @mod(lhs_float, rhs_float) },
                .equal => ir.ConstantValue{ .bool = lhs_float == rhs_float },
                .not_equal => ir.ConstantValue{ .bool = lhs_float != rhs_float },
                .less => ir.ConstantValue{ .bool = lhs_float < rhs_float },
                .less_equal => ir.ConstantValue{ .bool = lhs_float <= rhs_float },
                .greater => ir.ConstantValue{ .bool = lhs_float > rhs_float },
                .greater_equal => ir.ConstantValue{ .bool = lhs_float >= rhs_float },
                else => error.UnsupportedOperation,
            },
            else => error.TypeMismatch,
        },
    };
}

/// Resolve `expr_id` to a concrete `bool` if it is (transitively) a WGSL
/// boolean constant. Same peek-through rules as `resolve_constant_int`.
pub fn resolve_constant_bool(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?bool {
    return resolve_constant_bool_depth(module, function, expr_id, MAX_CONST_ALIAS_DEPTH);
}

fn resolve_constant_bool_depth(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    depth: u32,
) ?bool {
    if (depth == 0) return null;
    const expr = function.exprs.items[expr_id];
    return switch (expr.data) {
        .bool_lit => |value| value,
        .load => |inner| resolve_constant_bool_depth(module, function, inner, depth - 1),
        .construct => |construct| blk: {
            if (construct.args.len != 1) break :blk null;
            break :blk resolve_constant_bool_depth(module, function, function.expr_args.items[construct.args.start], depth - 1);
        },
        .local_ref => |index| blk: {
            const initializer = resolve_const_local_initializer(function, index) orelse break :blk null;
            break :blk resolve_constant_bool_depth(module, function, initializer, depth - 1);
        },
        .global_ref => |index| blk: {
            const global = module.globals.items[index];
            if (global.class != .const_) break :blk null;
            const init_value = global.initializer orelse break :blk null;
            break :blk switch (init_value) {
                .bool => |v| v,
                else => null,
            };
        },
        else => null,
    };
}

fn resolve_const_local_initializer(function: *const ir.Function, local_idx: u32) ?ir.ExprId {
    if (local_idx >= function.locals.items.len) return null;
    if (function.locals.items[local_idx].mutable) return null;
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
