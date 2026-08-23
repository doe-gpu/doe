//! Narrow outbound port interface for hardware metrics and timing observations.

const std = @import("std");
const runtime_telemetry = @import("../../contracts/runtime_telemetry.zig");

pub const TelemetryPortVTable = struct {
    get_gpu_timestamp_ns: *const fn (ctx: *anyopaque) anyerror!u64,
    snapshot: *const fn (ctx: *anyopaque) runtime_telemetry.RuntimeTelemetry,
};

pub const TelemetryPort = struct {
    context: *anyopaque,
    vtable: *const TelemetryPortVTable,

    pub fn getGpuTimestampNs(self: TelemetryPort) !u64 {
        return self.vtable.get_gpu_timestamp_ns(self.context);
    }

    pub fn snapshot(self: TelemetryPort) runtime_telemetry.RuntimeTelemetry {
        return self.vtable.snapshot(self.context);
    }
};
