const std = @import("std");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");

pub const MAX_BIND = native_shared.MAX_BIND;
pub const MAX_COMPUTE_BIND_GROUPS = native_shared.MAX_COMPUTE_BIND_GROUPS;
pub const MAX_FLAT_BIND = native_shared.MAX_FLAT_BIND;

pub const DoeBindGroup = native_types.DoeBindGroup;

pub const FlatResources = struct {
    textures: [MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** MAX_FLAT_BIND,
    samplers: [MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** MAX_FLAT_BIND,
    texture_count: u32 = 0,
    sampler_count: u32 = 0,

    pub fn hasNonBufferResources(self: *const FlatResources) bool {
        return self.texture_count != 0 or self.sampler_count != 0;
    }
};

comptime {
    if (MAX_FLAT_BIND != MAX_BIND * MAX_COMPUTE_BIND_GROUPS) {
        @compileError("doe_compute_bind_groups: flat slot constants drifted");
    }
}

pub inline fn flatBindSlot(group_index: usize, binding_index: usize) usize {
    return group_index * MAX_BIND + binding_index;
}

pub fn bindingCount(bg: *const DoeBindGroup) usize {
    const count: usize = @intCast(bg.count);
    std.debug.assert(count <= MAX_BIND);
    return count;
}

pub fn populateFlatBindings(
    bind_groups: []const ?*DoeBindGroup,
    bufs: *[MAX_FLAT_BIND]?*anyopaque,
    buf_offsets: *[MAX_FLAT_BIND]u64,
    buf_sizes: *[MAX_FLAT_BIND]u64,
) u32 {
    std.debug.assert(bind_groups.len <= MAX_COMPUTE_BIND_GROUPS);

    var total: u32 = 0;
    for (bind_groups, 0..) |maybe_bg, group_index| {
        const bg = maybe_bg orelse continue;
        const count = bindingCount(bg);
        if (count == 0) continue;

        for (0..count) |binding_index| {
            const slot = flatBindSlot(group_index, binding_index);
            bufs[slot] = bg.buffers[binding_index];
            buf_offsets[slot] = bg.offsets[binding_index];
            buf_sizes[slot] = bg.buffer_sizes[binding_index];
        }
        total = @intCast(flatBindSlot(group_index, count - 1) + 1);
    }
    return total;
}

pub fn collectFlatResources(bind_groups: []const ?*DoeBindGroup) FlatResources {
    std.debug.assert(bind_groups.len <= MAX_COMPUTE_BIND_GROUPS);

    var resources: FlatResources = .{};
    for (bind_groups, 0..) |maybe_bg, group_index| {
        const bg = maybe_bg orelse continue;
        const count = bindingCount(bg);
        for (0..count) |binding_index| {
            const slot = flatBindSlot(group_index, binding_index);
            if (bg.textures[binding_index]) |texture| {
                resources.textures[slot] = texture;
                resources.texture_count = @intCast(slot + 1);
            }
            if (bg.samplers[binding_index]) |sampler| {
                resources.samplers[slot] = sampler;
                resources.sampler_count = @intCast(slot + 1);
            }
        }
    }
    return resources;
}

pub fn collectFlatResourcesFromRaw(
    bg_ptrs: [*]const ?*anyopaque,
    bg_count: u32,
) FlatResources {
    var bind_groups: [MAX_COMPUTE_BIND_GROUPS]?*DoeBindGroup =
        [_]?*DoeBindGroup{null} ** MAX_COMPUTE_BIND_GROUPS;
    for (0..@min(bg_count, MAX_COMPUTE_BIND_GROUPS)) |index| {
        bind_groups[index] = native_helpers.cast(DoeBindGroup, bg_ptrs[index]);
    }
    return collectFlatResources(bind_groups[0..]);
}

test "flatBindSlot matches compute bind slot layout" {
    try std.testing.expectEqual(@as(usize, 0), flatBindSlot(0, 0));
    try std.testing.expectEqual(@as(usize, MAX_BIND), flatBindSlot(1, 0));
    try std.testing.expectEqual(@as(usize, MAX_FLAT_BIND - 1), flatBindSlot(MAX_COMPUTE_BIND_GROUPS - 1, MAX_BIND - 1));
}

test "collectFlatResources preserves separate flattened texture and sampler slots" {
    var group: DoeBindGroup = .{};
    group.count = 18;
    group.textures[16] = @ptrFromInt(0x1000);
    group.samplers[17] = @ptrFromInt(0x2000);
    const resources = collectFlatResources(&.{&group});
    try std.testing.expectEqual(@as(u32, 17), resources.texture_count);
    try std.testing.expectEqual(@as(u32, 18), resources.sampler_count);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x1000)), resources.textures[16]);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x2000)), resources.samplers[17]);
}
