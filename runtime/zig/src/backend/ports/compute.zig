//! Narrow outbound port interface for compute kernel dispatch.
//!
//! Replaces broad monolithic backend vtables with a focused, single-responsibility
//! contract for executing prepared compute operations.

const std = @import("std");
const prepared = @import("../../contracts/prepared_operation.zig");
const report = @import("../../contracts/execution_report.zig");

pub const ComputePortVTable = struct {
    execute_compute: *const fn (ctx: *anyopaque, op: prepared.PreparedComputeOperation) anyerror!report.ExecutionReport,
};

pub const ComputePort = struct {
    context: *anyopaque,
    vtable: *const ComputePortVTable,

    pub fn execute(self: ComputePort, op: prepared.PreparedComputeOperation) !report.ExecutionReport {
        return self.vtable.execute_compute(self.context, op);
    }
};
