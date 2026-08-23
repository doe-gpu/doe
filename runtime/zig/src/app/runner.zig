//! Application runner driving prepared operations through narrow outbound ports.

const std = @import("std");
const prepared = @import("../contracts/prepared_operation.zig");
const report = @import("../contracts/execution_report.zig");
const port_factory = @import("../backend/ports/factory.zig");
const compute_port = @import("../backend/ports/compute.zig");
const transfer_port = @import("../backend/ports/transfer.zig");

pub fn execute(ports: port_factory.PortBundle, op: prepared.PreparedOperation) !report.ExecutionReport {
    return switch (op) {
        .compute => |value| ports.compute.execute(value),
        .transfer => |value| ports.transfer.execute(value),
        .render => |value| ports.render.execute(value),
        .resource => |value| ports.resource.execute(value),
        .surface => |value| ports.surface.execute(value),
        .lifecycle => |value| ports.lifecycle.execute(value),
        .spatial => |value| ports.spatial.execute(value),
    };
}

pub fn executeCompute(port: compute_port.ComputePort, op: prepared.PreparedComputeOperation) !report.ExecutionReport {
    return port.execute(op);
}

pub fn executeTransfer(port: transfer_port.TransferPort, op: prepared.PreparedTransferOperation) !report.ExecutionReport {
    return port.execute(op);
}
