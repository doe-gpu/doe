const std = @import("std");
const common_timing = @import("../common/timing.zig");
const model_async_types = @import("../../contracts/model/model_async_types.zig");
const bridge = @import("metal_bridge_decls.zig");

const metal_bridge_buffer_contents = bridge.metal_bridge_buffer_contents;
const metal_bridge_device_new_buffer_shared = bridge.metal_bridge_device_new_buffer_shared;
const metal_bridge_query_device_max_buffer_length = bridge.metal_bridge_query_device_max_buffer_length;
const metal_bridge_release = bridge.metal_bridge_release;

pub fn execute_map_async(runtime: anytype, cmd: model_async_types.MapAsyncCommand) !u64 {
    try validate_map_async_size(cmd.bytes, metal_bridge_query_device_max_buffer_length());
    if (runtime.streaming_cmd_buf != null or runtime.has_deferred_submissions or runtime.outstanding_cmd_buf != null) {
        _ = try runtime.flush_queue();
    }

    const encode_start = common_timing.now_ns();
    const buffer = metal_bridge_device_new_buffer_shared(runtime.device, cmd.bytes) orelse return error.InvalidState;
    defer metal_bridge_release(buffer);

    const mapped = metal_bridge_buffer_contents(buffer) orelse return error.InvalidState;
    const bytes = mapped[0..cmd.bytes];
    switch (cmd.mode) {
        .write => bytes[0] = 0,
        .read => std.mem.doNotOptimizeAway(bytes[0]),
    }
    return common_timing.ns_delta(common_timing.now_ns(), encode_start);
}

fn validate_map_async_size(bytes: usize, max_buffer_length: u64) !void {
    if (bytes == 0) return error.InvalidArgument;
    if (max_buffer_length != 0 and @as(u64, @intCast(bytes)) > max_buffer_length) {
        return error.UnsupportedFeature;
    }
}

test "validate_map_async_size accepts unknown device limit" {
    try validate_map_async_size(1024, 0);
}

test "validate_map_async_size rejects requests above device limit" {
    try std.testing.expectError(error.UnsupportedFeature, validate_map_async_size(8192, 4096));
}
