const std = @import("std");
const model_commands = @import("../contracts/command.zig");
const model_transfer_types = @import("../contracts/model/model_compute_types.zig");
const compute_contract = @import("../contracts/compute.zig");
const runtime_types = @import("runtime_types.zig");
const backend_ids = @import("../contracts/backend.zig");
const backend_telemetry = @import("backend_telemetry.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const KernelBinding = model_transfer_types.KernelBinding;
};

pub const BackendVTable = struct {
    deinit: *const fn (ctx: *anyopaque) void,
    execute_command: *const fn (ctx: *anyopaque, command: model.Command) anyerror!runtime_types.NativeExecutionResult,
    execute_dispatch: *const fn (context: compute_contract.ComputeContext, request: compute_contract.DispatchRequest) anyerror!compute_contract.DispatchReport,
    execute_buffer_write_bytes: *const fn (ctx: *anyopaque, handle: u64, offset: u64, buffer_size: u64, data: []const u8) anyerror!runtime_types.NativeExecutionResult,
    set_upload_behavior: *const fn (ctx: *anyopaque, mode: runtime_types.UploadBufferUsageMode, submit_every: u32) void,
    set_queue_wait_mode: *const fn (ctx: *anyopaque, mode: runtime_types.QueueWaitMode) void,
    set_webgpu_ffi_queue_wait_timeout_ns: *const fn (ctx: *anyopaque, timeout_ns: u64) void,
    set_queue_sync_mode: *const fn (ctx: *anyopaque, mode: runtime_types.QueueSyncMode) void,
    set_gpu_timestamp_mode: *const fn (ctx: *anyopaque, mode: runtime_types.GpuTimestampMode) void,
    flush_queue: *const fn (ctx: *anyopaque) anyerror!u64,
    prewarm_upload_path: *const fn (ctx: *anyopaque, max_upload_bytes: u64) anyerror!void,
    prewarm_kernel_dispatch: *const fn (
        ctx: *anyopaque,
        kernel: []const u8,
        entry_point: ?[]const u8,
        bindings: ?[]const model.KernelBinding,
        initialize_buffers_on_create: bool,
    ) anyerror!void,
    capture_buffer: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8,
};

pub const BackendIface = struct {
    id: backend_ids.BackendId,
    context: *anyopaque,
    vtable: *const BackendVTable,
    telemetry: backend_telemetry.BackendTelemetry,

    pub fn deinit(self: *BackendIface) void {
        self.vtable.deinit(self.context);
    }

    pub fn execute_command(self: *BackendIface, command: model.Command) !runtime_types.NativeExecutionResult {
        return switch (command) {
            .kernel_dispatch => |dispatch| (try self.execute_dispatch(
                compute_contract.DispatchRequest.fromCommand(dispatch),
            )).execution,
            else => try self.vtable.execute_command(self.context, command),
        };
    }

    pub fn execute_dispatch(self: *BackendIface, request: compute_contract.DispatchRequest) !compute_contract.DispatchReport {
        return try self.vtable.execute_dispatch(.{
            .backend = self.id,
            .state = self.context,
        }, request);
    }

    pub fn execute_buffer_write_bytes(self: *BackendIface, handle: u64, offset: u64, buffer_size: u64, data: []const u8) !runtime_types.NativeExecutionResult {
        return try self.vtable.execute_buffer_write_bytes(self.context, handle, offset, buffer_size, data);
    }

    pub fn set_upload_behavior(self: *BackendIface, mode: runtime_types.UploadBufferUsageMode, submit_every: u32) void {
        self.vtable.set_upload_behavior(self.context, mode, submit_every);
    }

    pub fn set_queue_wait_mode(self: *BackendIface, mode: runtime_types.QueueWaitMode) void {
        self.vtable.set_queue_wait_mode(self.context, mode);
    }

    pub fn set_webgpu_ffi_queue_wait_timeout_ns(self: *BackendIface, timeout_ns: u64) void {
        self.vtable.set_webgpu_ffi_queue_wait_timeout_ns(self.context, timeout_ns);
    }

    pub fn set_queue_sync_mode(self: *BackendIface, mode: runtime_types.QueueSyncMode) void {
        self.vtable.set_queue_sync_mode(self.context, mode);
    }

    pub fn set_gpu_timestamp_mode(self: *BackendIface, mode: runtime_types.GpuTimestampMode) void {
        self.vtable.set_gpu_timestamp_mode(self.context, mode);
    }

    pub fn flush_queue(self: *BackendIface) !u64 {
        return try self.vtable.flush_queue(self.context);
    }

    pub fn prewarm_upload_path(self: *BackendIface, max_upload_bytes: u64) !void {
        try self.vtable.prewarm_upload_path(self.context, max_upload_bytes);
    }

    pub fn prewarm_kernel_dispatch(
        self: *BackendIface,
        kernel: []const u8,
        entry_point: ?[]const u8,
        bindings: ?[]const model.KernelBinding,
        initialize_buffers_on_create: bool,
    ) !void {
        try self.vtable.prewarm_kernel_dispatch(
            self.context,
            kernel,
            entry_point,
            bindings,
            initialize_buffers_on_create,
        );
    }

    pub fn capture_buffer(self: *BackendIface, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) ![]u8 {
        return try self.vtable.capture_buffer(self.context, allocator, handle, offset, size);
    }

    pub fn asComputePort(self: *BackendIface) @import("ports/compute.zig").ComputePort {
        const compute_port = @import("ports/compute.zig");
        const prepared_op = @import("../contracts/prepared_operation.zig");
        const report_contract = @import("../contracts/execution_report.zig");

        const Bridge = struct {
            fn execute(ctx: *anyopaque, op: prepared_op.PreparedComputeOperation) anyerror!report_contract.ExecutionReport {
                const iface: *BackendIface = @ptrCast(@alignCast(ctx));
                const req = op.toDispatchRequest();
                const dispatch_report = try iface.execute_dispatch(req);
                return report_contract.ExecutionReport{
                    .status = switch (dispatch_report.execution.status) {
                        .ok => .ok,
                        .unsupported => .unsupported,
                        .@"error" => .@"error",
                    },
                    .status_message = dispatch_report.execution.status_message,
                    .timing = .{
                        .setup_ns = dispatch_report.execution.setup_ns,
                        .encode_ns = dispatch_report.execution.encode_ns,
                        .submit_wait_ns = dispatch_report.execution.submit_wait_ns,
                        .gpu_timestamp_ns = dispatch_report.execution.gpu_timestamp_ns,
                    },
                    .dispatch_count = dispatch_report.execution.dispatch_count,
                    .gpu_timestamp_valid = dispatch_report.execution.gpu_timestamp_valid,
                };
            }
        };
        const vtable = struct {
            const vt: compute_port.ComputePortVTable = .{
                .execute_compute = Bridge.execute,
            };
        };
        return .{
            .context = self,
            .vtable = &vtable.vt,
        };
    }

    pub fn asTransferPort(self: *BackendIface) @import("ports/transfer.zig").TransferPort {
        const transfer_port = @import("ports/transfer.zig");
        const prepared_op = @import("../contracts/prepared_operation.zig");
        const report_contract = @import("../contracts/execution_report.zig");

        const Bridge = struct {
            fn execute(ctx: *anyopaque, op: prepared_op.PreparedTransferOperation) anyerror!report_contract.ExecutionReport {
                const iface: *BackendIface = @ptrCast(@alignCast(ctx));
                const res = try iface.execute_buffer_write_bytes(op.buffer_handle, op.offset_bytes, op.size_bytes, op.data);
                return report_contract.ExecutionReport{
                    .status = switch (res.status) {
                        .ok => .ok,
                        .unsupported => .unsupported,
                        .@"error" => .@"error",
                    },
                    .status_message = res.status_message,
                    .timing = .{
                        .setup_ns = res.setup_ns,
                        .encode_ns = res.encode_ns,
                        .submit_wait_ns = res.submit_wait_ns,
                        .gpu_timestamp_ns = res.gpu_timestamp_ns,
                    },
                    .dispatch_count = 0,
                    .submit_count = 1,
                    .gpu_timestamp_valid = res.gpu_timestamp_valid,
                };
            }
        };
        const vtable = struct {
            const vt: transfer_port.TransferPortVTable = .{
                .execute_transfer = Bridge.execute,
            };
        };
        return .{
            .context = self,
            .vtable = &vtable.vt,
        };
    }

    pub fn asQueuePort(self: *BackendIface) @import("ports/queue.zig").QueuePort {
        const queue_port = @import("ports/queue.zig");

        const Bridge = struct {
            fn flush(ctx: *anyopaque) anyerror!u64 {
                const iface: *BackendIface = @ptrCast(@alignCast(ctx));
                return try iface.flush_queue();
            }
            fn sync(ctx: *anyopaque) anyerror!void {
                const iface: *BackendIface = @ptrCast(@alignCast(ctx));
                _ = try iface.flush_queue();
            }
        };
        const vtable = struct {
            const vt: queue_port.QueuePortVTable = .{
                .flush = Bridge.flush,
                .sync = Bridge.sync,
            };
        };
        return .{
            .context = self,
            .vtable = &vtable.vt,
        };
    }

    pub fn asReadbackPort(self: *BackendIface) @import("ports/readback.zig").ReadbackPort {
        const readback_port = @import("ports/readback.zig");

        const Bridge = struct {
            fn capture(ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8 {
                const iface: *BackendIface = @ptrCast(@alignCast(ctx));
                return try iface.capture_buffer(allocator, handle, offset, size);
            }
        };
        const vtable = struct {
            const vt: readback_port.ReadbackPortVTable = .{
                .capture_buffer = Bridge.capture,
            };
        };
        return .{
            .context = self,
            .vtable = &vtable.vt,
        };
    }

    pub fn asTelemetryPort(self: *BackendIface) @import("ports/telemetry.zig").TelemetryPort {
        const telemetry_port = @import("ports/telemetry.zig");

        const Bridge = struct {
            fn getTimestamp(ctx: *anyopaque) anyerror!u64 {
                const iface: *BackendIface = @ptrCast(@alignCast(ctx));
                return iface.telemetry.last_timing_ns;
            }
        };
        const vtable = struct {
            const vt: telemetry_port.TelemetryPortVTable = .{
                .get_gpu_timestamp_ns = Bridge.getTimestamp,
            };
        };
        return .{
            .context = self,
            .vtable = &vtable.vt,
        };
    }

    pub fn asRenderPort(self: *BackendIface) @import("ports/render.zig").RenderPort {
        const render_port = @import("ports/render.zig");
        const render_contract = @import("../contracts/render_command.zig");
        const report_contract = @import("../contracts/execution_report.zig");

        const Bridge = struct {
            fn executePass(ctx: *anyopaque, op: render_contract.PreparedRenderPassOperation) anyerror!report_contract.ExecutionReport {
                _ = ctx;
                _ = op;
                return report_contract.ExecutionReport.success(.{}, 0);
            }
            fn createPipe(ctx: *anyopaque, op: render_contract.PreparedPipelineOperation) anyerror!report_contract.ExecutionReport {
                _ = ctx;
                _ = op;
                return report_contract.ExecutionReport.success(.{}, 0);
            }
        };
        const vtable = struct {
            const vt: render_port.RenderPortVTable = .{
                .execute_render_pass = Bridge.executePass,
                .create_pipeline = Bridge.createPipe,
            };
        };
        return .{
            .context = self,
            .vtable = &vtable.vt,
        };
    }

    pub fn asSpatialPort(self: *BackendIface) @import("ports/spatial.zig").SpatialPort {
        const spatial_port = @import("ports/spatial.zig");
        const spatial_contract = @import("../contracts/spatial_operation.zig");
        const report_contract = @import("../contracts/execution_report.zig");

        const Bridge = struct {
            fn execute(ctx: *anyopaque, op: spatial_contract.PreparedSpatialOperation) anyerror!report_contract.ExecutionReport {
                _ = ctx;
                _ = op;
                return report_contract.ExecutionReport.success(.{}, 0);
            }
        };
        const vtable = struct {
            const vt: spatial_port.SpatialPortVTable = .{
                .execute_spatial = Bridge.execute,
            };
        };
        return .{
            .context = self,
            .vtable = &vtable.vt,
        };
    }
};
