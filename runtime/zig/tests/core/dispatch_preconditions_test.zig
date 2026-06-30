// dispatch_preconditions_test.zig — Tests for compute dispatch precondition
// enforcement.
//
// Validates required_buffer_bytes and invocation_extent from
// dispatch_preconditions.zig across all DispatchPreconditionKind variants,
// including boundary conditions (zero dispatch, overflow, tiled groups).

const std = @import("std");
const testing = std.testing;

const dispatch = @import("../../src/dispatch_preconditions.zig");
const ir = @import("../../src/doe_wgsl/ir.zig");

const Precondition = ir.DispatchPrecondition;

// Helper to build a default gid_component precondition with overrides.
fn gidPrecondition(overrides: struct {
    axis: u8 = 0,
    multiplier: u64 = 1,
    loop_limit: u64 = 0,
    loop_limit_multiplier: u64 = 0,
    stride_bytes: u64 = 4,
    offset: u64 = 0,
}) Precondition {
    return .{
        .kind = .gid_component,
        .gid_axis = overrides.axis,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = overrides.multiplier,
        .loop_limit = overrides.loop_limit,
        .loop_limit_multiplier = overrides.loop_limit_multiplier,
        .element_stride_bytes = overrides.stride_bytes,
        .element_offset = overrides.offset,
    };
}

fn tiledPrecondition(overrides: struct {
    axis: u8 = 0,
    tile_stride: u64 = 8,
    tile_width: u64 = 4,
    stride_bytes: u64 = 4,
    offset: u64 = 0,
}) Precondition {
    return .{
        .kind = .gid_component_tiled,
        .gid_axis = overrides.axis,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = overrides.tile_stride,
        .tile_width = overrides.tile_width,
        .loop_limit = 0,
        .loop_limit_multiplier = 0,
        .element_stride_bytes = overrides.stride_bytes,
        .element_offset = overrides.offset,
    };
}

fn workgroupPrecondition(overrides: struct {
    axis: u8 = 0,
    multiplier: u64 = 1,
    stride_bytes: u64 = 4,
    offset: u64 = 0,
}) Precondition {
    return .{
        .kind = .workgroup_component,
        .gid_axis = overrides.axis,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = overrides.multiplier,
        .loop_limit = 0,
        .loop_limit_multiplier = 0,
        .element_stride_bytes = overrides.stride_bytes,
        .element_offset = overrides.offset,
    };
}

fn flat2dPrecondition(overrides: struct {
    stride_bytes: u64 = 4,
    offset: u64 = 0,
}) Precondition {
    return .{
        .kind = .flat_index_2d_dispatch_x,
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_multiplier = 1,
        .loop_limit = 0,
        .loop_limit_multiplier = 0,
        .element_stride_bytes = overrides.stride_bytes,
        .element_offset = overrides.offset,
    };
}

// ============================================================
// invocation_extent — basic multiplication
// ============================================================

test "invocation_extent: 8 workgroups * 64 workgroup size = 512" {
    const result = try dispatch.invocation_extent(8, 64);
    try testing.expectEqual(@as(u64, 512), result);
}

test "invocation_extent: 1 workgroup * 1 workgroup size = 1" {
    const result = try dispatch.invocation_extent(1, 1);
    try testing.expectEqual(@as(u64, 1), result);
}

test "invocation_extent: zero workgroups yields zero" {
    const result = try dispatch.invocation_extent(0, 64);
    try testing.expectEqual(@as(u64, 0), result);
}

test "invocation_extent: zero workgroup size yields zero" {
    const result = try dispatch.invocation_extent(8, 0);
    try testing.expectEqual(@as(u64, 0), result);
}

test "invocation_extent: both zero yields zero" {
    const result = try dispatch.invocation_extent(0, 0);
    try testing.expectEqual(@as(u64, 0), result);
}

test "invocation_extent: u32 max values do not overflow u64" {
    // u32 max * u32 max fits in u64 (4294967295 * 4294967295 < 2^64).
    const result = try dispatch.invocation_extent(std.math.maxInt(u32), std.math.maxInt(u32));
    const expected: u64 = @as(u64, std.math.maxInt(u32)) * @as(u64, std.math.maxInt(u32));
    try testing.expectEqual(expected, result);
}

// ============================================================
// Valid dispatch — gid_component kind
// ============================================================

test "valid dispatch: simple 1D gid component" {
    // 8 workgroups * 64 threads = 512 invocations, *4 bytes = 2048
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{}),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 2048), result);
}

test "valid dispatch: y-axis gid component" {
    // axis=1: 4 workgroups * 16 threads = 64 invocations, *4 bytes = 256
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{ .axis = 1 }),
        .{ 1, 4, 1 },
        .{ 1, 16, 1 },
    );
    try testing.expectEqual(@as(u64, 256), result);
}

test "valid dispatch: z-axis gid component" {
    // axis=2: 2 workgroups * 8 threads = 16 invocations, *4 bytes = 64
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{ .axis = 2 }),
        .{ 1, 1, 2 },
        .{ 1, 1, 8 },
    );
    try testing.expectEqual(@as(u64, 64), result);
}

test "valid dispatch: gid component with element offset" {
    // 512 invocations + 4 offset = 516 elements, *4 bytes = 2064
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{ .offset = 4 }),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 2064), result);
}

test "valid dispatch: gid component with multiplier" {
    // Tight formula: (511)*4 + 0 + 1 = 2045 elements; *4 bytes = 8180.
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{ .multiplier = 4 }),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 8180), result);
}

test "valid dispatch: gid component with multiplier and offset" {
    // Tight formula: (511)*4 + 2 + 1 = 2047 elements; *4 bytes = 8188.
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{ .multiplier = 4, .offset = 2 }),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 8188), result);
}

test "valid dispatch: gid component with loop contribution" {
    // Tight formula: (63)*1 + (3)*3 + 2 + 1 = 75 elements; *4 bytes = 300.
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{
            .loop_limit = 4,
            .loop_limit_multiplier = 3,
            .offset = 2,
        }),
        .{ 8, 1, 1 },
        .{ 8, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 300), result);
}

test "valid dispatch: gid component 16-byte stride" {
    // 512 invocations * 16 bytes = 8192
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{ .stride_bytes = 16 }),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 8192), result);
}

// ============================================================
// Zero dispatch — gid_component kind
// ============================================================

test "zero dispatch x=0: zero buffer bytes required" {
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{}),
        .{ 0, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 0), result);
}

test "zero dispatch workgroup_size=0: zero buffer bytes required" {
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{}),
        .{ 8, 1, 1 },
        .{ 0, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 0), result);
}

test "zero dispatch with offset: only offset contributes" {
    // Empty dispatch touches no elements even with a configured offset, so the
    // precondition requires zero buffer capacity. Tight formula short-circuits
    // when total_invocations == 0.
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{ .offset = 5 }),
        .{ 0, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 0), result);
}

test "all-zero dispatch triple: zero buffer bytes" {
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{}),
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
    );
    try testing.expectEqual(@as(u64, 0), result);
}

// ============================================================
// Invalid axis — gid_component kind
// ============================================================

test "invalid gid_axis=3 returns DispatchPreconditionFailed" {
    const result = dispatch.required_buffer_bytes(
        gidPrecondition(.{ .axis = 3 }),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectError(error.DispatchPreconditionFailed, result);
}

test "invalid gid_axis=255 returns DispatchPreconditionFailed" {
    const result = dispatch.required_buffer_bytes(
        gidPrecondition(.{ .axis = 255 }),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectError(error.DispatchPreconditionFailed, result);
}

// ============================================================
// Tiled gid — gid_component_tiled kind
// ============================================================

test "tiled dispatch: basic tiled gid stride and offset" {
    // 8 workgroups * 8 threads = 64 invocations
    // tiled_groups = ceil(64/4) = 16
    // 16 * 8 tile_stride + 3 offset = 131 elements, *4 bytes = 524
    const result = try dispatch.required_buffer_bytes(
        tiledPrecondition(.{ .offset = 3 }),
        .{ 8, 1, 1 },
        .{ 8, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 524), result);
}

test "tiled dispatch: single invocation" {
    // 1 invocation, tiled_groups = ceil(1/4) = 1
    // 1 * 8 + 0 = 8 elements, *4 = 32
    const result = try dispatch.required_buffer_bytes(
        tiledPrecondition(.{}),
        .{ 1, 1, 1 },
        .{ 1, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 32), result);
}

test "tiled dispatch: zero invocations yields zero" {
    const result = try dispatch.required_buffer_bytes(
        tiledPrecondition(.{}),
        .{ 0, 1, 1 },
        .{ 1, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 0), result);
}

test "tiled dispatch: tile_width=0 returns DispatchPreconditionFailed" {
    const result = dispatch.required_buffer_bytes(
        tiledPrecondition(.{ .tile_width = 0 }),
        .{ 8, 1, 1 },
        .{ 8, 1, 1 },
    );
    try testing.expectError(error.DispatchPreconditionFailed, result);
}

test "tiled dispatch: tile_stride < tile_width returns DispatchPreconditionFailed" {
    // element_multiplier (tile_stride) must be >= tile_width
    const result = dispatch.required_buffer_bytes(
        tiledPrecondition(.{ .tile_stride = 3, .tile_width = 4 }),
        .{ 8, 1, 1 },
        .{ 8, 1, 1 },
    );
    try testing.expectError(error.DispatchPreconditionFailed, result);
}

test "tiled dispatch: exact tile boundary" {
    // 64 invocations / 4 tile_width = 16 exact tiles
    // 16 * 8 = 128 elements, *4 = 512
    const result = try dispatch.required_buffer_bytes(
        tiledPrecondition(.{}),
        .{ 8, 1, 1 },
        .{ 8, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 512), result);
}

test "tiled dispatch: non-exact tile boundary rounds up" {
    // 65 invocations / 4 tile_width = ceil(65/4) = 17 groups
    // 17 * 8 = 136 elements, *4 = 544
    const result = try dispatch.required_buffer_bytes(
        tiledPrecondition(.{}),
        .{ 65, 1, 1 },
        .{ 1, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 544), result);
}

// ============================================================
// 2D flat dispatch — flat_index_2d_dispatch_x kind
// ============================================================

test "flat 2d dispatch: basic x*y buffer bytes" {
    // x: 4 wg * 8 ws = 32, y: 3 wg * 2 ws = 6
    // 32 * 6 = 192 elements, *16 bytes = 3072
    const result = try dispatch.required_buffer_bytes(
        flat2dPrecondition(.{ .stride_bytes = 16 }),
        .{ 4, 3, 1 },
        .{ 8, 2, 1 },
    );
    try testing.expectEqual(@as(u64, 3072), result);
}

test "flat 2d dispatch: with element offset" {
    // x: 4 * 8 = 32, y: 3 * 2 = 6 => 192 + 10 = 202 elements, *4 = 808
    const result = try dispatch.required_buffer_bytes(
        flat2dPrecondition(.{ .offset = 10 }),
        .{ 4, 3, 1 },
        .{ 8, 2, 1 },
    );
    try testing.expectEqual(@as(u64, 808), result);
}

test "flat 2d dispatch: zero x dimension" {
    const result = try dispatch.required_buffer_bytes(
        flat2dPrecondition(.{}),
        .{ 0, 3, 1 },
        .{ 8, 2, 1 },
    );
    try testing.expectEqual(@as(u64, 0), result);
}

test "flat 2d dispatch: zero y dimension" {
    const result = try dispatch.required_buffer_bytes(
        flat2dPrecondition(.{}),
        .{ 4, 0, 1 },
        .{ 8, 2, 1 },
    );
    try testing.expectEqual(@as(u64, 0), result);
}

test "flat 2d dispatch: 1x1 dispatch" {
    // 1 * 1 = 1 element, *4 = 4 bytes
    const result = try dispatch.required_buffer_bytes(
        flat2dPrecondition(.{}),
        .{ 1, 1, 1 },
        .{ 1, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 4), result);
}

// ============================================================
// Overflow detection — near u32 max
// ============================================================

test "gid component: large multiplier causes overflow" {
    // u32_max * u32_max = ~1.8e19 (fits u64), then * large multiplier overflows
    const result = dispatch.required_buffer_bytes(
        gidPrecondition(.{ .multiplier = std.math.maxInt(u64), .stride_bytes = 1 }),
        .{ std.math.maxInt(u32), 1, 1 },
        .{ std.math.maxInt(u32), 1, 1 },
    );
    try testing.expectError(error.Overflow, result);
}

test "gid component: large stride causes overflow" {
    const result = dispatch.required_buffer_bytes(
        gidPrecondition(.{ .stride_bytes = std.math.maxInt(u64) }),
        .{ 1000, 1, 1 },
        .{ 1000, 1, 1 },
    );
    try testing.expectError(error.Overflow, result);
}

test "gid component: large offset causes overflow" {
    const result = dispatch.required_buffer_bytes(
        gidPrecondition(.{ .offset = std.math.maxInt(u64) }),
        .{ 1000, 1, 1 },
        .{ 1000, 1, 1 },
    );
    try testing.expectError(error.Overflow, result);
}

test "workgroup component: bound uses dispatch workgroup count" {
    const result = try dispatch.required_buffer_bytes(
        workgroupPrecondition(.{}),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 32), result);
}

test "workgroup component: offset contributes to byte count" {
    const result = try dispatch.required_buffer_bytes(
        workgroupPrecondition(.{ .multiplier = 4, .offset = 2 }),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 124), result);
}

test "flat 2d: large workgroups cause element count overflow" {
    const result = dispatch.required_buffer_bytes(
        flat2dPrecondition(.{ .stride_bytes = std.math.maxInt(u64) }),
        .{ std.math.maxInt(u32), std.math.maxInt(u32), 1 },
        .{ std.math.maxInt(u32), std.math.maxInt(u32), 1 },
    );
    try testing.expectError(error.Overflow, result);
}

// ============================================================
// DispatchPreconditionKind enum — exhaustiveness
// ============================================================

test "DispatchPreconditionKind has exactly 8 variants" {
    const fields = @typeInfo(ir.DispatchPreconditionKind).@"enum".fields;
    try testing.expectEqual(@as(usize, 8), fields.len);
}

test "DispatchPreconditionKind names are stable" {
    try testing.expectEqualStrings("gid_component", @tagName(ir.DispatchPreconditionKind.gid_component));
    try testing.expectEqualStrings("workgroup_component", @tagName(ir.DispatchPreconditionKind.workgroup_component));
    try testing.expectEqualStrings("local_invocation_component", @tagName(ir.DispatchPreconditionKind.local_invocation_component));
    try testing.expectEqualStrings("gid_component_tiled", @tagName(ir.DispatchPreconditionKind.gid_component_tiled));
    try testing.expectEqualStrings("flat_index_2d_dispatch_x", @tagName(ir.DispatchPreconditionKind.flat_index_2d_dispatch_x));
    try testing.expectEqualStrings("flat_index_3d_dispatch_xy", @tagName(ir.DispatchPreconditionKind.flat_index_3d_dispatch_xy));
    try testing.expectEqualStrings("uniform_extent", @tagName(ir.DispatchPreconditionKind.uniform_extent));
    try testing.expectEqualStrings("loop_component", @tagName(ir.DispatchPreconditionKind.loop_component));
}

// ============================================================
// DispatchPrecondition struct defaults
// ============================================================

test "DispatchPrecondition default fields are sensible" {
    const p = Precondition{
        .gid_axis = 0,
        .storage_binding = .{ .group = 0, .binding = 0 },
        .element_stride_bytes = 4,
    };
    try testing.expectEqual(ir.DispatchPreconditionKind.gid_component, p.kind);
    try testing.expectEqual(@as(u64, 1), p.element_multiplier);
    try testing.expectEqual(@as(u64, 1), p.tile_width);
    try testing.expectEqual(@as(u64, 0), p.loop_limit);
    try testing.expectEqual(@as(u64, 0), p.loop_limit_multiplier);
    try testing.expectEqual(@as(u64, 0), p.element_offset);
}

// ============================================================
// Loop contribution — edge cases
// ============================================================

test "gid component: zero loop_limit contributes nothing" {
    const with_loop = try dispatch.required_buffer_bytes(
        gidPrecondition(.{ .loop_limit = 0, .loop_limit_multiplier = 100 }),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    const without_loop = try dispatch.required_buffer_bytes(
        gidPrecondition(.{}),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(without_loop, with_loop);
}

test "gid component: zero loop_limit_multiplier contributes nothing" {
    const with_loop = try dispatch.required_buffer_bytes(
        gidPrecondition(.{ .loop_limit = 100, .loop_limit_multiplier = 0 }),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    const without_loop = try dispatch.required_buffer_bytes(
        gidPrecondition(.{}),
        .{ 8, 1, 1 },
        .{ 64, 1, 1 },
    );
    try testing.expectEqual(without_loop, with_loop);
}

test "gid component: loop contribution adds to total before stride" {
    // Tight formula: (63)*1 + (9)*2 + 0 + 1 = 82 elements; *4 bytes = 328.
    const result = try dispatch.required_buffer_bytes(
        gidPrecondition(.{ .loop_limit = 10, .loop_limit_multiplier = 2 }),
        .{ 8, 1, 1 },
        .{ 8, 1, 1 },
    );
    try testing.expectEqual(@as(u64, 328), result);
}

// ============================================================
// Binding point is carried through (structural check)
// ============================================================

test "DispatchPrecondition carries binding point" {
    const p = Precondition{
        .kind = .gid_component,
        .gid_axis = 0,
        .storage_binding = .{ .group = 2, .binding = 7 },
        .element_stride_bytes = 4,
    };
    try testing.expectEqual(@as(u32, 2), p.storage_binding.group);
    try testing.expectEqual(@as(u32, 7), p.storage_binding.binding);
}

// ============================================================
// TextureDispatchPrecondition — structural checks
// ============================================================

test "TextureDispatchPreconditionKind has exactly 3 variants" {
    const fields = @typeInfo(ir.TextureDispatchPreconditionKind).@"enum".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);
}

test "TextureDispatchPrecondition default is 2D with mip_level 0" {
    const p = ir.TextureDispatchPrecondition{
        .texture_binding = .{ .group = 0, .binding = 0 },
    };
    try testing.expectEqual(ir.TextureDispatchPreconditionKind.gid_coords_2d, p.kind);
    try testing.expectEqual(@as(u32, 0), p.mip_level);
    try testing.expectEqual(ir.TextureDispatchCoordMode.affine, p.coord_mode);
    try testing.expectEqualSlices(u64, &.{ 1, 1, 1 }, &p.coord_multipliers);
    try testing.expectEqualSlices(u64, &.{ 0, 0, 0 }, &p.coord_offsets);
    try testing.expectEqualSlices(u64, &.{ 1, 1, 1 }, &p.coord_tile_widths);
    try testing.expectEqualSlices(u64, &.{ 1, 1, 1 }, &p.coord_tile_strides);
}
