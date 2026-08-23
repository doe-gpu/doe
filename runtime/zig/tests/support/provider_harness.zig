//! Test-only owner for a concrete provider exercised through application ports.

const std = @import("std");
const app = @import("../../src/app/mod.zig");
const command_contract = @import("../../src/contracts/command.zig");
const compute_contract = @import("../../src/contracts/compute.zig");
const runtime_types = @import("../../src/contracts/runtime_types.zig");
const runtime_telemetry = @import("../../src/contracts/runtime_telemetry.zig");
const port_factory = @import("../../src/backend/ports/factory.zig");

pub const ProviderHarness = struct {
    id: @import("../../src/contracts/backend.zig").BackendId,
    telemetry: runtime_telemetry.RuntimeTelemetry,
    ports: port_factory.PortBundle,
    context: *anyopaque,
    destroy_context: *const fn (*anyopaque) void,
    next_operation_id: u64 = 1,

    pub fn init(
        ports: port_factory.PortBundle,
        context: *anyopaque,
        destroy_context: *const fn (*anyopaque) void,
    ) ProviderHarness {
        return .{
            .id = ports.id,
            .telemetry = ports.telemetry.snapshot(),
            .ports = ports,
            .context = context,
            .destroy_context = destroy_context,
        };
    }

    pub fn deinit(self: *ProviderHarness) void {
        self.destroy_context(self.context);
        self.context = undefined;
    }

    pub fn execute_command(self: *ProviderHarness, command: command_contract.Command) !runtime_types.NativeExecutionResult {
        const operation_id = self.next_operation_id;
        self.next_operation_id +%= 1;
        return (try app.executePrepared(
            self.ports,
            app.prepareCommand(command, operation_id),
        )).toNative();
    }

    pub fn execute_dispatch(self: *ProviderHarness, request: compute_contract.DispatchRequest) !compute_contract.DispatchReport {
        return .{ .execution = try self.execute_command(.{ .kernel_dispatch = request.toCommand() }) };
    }

    pub fn execute_buffer_write_bytes(self: *ProviderHarness, handle: u64, offset: u64, buffer_size: u64, data: []const u8) !runtime_types.NativeExecutionResult {
        const operation_id = self.next_operation_id;
        self.next_operation_id +%= 1;
        return (try app.executePrepared(self.ports, .{ .transfer = app.prepareTransfer(.{
            .buffer_handle = handle,
            .offset_bytes = offset,
            .size_bytes = buffer_size,
            .data = data,
        }, operation_id) })).toNative();
    }

    pub fn set_upload_behavior(self: *ProviderHarness, mode: runtime_types.UploadBufferUsageMode, submit_every: u32) void {
        self.ports.transfer.setUploadBehavior(mode, submit_every);
    }

    pub fn set_queue_wait_mode(self: *ProviderHarness, mode: runtime_types.QueueWaitMode) void {
        self.ports.queue.setWaitMode(mode);
    }

    pub fn set_webgpu_ffi_queue_wait_timeout_ns(self: *ProviderHarness, timeout_ns: u64) void {
        self.ports.queue.setWaitTimeoutNs(timeout_ns);
    }

    pub fn set_queue_sync_mode(self: *ProviderHarness, mode: runtime_types.QueueSyncMode) void {
        self.ports.queue.setSyncMode(mode);
    }

    pub fn set_gpu_timestamp_mode(self: *ProviderHarness, mode: runtime_types.GpuTimestampMode) void {
        self.ports.compute.setGpuTimestampMode(mode);
    }

    pub fn flush_queue(self: *ProviderHarness) !u64 {
        return self.ports.queue.flush();
    }

    pub fn capture_buffer(self: *ProviderHarness, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) ![]u8 {
        return self.ports.readback.captureBuffer(allocator, handle, offset, size);
    }
};
