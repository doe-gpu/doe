//! Outbound port interface for graphics render pass execution.

const std = @import("std");
const prepared = @import("../../contracts/prepared_operation.zig");
const report_contract = @import("../../contracts/execution_report.zig");

pub const RenderPortVTable = struct {
    execute_render: *const fn (ctx: *anyopaque, op: prepared.PreparedRenderOperation) anyerror!report_contract.ExecutionReport,
};

pub const RenderPort = struct {
    context: *anyopaque,
    vtable: *const RenderPortVTable,

    pub fn execute(self: RenderPort, op: prepared.PreparedRenderOperation) !report_contract.ExecutionReport {
        return self.vtable.execute_render(self.context, op);
    }
};
