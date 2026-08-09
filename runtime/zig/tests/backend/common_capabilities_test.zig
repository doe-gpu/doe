const std = @import("std");
const model = @import("../../src/contracts/command.zig");
const capabilities = @import("../../src/contracts/capability.zig");
const command = @import("../../src/contracts/command.zig");

test "empty capability set supports nothing" {
    const set = capabilities.CapabilitySet{};
    try std.testing.expect(!set.supports(.compute_dispatch));
    try std.testing.expect(!set.supports(.kernel_dispatch));
    try std.testing.expect(!set.supports(.buffer_upload));
}

test "declare and query single capability" {
    var set = capabilities.CapabilitySet{};
    set.declare(.kernel_dispatch);
    try std.testing.expect(set.supports(.kernel_dispatch));
    try std.testing.expect(!set.supports(.compute_dispatch));
}

test "declare_all adds multiple capabilities" {
    var set = capabilities.CapabilitySet{};
    set.declare_all(&.{ .kernel_dispatch, .buffer_upload, .gpu_timestamps });
    try std.testing.expect(set.supports(.kernel_dispatch));
    try std.testing.expect(set.supports(.buffer_upload));
    try std.testing.expect(set.supports(.gpu_timestamps));
    try std.testing.expect(!set.supports(.surface_present));
}

test "missing returns first missing capability" {
    var backend = capabilities.CapabilitySet{};
    backend.declare(.kernel_dispatch);

    var required = capabilities.CapabilitySet{};
    required.declare(.kernel_dispatch);
    required.declare(.gpu_timestamps);

    const gap = backend.missing(required);
    try std.testing.expect(gap != null);
    try std.testing.expectEqual(capabilities.Capability.gpu_timestamps, gap.?);
}

test "missing returns null when all satisfied" {
    var backend = capabilities.CapabilitySet{};
    backend.declare_all(&.{ .kernel_dispatch, .gpu_timestamps });

    var required = capabilities.CapabilitySet{};
    required.declare(.kernel_dispatch);

    try std.testing.expectEqual(@as(?capabilities.Capability, null), backend.missing(required));
}

test "required_capabilities for kernel_dispatch" {
    const kernel = model.Command{ .kernel_dispatch = .{
        .kernel = "test",
        .x = 1,
        .y = 1,
        .z = 1,
    } };
    const required = command.requiredCapabilities(kernel);
    try std.testing.expect(required.supports(.kernel_dispatch));
    try std.testing.expect(!required.supports(.buffer_upload));
}

test "required_capabilities for upload" {
    const upload = model.Command{ .upload = .{ .bytes = 1024, .align_bytes = 256 } };
    const required = command.requiredCapabilities(upload);
    try std.testing.expect(required.supports(.buffer_upload));
    try std.testing.expect(!required.supports(.kernel_dispatch));
}

test "required_capabilities for dispatch_indirect includes both caps" {
    const cmd = model.Command{ .dispatch_indirect = .{ .x = 1, .y = 1, .z = 1 } };
    const required = command.requiredCapabilities(cmd);
    try std.testing.expect(required.supports(.compute_dispatch));
    try std.testing.expect(required.supports(.compute_dispatch_indirect));
}

test "required_capabilities for surface_present includes lifecycle" {
    const cmd = model.Command{ .surface_present = .{ .handle = 1 } };
    const required = command.requiredCapabilities(cmd);
    try std.testing.expect(required.supports(.surface_lifecycle));
    try std.testing.expect(required.supports(.surface_present));
}

test "capability_name returns stable strings" {
    try std.testing.expectEqualStrings("kernel_dispatch", capabilities.capability_name(.kernel_dispatch));
    try std.testing.expectEqualStrings("gpu_timestamps", capabilities.capability_name(.gpu_timestamps));
    try std.testing.expectEqualStrings("buffer_upload", capabilities.capability_name(.buffer_upload));
}
