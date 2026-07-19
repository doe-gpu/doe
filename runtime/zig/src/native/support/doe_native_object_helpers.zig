const std = @import("std");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub const alloc = gpa.allocator();
pub const label_store = @import("doe_label_store.zig");

pub fn make(comptime T: type) ?*T {
    return alloc.create(T) catch null;
}

pub fn cast(comptime T: type, p: ?*anyopaque) ?*T {
    const ptr = p orelse return null;
    const result: *T = @ptrCast(@alignCast(ptr));
    if (result.magic != T.TYPE_MAGIC) return null;
    return result;
}

pub fn object_add_ref(comptime T: type, raw: ?*anyopaque) void {
    const obj = cast(T, raw) orelse return;
    obj.ref_count +|= 1;
}

pub fn object_should_destroy(obj: anytype) bool {
    if (obj.ref_count > 1) {
        obj.ref_count -= 1;
        return false;
    }
    return true;
}

pub fn toOpaque(p: anytype) ?*anyopaque {
    return @ptrCast(p);
}
