const std = @import("std");
const common_timing = @import("../../src/backend/common/timing.zig");

test "now_ns returns nonzero on supported platforms" {
    const ts = common_timing.now_ns();
    try std.testing.expect(ts > 0);
}

test "operation_timing_ns returns nonzero" {
    const ts = try common_timing.operation_timing_ns();
    try std.testing.expect(ts > 0);
}

test "ns_delta computes positive difference" {
    try std.testing.expectEqual(@as(u64, 500), common_timing.ns_delta(1500, 1000));
}

test "ns_delta returns zero when after <= before" {
    try std.testing.expectEqual(@as(u64, 0), common_timing.ns_delta(1000, 1500));
    try std.testing.expectEqual(@as(u64, 0), common_timing.ns_delta(1000, 1000));
}

test "vulkan timing alias resolves to common" {
    const vulkan_timing = @import("../../src/backend/vulkan/vulkan_timing.zig");

    const vk_ts = try vulkan_timing.operation_timing_ns();

    try std.testing.expect(vk_ts > 0);
}
