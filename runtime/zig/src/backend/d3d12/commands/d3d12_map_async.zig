const std = @import("std");
const model_async_types = @import("../../../contracts/model/model_async_types.zig");
const common_timing = @import("../../common/timing.zig");
const dc = @import("../d3d12_constants.zig");
const bridge = @import("../d3d12_bridge_decls.zig");

const HEAP_TYPE_READBACK: c_int = 3;
const MAX_MAP_BYTES: usize = 256 * 1024 * 1024;

pub fn execute_map_async(
    device: ?*anyopaque,
    cmd: model_async_types.MapAsyncCommand,
) !u64 {
    if (cmd.bytes == 0) return error.InvalidArgument;
    if (cmd.bytes > MAX_MAP_BYTES) return error.UnsupportedFeature;

    const encode_start = common_timing.now_ns();

    const heap_type: c_int = switch (cmd.mode) {
        .write => dc.HEAP_TYPE_UPLOAD,
        .read => HEAP_TYPE_READBACK,
    };

    const buffer = bridge.c.d3d12_bridge_device_create_buffer(device, cmd.bytes, heap_type) orelse return error.InvalidState;
    defer bridge.c.d3d12_bridge_release(buffer);

    const mapped = bridge.c.d3d12_bridge_resource_map(buffer) orelse return error.InvalidState;
    _ = mapped;
    bridge.c.d3d12_bridge_resource_unmap(buffer);

    return common_timing.ns_delta(common_timing.now_ns(), encode_start);
}
