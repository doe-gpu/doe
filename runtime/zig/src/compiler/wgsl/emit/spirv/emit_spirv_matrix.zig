const std = @import("std");
const ir = @import("../../ir/ir.zig");
const spirv = @import("spirv_builder.zig");

pub fn emit_matrix_construct(self: anytype, target_ty: ir.TypeId, range: ir.Range) !u32 {
    const target = switch (self.emitter.module.types.get(target_ty)) {
        .matrix => |matrix| matrix,
        else => return error.UnsupportedConstruct,
    };
    if (range.len == 1) {
        const only_expr = self.function.expr_args.items[range.start];
        if (self.function.exprs.items[only_expr].ty == target_ty) {
            return try self.emit_value_expr(only_expr);
        }
    }

    var components = std.ArrayListUnmanaged(u32){};
    defer components.deinit(self.emitter.alloc);
    var arg_index: u32 = 0;
    while (arg_index < range.len) : (arg_index += 1) {
        const expr_id = self.function.expr_args.items[range.start + arg_index];
        const expr_ty = self.function.exprs.items[expr_id].ty;
        switch (self.emitter.module.types.get(expr_ty)) {
            .scalar => try components.append(
                self.emitter.alloc,
                try self.emit_scalar_construct_from_type(
                    target.elem,
                    expr_ty,
                    try self.emit_value_expr(expr_id),
                ),
            ),
            .vector => |source| {
                const vector_id = try self.emit_value_expr(expr_id);
                var component_index: u32 = 0;
                while (component_index < source.len) : (component_index += 1) {
                    const component_id = try self.emit_composite_extract(vector_id, source.elem, component_index);
                    try components.append(
                        self.emitter.alloc,
                        try self.emit_scalar_construct_from_type(target.elem, source.elem, component_id),
                    );
                }
            },
            else => return error.UnsupportedConstruct,
        }
    }

    const component_count: usize = @as(usize, target.columns) * @as(usize, target.rows);
    if (components.items.len != component_count) return error.UnsupportedConstruct;
    const column_type = try self.emitter.builder.type_vector(
        try self.emitter.lower_type(target.elem),
        target.rows,
    );
    var columns = std.ArrayListUnmanaged(u32){};
    defer columns.deinit(self.emitter.alloc);
    var column_index: usize = 0;
    while (column_index < target.columns) : (column_index += 1) {
        const start = column_index * target.rows;
        try columns.append(
            self.emitter.alloc,
            try self.emit_result_inst(
                spirv.Opcode.CompositeConstruct,
                column_type,
                components.items[start .. start + target.rows],
            ),
        );
    }
    return try self.emit_construct_from_operands(target_ty, columns.items);
}

pub fn emit_matrix_elementwise(
    self: anytype,
    op: ir.BinaryOp,
    lhs_id: u32,
    rhs_id: u32,
    lhs_ty: ir.TypeId,
    rhs_ty: ir.TypeId,
    result_ty: ir.TypeId,
) !?u32 {
    const lhs_mat = switch (self.emitter.module.types.get(lhs_ty)) {
        .matrix => |mat| mat,
        else => return null,
    };
    const rhs_mat = switch (self.emitter.module.types.get(rhs_ty)) {
        .matrix => |mat| mat,
        else => return null,
    };
    if (lhs_mat.elem != rhs_mat.elem or
        lhs_mat.columns != rhs_mat.columns or
        lhs_mat.rows != rhs_mat.rows)
    {
        return error.UnsupportedConstruct;
    }

    const opcode: u16 = switch (op) {
        .add => spirv.Opcode.FAdd,
        .sub => spirv.Opcode.FSub,
        else => return null,
    };
    if (self.scalar_kind(lhs_mat.elem) != .float) return error.UnsupportedConstruct;

    const column_type = try self.emitter.builder.type_vector(try self.emitter.lower_type(lhs_mat.elem), lhs_mat.rows);
    var columns = std.ArrayListUnmanaged(u32){};
    defer columns.deinit(self.emitter.alloc);

    var column_index: u32 = 0;
    while (column_index < lhs_mat.columns) : (column_index += 1) {
        const lhs_column = try self.emit_result_inst(spirv.Opcode.CompositeExtract, column_type, &.{ lhs_id, column_index });
        const rhs_column = try self.emit_result_inst(spirv.Opcode.CompositeExtract, column_type, &.{ rhs_id, column_index });
        try columns.append(
            self.emitter.alloc,
            try self.emit_result_inst(opcode, column_type, &.{ lhs_column, rhs_column }),
        );
    }
    return try self.emit_construct_from_operands(result_ty, columns.items);
}
