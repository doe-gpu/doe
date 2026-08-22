//! Direct execution helper executing a single application request through ports.

const std = @import("std");
const request = @import("request.zig");
const prepare = @import("prepare.zig");
const runner = @import("runner.zig");
const compute_port = @import("../backend/ports/compute.zig");
const transfer_port = @import("../backend/ports/transfer.zig");
const report = @import("../contracts/execution_report.zig");

pub fn executeComputeDirect(port: compute_port.ComputePort, req: request.ComputeRequest, operation_id: u64) !report.ExecutionReport {
    const op = prepare.prepareCompute(req, operation_id);
    return runner.executeCompute(port, op);
}

pub fn executeTransferDirect(port: transfer_port.TransferPort, req: request.TransferRequest, operation_id: u64) !report.ExecutionReport {
    const op = prepare.prepareTransfer(req, operation_id);
    return runner.executeTransfer(port, op);
}
