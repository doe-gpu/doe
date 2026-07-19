const std = @import("std");
const model_commands = @import("../contracts/model/model_commands.zig");
const model_transfer_types = @import("../contracts/model/model_compute_types.zig");
const runtime_types = @import("runtime_types.zig");
const backend_ids = @import("backend_ids.zig");
const backend_telemetry = @import("backend_telemetry.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const KernelBinding = model_transfer_types.KernelBinding;
};

pub const BackendVTable = struct {
    deinit: *const fn (ctx: *anyopaque) void,
    execute_command: *const fn (ctx: *anyopaque, command: model.Command) anyerror!runtime_types.NativeExecutionResult,
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
        return try self.vtable.execute_command(self.context, command);
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
};
