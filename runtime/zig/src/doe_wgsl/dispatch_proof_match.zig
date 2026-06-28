const ir = @import("ir.zig");
const ir_const_eval = @import("ir_const_eval.zig");
const loop_match = @import("dispatch_proof_loop_match.zig");
const layout_utils = @import("layout_utils.zig");
const lean_proof = @import("../lean_proof.zig");

pub fn try_elide_storage_index(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
    index_data: @FieldType(ir.Expr, "index"),
) ?ir.DispatchPrecondition {
    const binding = resolve_storage_binding(module, function, index_data.base) orelse return null;
    const element_stride_bytes = resolve_runtime_array_element_stride(module, function, index_data.base) orelse return null;

    if (lean_proof.boundsProven(.gid_1d_storage_buffer)) {
        if (classify_builtin_component(function, index_data.index, .global_invocation_id)) |gid_axis| {
            return .{
                .kind = .gid_component,
                .gid_axis = gid_axis,
                .storage_binding = binding,
                .element_multiplier = 1,
                .element_stride_bytes = element_stride_bytes,
                .element_offset = 0,
            };
        }
    }
    if (lean_proof.boundsProven(.gid_1d_storage_buffer_offset)) {
        if (match_gid_component_plus_offset(function, index_data.index, .global_invocation_id)) |match| {
            return .{
                .kind = .gid_component,
                .gid_axis = match.axis,
                .storage_binding = binding,
                .element_multiplier = 1,
                .element_stride_bytes = element_stride_bytes,
                .element_offset = match.offset,
            };
        }
    }
    if (lean_proof.boundsProven(.gid_1d_storage_buffer_stride)) {
        if (match_gid_component_times_stride_plus_offset(function, index_data.index, .global_invocation_id)) |match| {
            return .{
                .kind = .gid_component,
                .gid_axis = match.axis,
                .storage_binding = binding,
                .element_multiplier = match.multiplier,
                .element_stride_bytes = element_stride_bytes,
                .element_offset = match.offset,
            };
        }
    }
    if (lean_proof.boundsProven(.gid_1d_storage_buffer_loop_affine)) {
        if (match_gid_component_loop_affine_plus_offset(module, function, index_data.index, .global_invocation_id)) |match| {
            if (loop_match.find_bounded_loop_limit(module, function, expr_id, match.local_idx)) |loop_limit| {
                return .{
                    .kind = .gid_component,
                    .gid_axis = match.axis,
                    .storage_binding = binding,
                    .element_multiplier = match.gid_multiplier,
                    .loop_limit = loop_limit,
                    .loop_limit_multiplier = match.loop_multiplier,
                    .element_stride_bytes = element_stride_bytes,
                    .element_offset = match.offset,
                };
            }
        }
    } else if (lean_proof.boundsProven(.gid_1d_storage_buffer_loop_offset)) {
        if (match_gid_component_loop_affine_plus_offset(module, function, index_data.index, .global_invocation_id)) |match| {
            if (match.gid_multiplier == 1 and match.loop_multiplier == 1) {
                if (loop_match.find_bounded_loop_limit(module, function, expr_id, match.local_idx)) |loop_limit| {
                    return .{
                        .kind = .gid_component,
                        .gid_axis = match.axis,
                        .storage_binding = binding,
                        .element_multiplier = 1,
                        .loop_limit = loop_limit,
                        .loop_limit_multiplier = 1,
                        .element_stride_bytes = element_stride_bytes,
                        .element_offset = match.offset,
                    };
                }
            }
        }
    }
    if (lean_proof.boundsProven(.gid_1d_storage_buffer_tiled)) {
        if (match_gid_component_tiled_plus_offset(function, index_data.index, .global_invocation_id)) |match| {
            return .{
                .kind = .gid_component_tiled,
                .gid_axis = match.axis,
                .storage_binding = binding,
                .element_multiplier = match.tile_stride,
                .tile_width = match.tile_width,
                .element_stride_bytes = element_stride_bytes,
                .element_offset = match.offset,
            };
        }
    }
    if (lean_proof.boundsProven(.loop_1d_storage_buffer_affine)) {
        if (match_loop_only_affine_plus_offset(module, function, index_data.index)) |match| {
            if (loop_match.find_bounded_loop_limit(module, function, expr_id, match.local_idx)) |loop_limit| {
                return .{
                    .kind = .loop_component,
                    .gid_axis = 0,
                    .storage_binding = binding,
                    .element_multiplier = 0,
                    .loop_limit = loop_limit,
                    .loop_limit_multiplier = match.loop_multiplier,
                    .element_stride_bytes = element_stride_bytes,
                    .element_offset = match.offset,
                };
            }
        }
    }
    if (lean_proof.boundsProven(.gid_2d_flat_storage_buffer_offset)) {
        if (match_flat_index_2d_dispatch_x(module, function, function_id, index_data.index)) |offset| {
            return .{
                .kind = .flat_index_2d_dispatch_x,
                .gid_axis = 0,
                .storage_binding = binding,
                .element_multiplier = 1,
                .element_stride_bytes = element_stride_bytes,
                .element_offset = offset,
            };
        }
    } else if (lean_proof.boundsProven(.gid_2d_flat_storage_buffer)) {
        if (match_flat_index_2d_dispatch_x_base(module, function, function_id, index_data.index)) {
            return .{
                .kind = .flat_index_2d_dispatch_x,
                .gid_axis = 0,
                .storage_binding = binding,
                .element_multiplier = 1,
                .element_stride_bytes = element_stride_bytes,
                .element_offset = 0,
            };
        }
    }
    if (lean_proof.boundsProven(.gid_3d_flat_storage_buffer_offset)) {
        if (match_flat_index_3d_dispatch_xy(module, function, function_id, index_data.index)) |offset| {
            return .{
                .kind = .flat_index_3d_dispatch_xy,
                .gid_axis = 0,
                .storage_binding = binding,
                .element_multiplier = 1,
                .element_stride_bytes = element_stride_bytes,
                .element_offset = offset,
            };
        }
    } else if (lean_proof.boundsProven(.gid_3d_flat_storage_buffer)) {
        if (match_flat_index_3d_dispatch_xy_base(module, function, function_id, index_data.index)) {
            return .{
                .kind = .flat_index_3d_dispatch_xy,
                .gid_axis = 0,
                .storage_binding = binding,
                .element_multiplier = 1,
                .element_stride_bytes = element_stride_bytes,
                .element_offset = 0,
            };
        }
    }
    return null;
}

pub fn try_elide_dispatch_validated_storage_index(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    index_data: @FieldType(ir.Expr, "index"),
    allow_global_invocation_id: bool,
) ?ir.DispatchPrecondition {
    const binding = resolve_storage_binding(module, function, index_data.base) orelse return null;
    const element_stride_bytes = resolve_runtime_array_element_stride(module, function, index_data.base) orelse return null;
    const Candidate = struct {
        builtin: ir.Builtin,
        kind: ir.DispatchPreconditionKind,
        requires_global_opt_in: bool = false,
    };
    const candidates = [_]Candidate{
        .{ .builtin = .local_invocation_id, .kind = .local_invocation_component },
        .{ .builtin = .workgroup_id, .kind = .workgroup_component },
        .{ .builtin = .global_invocation_id, .kind = .gid_component, .requires_global_opt_in = true },
    };
    for (candidates) |candidate| {
        if (candidate.requires_global_opt_in and !allow_global_invocation_id) continue;
        if (try_elide_dispatch_validated_builtin_index(
            module,
            function,
            expr_id,
            index_data.index,
            binding,
            element_stride_bytes,
            candidate.builtin,
            candidate.kind,
        )) |precondition| return precondition;
    }
    return null;
}

fn try_elide_dispatch_validated_builtin_index(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    index_expr_id: ir.ExprId,
    binding: ir.BindingPoint,
    element_stride_bytes: u64,
    builtin: ir.Builtin,
    kind: ir.DispatchPreconditionKind,
) ?ir.DispatchPrecondition {
    if (classify_builtin_component(function, index_expr_id, builtin)) |axis| {
        return .{
            .kind = kind,
            .gid_axis = axis,
            .storage_binding = binding,
            .element_multiplier = 1,
            .element_stride_bytes = element_stride_bytes,
            .element_offset = 0,
        };
    }
    if (match_gid_component_times_stride_plus_offset(function, index_expr_id, builtin)) |match| {
        return .{
            .kind = kind,
            .gid_axis = match.axis,
            .storage_binding = binding,
            .element_multiplier = match.multiplier,
            .element_stride_bytes = element_stride_bytes,
            .element_offset = match.offset,
        };
    }
    if (match_gid_component_loop_affine_plus_offset(module, function, index_expr_id, builtin)) |match| {
        if (loop_match.find_bounded_loop_limit(module, function, expr_id, match.local_idx)) |loop_limit| {
            return .{
                .kind = kind,
                .gid_axis = match.axis,
                .storage_binding = binding,
                .element_multiplier = match.gid_multiplier,
                .loop_limit = loop_limit,
                .loop_limit_multiplier = match.loop_multiplier,
                .element_stride_bytes = element_stride_bytes,
                .element_offset = match.offset,
            };
        }
    }

    return null;
}

fn resolve_indexable_type(types: *const ir.TypeStore, ty: ir.TypeId) ir.TypeId {
    var current = ty;
    while (true) {
        switch (types.get(current)) {
            .ref => |ref_ty| current = ref_ty.elem,
            else => return current,
        }
    }
}

fn resolve_runtime_array_element_stride(
    module: *const ir.Module,
    function: *const ir.Function,
    base_id: ir.ExprId,
) ?u64 {
    const base_ty = resolve_indexable_type(&module.types, function.exprs.items[base_id].ty);
    const arr = switch (module.types.get(base_ty)) {
        .array => |value| value,
        else => return null,
    };
    if (arr.len != null) return null;
    const elem_size = layout_utils.type_size(module, arr.elem);
    const elem_align = layout_utils.type_alignment(module, arr.elem);
    return layout_utils.round_up(elem_size, elem_align);
}

fn resolve_storage_binding(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?ir.BindingPoint {
    const current_id = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[current_id];
    switch (expr.data) {
        .global_ref => |global_idx| {
            if (global_idx >= module.globals.items.len) return null;
            const global = module.globals.items[global_idx];
            if (global.addr_space != .storage) return null;
            return global.binding;
        },
        .member => |member| return resolve_storage_binding(module, function, member.base),
        .index => |index| return resolve_storage_binding(module, function, index.base),
        else => return null,
    }
}

fn match_flat_index_2d_dispatch_x(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
) ?u64 {
    if (match_flat_index_2d_dispatch_x_base(module, function, function_id, expr_id)) return 0;

    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .add) return null;

    if (match_u32_literal_value(function, binary.lhs)) |offset| {
        if (match_flat_index_2d_dispatch_x_base(module, function, function_id, binary.rhs)) return offset;
    }
    if (match_u32_literal_value(function, binary.rhs)) |offset| {
        if (match_flat_index_2d_dispatch_x_base(module, function, function_id, binary.lhs)) return offset;
    }
    return null;
}

fn match_flat_index_2d_dispatch_x_base(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
) bool {
    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.op != .add) return false;

    return (classify_builtin_component(function, binary.lhs, .global_invocation_id) == 0 and
        match_gid_y_times_dispatch_width(module, function, function_id, binary.rhs)) or
        (classify_builtin_component(function, binary.rhs, .global_invocation_id) == 0 and
            match_gid_y_times_dispatch_width(module, function, function_id, binary.lhs));
}

fn match_flat_index_3d_dispatch_xy(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
) ?u64 {
    if (match_flat_index_3d_dispatch_xy_base(module, function, function_id, expr_id)) return 0;

    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .add) return null;

    if (match_u32_literal_value(function, binary.lhs)) |offset| {
        if (match_flat_index_3d_dispatch_xy_base(module, function, function_id, binary.rhs)) return offset;
    }
    if (match_u32_literal_value(function, binary.rhs)) |offset| {
        if (match_flat_index_3d_dispatch_xy_base(module, function, function_id, binary.lhs)) return offset;
    }
    return null;
}

fn match_flat_index_3d_dispatch_xy_base(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
) bool {
    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.op != .add) return false;

    if (classify_builtin_component(function, binary.lhs, .global_invocation_id) == 0) {
        return match_flat_index_3d_dispatch_xy_without_x(module, function, function_id, binary.rhs);
    }
    if (classify_builtin_component(function, binary.rhs, .global_invocation_id) == 0) {
        return match_flat_index_3d_dispatch_xy_without_x(module, function, function_id, binary.lhs);
    }
    return false;
}

fn match_flat_index_3d_dispatch_xy_without_x(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
) bool {
    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.op != .add) return false;

    return (match_gid_z_times_dispatch_area_xy(module, function, function_id, binary.lhs) and
        match_gid_y_times_dispatch_width(module, function, function_id, binary.rhs)) or
        (match_gid_z_times_dispatch_area_xy(module, function, function_id, binary.rhs) and
            match_gid_y_times_dispatch_width(module, function, function_id, binary.lhs));
}

fn match_gid_y_times_dispatch_width(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
) bool {
    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.op != .mul) return false;

    return (classify_builtin_component(function, binary.lhs, .global_invocation_id) == 1 and
        match_dispatch_width(module, function, function_id, binary.rhs)) or
        (classify_builtin_component(function, binary.rhs, .global_invocation_id) == 1 and
            match_dispatch_width(module, function, function_id, binary.lhs));
}

fn match_gid_z_times_dispatch_area_xy(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
) bool {
    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.op != .mul) return false;

    return (classify_builtin_component(function, binary.lhs, .global_invocation_id) == 2 and
        match_dispatch_area_xy(module, function, function_id, binary.rhs)) or
        (classify_builtin_component(function, binary.rhs, .global_invocation_id) == 2 and
            match_dispatch_area_xy(module, function, function_id, binary.lhs));
}

fn match_dispatch_width(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
) bool {
    const workgroup_size = workgroup_size_for_function(module, function_id);
    if (classify_builtin_component(function, expr_id, .num_workgroups) == 0) {
        return workgroup_size[0] == 1;
    }

    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.op != .mul) return false;

    return (classify_builtin_component(function, binary.lhs, .num_workgroups) == 0 and
        match_u32_literal(function, binary.rhs, workgroup_size[0])) or
        (classify_builtin_component(function, binary.rhs, .num_workgroups) == 0 and
            match_u32_literal(function, binary.lhs, workgroup_size[0]));
}

fn match_dispatch_height(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
) bool {
    const workgroup_size = workgroup_size_for_function(module, function_id);
    if (classify_builtin_component(function, expr_id, .num_workgroups) == 1) {
        return workgroup_size[1] == 1;
    }

    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.op != .mul) return false;

    return (classify_builtin_component(function, binary.lhs, .num_workgroups) == 1 and
        match_u32_literal(function, binary.rhs, workgroup_size[1])) or
        (classify_builtin_component(function, binary.rhs, .num_workgroups) == 1 and
            match_u32_literal(function, binary.lhs, workgroup_size[1]));
}

fn match_dispatch_area_xy(
    module: *const ir.Module,
    function: *const ir.Function,
    function_id: ir.FunctionId,
    expr_id: ir.ExprId,
) bool {
    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return false,
    };
    if (binary.op != .mul) return false;

    return (match_dispatch_width(module, function, function_id, binary.lhs) and
        match_dispatch_height(module, function, function_id, binary.rhs)) or
        (match_dispatch_width(module, function, function_id, binary.rhs) and
            match_dispatch_height(module, function, function_id, binary.lhs));
}

fn workgroup_size_for_function(module: *const ir.Module, function_id: ir.FunctionId) [3]u32 {
    for (module.entry_points.items) |entry| {
        if (entry.function == function_id) return entry.workgroup_size;
    }
    return .{ 1, 1, 1 };
}

fn match_u32_literal(function: *const ir.Function, expr_id: ir.ExprId, expected: u32) bool {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    return switch (expr.data) {
        .int_lit => |value| value == expected,
        else => false,
    };
}

fn match_u32_literal_value(function: *const ir.Function, expr_id: ir.ExprId) ?u64 {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    return switch (expr.data) {
        .int_lit => |value| value,
        else => null,
    };
}

fn match_u32_literal_value_with_module(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?u64 {
    return ir_const_eval.resolve_constant_int(module, function, resolve_value_alias(function, expr_id));
}

pub fn match_gid_component_plus_offset(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?struct { axis: u8, offset: u64 } {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .add) return null;

    if (classify_builtin_component(function, binary.lhs, builtin)) |axis| {
        if (match_u32_literal_value(function, binary.rhs)) |offset| {
            return .{ .axis = axis, .offset = offset };
        }
    }
    if (classify_builtin_component(function, binary.rhs, builtin)) |axis| {
        if (match_u32_literal_value(function, binary.lhs)) |offset| {
            return .{ .axis = axis, .offset = offset };
        }
    }
    return null;
}

fn match_gid_component_times_stride(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?struct { axis: u8, multiplier: u64 } {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .mul) return null;

    if (classify_builtin_component(function, binary.lhs, builtin)) |axis| {
        if (match_u32_literal_value(function, binary.rhs)) |multiplier| {
            if (multiplier > 0) return .{ .axis = axis, .multiplier = multiplier };
        }
    }
    if (classify_builtin_component(function, binary.rhs, builtin)) |axis| {
        if (match_u32_literal_value(function, binary.lhs)) |multiplier| {
            if (multiplier > 0) return .{ .axis = axis, .multiplier = multiplier };
        }
    }
    return null;
}

pub fn match_gid_component_times_stride_plus_offset(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?struct { axis: u8, multiplier: u64, offset: u64 } {
    if (match_gid_component_times_stride(function, expr_id, builtin)) |match| {
        return .{ .axis = match.axis, .multiplier = match.multiplier, .offset = 0 };
    }

    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .add) return null;

    if (match_u32_literal_value(function, binary.lhs)) |offset| {
        if (match_gid_component_times_stride(function, binary.rhs, builtin)) |match| {
            return .{ .axis = match.axis, .multiplier = match.multiplier, .offset = offset };
        }
    }
    if (match_u32_literal_value(function, binary.rhs)) |offset| {
        if (match_gid_component_times_stride(function, binary.lhs, builtin)) |match| {
            return .{ .axis = match.axis, .multiplier = match.multiplier, .offset = offset };
        }
    }
    return null;
}

pub fn match_gid_component_tiled_plus_offset(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?struct { axis: u8, tile_width: u64, tile_stride: u64, offset: u64 } {
    if (match_gid_component_tiled(function, expr_id, builtin)) |match| {
        return .{
            .axis = match.axis,
            .tile_width = match.tile_width,
            .tile_stride = match.tile_stride,
            .offset = 0,
        };
    }

    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .add) return null;

    if (match_u32_literal_value(function, binary.lhs)) |offset| {
        if (match_gid_component_tiled(function, binary.rhs, builtin)) |match| {
            return .{
                .axis = match.axis,
                .tile_width = match.tile_width,
                .tile_stride = match.tile_stride,
                .offset = offset,
            };
        }
    }
    if (match_u32_literal_value(function, binary.rhs)) |offset| {
        if (match_gid_component_tiled(function, binary.lhs, builtin)) |match| {
            return .{
                .axis = match.axis,
                .tile_width = match.tile_width,
                .tile_stride = match.tile_stride,
                .offset = offset,
            };
        }
    }
    return null;
}

fn match_gid_component_loop_affine_plus_offset(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?struct { axis: u8, local_idx: u32, gid_multiplier: u64, loop_multiplier: u64, offset: u64 } {
    var state = AdditiveLoopIndexState{};
    if (!collect_additive_loop_terms(module, function, expr_id, builtin, &state)) return null;
    if (state.gid_multiplier == 0 or state.loop_multiplier == 0) return null;
    return .{
        .axis = state.axis orelse return null,
        .local_idx = state.local_idx orelse return null,
        .gid_multiplier = state.gid_multiplier,
        .loop_multiplier = state.loop_multiplier,
        .offset = state.offset,
    };
}

/// Match `loop_local * loop_stride + offset` with no gid term. Covers the
/// matvec `vectorData[col]` inner-loop load. Returns the local index, its
/// scale, and the additive offset.
fn match_loop_only_affine_plus_offset(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?struct { local_idx: u32, loop_multiplier: u64, offset: u64 } {
    var state = AdditiveLoopIndexState{};
    if (!collect_additive_loop_terms(module, function, expr_id, .global_invocation_id, &state)) return null;
    if (state.gid_multiplier != 0 or state.loop_multiplier == 0) return null;
    return .{
        .local_idx = state.local_idx orelse return null,
        .loop_multiplier = state.loop_multiplier,
        .offset = state.offset,
    };
}

const AdditiveLoopIndexState = struct {
    axis: ?u8 = null,
    local_idx: ?u32 = null,
    gid_multiplier: u64 = 0,
    loop_multiplier: u64 = 0,
    offset: u64 = 0,
};

fn collect_additive_loop_terms(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
    state: *AdditiveLoopIndexState,
) bool {
    const canonical = resolve_value_alias(function, expr_id);
    const expr = function.exprs.items[canonical];
    switch (expr.data) {
        .binary => |binary| {
            if (binary.op == .add) {
                return collect_additive_loop_terms(module, function, binary.lhs, builtin, state) and
                    collect_additive_loop_terms(module, function, binary.rhs, builtin, state);
            }
            if (binary.op == .mul) {
                return collect_scaled_loop_term(module, function, binary.lhs, binary.rhs, builtin, state) or
                    collect_scaled_loop_term(module, function, binary.rhs, binary.lhs, builtin, state);
            }
            return false;
        },
        .int_lit => |value| {
            state.offset = std.math.add(u64, state.offset, value) catch return false;
            return true;
        },
        .local_ref => |local_idx| {
            if (state.local_idx) |existing| {
                if (existing != local_idx) return false;
            } else {
                state.local_idx = local_idx;
            }
            state.loop_multiplier = std.math.add(u64, state.loop_multiplier, 1) catch return false;
            return true;
        },
        else => {
            if (classify_builtin_component(function, canonical, builtin)) |axis| {
                if (state.axis) |existing| {
                    if (existing != axis) return false;
                } else {
                    state.axis = axis;
                }
                state.gid_multiplier = std.math.add(u64, state.gid_multiplier, 1) catch return false;
                return true;
            }
            return false;
        },
    }
}

fn collect_scaled_loop_term(
    module: *const ir.Module,
    function: *const ir.Function,
    lhs: ir.ExprId,
    rhs: ir.ExprId,
    builtin: ir.Builtin,
    state: *AdditiveLoopIndexState,
) bool {
    const scale = match_u32_literal_value_with_module(module, function, rhs) orelse return false;
    if (scale == 0) return true;

    const lhs_expr = function.exprs.items[resolve_value_alias(function, lhs)];
    switch (lhs_expr.data) {
        .local_ref => |local_idx| {
            if (state.local_idx) |existing| {
                if (existing != local_idx) return false;
            } else {
                state.local_idx = local_idx;
            }
            state.loop_multiplier = std.math.add(u64, state.loop_multiplier, scale) catch return false;
            return true;
        },
        else => {
            if (classify_builtin_component(function, lhs, builtin)) |axis| {
                if (state.axis) |existing| {
                    if (existing != axis) return false;
                } else {
                    state.axis = axis;
                }
                state.gid_multiplier = std.math.add(u64, state.gid_multiplier, scale) catch return false;
                return true;
            }
            var nested = AdditiveLoopIndexState{};
            if (!collect_additive_loop_terms(module, function, lhs, builtin, &nested)) return false;
            return merge_scaled_loop_terms(state, nested, scale);
        },
    }
}

fn merge_scaled_loop_terms(
    state: *AdditiveLoopIndexState,
    nested: AdditiveLoopIndexState,
    scale: u64,
) bool {
    if (nested.axis) |axis| {
        if (state.axis) |existing| {
            if (existing != axis) return false;
        } else {
            state.axis = axis;
        }
        const scaled = std.math.mul(u64, nested.gid_multiplier, scale) catch return false;
        state.gid_multiplier = std.math.add(u64, state.gid_multiplier, scaled) catch return false;
    }
    if (nested.local_idx) |local_idx| {
        if (state.local_idx) |existing| {
            if (existing != local_idx) return false;
        } else {
            state.local_idx = local_idx;
        }
        const scaled = std.math.mul(u64, nested.loop_multiplier, scale) catch return false;
        state.loop_multiplier = std.math.add(u64, state.loop_multiplier, scaled) catch return false;
    }
    const scaled_offset = std.math.mul(u64, nested.offset, scale) catch return false;
    state.offset = std.math.add(u64, state.offset, scaled_offset) catch return false;
    return true;
}

fn match_gid_component_tiled(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?struct { axis: u8, tile_width: u64, tile_stride: u64 } {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .add) return null;

    if (match_gid_component_div_stride(function, binary.lhs, builtin)) |div_match| {
        if (match_gid_component_mod_tile(function, binary.rhs, builtin)) |mod_match| {
            if (div_match.axis == mod_match.axis and div_match.tile_width == mod_match.tile_width) {
                return .{
                    .axis = div_match.axis,
                    .tile_width = div_match.tile_width,
                    .tile_stride = div_match.tile_stride,
                };
            }
        }
    }
    if (match_gid_component_div_stride(function, binary.rhs, builtin)) |div_match| {
        if (match_gid_component_mod_tile(function, binary.lhs, builtin)) |mod_match| {
            if (div_match.axis == mod_match.axis and div_match.tile_width == mod_match.tile_width) {
                return .{
                    .axis = div_match.axis,
                    .tile_width = div_match.tile_width,
                    .tile_stride = div_match.tile_stride,
                };
            }
        }
    }
    return null;
}

fn match_gid_component_div_stride(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?struct { axis: u8, tile_width: u64, tile_stride: u64 } {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .mul) return null;

    if (match_gid_component_div_tile(function, binary.lhs, builtin)) |div_match| {
        if (match_u32_literal_value(function, binary.rhs)) |tile_stride| {
            if (tile_stride >= div_match.tile_width) {
                return .{
                    .axis = div_match.axis,
                    .tile_width = div_match.tile_width,
                    .tile_stride = tile_stride,
                };
            }
        }
    }
    if (match_gid_component_div_tile(function, binary.rhs, builtin)) |div_match| {
        if (match_u32_literal_value(function, binary.lhs)) |tile_stride| {
            if (tile_stride >= div_match.tile_width) {
                return .{
                    .axis = div_match.axis,
                    .tile_width = div_match.tile_width,
                    .tile_stride = tile_stride,
                };
            }
        }
    }
    return null;
}

fn match_gid_component_div_tile(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?struct { axis: u8, tile_width: u64 } {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .div) return null;

    if (classify_builtin_component(function, binary.lhs, builtin)) |axis| {
        if (match_u32_literal_value(function, binary.rhs)) |tile_width| {
            if (tile_width > 0) return .{ .axis = axis, .tile_width = tile_width };
        }
    }
    return null;
}

fn match_gid_component_mod_tile(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?struct { axis: u8, tile_width: u64 } {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const binary = switch (expr.data) {
        .binary => |value| value,
        else => return null,
    };
    if (binary.op != .rem) return null;

    if (classify_builtin_component(function, binary.lhs, builtin)) |axis| {
        if (match_u32_literal_value(function, binary.rhs)) |tile_width| {
            if (tile_width > 0) return .{ .axis = axis, .tile_width = tile_width };
        }
    }
    return null;
}

fn classify_builtin_component(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    builtin: ir.Builtin,
) ?u8 {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const member = switch (expr.data) {
        .member => |value| value,
        else => return null,
    };
    const base = function.exprs.items[resolve_value_alias(function, member.base)];
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

fn resolve_value_alias(function: *const ir.Function, expr_id: ir.ExprId) ir.ExprId {
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
                current = resolve_const_local_initializer(function, local_idx) orelse return current;
            },
            else => return current,
        }
    }
}

fn resolve_const_local_initializer(function: *const ir.Function, local_idx: u32) ?ir.ExprId {
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

const std = @import("std");
