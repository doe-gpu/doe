//! An owned reference crossing an execution-service boundary.
const std = @import("std");

pub const ResourceLease = struct {
    handle: ?*anyopaque,
    release: *const fn (?*anyopaque) callconv(.c) void,
};

pub fn retainCount(count: *u32) void {
    var current = @atomicLoad(u32, count, .monotonic);
    while (true) {
        if (current == 0 or current == std.math.maxInt(u32)) @panic("invalid resource reference count");
        current = @cmpxchgWeak(u32, count, current, current + 1, .monotonic, .monotonic) orelse return;
    }
}

pub fn releaseCount(count: *u32) bool {
    const previous = @atomicRmw(u32, count, .Sub, 1, .acq_rel);
    if (previous == 0) @panic("resource reference released more than once");
    return previous == 1;
}

test "concurrent leases retain one final owner" {
    const Worker = struct {
        fn run(count: *u32) void {
            for (0..10_000) |_| {
                retainCount(count);
                const last_reference = releaseCount(count);
                std.debug.assert(!last_reference);
            }
        }
    };
    var count: u32 = 1;
    var workers: [4]std.Thread = undefined;
    var started: usize = 0;
    defer for (workers[0..started]) |worker| worker.join();
    for (&workers) |*worker| {
        worker.* = try std.Thread.spawn(.{}, Worker.run, .{&count});
        started += 1;
    }
    for (workers) |worker| worker.join();
    started = 0;
    try std.testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &count, .acquire));
    try std.testing.expect(releaseCount(&count));
}

pub fn releaseAll(allocator: std.mem.Allocator, leases: *std.ArrayListUnmanaged(ResourceLease)) void {
    for (leases.items) |lease| lease.release(lease.handle);
    leases.deinit(allocator);
    leases.* = .{};
}
