//! Narrow outbound backend ports module.
//!
//! Exposes single-responsibility ports for compute, transfer, queue, readback, and telemetry.

pub const compute = @import("compute.zig");
pub const transfer = @import("transfer.zig");
pub const queue = @import("queue.zig");
pub const readback = @import("readback.zig");
pub const telemetry = @import("telemetry.zig");
pub const render = @import("render.zig");
pub const spatial = @import("spatial.zig");
pub const capture = @import("capture.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const provider_adapter = @import("provider_adapter.zig");
pub const resource = @import("resource.zig");
pub const surface = @import("surface.zig");
pub const factory = @import("factory.zig");

pub const ComputePort = compute.ComputePort;
pub const ComputePortVTable = compute.ComputePortVTable;

pub const TransferPort = transfer.TransferPort;
pub const TransferPortVTable = transfer.TransferPortVTable;

pub const QueuePort = queue.QueuePort;
pub const QueuePortVTable = queue.QueuePortVTable;

pub const ReadbackPort = readback.ReadbackPort;
pub const ReadbackPortVTable = readback.ReadbackPortVTable;

pub const TelemetryPort = telemetry.TelemetryPort;
pub const TelemetryPortVTable = telemetry.TelemetryPortVTable;

pub const RenderPort = render.RenderPort;
pub const RenderPortVTable = render.RenderPortVTable;

pub const SpatialPort = spatial.SpatialPort;
pub const SpatialPortVTable = spatial.SpatialPortVTable;

pub const CapturePort = capture.CapturePort;
pub const CapturePortVTable = capture.CapturePortVTable;
pub const LifecyclePort = lifecycle.LifecyclePort;
pub const LifecyclePortVTable = lifecycle.LifecyclePortVTable;
pub const ResourcePort = resource.ResourcePort;
pub const ResourcePortVTable = resource.ResourcePortVTable;
pub const SurfacePort = surface.SurfacePort;
pub const SurfacePortVTable = surface.SurfacePortVTable;
pub const PortBundle = factory.PortBundle;
