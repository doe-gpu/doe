const builtin = @import("builtin");
const shared = @import("doe_native_shared_types.zig");
const objects = @import("doe_native_object_types.zig");

pub fn device_vk_runtime(dev: *objects.DoeDevice) if (builtin.os.tag == .linux) ?*shared.NativeVulkanRuntime else ?*void {
    if (comptime builtin.os.tag != .linux) return null;
    const ptr = dev.vk_runtime orelse return null;
    return @as(*shared.NativeVulkanRuntime, @ptrCast(@alignCast(ptr)));
}

pub fn device_d3d12_runtime(dev: *objects.DoeDevice) ?*shared.NativeD3D12Runtime {
    const ptr = dev.d3d12_runtime orelse return null;
    return @as(*shared.NativeD3D12Runtime, @ptrCast(@alignCast(ptr)));
}
