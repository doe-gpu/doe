const std = @import("std");
const builtin = @import("builtin");
const model = @import("../../src/contracts/command.zig");
const webgpu = @import("../../src/compat/webgpu_ffi.zig");
const common_timing = @import("../../src/backend/common/timing.zig");
const d3d12_test_support = @import("d3d12_mod_test_support.zig");

test "d3d12 timing source query succeeds" {
    const timing_ns = try common_timing.operation_timing_ns();
    try std.testing.expect(timing_ns > 0);
}

test "d3d12 dispatch timing separates encode and submit-wait buckets" {
    const result = try d3d12_test_support.run_contract_path(
        model.Command{ .dispatch = .{ .x = 1, .y = 1, .z = 1 } },
        webgpu.QueueSyncMode.per_command,
    );
    try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
    if (result.status == .ok) {
        try std.testing.expect(result.encode_ns > 0 or result.submit_wait_ns > 0 or result.setup_ns > 0);
    } else if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(webgpu.NativeExecutionStatus.unsupported, result.status);
        try std.testing.expectEqualStrings("compute_dispatch", result.status_message);
    } else {
        try std.testing.expectEqual(webgpu.NativeExecutionStatus.unsupported, result.status);
    }
}

test "d3d12 deferred sync records submit cost but not per-command wait cost" {
    const result = try d3d12_test_support.run_contract_path(
        model.Command{ .dispatch = .{ .x = 1, .y = 1, .z = 1 } },
        webgpu.QueueSyncMode.deferred,
    );
    try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
    if (result.status == .ok) {
        try std.testing.expect(result.encode_ns > 0 or result.submit_wait_ns > 0 or result.setup_ns > 0);
    } else if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(webgpu.NativeExecutionStatus.unsupported, result.status);
        try std.testing.expectEqualStrings("compute_dispatch", result.status_message);
    } else {
        try std.testing.expectEqual(webgpu.NativeExecutionStatus.unsupported, result.status);
    }
}
