//! Composition root for concrete backend adapters.
//!
//! Hexagonal rule: Composition is the ONLY layer permitted to import multiple concrete backends.
//! Application and runtime code never imports concrete backends directly.

const std = @import("std");
const backend_contract = @import("../contracts/backend.zig");
const compute_port = @import("../backend/ports/compute.zig");
const transfer_port = @import("../backend/ports/transfer.zig");
const queue_port = @import("../backend/ports/queue.zig");
const readback_port = @import("../backend/ports/readback.zig");
const telemetry_port = @import("../backend/ports/telemetry.zig");
const render_port = @import("../backend/ports/render.zig");
const spatial_port = @import("../backend/ports/spatial.zig");
const backend_iface = @import("../backend/backend_iface.zig");

pub const BackendPortBundle = struct {
    id: backend_contract.BackendId,
    compute: compute_port.ComputePort,
    transfer: transfer_port.TransferPort,
    queue: queue_port.QueuePort,
    readback: readback_port.ReadbackPort,
    telemetry: telemetry_port.TelemetryPort,
    render: render_port.RenderPort,
    spatial: spatial_port.SpatialPort,

    pub fn fromBackendIface(iface: *backend_iface.BackendIface) BackendPortBundle {
        return .{
            .id = iface.id,
            .compute = iface.asComputePort(),
            .transfer = iface.asTransferPort(),
            .queue = iface.asQueuePort(),
            .readback = iface.asReadbackPort(),
            .telemetry = iface.asTelemetryPort(),
            .render = iface.asRenderPort(),
            .spatial = iface.asSpatialPort(),
        };
    }
};
