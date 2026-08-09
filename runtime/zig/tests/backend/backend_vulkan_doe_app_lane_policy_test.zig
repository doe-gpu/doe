const std = @import("std");
const model = @import("../../src/contracts/model/model_profile.zig");
const execution = @import("../../src/runtime/execution.zig");
const backend_ids = @import("../../src/contracts/backend.zig");
const backend_policy = @import("../../src/backend/backend_policy.zig");

test "execution backend lane parser accepts vulkan_doe_app" {
    try std.testing.expect(execution.parseBackendLane("vulkan_doe_app") == .vulkan_doe_app);
    try std.testing.expect(execution.parseBackendLane("vulkan-doe-app") == .vulkan_doe_app);
}

test "execution backend lane parser accepts metal_dawn_release" {
    try std.testing.expect(execution.parseBackendLane("metal_dawn_release") == .metal_dawn_release);
    try std.testing.expect(execution.parseBackendLane("metal-dawn-release") == .metal_dawn_release);
}

test "execution backend lane parser folds vulkan dawn directional alias into release" {
    try std.testing.expect(execution.parseBackendLane("vulkan_dawn_directional") == .vulkan_dawn_release);
    try std.testing.expect(execution.parseBackendLane("vulkan-dawn-directional") == .vulkan_dawn_release);
}

test "execution backend lane parser accepts d3d12_doe_app" {
    try std.testing.expect(execution.parseBackendLane("d3d12_doe_app") == .d3d12_doe_app);
    try std.testing.expect(execution.parseBackendLane("d3d12-doe-app") == .d3d12_doe_app);
}

test "default backend lane routes vulkan and metal profiles to app lanes" {
    const vulkan_profile = model.DeviceProfile{
        .vendor = "amd",
        .api = .vulkan,
        .device_family = "gfx11",
        .driver_version = .{ .major = 24, .minor = 0, .patch = 0 },
    };
    const metal_profile = model.DeviceProfile{
        .vendor = "apple",
        .api = .metal,
        .device_family = "m3",
        .driver_version = .{ .major = 1, .minor = 0, .patch = 0 },
    };
    const d3d12_profile = model.DeviceProfile{
        .vendor = "nvidia",
        .api = .d3d12,
        .device_family = "ada",
        .driver_version = .{ .major = 1, .minor = 0, .patch = 0 },
    };

    try std.testing.expect(execution.defaultBackendLane(vulkan_profile) == .vulkan_doe_app);
    try std.testing.expect(execution.defaultBackendLane(metal_profile) == .metal_doe_app);
    try std.testing.expect(execution.defaultBackendLane(d3d12_profile) == .d3d12_doe_app);
}

test "backend runtime policy exposes vulkan_doe_app as strict doe_vulkan lane" {
    const allocator = std.testing.allocator;
    const loaded = try backend_policy.load_policy_for_lane(
        allocator,
        backend_policy.DEFAULT_RUNTIME_POLICY_PATH,
        .vulkan_doe_app,
    );
    defer allocator.free(loaded.owned_policy_hash);

    try std.testing.expect(loaded.policy.default_backend == backend_ids.BackendId.doe_vulkan);
    try std.testing.expect(loaded.policy.allow_fallback == false);
    try std.testing.expect(loaded.policy.strict_no_fallback == true);
}

test "backend runtime policy exposes d3d12_doe_app as strict doe_d3d12 lane" {
    const allocator = std.testing.allocator;
    const loaded = try backend_policy.load_policy_for_lane(
        allocator,
        backend_policy.DEFAULT_RUNTIME_POLICY_PATH,
        .d3d12_doe_app,
    );
    defer allocator.free(loaded.owned_policy_hash);

    try std.testing.expect(loaded.policy.default_backend == backend_ids.BackendId.doe_d3d12);
    try std.testing.expect(loaded.policy.allow_fallback == false);
    try std.testing.expect(loaded.policy.strict_no_fallback == true);
}
