//! Outbound port for surface lifecycle and presentation operations.

const prepared = @import("../../contracts/prepared_operation.zig");
const report = @import("../../contracts/execution_report.zig");

pub const SurfacePortVTable = struct {
    execute_surface: *const fn (ctx: *anyopaque, op: prepared.PreparedSurfaceOperation) anyerror!report.ExecutionReport,
};

pub const SurfacePort = struct {
    context: *anyopaque,
    vtable: *const SurfacePortVTable,

    pub fn execute(self: SurfacePort, op: prepared.PreparedSurfaceOperation) !report.ExecutionReport {
        return self.vtable.execute_surface(self.context, op);
    }
};
