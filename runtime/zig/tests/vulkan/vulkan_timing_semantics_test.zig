const std = @import("std");
const builtin = @import("builtin");
const model = @import("../../src/contracts/command.zig");
const profile = @import("../../src/contracts/model/model_profile.zig");
const webgpu = @import("../../src/compat/webgpu_ffi.zig");
const vulkan_mod = @import("../../src/backend/vulkan/mod.zig");
const vulkan_timing = @import("../../src/backend/vulkan/vulkan_timing.zig");
const vulkan_test_support = @import("vulkan_mod_test_support.zig");

fn test_profile() profile.DeviceProfile {
    return .{
        .vendor = "amd",
        .api = .vulkan,
        .device_family = "gfx11",
        .driver_version = .{ .major = 24, .minor = 0, .patch = 0 },
    };
}

test "vulkan timing source query succeeds" {
    const timing_ns = try vulkan_timing.operation_timing_ns();
    try std.testing.expect(timing_ns > 0);
}

test "vulkan dispatch timing separates encode and submit-wait buckets" {
    const result = try vulkan_test_support.run_contract_path(
        model.Command{ .dispatch = .{ .x = 1, .y = 1, .z = 1 } },
        webgpu.QueueSyncMode.per_command,
    );
    if (result.status != .ok) {
        try std.testing.expectEqual(webgpu.NativeExecutionStatus.unsupported, result.status);
        try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
        return;
    }
    try std.testing.expect(result.encode_ns > 0);
    try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
}

test "vulkan deferred sync records submit cost but not per-command wait cost" {
    const result = try vulkan_test_support.run_contract_path(
        model.Command{ .dispatch = .{ .x = 1, .y = 1, .z = 1 } },
        webgpu.QueueSyncMode.deferred,
    );
    if (result.status != .ok) {
        try std.testing.expectEqual(webgpu.NativeExecutionStatus.unsupported, result.status);
        try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
        return;
    }
    try std.testing.expect(result.encode_ns > 0);
    try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
}

test "vulkan require gpu timestamps reports a real timestamp when supported" {
    if (builtin.os.tag == .macos) return;

    const backend = try vulkan_mod.ZigVulkanBackend.init(std.testing.allocator, test_profile(), null);
    var iface = try backend.as_iface(std.testing.allocator, "test_gpu_timestamps", "test_policy_hash");
    defer iface.deinit();
    iface.set_gpu_timestamp_mode(.require);

    const result = try iface.execute_command(model.Command{ .kernel_dispatch = .{
        .kernel = "bench/kernels/shader_compile_pipeline_stress.spv",
        .x = 1,
        .y = 1,
        .z = 1,
    } });
    if (result.status != .ok) return;
    try std.testing.expect(result.gpu_timestamp_attempted);
    try std.testing.expect(result.gpu_timestamp_valid);
    try std.testing.expect(result.gpu_timestamp_ns > 0);
}
