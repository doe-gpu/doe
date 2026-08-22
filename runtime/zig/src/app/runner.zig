//! Application runner driving prepared operations through narrow outbound ports.

const std = @import("std");
const prepared = @import("../contracts/prepared_operation.zig");
const report = @import("../contracts/execution_report.zig");
const compute_port = @import("../backend/ports/compute.zig");
const transfer_port = @import("../backend/ports/transfer.zig");

pub fn executeCompute(port: compute_port.ComputePort, op: prepared.PreparedComputeOperation) !report.ExecutionReport {
    return port.execute(op);
}

pub fn executeTransfer(port: transfer_port.TransferPort, op: prepared.PreparedTransferOperation) !report.ExecutionReport {
    return port.execute(op);
}
