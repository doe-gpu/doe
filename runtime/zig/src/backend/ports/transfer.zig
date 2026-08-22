//! Narrow outbound port interface for memory transfers and buffer updates.

const std = @import("std");
const prepared = @import("../../contracts/prepared_operation.zig");
const report = @import("../../contracts/execution_report.zig");

pub const TransferPortVTable = struct {
    execute_transfer: *const fn (ctx: *anyopaque, op: prepared.PreparedTransferOperation) anyerror!report.ExecutionReport,
};

pub const TransferPort = struct {
    context: *anyopaque,
    vtable: *const TransferPortVTable,

    pub fn execute(self: TransferPort, op: prepared.PreparedTransferOperation) !report.ExecutionReport {
        return self.vtable.execute_transfer(self.context, op);
    }
};
