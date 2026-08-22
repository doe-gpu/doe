//! Composition root assembling runtime services, port bundles, and evidence observers.

const std = @import("std");
const backend_factory = @import("backend_factory.zig");
const evidence_port = @import("../evidence/port.zig");
const app = @import("../app/mod.zig");
const prepared = @import("../contracts/prepared_operation.zig");
const report = @import("../contracts/execution_report.zig");

pub const RuntimeComposition = struct {
    ports: backend_factory.BackendPortBundle,
    evidence: ?evidence_port.EvidencePort = null,

    pub fn executeCompute(self: RuntimeComposition, op: prepared.PreparedComputeOperation) !report.ExecutionReport {
        if (self.evidence) |ev| {
            try ev.onOperationPrepared(.{ .compute = op });
        }
        const rep = try app.executeCompute(self.ports.compute, op);
        if (self.evidence) |ev| {
            try ev.onOperationCompleted(.{ .compute = op }, rep);
        }
        return rep;
    }

    pub fn executeTransfer(self: RuntimeComposition, op: prepared.PreparedTransferOperation) !report.ExecutionReport {
        if (self.evidence) |ev| {
            try ev.onOperationPrepared(.{ .transfer = op });
        }
        const rep = try app.executeTransfer(self.ports.transfer, op);
        if (self.evidence) |ev| {
            try ev.onOperationCompleted(.{ .transfer = op }, rep);
        }
        return rep;
    }
};
