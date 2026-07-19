const std = @import("std");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");

pub const MAX_BIND = native_shared.MAX_BIND;
pub const MAX_COMPUTE_BIND_GROUPS = native_shared.MAX_COMPUTE_BIND_GROUPS;
pub const MAX_FLAT_BIND = native_shared.MAX_FLAT_BIND;

pub const DoeBindGroup = native_types.DoeBindGroup;

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

test "flatBindSlot matches compute bind slot layout" {
    try std.testing.expectEqual(@as(usize, 0), flatBindSlot(0, 0));
    try std.testing.expectEqual(@as(usize, MAX_BIND), flatBindSlot(1, 0));
    try std.testing.expectEqual(@as(usize, MAX_FLAT_BIND - 1), flatBindSlot(MAX_COMPUTE_BIND_GROUPS - 1, MAX_BIND - 1));
}
