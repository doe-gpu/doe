//! Request normalization module.
//!
//! Normalizes memory alignments, coordinate systems, and input parameters into canonical forms.

const std = @import("std");
const request = @import("request.zig");

pub fn normalizeWorkgroups(count: request.WorkgroupCount) request.WorkgroupCount {
    return .{
        .x = @max(count.x, 1),
        .y = @max(count.y, 1),
        .z = @max(count.z, 1),
    };
}

pub fn normalizeOffset(offset: u64, alignment: u64) u64 {
    if (alignment == 0) return offset;
    return (offset + alignment - 1) & ~(alignment - 1);
}
