//! Infallible observer port for prepared operations and execution reports.
//!
//! Observer callbacks deliberately return `void`: evidence collection cannot
//! veto, replace, retry, or otherwise alter an execution decision. Operations
//! are borrowed only for the callback extent. An observer that retains one
//! must create an `OwnedPreparedOperation` snapshot before returning.

const prepared = @import("prepared_operation.zig");
const report = @import("execution_report.zig");

pub const EvidenceObserverVTable = struct {
    on_operation_prepared: *const fn (ctx: *anyopaque, op: prepared.PreparedOperation) void,
    on_operation_completed: *const fn (ctx: *anyopaque, op: prepared.PreparedOperation, execution_report: report.ExecutionReport) void,
};

pub const EvidenceObserver = struct {
    context: *anyopaque,
    vtable: *const EvidenceObserverVTable,

    pub fn onOperationPrepared(self: EvidenceObserver, op: prepared.PreparedOperation) void {
        self.vtable.on_operation_prepared(self.context, op);
    }

    pub fn onOperationCompleted(self: EvidenceObserver, op: prepared.PreparedOperation, execution_report: report.ExecutionReport) void {
        self.vtable.on_operation_completed(self.context, op, execution_report);
    }
};
