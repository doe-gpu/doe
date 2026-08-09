const std = @import("std");
const model = @import("../../src/contracts/model/model_profile.zig");
const backend_policy = @import("../../src/backend/backend_policy.zig");
const backend_selection = @import("../../src/contracts/backend.zig");

test "metal lane selects doe_metal" {
    const profile = model.DeviceProfile{
        .vendor = "intel",
        .api = .metal,
        .device_family = null,
        .driver_version = .{ .major = 0, .minor = 0, .patch = 0 },
    };
    const policy = backend_policy.default_policy_for_lane(.metal_doe_comparable);
    const selected = backend_selection.select_backend(profile, policy);
    try std.testing.expect(selected.backend_id == .doe_metal);
    try std.testing.expectEqualStrings("policy_lane_prefers_doe_metal", selected.reason);
}

test "vulkan lane selects doe_vulkan" {
    const profile = model.DeviceProfile{
        .vendor = "intel",
        .api = .vulkan,
        .device_family = null,
        .driver_version = .{ .major = 0, .minor = 0, .patch = 0 },
    };
    const policy = backend_policy.default_policy_for_lane(.vulkan_doe_comparable);
    const selected = backend_selection.select_backend(profile, policy);
    try std.testing.expect(selected.backend_id == .doe_vulkan);
    try std.testing.expectEqualStrings("policy_lane_prefers_doe_vulkan", selected.reason);
}

test "d3d12 lane selects doe_d3d12" {
    const profile = model.DeviceProfile{
        .vendor = "intel",
        .api = .d3d12,
        .device_family = null,
        .driver_version = .{ .major = 0, .minor = 0, .patch = 0 },
    };
    const policy = backend_policy.default_policy_for_lane(.d3d12_doe_comparable);
    const selected = backend_selection.select_backend(profile, policy);
    try std.testing.expect(selected.backend_id == .doe_d3d12);
    try std.testing.expectEqualStrings("policy_lane_prefers_doe_d3d12", selected.reason);
}
