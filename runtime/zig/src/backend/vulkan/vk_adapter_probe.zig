// Vulkan adapter identity and capabilities captured from one physical-device
// selection. Keeping these values in one probe prevents capabilities from a
// different ICD/device being attached to the published adapter identity.

const std = @import("std");
const backend_contract = @import("../../contracts/backend.zig");
const c = @import("vk_constants.zig");
const native_runtime = @import("native_runtime.zig");
const vk_device = @import("vk_device.zig");
const vk_device_caps = @import("vk_device_caps.zig");
const vk_feature_caps = @import("vk_feature_caps.zig");

pub const AdapterProbe = struct {
    identity: native_runtime.AdapterIdentity,
    feature_caps: vk_feature_caps.VulkanFeatureCaps,
    device_caps: vk_device_caps.VulkanDeviceCaps,
};

pub fn probe_selected_adapter(
    allocator: std.mem.Allocator,
    queue_family_policy: backend_contract.QueueFamilyPolicy,
) !AdapterProbe {
    var probe = native_runtime.NativeVulkanRuntime{
        .allocator = allocator,
        .kernel_root = null,
        .queue_family_policy = queue_family_policy,
    };
    try vk_device.create_instance(&probe);
    defer vk_device.destroy_instance_only(&probe);
    try vk_device.select_physical_device(&probe);

    const identity = query_identity(probe.physical_device);
    const timestamp_valid_bits = probe.queue_family_timestamp_valid_bits_value_cache orelse 0;
    return .{
        .identity = identity,
        .feature_caps = vk_feature_caps.query(probe.physical_device).caps,
        .device_caps = vk_device_caps.query_device_caps(
            probe.physical_device,
            timestamp_valid_bits,
        ),
    };
}

pub fn query_identity(physical_device: c.VkPhysicalDevice) native_runtime.AdapterIdentity {
    var properties2 = std.mem.zeroes(c.VkPhysicalDeviceProperties2);
    properties2.sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
    c.vkGetPhysicalDeviceProperties2(physical_device, &properties2);
    const properties = properties2.properties;
    return .{
        .vendor_id = properties.vendorID,
        .device_id = properties.deviceID,
        .driver_version = properties.driverVersion,
        .device_name = properties.deviceName,
        .device_name_len = std.mem.indexOfScalar(
            u8,
            properties.deviceName[0..],
            0,
        ) orelse properties.deviceName.len,
    };
}

pub fn identity_matches(
    expected: native_runtime.AdapterIdentity,
    actual: native_runtime.AdapterIdentity,
) bool {
    return expected.vendor_id == actual.vendor_id and
        expected.device_id == actual.device_id and
        expected.driver_version == actual.driver_version and
        std.mem.eql(
            u8,
            expected.device_name[0..expected.device_name_len],
            actual.device_name[0..actual.device_name_len],
        );
}

pub fn identity_matches_fields(
    vendor_id: u32,
    device_id: u32,
    driver_version: u32,
    device_name: []const u8,
    actual: native_runtime.AdapterIdentity,
) bool {
    return vendor_id == actual.vendor_id and
        device_id == actual.device_id and
        driver_version == actual.driver_version and
        std.mem.eql(
            u8,
            device_name,
            actual.device_name[0..actual.device_name_len],
        );
}

test "adapter capability binding requires the selected physical-device identity" {
    var name = [_]u8{0} ** backend_contract.ADAPTER_DEVICE_NAME_BYTES;
    @memcpy(name[0..6], "Radeon");
    const actual = native_runtime.AdapterIdentity{
        .vendor_id = 0x1002,
        .device_id = 0x744c,
        .driver_version = 7,
        .device_name = name,
        .device_name_len = 6,
    };
    try std.testing.expect(identity_matches_fields(
        0x1002,
        0x744c,
        7,
        "Radeon",
        actual,
    ));
    try std.testing.expect(!identity_matches_fields(
        0x10005,
        0x0000,
        1,
        "llvmpipe",
        actual,
    ));
}
