//! Outbound port interface for spatial and CSL execution.

const std = @import("std");
const spatial_contract = @import("../../contracts/spatial_operation.zig");
const report_contract = @import("../../contracts/execution_report.zig");

pub const SpatialPortVTable = struct {
    execute_spatial: *const fn (ctx: *anyopaque, op: spatial_contract.PreparedSpatialOperation) anyerror!report_contract.ExecutionReport,
};

pub const SpatialPort = struct {
    context: *anyopaque,
    vtable: *const SpatialPortVTable,

    pub fn executeSpatial(self: SpatialPort, op: spatial_contract.PreparedSpatialOperation) !report_contract.ExecutionReport {
        return self.vtable.execute_spatial(self.context, op);
    }
};
