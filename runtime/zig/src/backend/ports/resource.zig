//! Outbound port for sampler, texture, and mapping resource operations.

const prepared = @import("../../contracts/prepared_operation.zig");
const report = @import("../../contracts/execution_report.zig");

pub const ResourcePortVTable = struct {
    execute_resource: *const fn (ctx: *anyopaque, op: prepared.PreparedResourceOperation) anyerror!report.ExecutionReport,
};

pub const ResourcePort = struct {
    context: *anyopaque,
    vtable: *const ResourcePortVTable,

    pub fn execute(self: ResourcePort, op: prepared.PreparedResourceOperation) !report.ExecutionReport {
        return self.vtable.execute_resource(self.context, op);
    }
};
