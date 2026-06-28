const std = @import("std");
const ir = @import("doe_wgsl/ir.zig");

pub const ValidationError = error{
    DispatchPreconditionFailed,
    Overflow,
};

pub fn required_buffer_bytes(
    precondition: ir.DispatchPrecondition,
    dispatch_workgroups: [3]u32,
    workgroup_size: [3]u32,
) ValidationError!u64 {
    return switch (precondition.kind) {
        .gid_component => blk: {
            const axis = precondition.gid_axis;
            if (axis >= dispatch_workgroups.len or axis >= workgroup_size.len) {
                return error.DispatchPreconditionFailed;
            }
            const total_invocations = try invocation_extent(dispatch_workgroups[axis], workgroup_size[axis]);
            // Empty dispatch touches nothing; no buffer capacity required.
            if (total_invocations == 0) break :blk 0;
            // Tight upper bound on the maximum accessed index, matching the
            // Lean theorem `gid_affine_plus_scaled_loop_index_inbounds_when_dispatch_fits_tight`:
            //   (total_invocations - 1) * element_multiplier
            //     + (loop_limit - 1) * loop_limit_multiplier
            //     + element_offset
            // is the strict supremum of `gid*em + i*lm + offset` when
            // gid < total and i < loop_limit; required buffer size is
            // (that max index + 1) * element_stride_bytes.
            //
            // Switching from the prior `total*em + limit*lm + offset` form
            // reclaims `em + lm - 1` elements of slack per dispatch, which
            // is what enables bounds elision on the AMD Vulkan matvec where
            // the buffer is packed to exactly `total*em` vec4<f32> entries.
            const max_gid_scaled = try std.math.mul(u64, total_invocations - 1, precondition.element_multiplier);
            const max_loop_scaled: u64 = if (precondition.loop_limit == 0)
                0
            else
                try std.math.mul(u64, precondition.loop_limit - 1, precondition.loop_limit_multiplier);
            const affine_max = try std.math.add(u64, max_gid_scaled, max_loop_scaled);
            const max_accessed = try std.math.add(u64, affine_max, precondition.element_offset);
            const total_elements = try std.math.add(u64, max_accessed, 1);
            break :blk try std.math.mul(u64, total_elements, precondition.element_stride_bytes);
        },
        .workgroup_component => blk: {
            const axis = precondition.gid_axis;
            if (axis >= dispatch_workgroups.len) {
                return error.DispatchPreconditionFailed;
            }
            const total_workgroups: u64 = dispatch_workgroups[axis];
            if (total_workgroups == 0) break :blk 0;
            const max_group_scaled = try std.math.mul(u64, total_workgroups - 1, precondition.element_multiplier);
            const max_loop_scaled: u64 = if (precondition.loop_limit == 0)
                0
            else
                try std.math.mul(u64, precondition.loop_limit - 1, precondition.loop_limit_multiplier);
            const affine_max = try std.math.add(u64, max_group_scaled, max_loop_scaled);
            const max_accessed = try std.math.add(u64, affine_max, precondition.element_offset);
            const total_elements = try std.math.add(u64, max_accessed, 1);
            break :blk try std.math.mul(u64, total_elements, precondition.element_stride_bytes);
        },
        .local_invocation_component => blk: {
            const axis = precondition.gid_axis;
            if (axis >= workgroup_size.len) {
                return error.DispatchPreconditionFailed;
            }
            const total_lanes: u64 = workgroup_size[axis];
            if (total_lanes == 0) break :blk 0;
            const max_lane_scaled = try std.math.mul(u64, total_lanes - 1, precondition.element_multiplier);
            const max_loop_scaled: u64 = if (precondition.loop_limit == 0)
                0
            else
                try std.math.mul(u64, precondition.loop_limit - 1, precondition.loop_limit_multiplier);
            const affine_max = try std.math.add(u64, max_lane_scaled, max_loop_scaled);
            const max_accessed = try std.math.add(u64, affine_max, precondition.element_offset);
            const total_elements = try std.math.add(u64, max_accessed, 1);
            break :blk try std.math.mul(u64, total_elements, precondition.element_stride_bytes);
        },
        .gid_component_tiled => blk: {
            const axis = precondition.gid_axis;
            if (axis >= dispatch_workgroups.len or axis >= workgroup_size.len) {
                return error.DispatchPreconditionFailed;
            }
            if (precondition.tile_width == 0) return error.DispatchPreconditionFailed;
            if (precondition.element_multiplier < precondition.tile_width) {
                return error.DispatchPreconditionFailed;
            }
            const total_invocations = try invocation_extent(dispatch_workgroups[axis], workgroup_size[axis]);
            const tiled_groups = try tiled_group_count(total_invocations, precondition.tile_width);
            const scaled_groups = try std.math.mul(u64, tiled_groups, precondition.element_multiplier);
            const total_elements = try std.math.add(u64, scaled_groups, precondition.element_offset);
            break :blk try std.math.mul(u64, total_elements, precondition.element_stride_bytes);
        },
        .flat_index_2d_dispatch_x => blk: {
            const total_x = try invocation_extent(dispatch_workgroups[0], workgroup_size[0]);
            const total_y = try invocation_extent(dispatch_workgroups[1], workgroup_size[1]);
            const element_count = try std.math.mul(u64, total_x, total_y);
            const total_elements = try std.math.add(u64, element_count, precondition.element_offset);
            break :blk try std.math.mul(u64, total_elements, precondition.element_stride_bytes);
        },
        .flat_index_3d_dispatch_xy => blk: {
            const total_x = try invocation_extent(dispatch_workgroups[0], workgroup_size[0]);
            const total_y = try invocation_extent(dispatch_workgroups[1], workgroup_size[1]);
            const total_z = try invocation_extent(dispatch_workgroups[2], workgroup_size[2]);
            const plane = try std.math.mul(u64, total_x, total_y);
            const element_count = try std.math.mul(u64, plane, total_z);
            const total_elements = try std.math.add(u64, element_count, precondition.element_offset);
            break :blk try std.math.mul(u64, total_elements, precondition.element_stride_bytes);
        },
        .uniform_extent => error.DispatchPreconditionFailed,
        .loop_component => blk: {
            // Pure loop-only: max accessed index is
            //   (loop_limit - 1) * loop_limit_multiplier + element_offset
            // per the Lean theorem `loop_index_affine_inbounds_when_loop_fits_tight`.
            // Empty loops touch nothing; no buffer capacity required.
            if (precondition.loop_limit == 0) break :blk 0;
            const max_loop_scaled = try std.math.mul(
                u64,
                precondition.loop_limit - 1,
                precondition.loop_limit_multiplier,
            );
            const max_accessed = try std.math.add(u64, max_loop_scaled, precondition.element_offset);
            const total_elements = try std.math.add(u64, max_accessed, 1);
            break :blk try std.math.mul(u64, total_elements, precondition.element_stride_bytes);
        },
    };
}

pub fn required_uniform_extent_buffer_bytes(
    precondition: ir.DispatchPrecondition,
    uniform_values: [2]u32,
) ValidationError!u64 {
    if (precondition.kind != .uniform_extent) return error.DispatchPreconditionFailed;
    if (precondition.uniform_u32_count == 0 or precondition.uniform_u32_count > uniform_values.len) {
        return error.DispatchPreconditionFailed;
    }
    var total_elements: u64 = 1;
    for (0..precondition.uniform_u32_count) |index| {
        total_elements = try std.math.mul(u64, total_elements, uniform_values[index]);
    }
    total_elements = try std.math.add(u64, total_elements, precondition.element_offset);
    return try std.math.mul(u64, total_elements, precondition.element_stride_bytes);
}

pub fn invocation_extent(dispatch_workgroups: u32, workgroup_size: u32) ValidationError!u64 {
    return std.math.mul(u64, dispatch_workgroups, workgroup_size) catch error.Overflow;
}

fn tiled_group_count(total_invocations: u64, tile_width: u64) ValidationError!u64 {
    if (tile_width == 0) return error.DispatchPreconditionFailed;
    if (total_invocations == 0) return 0;
    const truncated = try std.math.sub(u64, total_invocations, 1);
    const whole_tiles = truncated / tile_width;
    return std.math.add(u64, whole_tiles, 1) catch error.Overflow;
}

test "required_buffer_bytes computes gid component bound in bytes" {
    const required = try required_buffer_bytes(.{
        .kind = .gid_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 1,
        .loop_limit = 0,
        .loop_limit_multiplier = 0,
        .element_stride_bytes = 4,
        .element_offset = 0,
    }, .{ 8, 1, 1 }, .{ 64, 1, 1 });
    try std.testing.expectEqual(@as(u64, 2048), required);
}

test "required_buffer_bytes computes 2d flat dispatch bound in bytes" {
    const required = try required_buffer_bytes(.{
        .kind = .flat_index_2d_dispatch_x,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 1 },
        .element_multiplier = 1,
        .loop_limit = 0,
        .loop_limit_multiplier = 0,
        .element_stride_bytes = 16,
        .element_offset = 0,
    }, .{ 4, 3, 1 }, .{ 8, 2, 1 });
    try std.testing.expectEqual(@as(u64, 3072), required);
}

test "required_buffer_bytes computes 3d flat dispatch bound in bytes" {
    const required = try required_buffer_bytes(.{
        .kind = .flat_index_3d_dispatch_xy,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 1 },
        .element_multiplier = 1,
        .loop_limit = 0,
        .loop_limit_multiplier = 0,
        .element_stride_bytes = 4,
        .element_offset = 0,
    }, .{ 2, 3, 4 }, .{ 4, 5, 6 });
    try std.testing.expectEqual(@as(u64, 11520), required);
}

test "required_buffer_bytes accounts for affine gid offset" {
    const required = try required_buffer_bytes(.{
        .kind = .gid_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 1,
        .loop_limit = 0,
        .loop_limit_multiplier = 0,
        .element_stride_bytes = 4,
        .element_offset = 4,
    }, .{ 8, 1, 1 }, .{ 64, 1, 1 });
    try std.testing.expectEqual(@as(u64, 2064), required);
}

test "required_buffer_bytes accounts for affine gid multiplier and offset" {
    const required = try required_buffer_bytes(.{
        .kind = .gid_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 4,
        .loop_limit = 0,
        .loop_limit_multiplier = 0,
        .element_stride_bytes = 4,
        .element_offset = 2,
    }, .{ 8, 1, 1 }, .{ 64, 1, 1 });
    // Tight formula: (total-1)*em + offset + 1 = 511*4 + 2 + 1 = 2047; *stride=4 = 8188.
    // Prior over-approximate formula yielded 8200; the 12-byte reclaim is the
    // `em - 1 = 3` elements of slack eliminated by the tight precondition.
    try std.testing.expectEqual(@as(u64, 8188), required);
}

test "required_buffer_bytes accounts for tiled gid stride and offset" {
    const required = try required_buffer_bytes(.{
        .kind = .gid_component_tiled,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 8,
        .tile_width = 4,
        .loop_limit = 0,
        .loop_limit_multiplier = 0,
        .element_stride_bytes = 4,
        .element_offset = 3,
    }, .{ 8, 1, 1 }, .{ 8, 1, 1 });
    try std.testing.expectEqual(@as(u64, 524), required);
}

test "required_buffer_bytes accounts for affine loop contribution" {
    const required = try required_buffer_bytes(.{
        .kind = .gid_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 1,
        .loop_limit = 4,
        .loop_limit_multiplier = 3,
        .element_stride_bytes = 4,
        .element_offset = 2,
    }, .{ 8, 1, 1 }, .{ 8, 1, 1 });
    // Tight formula: (total-1)*em + (limit-1)*lm + offset + 1 = 63 + 9 + 2 + 1 = 75; *stride=4 = 300.
    // Prior over-approximate formula yielded 312; the 12-byte reclaim is the
    // `em + lm - 1 = 3` elements of slack eliminated by the tight precondition.
    try std.testing.expectEqual(@as(u64, 300), required);
}

test "required_buffer_bytes computes local invocation affine loop bound" {
    const required = try required_buffer_bytes(.{
        .kind = .local_invocation_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 8,
        .loop_limit = 8,
        .loop_limit_multiplier = 1,
        .element_stride_bytes = 4,
        .element_offset = 0,
    }, .{ 5, 1, 1 }, .{ 256, 1, 1 });
    // local_id.x is bounded by workgroup_size only:
    // (255 * 8) + (7 * 1) + 1 = 2048 elements; *stride=4 = 8192.
    try std.testing.expectEqual(@as(u64, 8192), required);
}

test "required_buffer_bytes computes loop-only bound independent of dispatch" {
    const required = try required_buffer_bytes(.{
        .kind = .loop_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 0,
        .loop_limit = 2048,
        .loop_limit_multiplier = 1,
        .element_stride_bytes = 4,
        .element_offset = 0,
    }, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    // Tight loop-only: (limit-1)*lm + offset + 1 = 2047 + 0 + 1 = 2048; *stride=4 = 8192.
    try std.testing.expectEqual(@as(u64, 8192), required);
}

test "required_uniform_extent_buffer_bytes multiplies uniform dimensions" {
    const required = try required_uniform_extent_buffer_bytes(.{
        .kind = .uniform_extent,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 1 },
        .element_stride_bytes = 4,
        .uniform_binding = .{ .group = 0, .binding = 0 },
        .uniform_u32_offsets = .{ 0, 4 },
        .uniform_u32_count = 2,
    }, .{ 8, 16 });
    try std.testing.expectEqual(@as(u64, 512), required);
}

test "required_buffer_bytes loop-only empty loop needs no capacity" {
    const required = try required_buffer_bytes(.{
        .kind = .loop_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 0,
        .loop_limit = 0,
        .loop_limit_multiplier = 1,
        .element_stride_bytes = 4,
        .element_offset = 7,
    }, .{ 1, 1, 1 }, .{ 1, 1, 1 });
    try std.testing.expectEqual(@as(u64, 0), required);
}
