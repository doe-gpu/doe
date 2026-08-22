//! Narrow outbound port interface for hardware metrics and timing observations.

const std = @import("std");

pub const TelemetryPortVTable = struct {
    get_gpu_timestamp_ns: *const fn (ctx: *anyopaque) anyerror!u64,
};

pub const TelemetryPort = struct {
    context: *anyopaque,
    vtable: *const TelemetryPortVTable,

    pub fn getGpuTimestampNs(self: TelemetryPort) !u64 {
        return self.vtable.get_gpu_timestamp_ns(self.context);
    }
};
