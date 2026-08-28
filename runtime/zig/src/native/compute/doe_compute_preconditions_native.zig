const std = @import("std");
const builtin = @import("builtin");
const dispatch_preconditions = @import("../../core/compute/dispatch_preconditions.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const queue_submit_ops = @import("../../backend/dropin_queue_submit.zig");
const ir = @import("../../compiler/wgsl/ir/ir.zig");

pub const ValidationError = dispatch_preconditions.ValidationError;
const bridge = queue_submit_ops.metal_bridge;

fn failStoragePrecondition(reason: []const u8, group: u32, binding: u32) ValidationError {
    std.log.warn(
        "doe_compute_preconditions: storage dispatch precondition failed: {s} group={} binding={}",
        .{ reason, group, binding },
    );
    return error.DispatchPreconditionFailed;
}

fn failStorageExtentPrecondition(
    group: u32,
    binding: u32,
    required_bytes: u64,
    bound_bytes: u64,
    kind: ir.DispatchPreconditionKind,
) ValidationError {
    std.log.warn(
        "doe_compute_preconditions: storage dispatch precondition failed: requiredBytes={} boundBytes={} kind={s} group={} binding={}",
        .{ required_bytes, bound_bytes, @tagName(kind), group, binding },
    );
    return error.DispatchPreconditionFailed;
}

pub fn validate_bind_groups(
    preconditions: []const ir.DispatchPrecondition,
    texture_preconditions: []const ir.TextureDispatchPrecondition,
    bind_groups: []const ?*native_types.DoeBindGroup,
    dispatch_workgroups: [3]u32,
    workgroup_size: [3]u32,
) ValidationError!void {
    for (preconditions) |precondition| {
        const group = precondition.storage_binding.group;
        const binding = precondition.storage_binding.binding;
        if (group >= bind_groups.len) return failStoragePrecondition("group index out of range", group, binding);
        const bind_group = bind_groups[group] orelse return failStoragePrecondition("bind group missing", group, binding);
        if (binding >= bind_group.buffers.len) return failStoragePrecondition("binding index out of range", group, binding);
        if (bind_group.buffers[binding] == null) return failStoragePrecondition("buffer missing", group, binding);
        const required = if (precondition.kind == .uniform_extent)
            try required_uniform_extent_bytes(precondition, bind_groups)
        else
            try dispatch_preconditions.required_buffer_bytes(precondition, dispatch_workgroups, workgroup_size);
        if (required > bind_group.buffer_sizes[binding]) {
            return failStorageExtentPrecondition(
                group,
                binding,
                required,
                bind_group.buffer_sizes[binding],
                precondition.kind,
            );
        }
    }
    for (texture_preconditions) |precondition| {
        const group = precondition.texture_binding.group;
        const binding = precondition.texture_binding.binding;
        if (group >= bind_groups.len) return error.DispatchPreconditionFailed;
        const bind_group = bind_groups[group] orelse return error.DispatchPreconditionFailed;
        if (binding >= bind_group.texture_views.len) return error.DispatchPreconditionFailed;
        const raw_view = bind_group.texture_views[binding] orelse return error.DispatchPreconditionFailed;
        const view = native_helpers.cast(native_types.DoeTextureView, raw_view) orelse return error.DispatchPreconditionFailed;
        const required_x = try required_texture_axis_extent(precondition, 0, dispatch_workgroups, workgroup_size);
        if (required_x > mip_extent(view.tex.width, precondition.mip_level)) return error.DispatchPreconditionFailed;
        const axis_count: u8 = switch (precondition.kind) {
            .gid_coords_1d => 1,
            .gid_coords_2d => 2,
            .gid_coords_3d => 3,
        };
        if (axis_count >= 2) {
            const required_y = try required_texture_axis_extent(precondition, 1, dispatch_workgroups, workgroup_size);
            if (required_y > mip_extent(view.tex.height, precondition.mip_level)) return error.DispatchPreconditionFailed;
        }
        if (axis_count >= 3) {
            const required_z = try required_texture_axis_extent(precondition, 2, dispatch_workgroups, workgroup_size);
            if (required_z > mip_extent(view.tex.depth_or_array_layers, precondition.mip_level)) return error.DispatchPreconditionFailed;
        }
    }
}

fn required_uniform_extent_bytes(
    precondition: ir.DispatchPrecondition,
    bind_groups: []const ?*native_types.DoeBindGroup,
) ValidationError!u64 {
    const group = precondition.uniform_binding.group;
    const binding = precondition.uniform_binding.binding;
    if (group >= bind_groups.len) return error.DispatchPreconditionFailed;
    const bind_group = bind_groups[group] orelse return error.DispatchPreconditionFailed;
    if (binding >= bind_group.retained_buffers.len) return error.DispatchPreconditionFailed;
    const buffer = bind_group.retained_buffers[binding] orelse return error.DispatchPreconditionFailed;
    const contents = bufferContents(buffer) orelse return error.DispatchPreconditionFailed;
    var values = [_]u32{ 0, 0 };
    for (0..precondition.uniform_u32_count) |index| {
        const byte_offset = try std.math.add(u64, bind_group.offsets[binding], precondition.uniform_u32_offsets[index]);
        const end_offset = try std.math.add(u64, byte_offset, @sizeOf(u32));
        if (end_offset > buffer.size) return error.DispatchPreconditionFailed;
        const ptr: *align(1) const u32 = @ptrCast(contents + @as(usize, @intCast(byte_offset)));
        values[index] = ptr.*;
    }
    return dispatch_preconditions.required_uniform_extent_buffer_bytes(precondition, values);
}

fn bufferContents(buffer: *const native_types.DoeBuffer) ?[*]u8 {
    if (buffer.vk_mapped_ptr) |mapped_ptr| return mapped_ptr;
    if (buffer.d3d12_mapped_ptr) |mapped_ptr| return @ptrCast(mapped_ptr);
    if (builtin.os.tag == .macos) return bridge.metal_bridge_buffer_contents(buffer.mtl);
    return null;
}

fn required_texture_axis_extent(
    precondition: ir.TextureDispatchPrecondition,
    axis: usize,
    dispatch_workgroups: [3]u32,
    workgroup_size: [3]u32,
) ValidationError!u64 {
    if (axis >= dispatch_workgroups.len or axis >= workgroup_size.len) {
        return error.DispatchPreconditionFailed;
    }
    const invocations = try dispatch_preconditions.invocation_extent(dispatch_workgroups[axis], workgroup_size[axis]);
    return switch (precondition.coord_mode) {
        .affine => blk: {
            const scaled = try std.math.mul(u64, invocations, precondition.coord_multipliers[axis]);
            break :blk try std.math.add(u64, scaled, precondition.coord_offsets[axis]);
        },
        .tiled => blk: {
            const tile_width = precondition.coord_tile_widths[axis];
            const tile_stride = precondition.coord_tile_strides[axis];
            if (tile_width == 0 or tile_stride < tile_width) return error.DispatchPreconditionFailed;
            const tiled_groups = try tiled_group_count(invocations, tile_width);
            const scaled = try std.math.mul(u64, tiled_groups, tile_stride);
            break :blk try std.math.add(u64, scaled, precondition.coord_offsets[axis]);
        },
    };
}

fn mip_extent(base: u32, level: u32) u64 {
    if (base == 0) return 0;
    if (level >= 31) return 1;
    const shifted = base >> @intCast(level);
    return if (shifted > 0) shifted else 1;
}

fn tiled_group_count(total_invocations: u64, tile_width: u64) ValidationError!u64 {
    if (tile_width == 0) return error.DispatchPreconditionFailed;
    if (total_invocations == 0) return 0;
    const truncated = try std.math.sub(u64, total_invocations, 1);
    const whole_tiles = truncated / tile_width;
    return std.math.add(u64, whole_tiles, 1) catch error.Overflow;
}

test "validate_bind_groups accepts matching gid component coverage" {
    var bind_group = native_types.DoeBindGroup{};
    bind_group.buffers[0] = @ptrFromInt(1);
    bind_group.buffer_sizes[0] = 2048;

    try validate_bind_groups(&.{.{
        .kind = .gid_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 1,
        .element_stride_bytes = 4,
        .element_offset = 0,
    }}, &.{}, &.{&bind_group}, .{ 8, 1, 1 }, .{ 64, 1, 1 });
}

test "validate_bind_groups rejects undersized 2d flat coverage" {
    var bind_group = native_types.DoeBindGroup{};
    bind_group.buffers[1] = @ptrFromInt(1);
    bind_group.buffer_sizes[1] = 2047;

    try std.testing.expectError(error.DispatchPreconditionFailed, validate_bind_groups(&.{.{
        .kind = .flat_index_2d_dispatch_x,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 1 },
        .element_multiplier = 1,
        .element_stride_bytes = 16,
        .element_offset = 0,
    }}, &.{}, &.{&bind_group}, .{ 4, 3, 1 }, .{ 8, 2, 1 }));
}

test "validate_bind_groups accepts affine gid multiplier coverage" {
    var bind_group = native_types.DoeBindGroup{};
    bind_group.buffers[0] = @ptrFromInt(1);
    bind_group.buffer_sizes[0] = 8200;

    try validate_bind_groups(&.{.{
        .kind = .gid_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 4,
        .element_stride_bytes = 4,
        .element_offset = 2,
    }}, &.{}, &.{&bind_group}, .{ 8, 1, 1 }, .{ 64, 1, 1 });
}

test "validate_bind_groups accepts tiled gid coverage" {
    var bind_group = native_types.DoeBindGroup{};
    bind_group.buffers[0] = @ptrFromInt(1);
    bind_group.buffer_sizes[0] = 524;

    try validate_bind_groups(&.{.{
        .kind = .gid_component_tiled,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 8,
        .tile_width = 4,
        .element_stride_bytes = 4,
        .element_offset = 3,
    }}, &.{}, &.{&bind_group}, .{ 8, 1, 1 }, .{ 8, 1, 1 });
}

test "validate_bind_groups accepts matching 2d texture coverage" {
    var texture = native_types.DoeTexture{
        .width = 64,
        .height = 32,
    };
    var view = native_types.DoeTextureView{
        .tex = &texture,
    };
    var bind_group = native_types.DoeBindGroup{};
    bind_group.texture_views[0] = native_helpers.toOpaque(&view);

    try validate_bind_groups(&.{}, &.{.{
        .kind = .gid_coords_2d,
        .texture_binding = .{ .group = 0, .binding = 0 },
        .mip_level = 0,
    }}, &.{&bind_group}, .{ 8, 4, 1 }, .{ 8, 8, 1 });
}

test "validate_bind_groups accepts affine 2d texture coverage at mip level" {
    var texture = native_types.DoeTexture{
        .width = 256,
        .height = 128,
    };
    var view = native_types.DoeTextureView{
        .tex = &texture,
    };
    var bind_group = native_types.DoeBindGroup{};
    bind_group.texture_views[0] = native_helpers.toOpaque(&view);

    try validate_bind_groups(&.{}, &.{.{
        .kind = .gid_coords_2d,
        .texture_binding = .{ .group = 0, .binding = 0 },
        .mip_level = 1,
        .coord_mode = .affine,
        .coord_multipliers = .{ 2, 3, 1 },
        .coord_offsets = .{ 4, 5, 0 },
    }}, &.{&bind_group}, .{ 4, 2, 1 }, .{ 8, 8, 1 });
}

test "validate_bind_groups accepts tiled 1d texture coverage" {
    var texture = native_types.DoeTexture{
        .width = 72,
    };
    var view = native_types.DoeTextureView{
        .tex = &texture,
    };
    var bind_group = native_types.DoeBindGroup{};
    bind_group.texture_views[0] = native_helpers.toOpaque(&view);

    try validate_bind_groups(&.{}, &.{.{
        .kind = .gid_coords_1d,
        .texture_binding = .{ .group = 0, .binding = 0 },
        .mip_level = 0,
        .coord_mode = .tiled,
        .coord_offsets = .{ 3, 0, 0 },
        .coord_tile_widths = .{ 4, 1, 1 },
        .coord_tile_strides = .{ 8, 1, 1 },
    }}, &.{&bind_group}, .{ 8, 1, 1 }, .{ 4, 1, 1 });
}

test "validate_bind_groups rejects undersized 2d texture coverage" {
    var texture = native_types.DoeTexture{
        .width = 63,
        .height = 32,
    };
    var view = native_types.DoeTextureView{
        .tex = &texture,
    };
    var bind_group = native_types.DoeBindGroup{};
    bind_group.texture_views[0] = native_helpers.toOpaque(&view);

    try std.testing.expectError(error.DispatchPreconditionFailed, validate_bind_groups(&.{}, &.{.{
        .kind = .gid_coords_2d,
        .texture_binding = .{ .group = 0, .binding = 0 },
        .mip_level = 0,
    }}, &.{&bind_group}, .{ 8, 4, 1 }, .{ 8, 8, 1 }));
}

test "validate_bind_groups rejects missing storage binding" {
    var bind_group = native_types.DoeBindGroup{};

    try std.testing.expectError(error.DispatchPreconditionFailed, validate_bind_groups(&.{.{
        .kind = .gid_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 1,
        .element_stride_bytes = 4,
        .element_offset = 0,
    }}, &.{}, &.{&bind_group}, .{ 8, 1, 1 }, .{ 64, 1, 1 }));
}

test "validate_bind_groups accepts matching 1d texture coverage" {
    var texture = native_types.DoeTexture{
        .width = 64,
    };
    var view = native_types.DoeTextureView{
        .tex = &texture,
    };
    var bind_group = native_types.DoeBindGroup{};
    bind_group.texture_views[0] = native_helpers.toOpaque(&view);

    try validate_bind_groups(&.{}, &.{.{
        .kind = .gid_coords_1d,
        .texture_binding = .{ .group = 0, .binding = 0 },
        .mip_level = 0,
    }}, &.{&bind_group}, .{ 8, 1, 1 }, .{ 8, 1, 1 });
}

test "validate_bind_groups rejects undersized 3d texture mip coverage" {
    var texture = native_types.DoeTexture{
        .width = 64,
        .height = 64,
        .depth_or_array_layers = 3,
    };
    var view = native_types.DoeTextureView{
        .tex = &texture,
    };
    var bind_group = native_types.DoeBindGroup{};
    bind_group.texture_views[0] = native_helpers.toOpaque(&view);

    try std.testing.expectError(error.DispatchPreconditionFailed, validate_bind_groups(&.{}, &.{.{
        .kind = .gid_coords_3d,
        .texture_binding = .{ .group = 0, .binding = 0 },
        .mip_level = 1,
    }}, &.{&bind_group}, .{ 2, 2, 2 }, .{ 8, 8, 2 }));
}
