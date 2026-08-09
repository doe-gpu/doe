//! Neutral execution outcome and backend-failure taxonomy.

pub const NativeExecutionStatus = enum {
    ok,
    unsupported,
    @"error",
};

pub const ExecutionStatus = enum {
    skipped,
    ok,
    unsupported,
    @"error",
};

pub const BackendNativeError = error{
    InvalidArgument,
    InvalidState,
    Unsupported,
    UnsupportedFeature,
    ShaderToolchainUnavailable,
    ShaderCompileFailed,
    SyncUnavailable,
    TimingPolicyMismatch,
    SurfaceUnavailable,
};

/// Backend-neutral measurements for one dispatch submission. Backends may
/// leave unsupported measurements at their zero defaults, but must not rename
/// or reinterpret a populated field.
pub const DispatchMetrics = struct {
    setup_ns: u64 = 0,
    encode_ns: u64 = 0,
    submit_wait_ns: u64 = 0,
    dispatch_count: u32 = 0,
    submit_count: u32 = 0,
    gpu_timestamp_ns: u64 = 0,
    gpu_timestamp_attempted: bool = false,
    gpu_timestamp_valid: bool = false,
};

pub const NativeExecutionResult = struct {
    status: NativeExecutionStatus,
    status_message: []const u8,
    setup_ns: u64 = 0,
    encode_ns: u64 = 0,
    submit_wait_ns: u64 = 0,
    dispatch_count: u32 = 0,
    gpu_timestamp_ns: u64 = 0,
    gpu_timestamp_attempted: bool = false,
    gpu_timestamp_valid: bool = false,
};

pub fn classifyBackendError(err: anyerror) NativeExecutionStatus {
    return switch (err) {
        error.Unsupported,
        error.UnsupportedFeature,
        error.ShaderToolchainUnavailable,
        error.SyncUnavailable,
        error.TimingPolicyMismatch,
        error.SurfaceUnavailable,
        => .unsupported,
        else => .@"error",
    };
}

pub fn fromNativeStatus(status: NativeExecutionStatus) ExecutionStatus {
    return switch (status) {
        .ok => .ok,
        .unsupported => .unsupported,
        .@"error" => .@"error",
    };
}

pub fn statusName(status: anytype) []const u8 {
    return @tagName(status);
}

pub fn errorCode(err: anyerror) []const u8 {
    return @errorName(err);
}

pub const map_error_status = classifyBackendError;
pub const error_code = errorCode;

test "backend errors have one unsupported classification" {
    const std = @import("std");
    try std.testing.expectEqual(NativeExecutionStatus.unsupported, classifyBackendError(error.Unsupported));
    try std.testing.expectEqual(NativeExecutionStatus.unsupported, classifyBackendError(error.SyncUnavailable));
    try std.testing.expectEqual(NativeExecutionStatus.@"error", classifyBackendError(error.InvalidState));
    try std.testing.expectEqual(ExecutionStatus.unsupported, fromNativeStatus(.unsupported));
    try std.testing.expectEqualStrings("error", statusName(ExecutionStatus.@"error"));
    const metrics = DispatchMetrics{ .encode_ns = 3, .dispatch_count = 2 };
    try std.testing.expectEqual(@as(u64, 3), metrics.encode_ns);
    try std.testing.expectEqual(@as(u32, 2), metrics.dispatch_count);
}
