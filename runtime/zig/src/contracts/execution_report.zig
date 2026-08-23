//! Standardized execution result and timing breakdown contracts.
//!
//! Every backend port and application runner produces this common report.

const std = @import("std");
const execution_contract = @import("execution.zig");

pub const ExecutionStatus = enum {
    ok,
    skipped,
    unsupported,
    @"error",

    pub fn isSuccess(self: ExecutionStatus) bool {
        return self == .ok or self == .skipped;
    }
};

pub const TimingBreakdownNs = struct {
    setup_ns: u64 = 0,
    encode_ns: u64 = 0,
    submit_wait_ns: u64 = 0,
    gpu_timestamp_ns: u64 = 0,

    pub fn totalWallNs(self: TimingBreakdownNs) u64 {
        return self.setup_ns + self.encode_ns + self.submit_wait_ns;
    }
};

pub const ExecutionReport = struct {
    status: ExecutionStatus = .ok,
    status_message: []const u8 = "",
    timing: TimingBreakdownNs = .{},
    dispatch_count: u32 = 0,
    submit_count: u32 = 0,
    gpu_timestamp_valid: bool = false,

    pub fn success(timing: TimingBreakdownNs, dispatch_count: u32) ExecutionReport {
        return .{
            .status = .ok,
            .timing = timing,
            .dispatch_count = dispatch_count,
            .submit_count = if (dispatch_count > 0) 1 else 0,
        };
    }

    pub fn fail(message: []const u8) ExecutionReport {
        return .{
            .status = .@"error",
            .status_message = message,
        };
    }

    pub fn unsupported(message: []const u8) ExecutionReport {
        return .{
            .status = .unsupported,
            .status_message = message,
        };
    }

    pub fn fromNative(native: execution_contract.NativeExecutionResult) ExecutionReport {
        return .{
            .status = switch (native.status) {
                .ok => .ok,
                .unsupported => .unsupported,
                .@"error" => .@"error",
            },
            .status_message = native.status_message,
            .timing = .{
                .setup_ns = native.setup_ns,
                .encode_ns = native.encode_ns,
                .submit_wait_ns = native.submit_wait_ns,
                .gpu_timestamp_ns = native.gpu_timestamp_ns,
            },
            .dispatch_count = native.dispatch_count,
            .submit_count = if (native.dispatch_count > 0) 1 else 0,
            .gpu_timestamp_valid = native.gpu_timestamp_valid,
        };
    }

    pub fn toNative(self: ExecutionReport) execution_contract.NativeExecutionResult {
        return .{
            .status = switch (self.status) {
                .ok, .skipped => .ok,
                .unsupported => .unsupported,
                .@"error" => .@"error",
            },
            .status_message = self.status_message,
            .setup_ns = self.timing.setup_ns,
            .encode_ns = self.timing.encode_ns,
            .submit_wait_ns = self.timing.submit_wait_ns,
            .dispatch_count = self.dispatch_count,
            .gpu_timestamp_ns = self.timing.gpu_timestamp_ns,
            .gpu_timestamp_attempted = self.timing.gpu_timestamp_ns > 0,
            .gpu_timestamp_valid = self.gpu_timestamp_valid,
        };
    }
};
