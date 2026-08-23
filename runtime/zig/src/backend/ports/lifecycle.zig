//! Outbound port for asynchronous diagnostics and lifecycle operations.

const prepared = @import("../../contracts/prepared_operation.zig");
const report = @import("../../contracts/execution_report.zig");

pub const LifecyclePortVTable = struct {
    execute_lifecycle: *const fn (ctx: *anyopaque, op: prepared.PreparedLifecycleOperation) anyerror!report.ExecutionReport,
};

pub const LifecyclePort = struct {
    context: *anyopaque,
    vtable: *const LifecyclePortVTable,

    pub fn execute(self: LifecyclePort, op: prepared.PreparedLifecycleOperation) !report.ExecutionReport {
        return self.vtable.execute_lifecycle(self.context, op);
    }
};
