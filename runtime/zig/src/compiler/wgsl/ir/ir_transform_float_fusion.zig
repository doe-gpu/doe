const std = @import("std");
const ir = @import("ir.zig");

// WGSL permits reassociation, then fusion at least as accurate as that
// formulation. Keep operand evaluation in a,b,c,d order while expressing
// (a + b*c) + d as a + fma(b,c,d); no source values or names select this rule.
pub fn apply(module: *ir.Module) error{OutOfMemory}!usize {
    var changed: usize = 0;
    for (module.functions.items) |*function| {
        const original_count = function.exprs.items.len;
        for (0..original_count) |index| {
            const outer = function.exprs.items[index];
            if (outer.category != .value or outer.data != .binary or outer.data.binary.op != .add) continue;
            const ty = module.types.get(outer.ty);
            if (ty != .scalar or ty.scalar != .f32) continue;
            const sum = function.exprs.items[outer.data.binary.lhs];
            if (sum.data != .binary or sum.data.binary.op != .add) continue;
            const product = function.exprs.items[sum.data.binary.rhs];
            if (product.data != .binary or product.data.binary.op != .mul) continue;
            const operands = [_]ir.ExprId{
                sum.data.binary.lhs,
                product.data.binary.lhs,
                product.data.binary.rhs,
                outer.data.binary.rhs,
            };
            var compatible = sum.ty == outer.ty and product.ty == outer.ty;
            for (operands) |operand| {
                const value = function.exprs.items[operand];
                compatible = compatible and value.ty == outer.ty and value.category == .value;
            }
            if (!compatible) continue;

            // Reserve before transferring the owned builtin name or changing
            // expression edges, so allocation failure leaves valid owned IR.
            try function.exprs.ensureUnusedCapacity(module.allocator, 1);
            try function.expr_args.ensureUnusedCapacity(module.allocator, 3);
            const name = try module.allocator.dupe(u8, "fma");
            const args = ir.Range{ .start = @intCast(function.expr_args.items.len), .len = 3 };
            function.expr_args.appendSliceAssumeCapacity(operands[1..]);
            const fused: ir.ExprId = @intCast(function.exprs.items.len);
            function.exprs.appendAssumeCapacity(.{
                .ty = outer.ty,
                .category = .value,
                .data = .{ .call = .{ .name = name, .kind = .builtin, .args = args } },
            });
            function.exprs.items[index].data = .{ .binary = .{ .op = .add, .lhs = operands[0], .rhs = fused } };
            changed += 1;
        }
    }
    return changed;
}
