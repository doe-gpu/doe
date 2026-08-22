//! Canonical error taxonomy for the Hexagonal core and backend ports.

const std = @import("std");
const execution_report = @import("execution_report.zig");

pub const DoeError = error{
    InvalidArgument,
    InvalidState,
    UnsupportedCapability,
    UnsupportedFormat,
    OutOfMemory,
    DeviceLost,
    ShaderCompilationFailed,
    PipelineCreationFailed,
    BufferAllocationFailed,
    BoundsViolation,
    Timeout,
    SyncUnavailable,
    ExactnessFailure,
    ProviderDrift,
};

pub fn classifyError(err: anyerror) execution_report.ExecutionStatus {
    return switch (err) {
        error.UnsupportedCapability,
        error.UnsupportedFormat,
        => .unsupported,
        else => .@"error",
    };
}
