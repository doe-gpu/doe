//! Composition root assembling runtime services, port bundles, and evidence observers.

const std = @import("std");
const port_factory = @import("../backend/ports/factory.zig");
const evidence_port = @import("../evidence/port.zig");
const app = @import("../app/mod.zig");
const prepared = @import("../contracts/prepared_operation.zig");
const report = @import("../contracts/execution_report.zig");

pub const RuntimeComposition = struct {
    ports: port_factory.PortBundle,
    evidence: ?evidence_port.EvidencePort = null,

    pub fn execute(self: RuntimeComposition, op: prepared.PreparedOperation) !report.ExecutionReport {
        if (self.evidence) |observer| observer.onOperationPrepared(op);
        const execution_report = app.executePrepared(self.ports, op) catch |err| {
            if (self.evidence) |observer| observer.onOperationCompleted(op, .fail(@errorName(err)));
            return err;
        };
        if (self.evidence) |observer| observer.onOperationCompleted(op, execution_report);
        return execution_report;
    }

    pub fn executeCompute(self: RuntimeComposition, op: prepared.PreparedComputeOperation) !report.ExecutionReport {
        return self.execute(.{ .compute = op });
    }

    pub fn executeTransfer(self: RuntimeComposition, op: prepared.PreparedTransferOperation) !report.ExecutionReport {
        return self.execute(.{ .transfer = op });
    }
};
