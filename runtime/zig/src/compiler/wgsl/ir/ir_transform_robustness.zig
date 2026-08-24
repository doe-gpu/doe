const std = @import("std");
const dispatch_proof_match = @import("../proof/dispatch_proof_match.zig");
const dispatch_uniform_bounds = @import("../proof/dispatch_uniform_bounds.zig");
const ir = @import("ir.zig");
const ir_query = @import("ir_query.zig");
const lean_proof = @import("../../../verification/lean_proof.zig");
const robustness_static_bounds = @import("../proof/robustness_static_bounds.zig");

const resolve_const_local_initializer = ir_query.resolveConstLocalInitializer;
const resolve_indexable_type = ir_query.resolveIndexableType;
const resolve_value_alias = ir_query.resolveValueAlias;

pub const TransformError = error{
    OutOfMemory,
};

pub const Config = struct {
    elide_proven_bounds: bool = false,
    elide_proven_texture_bounds: bool = false,
    elide_dispatch_validated_bounds: bool = false,
    elide_dispatch_validated_global_bounds: bool = false,
    elide_static_storage_bounds: bool = false,
    elide_uniform_validated_bounds: bool = false,
    rely_on_storage_buffer_robustness: bool = false,
};

/// Apply robustness clamping to all index and texture expressions in the module.
/// When config.elide_proven_bounds is true, proven gid-indexed storage buffer
/// accesses skip the clamp and record dispatch preconditions on the module.
pub fn apply(allocator: std.mem.Allocator, module: *ir.Module, config: Config) TransformError!void {
    for (module.functions.items, 0..) |*function, function_index| {
        try transform_function(allocator, module, @intCast(function_index), function, config);
    }
}

fn transform_function(
    allocator: std.mem.Allocator,
    module: *ir.Module,
    function_id: ir.FunctionId,
    function: *ir.Function,
    config: Config,
) TransformError!void {
    // Snapshot the expression count — we only transform pre-existing expressions.
    // New expressions appended by the transform are helper nodes and need not be
    // re-examined (they cannot themselves be index operations).
    const expr_count: u32 = @intCast(function.exprs.items.len);
    var i: u32 = 0;
    while (i < expr_count) : (i += 1) {
        const expr_node = function.exprs.items[i];
        switch (expr_node.data) {
            .index => |index_data| {
                const base_ty = resolve_indexable_type(&module.types, function.exprs.items[index_data.base].ty);
                switch (module.types.get(base_ty)) {
                    .array => |arr| {
                        if (config.rely_on_storage_buffer_robustness and
                            index_base_is_storage(module, function, index_data.base))
                        {
                            continue;
                        }
                        if (arr.len) |len| {
                            if (len > 0) {
                                if (robustness_static_bounds.sizedArrayIndexProvablyInBounds(module, function, i, index_data.base, index_data.index, len, config.elide_static_storage_bounds)) {
                                    continue;
                                }
                                try clamp_sized(allocator, module, function, i, len);
                            }
                        } else {
                            if (config.elide_proven_bounds) {
                                if (dispatch_proof_match.try_elide_storage_index(module, function, function_id, i, index_data)) |precondition| {
                                    module.dispatch_preconditions.append(
                                        module.allocator,
                                        precondition,
                                    ) catch return error.OutOfMemory;
                                    continue;
                                }
                            }
                            if (config.elide_dispatch_validated_bounds) {
                                if (dispatch_proof_match.try_elide_dispatch_validated_storage_index(module, function, i, index_data, false)) |precondition| {
                                    module.dispatch_preconditions.append(
                                        module.allocator,
                                        precondition,
                                    ) catch return error.OutOfMemory;
                                    continue;
                                }
                            }
                            if (config.elide_uniform_validated_bounds) {
                                if (dispatch_uniform_bounds.try_elide_uniform_validated_storage_index(module, function, function_id, i, index_data)) |precondition| {
                                    module.dispatch_preconditions.append(module.allocator, precondition) catch return error.OutOfMemory;
                                    continue;
                                }
                            }
                            if (config.elide_dispatch_validated_global_bounds) {
                                if (dispatch_proof_match.try_elide_dispatch_validated_storage_index(module, function, i, index_data, true)) |precondition| {
                                    module.dispatch_preconditions.append(module.allocator, precondition) catch return error.OutOfMemory;
                                    continue;
                                }
                            }
                            try clamp_runtime_sized(allocator, module, function, i);
                        }
                    },
                    .vector => |vec| {
                        if (vec.len > 0) try clamp_sized(allocator, module, function, i, vec.len);
                    },
                    .matrix => |mat| {
                        if (mat.columns > 0) try clamp_sized(allocator, module, function, i, mat.columns);
                    },
                    else => {},
                }
            },
            .call => |call_data| {
                if (call_data.kind != .builtin) continue;
                if (config.elide_proven_texture_bounds) {
                    if (try_elide_dispatch_fit_texture_coords(module, function, call_data)) |precondition| {
                        module.texture_dispatch_preconditions.append(
                            module.allocator,
                            precondition,
                        ) catch return error.OutOfMemory;
                        continue;
                    }
                }
                try clamp_texture_coords(allocator, module, function, call_data);
            },
            else => {},
        }
    }
}

fn index_base_is_storage(
    module: *const ir.Module,
    function: *const ir.Function,
    base_expr_id: ir.ExprId,
) bool {
    if (ir_query.findGlobalBase(function, base_expr_id)) |global_index| {
        if (global_index < module.globals.items.len) {
            return module.globals.items[global_index].addr_space == .storage;
        }
    }
    return switch (module.types.get(function.exprs.items[base_expr_id].ty)) {
        .ref => |ref_type| ref_type.addr_space == .storage,
        else => false,
    };
}

/// Resolve through ref types to get the indexable element type.
fn ensure_u32_type(module: *ir.Module) TransformError!ir.TypeId {
    return module.types.intern(.{ .scalar = .u32 }) catch return error.OutOfMemory;
}

/// Clamp index for a sized container: min(index, length - 1)
fn clamp_sized(
    allocator: std.mem.Allocator,
    module: *ir.Module,
    function: *ir.Function,
    expr_idx: u32,
    length: u32,
) TransformError!void {
    const u32_ty = try ensure_u32_type(module);
    const index_data = function.exprs.items[expr_idx].data.index;
    const original_index = index_data.index;

    // int_lit(length - 1)
    const max_id = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = length - 1 },
    });

    // min(index, length - 1)
    const args = try function.append_expr_args(allocator, &.{ original_index, max_id });
    const min_id = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "min"),
            .kind = .builtin,
            .args = args,
            .robustness_generated = true,
        } },
    });

    // Replace the original index with the clamped version.
    function.exprs.items[expr_idx].data = .{ .index = .{
        .base = index_data.base,
        .index = min_id,
    } };
}

/// Clamp index for a runtime-sized array: min(index, arrayLength(&buf) - 1)
///
/// Accepts any base expression shape that can produce a runtime-sized array
/// reference. The transform keeps the base expression intact and relies on
/// backend emission to lower `arrayLength` for that base shape.
fn clamp_runtime_sized(
    allocator: std.mem.Allocator,
    module: *ir.Module,
    function: *ir.Function,
    expr_idx: u32,
) TransformError!void {
    const index_data = function.exprs.items[expr_idx].data.index;

    switch (function.exprs.items[index_data.base].data) {
        .global_ref, .member, .load, .local_ref, .param_ref, .index, .call => {},
        else => return,
    }

    const u32_ty = try ensure_u32_type(module);
    const original_index = index_data.index;
    const base_ref = index_data.base;

    const al_args = try function.append_expr_args(allocator, &.{base_ref});
    const array_length_id = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "arrayLength"),
            .kind = .builtin,
            .args = al_args,
        } },
    });

    const one_id = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 1 },
    });

    const sub_id = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .binary = .{
            .op = .sub,
            .lhs = array_length_id,
            .rhs = one_id,
        } },
    });

    const min_args = try function.append_expr_args(allocator, &.{ original_index, sub_id });
    const min_id = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "min"),
            .kind = .builtin,
            .args = min_args,
            .robustness_generated = true,
        } },
    });

    function.exprs.items[expr_idx].data = .{ .index = .{
        .base = base_ref,
        .index = min_id,
    } };
}

// ---- Texture coordinate clamping ----

const TEXTURE_LOAD_NAME = "textureLoad";
const TEXTURE_STORE_NAME = "textureStore";

/// Returns true if the name is a texture builtin whose integer coordinate
/// argument requires robustness clamping.
///
/// Per the WGSL specification, only textureLoad and textureStore accept integer
/// coordinates that require runtime clamping. All textureSample* variants
/// (textureSample, textureSampleLevel, textureSampleOffset,
/// textureSampleLevelOffset, textureSampleGrad, textureSampleCompare,
/// textureSampleCompareLevel) use float coordinates; the GPU hardware samples
/// with clamp-to-edge or wrap semantics, so integer clamping does not apply.
/// textureGather and textureGatherCompare also use float coordinates.
/// The "offset" parameter in textureSampleOffset / textureSampleLevelOffset is
/// a compile-time constant integer, not a runtime coordinate.
fn is_clamped_texture_builtin(name: []const u8) bool {
    return std.mem.eql(u8, name, TEXTURE_LOAD_NAME) or
        std.mem.eql(u8, name, TEXTURE_STORE_NAME);
}

/// Resolve the texture type from a type id, looking through refs.
fn resolve_texture_type(types: *const ir.TypeStore, ty: ir.TypeId) ir.Type {
    var current = ty;
    while (true) {
        const t = types.get(current);
        switch (t) {
            .ref => |ref_ty| current = ref_ty.elem,
            else => return t,
        }
    }
}

/// Return the coordinate vector dimensionality for a given texture type.
fn texture_coord_dim(tex_type: ir.Type) ?u8 {
    return switch (tex_type) {
        .texture_1d => 1,
        .texture_2d, .texture_depth_2d, .texture_multisampled_2d, .storage_texture_2d => 2,
        .texture_3d, .texture_cube, .texture_depth_cube => 3,
        .texture_2d_array => 2,
        else => null,
    };
}

/// Returns true if this texture type variant has a mip level parameter.
fn texture_has_level(tex_type: ir.Type) bool {
    return switch (tex_type) {
        .texture_1d, .texture_2d, .texture_depth_2d => true,
        .texture_3d, .texture_cube, .texture_depth_cube => true,
        else => false,
    };
}

fn dispatch_fit_texture_coord_dim(tex_type: ir.Type) ?u8 {
    return switch (tex_type) {
        .texture_1d => 1,
        .texture_2d, .texture_depth_2d, .texture_multisampled_2d, .storage_texture_2d => 2,
        .texture_3d => 3,
        else => null,
    };
}

fn classify_gid_scalar(function: *const ir.Function, expr_id: ir.ExprId) ?u8 {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    switch (expr.data) {
        .construct => |construct| {
            if (construct.args.len != 1) return null;
            return classify_gid_scalar(function, function.expr_args.items[construct.args.start]);
        },
        .member => |member_data| {
            const base_expr = function.exprs.items[resolve_value_alias(function, member_data.base)];
            switch (base_expr.data) {
                .param_ref => |param_idx| {
                    if (param_idx >= function.params.items.len) return null;
                    const param = function.params.items[param_idx];
                    const io = param.io orelse return null;
                    if (io.builtin != .global_invocation_id) return null;
                    if (std.mem.eql(u8, member_data.field_name, "x")) return 0;
                    if (std.mem.eql(u8, member_data.field_name, "y")) return 1;
                    if (std.mem.eql(u8, member_data.field_name, "z")) return 2;
                    return null;
                },
                else => return null,
            }
        },
        else => return null,
    }
}

fn match_u32_literal_value(function: *const ir.Function, expr_id: ir.ExprId) ?u32 {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    return switch (expr.data) {
        .int_lit => |value| std.math.cast(u32, value),
        else => null,
    };
}

fn resolve_texture_binding(
    module: *const ir.Module,
    function: *const ir.Function,
    expr_id: ir.ExprId,
) ?ir.BindingPoint {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    switch (expr.data) {
        .global_ref => |global_idx| {
            if (global_idx >= module.globals.items.len) return null;
            const global = module.globals.items[global_idx];
            const binding = global.binding orelse return null;
            return switch (resolve_texture_type(&module.types, global.ty)) {
                .texture_1d,
                .texture_2d,
                .texture_depth_2d,
                .texture_multisampled_2d,
                .storage_texture_2d,
                .texture_3d,
                => binding,
                else => null,
            };
        },
        .member => |member| return resolve_texture_binding(module, function, member.base),
        .index => |index| return resolve_texture_binding(module, function, index.base),
        else => return null,
    }
}

const TextureCoordPatternFamily = enum {
    affine,
    tiled,
};

const TextureCoordPattern = struct {
    family: TextureCoordPatternFamily = .affine,
    multipliers: [3]u64 = .{ 1, 1, 1 },
    offsets: [3]u64 = .{ 0, 0, 0 },
    tile_widths: [3]u64 = .{ 1, 1, 1 },
    tile_strides: [3]u64 = .{ 1, 1, 1 },
};

const TextureCoordComponent = union(enum) {
    affine: struct {
        multiplier: u64,
        offset: u64,
    },
    tiled: struct {
        tile_width: u64,
        tile_stride: u64,
        offset: u64,
    },
};

fn texture_pattern_is_identity(pattern: TextureCoordPattern, dim: u8) bool {
    if (pattern.family != .affine) return false;
    const used_axes: usize = dim;
    var axis: usize = 0;
    while (axis < used_axes) : (axis += 1) {
        if (pattern.multipliers[axis] != 1 or pattern.offsets[axis] != 0) return false;
    }
    return true;
}

fn match_texture_coord_component(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    expected_axis: u8,
) ?TextureCoordComponent {
    if (dispatch_proof_match.match_gid_component_tiled_plus_offset(function, expr_id, .global_invocation_id)) |match| {
        if (match.axis == expected_axis) {
            return .{ .tiled = .{
                .tile_width = match.tile_width,
                .tile_stride = match.tile_stride,
                .offset = match.offset,
            } };
        }
    }
    if (dispatch_proof_match.match_gid_component_times_stride_plus_offset(function, expr_id, .global_invocation_id)) |match| {
        if (match.axis == expected_axis) {
            return .{ .affine = .{
                .multiplier = match.multiplier,
                .offset = match.offset,
            } };
        }
    }
    if (dispatch_proof_match.match_gid_component_plus_offset(function, expr_id, .global_invocation_id)) |match| {
        if (match.axis == expected_axis) {
            return .{ .affine = .{
                .multiplier = 1,
                .offset = match.offset,
            } };
        }
    }
    if (classify_gid_scalar(function, expr_id) == expected_axis) {
        return .{ .affine = .{
            .multiplier = 1,
            .offset = 0,
        } };
    }
    return null;
}

fn match_texture_coord_pattern(function: *const ir.Function, expr_id: ir.ExprId, dim: u8) ?TextureCoordPattern {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    switch (expr.data) {
        .member => |member| {
            const base_expr = function.exprs.items[resolve_value_alias(function, member.base)];
            const param_idx = switch (base_expr.data) {
                .param_ref => |value| value,
                else => return null,
            };
            if (param_idx >= function.params.items.len) return null;
            const io = function.params.items[param_idx].io orelse return null;
            if (io.builtin != .global_invocation_id) return null;
            const field_matches = switch (dim) {
                1 => std.mem.eql(u8, member.field_name, "x"),
                2 => std.mem.eql(u8, member.field_name, "xy"),
                3 => std.mem.eql(u8, member.field_name, "xyz"),
                else => false,
            };
            if (!field_matches) return null;
            return .{};
        },
        .construct => |construct| {
            if (construct.args.len == 1) {
                return match_texture_coord_pattern(function, function.expr_args.items[construct.args.start], dim);
            }
            if (construct.args.len != dim) return null;
            const used_axes: u32 = dim;

            var pattern = TextureCoordPattern{};
            var saw_tiled = false;
            var arg_index: u32 = 0;
            while (arg_index < used_axes) : (arg_index += 1) {
                const axis: usize = arg_index;
                const component = match_texture_coord_component(
                    function,
                    function.expr_args.items[construct.args.start + arg_index],
                    @intCast(arg_index),
                ) orelse return null;
                switch (component) {
                    .affine => |affine| {
                        pattern.multipliers[axis] = affine.multiplier;
                        pattern.offsets[axis] = affine.offset;
                    },
                    .tiled => |tiled| {
                        saw_tiled = true;
                        pattern.tile_widths[axis] = tiled.tile_width;
                        pattern.tile_strides[axis] = tiled.tile_stride;
                        pattern.offsets[axis] = tiled.offset;
                    },
                }
            }
            if (!saw_tiled) return pattern;

            var tiled_pattern = TextureCoordPattern{
                .family = .tiled,
            };
            var tiled_axis: u32 = 0;
            while (tiled_axis < used_axes) : (tiled_axis += 1) {
                const component = match_texture_coord_component(
                    function,
                    function.expr_args.items[construct.args.start + tiled_axis],
                    @intCast(tiled_axis),
                ) orelse return null;
                switch (component) {
                    .tiled => |tiled| {
                        const axis: usize = tiled_axis;
                        tiled_pattern.tile_widths[axis] = tiled.tile_width;
                        tiled_pattern.tile_strides[axis] = tiled.tile_stride;
                        tiled_pattern.offsets[axis] = tiled.offset;
                    },
                    .affine => |affine| {
                        if (affine.multiplier != 1 or affine.offset != 0) return null;
                    },
                }
            }
            return tiled_pattern;
        },
        else => {
            if (dim != 1) return null;
            var pattern = TextureCoordPattern{};
            switch (match_texture_coord_component(function, expr_id, 0) orelse return null) {
                .affine => |affine| {
                    pattern.multipliers[0] = affine.multiplier;
                    pattern.offsets[0] = affine.offset;
                },
                .tiled => |tiled| {
                    pattern.family = .tiled;
                    pattern.tile_widths[0] = tiled.tile_width;
                    pattern.tile_strides[0] = tiled.tile_stride;
                    pattern.offsets[0] = tiled.offset;
                },
            }
            return pattern;
        },
    }
}

fn texture_level_is_dispatch_fit_supported(
    function: *const ir.Function,
    tex_ty: ir.Type,
    call_data: @FieldType(ir.Expr, "call"),
) ?u32 {
    if (!std.mem.eql(u8, call_data.name, TEXTURE_LOAD_NAME)) return if (!texture_has_level(tex_ty)) 0 else null;
    if (!texture_has_level(tex_ty)) return 0;
    if (call_data.args.len < 3) return null;
    const level_arg = function.expr_args.items[call_data.args.start + 2];
    return match_u32_literal_value(function, level_arg);
}

fn try_elide_dispatch_fit_texture_coords(
    module: *const ir.Module,
    function: *const ir.Function,
    call_data: @FieldType(ir.Expr, "call"),
) ?ir.TextureDispatchPrecondition {
    if (!is_clamped_texture_builtin(call_data.name) or call_data.args.len < 2) return null;

    const texture_arg = function.expr_args.items[call_data.args.start];
    const coord_arg = function.expr_args.items[call_data.args.start + 1];
    const tex_ty = resolve_texture_type(&module.types, function.exprs.items[texture_arg].ty);
    const dim = dispatch_fit_texture_coord_dim(tex_ty) orelse return null;
    const is_load = std.mem.eql(u8, call_data.name, TEXTURE_LOAD_NAME);
    const level_arg = if (is_load and texture_has_level(tex_ty) and call_data.args.len >= 3)
        function.expr_args.items[call_data.args.start + 2]
    else
        null;
    if (texture_coord_is_explicitly_guarded(function, texture_arg, level_arg, coord_arg, dim)) return null;
    const mip_level = texture_level_is_dispatch_fit_supported(function, tex_ty, call_data) orelse return null;
    const pattern = match_texture_coord_pattern(function, coord_arg, dim) orelse return null;

    const binding = resolve_texture_binding(module, function, texture_arg) orelse return null;
    const kind: ir.TextureDispatchPreconditionKind = switch (dim) {
        1 => blk: {
            if (pattern.family == .tiled) {
                if (!lean_proof.boundsProven(.gid_texture_1d_tiled_dispatch_fit)) return null;
            } else if (texture_pattern_is_identity(pattern, dim)) {
                if (!lean_proof.boundsProven(.gid_texture_1d_dispatch_fit)) return null;
            } else if (!lean_proof.boundsProven(.gid_texture_1d_affine_dispatch_fit)) return null;
            break :blk .gid_coords_1d;
        },
        2 => blk: {
            if (pattern.family == .tiled) {
                if (!lean_proof.boundsProven(.gid_texture_2d_tiled_dispatch_fit)) return null;
            } else if (texture_pattern_is_identity(pattern, dim)) {
                if (!lean_proof.boundsProven(.gid_texture_2d_dispatch_fit)) return null;
            } else if (!lean_proof.boundsProven(.gid_texture_2d_affine_dispatch_fit)) return null;
            break :blk .gid_coords_2d;
        },
        3 => blk: {
            if (pattern.family == .tiled) {
                if (!lean_proof.boundsProven(.gid_texture_3d_tiled_dispatch_fit)) return null;
            } else if (texture_pattern_is_identity(pattern, dim)) {
                if (!lean_proof.boundsProven(.gid_texture_3d_dispatch_fit)) return null;
            } else if (!lean_proof.boundsProven(.gid_texture_3d_affine_dispatch_fit)) return null;
            break :blk .gid_coords_3d;
        },
        else => return null,
    };
    return .{
        .kind = kind,
        .texture_binding = binding,
        .mip_level = mip_level,
        .coord_mode = switch (pattern.family) {
            .affine => .affine,
            .tiled => .tiled,
        },
        .coord_multipliers = pattern.multipliers,
        .coord_offsets = pattern.offsets,
        .coord_tile_widths = pattern.tile_widths,
        .coord_tile_strides = pattern.tile_strides,
    };
}

fn classify_gid_coord_axes(function: *const ir.Function, expr_id: ir.ExprId, dim: u8) ?[3]bool {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const construct = switch (expr.data) {
        .construct => |value| value,
        else => return null,
    };
    if (construct.args.len != dim) return null;

    var axes = [_]bool{ false, false, false };
    var arg_index: u32 = 0;
    while (arg_index < construct.args.len) : (arg_index += 1) {
        const axis = classify_gid_scalar(function, function.expr_args.items[construct.args.start + arg_index]) orelse return null;
        axes[axis] = true;
    }
    return axes;
}

fn expr_values_equivalent(function: *const ir.Function, lhs: ir.ExprId, rhs: ir.ExprId) bool {
    const lhs_id = resolve_value_alias(function, lhs);
    const rhs_id = resolve_value_alias(function, rhs);
    if (lhs_id == rhs_id) return true;
    const lhs_expr = function.exprs.items[lhs_id];
    const rhs_expr = function.exprs.items[rhs_id];
    return switch (lhs_expr.data) {
        .global_ref => |lhs_global| rhs_expr.data == .global_ref and rhs_expr.data.global_ref == lhs_global,
        .local_ref => |lhs_local| rhs_expr.data == .local_ref and rhs_expr.data.local_ref == lhs_local,
        .param_ref => |lhs_param| rhs_expr.data == .param_ref and rhs_expr.data.param_ref == lhs_param,
        .int_lit => |lhs_value| rhs_expr.data == .int_lit and rhs_expr.data.int_lit == lhs_value,
        else => false,
    };
}

fn match_texture_dimensions_call(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    texture_arg: ir.ExprId,
    level_arg: ?ir.ExprId,
) bool {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    const call = switch (expr.data) {
        .call => |value| value,
        else => return false,
    };
    if (call.kind != .builtin or !std.mem.eql(u8, call.name, "textureDimensions")) return false;
    const expected_args: u32 = if (level_arg == null) 1 else 2;
    if (call.args.len != expected_args) return false;
    if (!expr_values_equivalent(function, function.expr_args.items[call.args.start], texture_arg)) return false;
    if (level_arg) |level| {
        return expr_values_equivalent(function, function.expr_args.items[call.args.start + 1], level);
    }
    return true;
}

fn guard_rhs_matches_texture_extent(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    texture_arg: ir.ExprId,
    level_arg: ?ir.ExprId,
    axis: u8,
) bool {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    return switch (expr.data) {
        .member => |member| member.field_index == axis and
            match_texture_dimensions_call(function, member.base, texture_arg, level_arg),
        .call => axis == 0 and match_texture_dimensions_call(function, expr_id, texture_arg, level_arg),
        else => false,
    };
}

fn collect_guarded_gid_axes(
    function: *const ir.Function,
    expr_id: ir.ExprId,
    texture_arg: ir.ExprId,
    level_arg: ?ir.ExprId,
    axes: *[3]bool,
) bool {
    const expr = function.exprs.items[resolve_value_alias(function, expr_id)];
    switch (expr.data) {
        .binary => |binary| switch (binary.op) {
            .logical_or => {
                const lhs_ok = collect_guarded_gid_axes(function, binary.lhs, texture_arg, level_arg, axes);
                const rhs_ok = collect_guarded_gid_axes(function, binary.rhs, texture_arg, level_arg, axes);
                return lhs_ok and rhs_ok;
            },
            .greater_equal => {
                const axis = classify_gid_scalar(function, binary.lhs) orelse return false;
                if (!guard_rhs_matches_texture_extent(function, binary.rhs, texture_arg, level_arg, axis)) {
                    return false;
                }
                axes[axis] = true;
                return true;
            },
            else => return false,
        },
        else => return false,
    }
}

fn stmt_is_return_only(function: *const ir.Function, stmt_id: ir.StmtId) bool {
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .return_ => return true,
        .block => |range| {
            if (range.len != 1) return false;
            return stmt_is_return_only(function, function.stmt_children.items[range.start]);
        },
        else => return false,
    }
}

fn function_has_root_gid_guard(
    function: *const ir.Function,
    texture_arg: ir.ExprId,
    level_arg: ?ir.ExprId,
    required_axes: [3]bool,
) bool {
    const root = function.stmts.items[function.root_stmt];
    const root_range = switch (root) {
        .block => |range| range,
        else => return false,
    };
    for (function.stmt_children.items[root_range.start .. root_range.start + root_range.len]) |child_id| {
        const child = function.stmts.items[child_id];
        const branch = switch (child) {
            .if_ => |value| value,
            else => continue,
        };
        if (branch.else_block != null) continue;
        if (!stmt_is_return_only(function, branch.then_block)) continue;

        var guarded_axes = [_]bool{ false, false, false };
        if (!collect_guarded_gid_axes(function, branch.cond, texture_arg, level_arg, &guarded_axes)) continue;

        var axis_index: usize = 0;
        while (axis_index < required_axes.len) : (axis_index += 1) {
            if (required_axes[axis_index] and !guarded_axes[axis_index]) break;
        } else {
            return true;
        }
    }
    return false;
}

fn texture_coord_is_explicitly_guarded(
    function: *const ir.Function,
    texture_arg: ir.ExprId,
    level_arg: ?ir.ExprId,
    coord_arg: ir.ExprId,
    dim: u8,
) bool {
    const required_axes = classify_gid_coord_axes(function, coord_arg, dim) orelse return false;
    return function_has_root_gid_guard(function, texture_arg, level_arg, required_axes);
}

/// Clamp coordinate arguments of textureLoad/textureStore to valid ranges.
///
/// For textureLoad(tex, coords, level):
///   coords = clamp(coords, vec(0), vec(textureDimensions(tex, level) - 1))
///
/// For textureStore(tex, coords, value):
///   coords = clamp(coords, vec(0), vec(textureDimensions(tex) - 1))
fn clamp_texture_coords(
    allocator: std.mem.Allocator,
    module: *ir.Module,
    function: *ir.Function,
    call_data: @FieldType(ir.Expr, "call"),
) TransformError!void {
    if (!is_clamped_texture_builtin(call_data.name)) return;
    if (call_data.args.len < 2) return;

    const texture_arg = function.expr_args.items[call_data.args.start];
    const coord_arg = function.expr_args.items[call_data.args.start + 1];
    const tex_ty = resolve_texture_type(&module.types, function.exprs.items[texture_arg].ty);
    const dim = texture_coord_dim(tex_ty) orelse return;
    const is_load = std.mem.eql(u8, call_data.name, TEXTURE_LOAD_NAME);
    const level_arg = if (is_load and texture_has_level(tex_ty) and call_data.args.len >= 3)
        function.expr_args.items[call_data.args.start + 2]
    else
        null;
    if (texture_coord_is_explicitly_guarded(function, texture_arg, level_arg, coord_arg, dim)) return;

    const coord_ty = function.exprs.items[coord_arg].ty;

    // 1D textures use a scalar u32 coordinate, not a vector.
    if (dim == 1) {
        try clamp_texture_coords_scalar(allocator, module, function, call_data, texture_arg, coord_arg, coord_ty, tex_ty);
        return;
    }

    const coord_elem_ty = switch (module.types.get(coord_ty)) {
        .vector => |vec| blk: {
            if (vec.len != dim) return;
            break :blk vec.elem;
        },
        else => return,
    };
    // Build textureDimensions(tex) or textureDimensions(tex, level)
    const td_id = blk: {
        if (level_arg) |texture_level_arg| {
            const td_args = try function.append_expr_args(allocator, &.{ texture_arg, texture_level_arg });
            break :blk try function.append_expr(allocator, .{
                .ty = coord_ty,
                .category = .value,
                .data = .{ .call = .{
                    .name = try ir.dup_string(allocator, "textureDimensions"),
                    .kind = .builtin,
                    .args = td_args,
                } },
            });
        } else {
            const td_args = try function.append_expr_args(allocator, &.{texture_arg});
            break :blk try function.append_expr(allocator, .{
                .ty = coord_ty,
                .category = .value,
                .data = .{ .call = .{
                    .name = try ir.dup_string(allocator, "textureDimensions"),
                    .kind = .builtin,
                    .args = td_args,
                } },
            });
        }
    };
    const td_cast_args = try function.append_expr_args(allocator, &.{td_id});
    const td_coord_id = try function.append_expr(allocator, .{
        .ty = coord_ty,
        .category = .value,
        .data = .{ .construct = .{ .ty = coord_ty, .args = td_cast_args } },
    });

    // vec<T, dim>(1), where T matches the original coordinate element type.
    const one_scalar = try function.append_expr(allocator, .{
        .ty = coord_elem_ty,
        .category = .value,
        .data = .{ .int_lit = 1 },
    });
    const splat_one_args = try function.append_expr_args(allocator, &.{one_scalar});
    const one_vec = try function.append_expr(allocator, .{
        .ty = coord_ty,
        .category = .value,
        .data = .{ .construct = .{ .ty = coord_ty, .args = splat_one_args } },
    });

    // textureDimensions - vec(1)
    const max_coord = try function.append_expr(allocator, .{
        .ty = coord_ty,
        .category = .value,
        .data = .{ .binary = .{ .op = .sub, .lhs = td_coord_id, .rhs = one_vec } },
    });

    // vec<T, dim>(0), where T matches the original coordinate element type.
    const zero_scalar = try function.append_expr(allocator, .{
        .ty = coord_elem_ty,
        .category = .value,
        .data = .{ .int_lit = 0 },
    });
    const splat_zero_args = try function.append_expr_args(allocator, &.{zero_scalar});
    const zero_vec = try function.append_expr(allocator, .{
        .ty = coord_ty,
        .category = .value,
        .data = .{ .construct = .{ .ty = coord_ty, .args = splat_zero_args } },
    });

    // clamp(coords, vec(0), textureDimensions - 1)
    const clamp_args = try function.append_expr_args(allocator, &.{ coord_arg, zero_vec, max_coord });
    const clamped_coord = try function.append_expr(allocator, .{
        .ty = coord_ty,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "clamp"),
            .kind = .builtin,
            .args = clamp_args,
        } },
    });

    // Replace the coordinate argument in the original call's arg list.
    function.expr_args.items[call_data.args.start + 1] = clamped_coord;
}

/// Clamp a scalar (1D) texture coordinate: min(coord, textureDimensions(tex, level) - 1)
fn clamp_texture_coords_scalar(
    allocator: std.mem.Allocator,
    module: *ir.Module,
    function: *ir.Function,
    call_data: @FieldType(ir.Expr, "call"),
    texture_arg: ir.ExprId,
    coord_arg: ir.ExprId,
    coord_ty: ir.TypeId,
    tex_ty: ir.Type,
) TransformError!void {
    const u32_ty = try ensure_u32_type(module);

    // Build textureDimensions(tex) or textureDimensions(tex, level)
    const td_id = blk: {
        const is_load = std.mem.eql(u8, call_data.name, TEXTURE_LOAD_NAME);
        if (is_load and texture_has_level(tex_ty) and call_data.args.len >= 3) {
            const level_arg = function.expr_args.items[call_data.args.start + 2];
            const td_args = try function.append_expr_args(allocator, &.{ texture_arg, level_arg });
            break :blk try function.append_expr(allocator, .{
                .ty = u32_ty,
                .category = .value,
                .data = .{ .call = .{
                    .name = try ir.dup_string(allocator, "textureDimensions"),
                    .kind = .builtin,
                    .args = td_args,
                } },
            });
        } else {
            const td_args = try function.append_expr_args(allocator, &.{texture_arg});
            break :blk try function.append_expr(allocator, .{
                .ty = u32_ty,
                .category = .value,
                .data = .{ .call = .{
                    .name = try ir.dup_string(allocator, "textureDimensions"),
                    .kind = .builtin,
                    .args = td_args,
                } },
            });
        }
    };

    // textureDimensions - 1
    const one_lit = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 1 },
    });
    const max_coord = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .binary = .{ .op = .sub, .lhs = td_id, .rhs = one_lit } },
    });

    // min(coord, textureDimensions - 1)
    const min_args = try function.append_expr_args(allocator, &.{ coord_arg, max_coord });
    const clamped_coord = try function.append_expr(allocator, .{
        .ty = coord_ty,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "min"),
            .kind = .builtin,
            .args = min_args,
        } },
    });

    // Replace the coordinate argument in the original call's arg list.
    function.expr_args.items[call_data.args.start + 1] = clamped_coord;
}

// Tests are in runtime/zig/tests/wgsl/ir_transform_robustness_test.zig.
