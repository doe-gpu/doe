//! Evidence port interface for observing execution without changing behavior.
//!
//! Hexagonal rule: Evidence code observes requests, prepared operations, and execution
//! reports. It never alters provider selection, runtime kernels, or execution semantics.

const std = @import("std");
const prepared = @import("../contracts/prepared_operation.zig");
const report = @import("../contracts/execution_report.zig");
const identity = @import("../contracts/identity.zig");

pub const EvidencePortVTable = struct {
    on_operation_prepared: *const fn (ctx: *anyopaque, op: prepared.PreparedOperation) anyerror!void,
    on_operation_completed: *const fn (ctx: *anyopaque, op: prepared.PreparedOperation, rep: report.ExecutionReport) anyerror!void,
};

pub const EvidencePort = struct {
    context: *anyopaque,
    vtable: *const EvidencePortVTable,

    pub fn onOperationPrepared(self: EvidencePort, op: prepared.PreparedOperation) !void {
        return self.vtable.on_operation_prepared(self.context, op);
    }

    pub fn onOperationCompleted(self: EvidencePort, op: prepared.PreparedOperation, rep: report.ExecutionReport) !void {
        return self.vtable.on_operation_completed(self.context, op, rep);
    }
};
