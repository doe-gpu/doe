//! Compile-time adapter from a concrete provider driver to narrow runtime ports.
//!
//! This is deliberately not a runtime backend vtable. Each instantiation binds
//! a concrete provider's functions directly into capability-specific ports, so
//! application code can receive a `PortBundle` without a catch-all execution
//! interface surviving at runtime.

const std = @import("std");
const prepared = @import("../../contracts/prepared_operation.zig");
const report = @import("../../contracts/execution_report.zig");
const configuration = @import("../../contracts/runtime_configuration.zig");
const model_compute = @import("../../contracts/model/model_compute_types.zig");
const backend_contract = @import("../../contracts/backend.zig");
const compute_port = @import("compute.zig");
const transfer_port = @import("transfer.zig");
const queue_port = @import("queue.zig");
const readback_port = @import("readback.zig");
const telemetry_port = @import("telemetry.zig");
const render_port = @import("render.zig");
const spatial_port = @import("spatial.zig");
const resource_port = @import("resource.zig");
const surface_port = @import("surface.zig");
const lifecycle_port = @import("lifecycle.zig");
const factory = @import("factory.zig");

pub fn fromDriver(
    comptime Driver: type,
    context: *anyopaque,
    backend_id: backend_contract.BackendId,
) factory.PortBundle {
    const Bridge = struct {
        fn executeCompute(ctx: *anyopaque, operation: prepared.PreparedComputeOperation) anyerror!report.ExecutionReport {
            if (operation.toDispatchRequest()) |request| {
                const dispatch_report = try Driver.executeDispatch(.{
                    .backend = Driver.backendId(ctx),
                    .state = ctx,
                }, request);
                return report.ExecutionReport.fromNative(dispatch_report.execution);
            }
            return report.ExecutionReport.fromNative(try Driver.executePreparedCompute(ctx, operation));
        }

        fn prewarmKernel(ctx: *anyopaque, kernel: []const u8, entry_point: ?[]const u8, bindings: ?[]const model_compute.KernelBinding, initialize_buffers_on_create: bool) anyerror!void {
            return Driver.prewarmKernel(ctx, kernel, entry_point, bindings, initialize_buffers_on_create);
        }

        fn setGpuTimestampMode(ctx: *anyopaque, mode: configuration.GpuTimestampMode) void {
            Driver.setGpuTimestampMode(ctx, mode);
        }

        fn executeTransfer(ctx: *anyopaque, operation: prepared.PreparedTransferOperation) anyerror!report.ExecutionReport {
            return switch (operation.operation) {
                .direct_buffer_write => |write| report.ExecutionReport.fromNative(try Driver.executeBufferWrite(
                    ctx,
                    write.handle,
                    write.offset_bytes,
                    write.buffer_size,
                    write.data,
                )),
                else => report.ExecutionReport.fromNative(try Driver.executePreparedTransfer(ctx, operation)),
            };
        }

        fn prewarmUpload(ctx: *anyopaque, max_upload_bytes: u64) anyerror!void {
            return Driver.prewarmUpload(ctx, max_upload_bytes);
        }

        fn setUploadBehavior(ctx: *anyopaque, mode: configuration.UploadBufferUsageMode, submit_every: u32) void {
            Driver.setUploadBehavior(ctx, mode, submit_every);
        }

        fn executeRender(ctx: *anyopaque, operation: prepared.PreparedRenderOperation) anyerror!report.ExecutionReport {
            return report.ExecutionReport.fromNative(try Driver.executePreparedRender(ctx, operation));
        }

        fn executeResource(ctx: *anyopaque, operation: prepared.PreparedResourceOperation) anyerror!report.ExecutionReport {
            return report.ExecutionReport.fromNative(try Driver.executePreparedResource(ctx, operation));
        }

        fn executeSurface(ctx: *anyopaque, operation: prepared.PreparedSurfaceOperation) anyerror!report.ExecutionReport {
            return report.ExecutionReport.fromNative(try Driver.executePreparedSurface(ctx, operation));
        }

        fn executeLifecycle(ctx: *anyopaque, operation: prepared.PreparedLifecycleOperation) anyerror!report.ExecutionReport {
            return report.ExecutionReport.fromNative(try Driver.executePreparedLifecycle(ctx, operation));
        }

        fn executeSpatial(ctx: *anyopaque, operation: prepared.PreparedSpatialOperation) anyerror!report.ExecutionReport {
            _ = ctx;
            _ = operation;
            return report.ExecutionReport.unsupported("spatial execution requires a qualified spatial adapter");
        }

        fn flush(ctx: *anyopaque) anyerror!u64 {
            return Driver.flush(ctx);
        }

        fn sync(ctx: *anyopaque) anyerror!void {
            _ = try Driver.flush(ctx);
        }

        fn setQueueWaitMode(ctx: *anyopaque, mode: configuration.QueueWaitMode) void {
            Driver.setQueueWaitMode(ctx, mode);
        }

        fn setQueueWaitTimeoutNs(ctx: *anyopaque, timeout_ns: u64) void {
            Driver.setQueueWaitTimeoutNs(ctx, timeout_ns);
        }

        fn setQueueSyncMode(ctx: *anyopaque, mode: configuration.QueueSyncMode) void {
            Driver.setQueueSyncMode(ctx, mode);
        }

        fn capture(ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8 {
            return Driver.capture(ctx, allocator, handle, offset, size);
        }

        fn timestamp(ctx: *anyopaque) anyerror!u64 {
            _ = ctx;
            return error.UnsupportedFeature;
        }
    };
    const VTables = struct {
        const compute: compute_port.ComputePortVTable = .{
            .execute_compute = Bridge.executeCompute,
            .prewarm_kernel = Bridge.prewarmKernel,
            .set_gpu_timestamp_mode = Bridge.setGpuTimestampMode,
        };
        const transfer: transfer_port.TransferPortVTable = .{
            .execute_transfer = Bridge.executeTransfer,
            .prewarm_upload = Bridge.prewarmUpload,
            .set_upload_behavior = Bridge.setUploadBehavior,
        };
        const render: render_port.RenderPortVTable = .{ .execute_render = Bridge.executeRender };
        const resource: resource_port.ResourcePortVTable = .{ .execute_resource = Bridge.executeResource };
        const surface: surface_port.SurfacePortVTable = .{ .execute_surface = Bridge.executeSurface };
        const lifecycle: lifecycle_port.LifecyclePortVTable = .{ .execute_lifecycle = Bridge.executeLifecycle };
        const spatial: spatial_port.SpatialPortVTable = .{ .execute_spatial = Bridge.executeSpatial };
        const queue: queue_port.QueuePortVTable = .{
            .flush = Bridge.flush,
            .sync = Bridge.sync,
            .set_wait_mode = Bridge.setQueueWaitMode,
            .set_wait_timeout_ns = Bridge.setQueueWaitTimeoutNs,
            .set_sync_mode = Bridge.setQueueSyncMode,
        };
        const readback: readback_port.ReadbackPortVTable = .{ .capture_buffer = Bridge.capture };
        const telemetry: telemetry_port.TelemetryPortVTable = .{
            .get_gpu_timestamp_ns = Bridge.timestamp,
            .snapshot = Driver.telemetrySnapshot,
        };
    };

    return .{
        .id = backend_id,
        .compute = .{ .context = context, .vtable = &VTables.compute },
        .transfer = .{ .context = context, .vtable = &VTables.transfer },
        .queue = .{ .context = context, .vtable = &VTables.queue },
        .readback = .{ .context = context, .vtable = &VTables.readback },
        .telemetry = .{ .context = context, .vtable = &VTables.telemetry },
        .render = .{ .context = context, .vtable = &VTables.render },
        .resource = .{ .context = context, .vtable = &VTables.resource },
        .surface = .{ .context = context, .vtable = &VTables.surface },
        .lifecycle = .{ .context = context, .vtable = &VTables.lifecycle },
        .spatial = .{ .context = context, .vtable = &VTables.spatial },
    };
}
