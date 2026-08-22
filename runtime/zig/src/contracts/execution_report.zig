//! Standardized execution result and timing breakdown contracts.
//!
//! Every backend port and application runner produces this common report.

const std = @import("std");

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
};
