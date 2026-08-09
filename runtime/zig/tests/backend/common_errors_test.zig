const std = @import("std");
const common_errors = @import("../../src/contracts/execution.zig");
const wgpu_types = @import("../../src/core/abi/wgpu_runtime_abi.zig");

test "map_error_status returns unsupported for taxonomy errors" {
    try std.testing.expectEqual(
        wgpu_types.NativeExecutionStatus.unsupported,
        common_errors.map_error_status(error.Unsupported),
    );
    try std.testing.expectEqual(
        wgpu_types.NativeExecutionStatus.unsupported,
        common_errors.map_error_status(error.UnsupportedFeature),
    );
    try std.testing.expectEqual(
        wgpu_types.NativeExecutionStatus.unsupported,
        common_errors.map_error_status(error.SyncUnavailable),
    );
    try std.testing.expectEqual(
        wgpu_types.NativeExecutionStatus.unsupported,
        common_errors.map_error_status(error.TimingPolicyMismatch),
    );
    try std.testing.expectEqual(
        wgpu_types.NativeExecutionStatus.unsupported,
        common_errors.map_error_status(error.SurfaceUnavailable),
    );
}

test "map_error_status returns error for non-taxonomy errors" {
    try std.testing.expectEqual(
        wgpu_types.NativeExecutionStatus.@"error",
        common_errors.map_error_status(error.OutOfMemory),
    );
}

test "error_code returns error name" {
    try std.testing.expectEqualStrings("Unsupported", common_errors.error_code(error.Unsupported));
    try std.testing.expectEqualStrings("InvalidArgument", common_errors.error_code(error.InvalidArgument));
    try std.testing.expectEqualStrings("InvalidState", common_errors.error_code(error.InvalidState));
}
