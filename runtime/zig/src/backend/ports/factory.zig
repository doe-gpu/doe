//! Outbound backend port interface factory contracts.

const std = @import("std");
const backend_contract = @import("../../contracts/backend.zig");
const compute_port = @import("compute.zig");
const transfer_port = @import("transfer.zig");
const queue_port = @import("queue.zig");
const readback_port = @import("readback.zig");
const telemetry_port = @import("telemetry.zig");
const render_port = @import("render.zig");
const spatial_port = @import("spatial.zig");
const capture_port = @import("capture.zig");

pub const PortBundle = struct {
    id: backend_contract.BackendId,
    compute: compute_port.ComputePort,
    transfer: transfer_port.TransferPort,
    queue: queue_port.QueuePort,
    readback: readback_port.ReadbackPort,
    telemetry: telemetry_port.TelemetryPort,
    render: render_port.RenderPort,
    spatial: spatial_port.SpatialPort,
    capture: ?capture_port.CapturePort = null,
};
