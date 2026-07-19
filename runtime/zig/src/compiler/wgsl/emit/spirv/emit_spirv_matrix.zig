const std = @import("std");
const ir = @import("../../ir/ir.zig");
const spirv = @import("spirv_builder.zig");

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
