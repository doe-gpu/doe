const builtin = @import("builtin");
const std = @import("std");
const bridge = @import("../../src/backend/metal/metal_bridge_decls.zig");

const source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\kernel void doe_cache_race_regression_20260715(
    \\    device uint* output [[buffer(0)]],
    \\    uint index [[thread_position_in_grid]]) {
    \\  output[index] = index;
    \\}
;

const CompileWorker = struct {
    device: ?*anyopaque,
    failed: bool = false,

    fn run(self: *CompileWorker) void {
        var error_buf: [512]u8 = undefined;
        const library = bridge.metal_bridge_device_new_library_msl(
            self.device,
            source.ptr,
            source.len,
            &error_buf,
            error_buf.len,
        ) orelse {
            self.failed = true;
            return;
        };
        bridge.metal_bridge_release(library);
    }
};

test "Metal MSL library cache supports concurrent first compilation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const device = bridge.metal_bridge_create_default_device() orelse return error.SkipZigTest;
    defer bridge.metal_bridge_release(device);

    var workers = [_]CompileWorker{.{ .device = device }} ** 8;
    var threads: [workers.len]std.Thread = undefined;
    for (&workers, 0..) |*worker, index| {
        threads[index] = try std.Thread.spawn(.{}, CompileWorker.run, .{worker});
    }
    for (&threads) |*thread| thread.join();
    for (workers) |worker| try std.testing.expect(!worker.failed);
}
