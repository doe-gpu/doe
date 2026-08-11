const std = @import("std");
const token_mod = @import("token.zig");
const ir = @import("../ir/ir.zig");
const sema_type_syntax = @import("sema_type_syntax.zig");
const sema_helpers = @import("sema_helpers.zig");
const sema_typeutils = @import("sema_typeutils.zig");

const Tag = token_mod.Tag;
const concrete_numeric_type = sema_helpers.concrete_numeric_type;
const materialize_inferred_local_type = sema_typeutils.materialize_inferred_local_type;
const parse_matrix_shape = sema_type_syntax.parseMatrixShape;

pub fn analyze_binary_type(self: anytype, lhs_ty: ir.TypeId, rhs_ty: ir.TypeId, op: Tag) !ir.TypeId {
    return switch (op) {
        .eq_eq, .not_eq, .@"<", .lte, .@">", .gte => try comparison_result_type(self, lhs_ty, rhs_ty),
        .and_and, .or_or => logical_result_type(self, lhs_ty, rhs_ty),
        .shift_left, .shift_right => shift_result_type(self, lhs_ty, rhs_ty),
        .@"&", .@"|", .@"^" => try bitwise_result_type(self, lhs_ty, rhs_ty),
        else => try arithmetic_result_type(self, lhs_ty, rhs_ty, op),
    };
}

pub fn analyze_assignment_value_type(
    self: anytype,
    lhs_ty: ir.TypeId,
    rhs_ty: ir.TypeId,
    assignment_op: Tag,
) !ir.TypeId {
    const binary_op: Tag = switch (assignment_op) {
        .@"=" => return rhs_ty,
        .plus_eq => .@"+",
        .minus_eq => .@"-",
        .star_eq => .@"*",
        .slash_eq => .@"/",
        .percent_eq => .@"%",
        .amp_eq => .@"&",
        .pipe_eq => .@"|",
        .caret_eq => .@"^",
        else => return error.InvalidWgsl,
    };
    return analyze_binary_type(self, lhs_ty, rhs_ty, binary_op);
}

pub fn logical_not_result_type(self: anytype, operand_ty: ir.TypeId) !ir.TypeId {
    return switch (self.module.types.get(operand_ty)) {
        .scalar => if (operand_ty == self.module.bool_type) operand_ty else error.TypeMismatch,
        .vector => |vec| if (vec.elem == self.module.bool_type) operand_ty else error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

pub fn analyze_unary_type(self: anytype, node: anytype, body: anytype, operand_ty: ir.TypeId) !ir.TypeId {
    return switch (self.module.tree.tokens.items[node.main_token].tag) {
        .@"-", .@"~" => operand_ty,
        .@"!" => try logical_not_result_type(self, operand_ty),
        .@"&" => try address_of_type(self, node.data.lhs, body, operand_ty),
        .@"*" => switch (self.module.types.get(operand_ty)) {
            .ref => |ref_ty| ref_ty.elem,
            else => error.TypeMismatch,
        },
        else => error.InvalidWgsl,
    };
}

pub fn infer_constructor_call(self: anytype, name: []const u8, arg_types: []const ir.TypeId) !?ir.TypeId {
    if (parse_vector_len(name)) |len| {
        const elem_ty = try infer_constructor_elem_type(self, arg_types);
        const target_ty = try self.module.types.intern(.{ .vector = .{ .elem = elem_ty, .len = len } });
        try validate_construct(self, target_ty, arg_types);
        return target_ty;
    }
    if (parse_matrix_shape(name)) |shape| {
        const elem_ty = try infer_matrix_elem_type(self, arg_types, shape.columns, shape.rows);
        const target_ty = try self.module.types.intern(.{ .matrix = .{ .elem = elem_ty, .columns = shape.columns, .rows = shape.rows } });
        try validate_construct(self, target_ty, arg_types);
        return target_ty;
    }
    return null;
}

pub fn validate_construct(self: anytype, target_ty: ir.TypeId, arg_types: []const ir.TypeId) !void {
    switch (self.module.types.get(target_ty)) {
        .scalar => {
            if (arg_types.len == 0) return;
            if (arg_types.len != 1 or !construct_scalar_compatible(self, target_ty, arg_types[0])) return error.TypeMismatch;
        },
        .vector => |vec| try validate_vector_construct(self, vec, arg_types),
        .matrix => |mat| try validate_matrix_construct(self, mat, arg_types),
        .struct_ => |struct_id| {
            const fields = self.module.structs.items[struct_id].fields.items;
            if (fields.len != arg_types.len) return error.TypeMismatch;
            for (fields, arg_types) |field, arg_ty| {
                if (!self.type_compatible(field.ty, arg_ty)) return error.TypeMismatch;
            }
        },
        else => {},
    }
}

fn logical_result_type(self: anytype, lhs_ty: ir.TypeId, rhs_ty: ir.TypeId) !ir.TypeId {
    if (lhs_ty == self.module.bool_type and rhs_ty == self.module.bool_type) return self.module.bool_type;
    return error.TypeMismatch;
}

fn comparison_result_type(self: anytype, lhs_ty: ir.TypeId, rhs_ty: ir.TypeId) !ir.TypeId {
    if (lhs_ty == rhs_ty) {
        return switch (self.module.types.get(lhs_ty)) {
            .scalar => self.module.bool_type,
            .vector => |vec| try self.module.types.intern(.{ .vector = .{ .elem = self.module.bool_type, .len = vec.len } }),
            else => error.TypeMismatch,
        };
    }

    switch (self.module.types.get(lhs_ty)) {
        .vector => |lhs_vec| switch (self.module.types.get(rhs_ty)) {
            .vector => |rhs_vec| {
                if (lhs_vec.len != rhs_vec.len or !self.type_compatible(lhs_vec.elem, rhs_vec.elem)) return error.TypeMismatch;
                return try self.module.types.intern(.{ .vector = .{ .elem = self.module.bool_type, .len = lhs_vec.len } });
            },
            .scalar => {
                if (!self.type_compatible(lhs_vec.elem, rhs_ty)) return error.TypeMismatch;
                return try self.module.types.intern(.{ .vector = .{ .elem = self.module.bool_type, .len = lhs_vec.len } });
            },
            else => return error.TypeMismatch,
        },
        .scalar => switch (self.module.types.get(rhs_ty)) {
            .vector => |rhs_vec| {
                if (!self.type_compatible(rhs_vec.elem, lhs_ty)) return error.TypeMismatch;
                return try self.module.types.intern(.{ .vector = .{ .elem = self.module.bool_type, .len = rhs_vec.len } });
            },
            .scalar => return if (self.type_compatible(lhs_ty, rhs_ty) or self.type_compatible(rhs_ty, lhs_ty)) self.module.bool_type else error.TypeMismatch,
            else => return error.TypeMismatch,
        },
        else => return error.TypeMismatch,
    }
}

fn arithmetic_result_type(self: anytype, lhs_ty: ir.TypeId, rhs_ty: ir.TypeId, op: Tag) !ir.TypeId {
    if (lhs_ty == rhs_ty) {
        return switch (self.module.types.get(lhs_ty)) {
            .scalar, .vector, .matrix => lhs_ty,
            else => error.TypeMismatch,
        };
    }

    switch (self.module.types.get(lhs_ty)) {
        .scalar => switch (self.module.types.get(rhs_ty)) {
            .scalar => return if (self.type_compatible(lhs_ty, rhs_ty) or self.type_compatible(rhs_ty, lhs_ty)) concrete_numeric_type(self.module, lhs_ty, rhs_ty) else error.TypeMismatch,
            .vector => |rhs_vec| {
                if (!self.type_compatible(rhs_vec.elem, lhs_ty)) return error.TypeMismatch;
                const elem_ty = concrete_numeric_type(self.module, rhs_vec.elem, lhs_ty);
                return try self.module.types.intern(.{ .vector = .{ .elem = elem_ty, .len = rhs_vec.len } });
            },
            .matrix => |rhs_mat| {
                if (!self.type_compatible(rhs_mat.elem, lhs_ty)) return error.TypeMismatch;
                const elem_ty = concrete_numeric_type(self.module, rhs_mat.elem, lhs_ty);
                return try self.module.types.intern(.{ .matrix = .{ .elem = elem_ty, .columns = rhs_mat.columns, .rows = rhs_mat.rows } });
            },
            else => return error.TypeMismatch,
        },
        .vector => |lhs_vec| switch (self.module.types.get(rhs_ty)) {
            .scalar => {
                if (!self.type_compatible(lhs_vec.elem, rhs_ty)) return error.TypeMismatch;
                const elem_ty = concrete_numeric_type(self.module, lhs_vec.elem, rhs_ty);
                return try self.module.types.intern(.{ .vector = .{ .elem = elem_ty, .len = lhs_vec.len } });
            },
            .vector => |rhs_vec| {
                if (lhs_vec.len != rhs_vec.len or !self.type_compatible(lhs_vec.elem, rhs_vec.elem)) return error.TypeMismatch;
                const elem_ty = concrete_numeric_type(self.module, lhs_vec.elem, rhs_vec.elem);
                return try self.module.types.intern(.{ .vector = .{ .elem = elem_ty, .len = lhs_vec.len } });
            },
            .matrix => |rhs_mat| {
                if (op != .@"*" or lhs_vec.len != rhs_mat.rows or !self.type_compatible(lhs_vec.elem, rhs_mat.elem)) return error.TypeMismatch;
                const elem_ty = concrete_numeric_type(self.module, lhs_vec.elem, rhs_mat.elem);
                return try self.module.types.intern(.{ .vector = .{ .elem = elem_ty, .len = rhs_mat.columns } });
            },
            else => return error.TypeMismatch,
        },
        .matrix => |lhs_mat| switch (self.module.types.get(rhs_ty)) {
            .scalar => {
                if (!self.type_compatible(lhs_mat.elem, rhs_ty)) return error.TypeMismatch;
                const elem_ty = concrete_numeric_type(self.module, lhs_mat.elem, rhs_ty);
                return try self.module.types.intern(.{ .matrix = .{ .elem = elem_ty, .columns = lhs_mat.columns, .rows = lhs_mat.rows } });
            },
            .vector => |rhs_vec| {
                if (op != .@"*" or lhs_mat.columns != rhs_vec.len or !self.type_compatible(lhs_mat.elem, rhs_vec.elem)) return error.TypeMismatch;
                const elem_ty = concrete_numeric_type(self.module, lhs_mat.elem, rhs_vec.elem);
                return try self.module.types.intern(.{ .vector = .{ .elem = elem_ty, .len = lhs_mat.rows } });
            },
            .matrix => |rhs_mat| {
                if (lhs_mat.columns != rhs_mat.columns or lhs_mat.rows != rhs_mat.rows or !self.type_compatible(lhs_mat.elem, rhs_mat.elem)) return error.TypeMismatch;
                const elem_ty = concrete_numeric_type(self.module, lhs_mat.elem, rhs_mat.elem);
                return try self.module.types.intern(.{ .matrix = .{ .elem = elem_ty, .columns = lhs_mat.columns, .rows = lhs_mat.rows } });
            },
            else => return error.TypeMismatch,
        },
        else => return error.TypeMismatch,
    }
}

fn bitwise_result_type(self: anytype, lhs_ty: ir.TypeId, rhs_ty: ir.TypeId) !ir.TypeId {
    if (lhs_ty == rhs_ty) {
        return switch (self.module.types.get(lhs_ty)) {
            .scalar => lhs_ty,
            .vector => lhs_ty,
            else => error.TypeMismatch,
        };
    }
    return try arithmetic_result_type(self, lhs_ty, rhs_ty, .@"&");
}

fn shift_result_type(self: anytype, lhs_ty: ir.TypeId, rhs_ty: ir.TypeId) !ir.TypeId {
    return switch (self.module.types.get(lhs_ty)) {
        .scalar => if (is_shift_scalar(self.module, lhs_ty) and is_shift_scalar(self.module, rhs_ty)) lhs_ty else error.TypeMismatch,
        .vector => |lhs_vec| switch (self.module.types.get(rhs_ty)) {
            .scalar => if (is_shift_scalar(self.module, lhs_vec.elem) and is_shift_scalar(self.module, rhs_ty)) lhs_ty else error.TypeMismatch,
            .vector => |rhs_vec| if (lhs_vec.len == rhs_vec.len and is_shift_scalar(self.module, lhs_vec.elem) and is_shift_scalar(self.module, rhs_vec.elem)) lhs_ty else error.TypeMismatch,
            else => error.TypeMismatch,
        },
        else => error.TypeMismatch,
    };
}

fn validate_vector_construct(self: anytype, vec: @FieldType(ir.Type, "vector"), arg_types: []const ir.TypeId) !void {
    if (arg_types.len == 0) return;
    if (arg_types.len == 1) {
        switch (self.module.types.get(arg_types[0])) {
            .scalar => {
                if (!construct_scalar_compatible(self, vec.elem, arg_types[0])) return error.TypeMismatch;
                return;
            },
            .vector => |arg_vec| {
                if (arg_vec.len != vec.len or !construct_scalar_compatible(self, vec.elem, arg_vec.elem)) return error.TypeMismatch;
                return;
            },
            else => return error.TypeMismatch,
        }
    }
    var components: u32 = 0;
    for (arg_types) |arg_ty| {
        switch (self.module.types.get(arg_ty)) {
            .scalar => {
                if (!construct_scalar_compatible(self, vec.elem, arg_ty)) return error.TypeMismatch;
                components += 1;
            },
            .vector => |arg_vec| {
                if (!construct_scalar_compatible(self, vec.elem, arg_vec.elem)) return error.TypeMismatch;
                components += arg_vec.len;
            },
            else => return error.TypeMismatch,
        }
    }
    if (components != vec.len) return error.TypeMismatch;
}

fn validate_matrix_construct(self: anytype, mat: @FieldType(ir.Type, "matrix"), arg_types: []const ir.TypeId) !void {
    if (arg_types.len == 0) return;
    if (arg_types.len == 1) {
        switch (self.module.types.get(arg_types[0])) {
            .matrix => |arg_mat| {
                if (arg_mat.columns != mat.columns or arg_mat.rows != mat.rows or !construct_scalar_compatible(self, mat.elem, arg_mat.elem)) return error.TypeMismatch;
                return;
            },
            else => {},
        }
    }
    if (arg_types.len == mat.columns) {
        for (arg_types) |arg_ty| {
            switch (self.module.types.get(arg_ty)) {
                .vector => |arg_vec| if (arg_vec.len != mat.rows or !construct_scalar_compatible(self, mat.elem, arg_vec.elem)) return error.TypeMismatch,
                else => return error.TypeMismatch,
            }
        }
        return;
    }
    var components: u32 = 0;
    for (arg_types) |arg_ty| {
        switch (self.module.types.get(arg_ty)) {
            .scalar => {
                if (!construct_scalar_compatible(self, mat.elem, arg_ty)) return error.TypeMismatch;
                components += 1;
            },
            .vector => |arg_vec| {
                if (!construct_scalar_compatible(self, mat.elem, arg_vec.elem)) return error.TypeMismatch;
                components += arg_vec.len;
            },
            else => return error.TypeMismatch,
        }
    }
    if (components != mat.columns * mat.rows) return error.TypeMismatch;
}

fn infer_constructor_elem_type(self: anytype, arg_types: []const ir.TypeId) !ir.TypeId {
    var elem_ty = ir.INVALID_TYPE;
    for (arg_types) |arg_ty| {
        const current_elem_ty = switch (self.module.types.get(arg_ty)) {
            .scalar => arg_ty,
            .vector => |vec| vec.elem,
            else => return error.TypeMismatch,
        };
        if (elem_ty == ir.INVALID_TYPE) {
            elem_ty = current_elem_ty;
        } else if (self.type_compatible(elem_ty, current_elem_ty) or self.type_compatible(current_elem_ty, elem_ty)) {
            elem_ty = concrete_numeric_type(self.module, elem_ty, current_elem_ty);
        } else {
            return error.TypeMismatch;
        }
    }
    if (elem_ty == ir.INVALID_TYPE) return error.TypeMismatch;
    return materialize_inferred_local_type(self.module, elem_ty);
}

fn infer_matrix_elem_type(self: anytype, arg_types: []const ir.TypeId, columns: u8, rows: u8) !ir.TypeId {
    if (arg_types.len == columns) {
        var elem_ty = ir.INVALID_TYPE;
        for (arg_types) |arg_ty| {
            const arg_vec = switch (self.module.types.get(arg_ty)) {
                .vector => |vec| vec,
                else => return error.TypeMismatch,
            };
            if (arg_vec.len != rows) return error.TypeMismatch;
            if (elem_ty == ir.INVALID_TYPE) {
                elem_ty = arg_vec.elem;
            } else if (self.type_compatible(elem_ty, arg_vec.elem) or self.type_compatible(arg_vec.elem, elem_ty)) {
                elem_ty = concrete_numeric_type(self.module, elem_ty, arg_vec.elem);
            } else {
                return error.TypeMismatch;
            }
        }
        if (elem_ty == ir.INVALID_TYPE) return error.TypeMismatch;
        return materialize_inferred_local_type(self.module, elem_ty);
    }
    return try infer_constructor_elem_type(self, arg_types);
}

const RefBindingInfo = struct {
    addr_space: ir.AddressSpace,
    access: ir.AccessMode,
};

fn address_of_type(self: anytype, operand_node_idx: u32, body: anytype, operand_ty: ir.TypeId) !ir.TypeId {
    const binding = try resolve_reference_binding(self, operand_node_idx, body);
    return try self.module.types.intern(.{ .ref = .{
        .elem = operand_ty,
        .addr_space = binding.addr_space,
        .access = binding.access,
    } });
}

fn resolve_reference_binding(self: anytype, node_idx: u32, body: anytype) !RefBindingInfo {
    const info = self.module.node_info.items[node_idx];
    if (info.category != .ref) return error.TypeMismatch;

    const node = self.module.tree.nodes.items[node_idx];
    return switch (node.tag) {
        .ident_expr => switch (info.symbol) {
            .local => |index| local_binding_info(self, index, body),
            .param => |index| param_binding_info(self, index, body),
            .global => |index| global_binding_info(self, index),
            else => error.TypeMismatch,
        },
        .member_expr, .index_expr => try resolve_reference_binding(self, node.data.lhs, body),
        .unary_expr => switch (self.module.tree.tokens.items[node.main_token].tag) {
            .@"*" => try resolve_reference_binding(self, node.data.lhs, body),
            else => error.TypeMismatch,
        },
        else => error.TypeMismatch,
    };
}

fn local_binding_info(self: anytype, index: u32, body: anytype) !RefBindingInfo {
    const function = if (body) |ctx|
        &ctx.parent.module.functions.items[ctx.function_index]
    else
        return error.InvalidWgsl;
    const local = function.locals.items[index];
    return switch (self.module.types.get(local.ty)) {
        .ref => |ref_ty| .{ .addr_space = ref_ty.addr_space, .access = ref_ty.access },
        else => .{
            .addr_space = .function,
            .access = if (local.mutable) .read_write else .read,
        },
    };
}

fn param_binding_info(self: anytype, index: u32, body: anytype) !RefBindingInfo {
    const function = if (body) |ctx|
        &ctx.parent.module.functions.items[ctx.function_index]
    else
        return error.InvalidWgsl;
    const param_ty = function.params.items[index].ty;
    return switch (self.module.types.get(param_ty)) {
        .ref => |ref_ty| .{ .addr_space = ref_ty.addr_space, .access = ref_ty.access },
        else => .{ .addr_space = .function, .access = .read_write },
    };
}

fn global_binding_info(self: anytype, index: u32) !RefBindingInfo {
    const global = self.module.globals.items[index];
    return switch (self.module.types.get(global.ty)) {
        .ref => |ref_ty| .{ .addr_space = ref_ty.addr_space, .access = ref_ty.access },
        else => switch (global.class) {
            .var_ => .{
                .addr_space = global.addr_space orelse .private,
                .access = global.access orelse .read_write,
            },
            .const_, .override_ => .{
                .addr_space = global.addr_space orelse .private,
                .access = .read,
            },
            .input, .output => error.TypeMismatch,
        },
    };
}

fn parse_vector_len(name: []const u8) ?u8 {
    if (!std.mem.startsWith(u8, name, "vec") or name.len != 4) return null;
    return switch (name[3]) {
        '2' => 2,
        '3' => 3,
        '4' => 4,
        else => null,
    };
}

fn construct_scalar_compatible(self: anytype, target_ty: ir.TypeId, actual_ty: ir.TypeId) bool {
    const target_scalar = switch (self.module.types.get(target_ty)) {
        .scalar => |scalar| scalar,
        else => return false,
    };
    const actual_scalar = switch (self.module.types.get(actual_ty)) {
        .scalar => |scalar| scalar,
        else => return false,
    };
    if (target_scalar == .void or actual_scalar == .void) return false;
    return true;
}

fn is_shift_scalar(module: anytype, ty: ir.TypeId) bool {
    return switch (module.types.get(ty)) {
        .scalar => |scalar| switch (scalar) {
            .abstract_int, .i32, .u32 => true,
            else => false,
        },
        else => false,
    };
}
