const builtin = @import("builtin");
const bridge = @import("metal/metal_bridge_decls.zig");

pub const d3d12_device_caps = @import("d3d12/d3d12_device_caps.zig");
pub const vk_feature_caps = if (builtin.os.tag == .linux) @import("vulkan/vk_feature_caps.zig") else struct {};
pub const vk_device_caps = if (builtin.os.tag == .linux) @import("vulkan/vk_device_caps.zig") else struct {};
pub const vk_feature_probe = if (builtin.os.tag == .linux) @import("vulkan/vk_feature_probe.zig") else struct {};

pub fn metal_device_max_buffer_length(device: ?*anyopaque) u64 {
    return bridge.metal_bridge_device_max_buffer_length(device);
}

pub fn metal_supports_timestamp_query(device: ?*anyopaque) bool {
    return bridge.metal_bridge_supports_timestamp_query(device) != 0;
}
