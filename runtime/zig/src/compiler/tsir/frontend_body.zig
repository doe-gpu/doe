const std = @import("std");
const ir = @import("../wgsl/ir/ir.zig");
const layout_utils = @import("../wgsl/ir/layout_utils.zig");
const tsir = @import("mod.zig");

const FrontendBodyError = error{
    OutOfMemory,
};

pub fn inferSemanticBody(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    hint: tsir.schema.KernelFamilyHint,
    axes: []const tsir.schema.IterationAxis,
    bindings: []const tsir.schema.BufferBinding,
    reductions: []const tsir.schema.ReductionRegion,
) FrontendBodyError!tsir.schema.SemanticBody {
    if (hint == .fused_gemv and axes.len >= 2 and bindings.len >= 3 and reductions.len >= 1) {
        const binding_roles = try allocator.alloc(tsir.schema.SemanticBodyBinding, 3);
        binding_roles[0] = .{ .binding_index = 0, .role = .matrix };
        binding_roles[1] = .{ .binding_index = 1, .role = .vector };
        binding_roles[2] = .{ .binding_index = 2, .role = .output };
        const axis_roles = try allocator.alloc(tsir.schema.SemanticBodyAxis, 2);
        axis_roles[0] = .{ .axis_index = 0, .role = .output };
        axis_roles[1] = .{ .axis_index = reductions[0].axis, .role = .reduction };
        return .{ .op = .fused_gemv, .binding_roles = binding_roles, .axis_roles = axis_roles };
    }

    if (hint == .gather and axes.len >= 2 and bindings.len >= 3) {
        const binding_roles = try allocator.alloc(tsir.schema.SemanticBodyBinding, 3);
        binding_roles[0] = .{ .binding_index = 0, .role = .indices };
        binding_roles[1] = .{ .binding_index = 1, .role = .table };
        binding_roles[2] = .{ .binding_index = 2, .role = .output };
        const axis_roles = try allocator.alloc(tsir.schema.SemanticBodyAxis, 2);
        axis_roles[0] = .{ .axis_index = 0, .role = .token };
        axis_roles[1] = .{ .axis_index = 1, .role = .hidden };
        return .{ .op = .gather, .binding_roles = binding_roles, .axis_roles = axis_roles };
    }

    if (looksLikeRmsNorm(axes, bindings, reductions)) {
        const epsilon = (try inferRmsNormEpsilon(
            allocator,
            module,
            bindings,
            axes[0].upper_bound,
        )) orelse return .{};
        const binding_roles = try allocator.alloc(tsir.schema.SemanticBodyBinding, 3);
        binding_roles[0] = .{ .binding_index = 0, .role = .input };
        binding_roles[1] = .{ .binding_index = 1, .role = .scale };
        binding_roles[2] = .{ .binding_index = 2, .role = .output };
        const axis_roles = try allocator.alloc(tsir.schema.SemanticBodyAxis, 2);
        axis_roles[0] = .{ .axis_index = 0, .role = .hidden };
        axis_roles[1] = .{ .axis_index = reductions[0].axis, .role = .reduction };
        const rms_norm = tsir.schema.RmsNormBody{
            .formula = .sum_squares_mean_epsilon_rsqrt_scale,
            .epsilon = epsilon,
            .hidden_extent_axis = 0,
            .reduction_target = .intermediate_scalar,
        };
        return .{
            .op = .rms_norm,
            .binding_roles = binding_roles,
            .axis_roles = axis_roles,
            .rms_norm = rms_norm,
        };
    }

    return .{};
}

fn looksLikeRmsNorm(
    axes: []const tsir.schema.IterationAxis,
    bindings: []const tsir.schema.BufferBinding,
    reductions: []const tsir.schema.ReductionRegion,
) bool {
    if (axes.len < 2 or bindings.len < 3 or reductions.len != 1) return false;
    if (reductions[0].op != .sum) return false;
    if (reductions[0].axis >= axes.len) return false;
    if (!std.mem.eql(u8, axes[0].upper_bound, axes[reductions[0].axis].upper_bound)) return false;
    return bindingNameEquals(bindings[0], "input") and
        (bindingNameEquals(bindings[1], "weight") or bindingNameEquals(bindings[1], "scale")) and
        bindingNameEquals(bindings[2], "output");
}

fn bindingNameEquals(binding: tsir.schema.BufferBinding, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(binding.name, expected);
}

fn inferRmsNormEpsilon(
    allocator: std.mem.Allocator,
    module: *const ir.Module,
    bindings: []const tsir.schema.BufferBinding,
    hidden_extent_bound: []const u8,
) FrontendBodyError!?tsir.schema.RmsNormEpsilon {
    const epsilon_path = try inferRmsNormEpsilonPath(allocator, hidden_extent_bound);
    const path = splitUniformPath(epsilon_path) orelse {
        allocator.free(epsilon_path);
        return null;
    };
    const binding_index = findBindingIndexByName(bindings, path.binding_name) orelse {
        allocator.free(epsilon_path);
        return null;
    };
    const byte_offset = inferUniformFieldOffset(module, path.binding_name, path.field_name) orelse {
        allocator.free(epsilon_path);
        return null;
    };

    return .{
        .source = .uniform_field,
        .path = epsilon_path,
        .binding_index = binding_index,
        .byte_offset = byte_offset,
        .literal_f32 = null,
    };
}

fn inferRmsNormEpsilonPath(
    allocator: std.mem.Allocator,
    hidden_extent_bound: []const u8,
) FrontendBodyError![]const u8 {
    if (std.mem.startsWith(u8, hidden_extent_bound, "uniform:")) {
        if (std.mem.lastIndexOfScalar(u8, hidden_extent_bound, '.')) |dot| {
            return std.fmt.allocPrint(allocator, "{s}eps", .{hidden_extent_bound[0 .. dot + 1]});
        }
    }
    return allocator.dupe(u8, "uniform:u.eps");
}

const UniformPath = struct {
    binding_name: []const u8,
    field_name: []const u8,
};

fn splitUniformPath(path: []const u8) ?UniformPath {
    const prefix = "uniform:";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    if (dot == 0 or dot + 1 >= rest.len) return null;
    return .{
        .binding_name = rest[0..dot],
        .field_name = rest[dot + 1 ..],
    };
}

fn findBindingIndexByName(
    bindings: []const tsir.schema.BufferBinding,
    name: []const u8,
) ?u32 {
    for (bindings, 0..) |binding, i| {
        if (std.mem.eql(u8, binding.name, name)) return @intCast(i);
    }
    return null;
}

fn inferUniformFieldOffset(
    module: *const ir.Module,
    global_name: []const u8,
    field_name: []const u8,
) ?u32 {
    for (module.globals.items) |global| {
        if (!std.mem.eql(u8, global.name, global_name)) continue;
        var ty = global.ty;
        const maybe_ref = module.types.get(ty);
        if (maybe_ref == .ref) ty = maybe_ref.ref.elem;
        const type_info = module.types.get(ty);
        if (type_info != .struct_) return null;
        const struct_def = module.structs.items[type_info.struct_];
        for (struct_def.fields.items, 0..) |field, i| {
            if (!std.mem.eql(u8, field.name, field_name)) continue;
            if (!ir.is_scalar(&module.types, field.ty, .f32)) return null;
            return layout_utils.struct_field_offset(module, struct_def, @intCast(i));
        }
        return null;
    }
    return null;
}
