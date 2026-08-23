const std = @import("std");
const builtin = @import("builtin");
const model = @import("../../src/contracts/command.zig");
const profile = @import("../../src/contracts/model/model_profile.zig");
const webgpu = @import("../../src/compat/webgpu_ffi.zig");
const d3d12_mod = @import("../../src/backend/d3d12/mod.zig");
const d3d12_test_support = @import("d3d12_mod_test_support.zig");
const provider_harness = @import("../support/provider_harness.zig");

fn test_profile() profile.DeviceProfile {
    return .{
        .vendor = "amd",
        .api = .d3d12,
        .device_family = "gfx11",
        .driver_version = .{ .major = 24, .minor = 0, .patch = 0 },
    };
}

test "d3d12 provider ports advertise doe_d3d12 lane identity" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const backend = try d3d12_mod.ZigD3D12Backend.init(std.testing.allocator, test_profile(), null);
    var iface = provider_harness.ProviderHarness.init(
        backend.asPorts("test_backend_identity", "test_policy_hash", false),
        backend,
        d3d12_mod.destroyContext,
    );
    defer iface.deinit();

    try std.testing.expectEqualStrings("doe_d3d12", @tagName(iface.id));
    try std.testing.expectEqualStrings("doe_d3d12", @tagName(iface.telemetry.backend_id));
    try std.testing.expect(!iface.telemetry.fallback_used);
}

test "d3d12 run_contract_path_for_test preserves dispatch operation count" {
    const result = try d3d12_test_support.run_contract_path(
        model.Command{ .dispatch = .{ .x = 1, .y = 1, .z = 1 } },
        webgpu.QueueSyncMode.per_command,
    );
    try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(webgpu.NativeExecutionStatus.unsupported, result.status);
        try std.testing.expectEqualStrings("d3d12-native-tests-require-windows", result.status_message);
    }
}
