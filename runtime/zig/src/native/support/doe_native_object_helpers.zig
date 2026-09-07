const std = @import("std");
const program_identity_trace = @import("../diagnostics/doe_program_identity_trace.zig");
const leases = @import("../../contracts/resource_lease.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub const alloc = gpa.allocator();
pub const label_store = @import("doe_label_store.zig");

pub fn make(comptime T: type) ?*T {
    return create(T, alloc) catch null;
}

pub fn create(comptime T: type, allocator: std.mem.Allocator) std.mem.Allocator.Error!*T {
    const object = try allocator.create(T);
    program_identity_trace.recordNativeObjectCreate(T, object);
    return object;
}

pub fn cast(comptime T: type, p: ?*anyopaque) ?*T {
    const ptr = p orelse return null;
    const result: *T = @ptrCast(@alignCast(ptr));
    if (result.magic != T.TYPE_MAGIC) return null;
    return result;
}

pub fn object_add_ref(comptime T: type, raw: ?*anyopaque) void {
    const obj = cast(T, raw) orelse return;
    leases.retainCount(&obj.ref_count);
}

pub fn object_should_destroy(obj: anytype) bool {
    return leases.releaseCount(&obj.ref_count);
}

pub fn toOpaque(p: anytype) ?*anyopaque {
    return @ptrCast(p);
}
