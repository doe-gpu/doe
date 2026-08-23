//! Outbound port interface for spatial and CSL execution.

const std = @import("std");
const prepared = @import("../../contracts/prepared_operation.zig");
const report_contract = @import("../../contracts/execution_report.zig");

pub const SpatialPortVTable = struct {
    execute_spatial: *const fn (ctx: *anyopaque, op: prepared.PreparedSpatialOperation) anyerror!report_contract.ExecutionReport,
};

pub const SpatialPort = struct {
    context: *anyopaque,
    vtable: *const SpatialPortVTable,

    pub fn execute(self: SpatialPort, op: prepared.PreparedSpatialOperation) !report_contract.ExecutionReport {
        return self.vtable.execute_spatial(self.context, op);
    }
};
