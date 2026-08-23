const std = @import("std");
const model_commands = @import("../contracts/command.zig");
const model_profile = @import("../contracts/model/model_profile.zig");
const model_transfer_types = @import("../contracts/model/model_compute_types.zig");
const compute_contract = @import("../contracts/compute.zig");
const webgpu = @import("webgpu_backend.zig");
const backend_ids = @import("../contracts/backend.zig");
const runtime_telemetry = @import("../contracts/runtime_telemetry.zig");
const backend_telemetry = @import("backend_telemetry.zig");
const port_factory = @import("ports/factory.zig");
const provider_adapter = @import("ports/provider_adapter.zig");
const submit_count_policy = @import("common/submit_count_policy.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const KernelBinding = model_transfer_types.KernelBinding;
};

pub const DawnDelegateBackend = struct {
    allocator: std.mem.Allocator,
    inner: webgpu.WebGPUBackend,
    effective_id: backend_ids.BackendId,
    last_submit_count: ?u32 = null,
    telemetry: runtime_telemetry.RuntimeTelemetry = backend_telemetry.default_telemetry(),

    pub fn init(allocator: std.mem.Allocator, profile: model.DeviceProfile, kernel_root: ?[]const u8) !*DawnDelegateBackend {
        return init_with_id(allocator, profile, kernel_root, .dawn_delegate);
    }

    pub fn init_with_id(allocator: std.mem.Allocator, profile: model.DeviceProfile, kernel_root: ?[]const u8, id: backend_ids.BackendId) !*DawnDelegateBackend {
        const ptr = try allocator.create(DawnDelegateBackend);
        errdefer allocator.destroy(ptr);
        ptr.* = .{
            .allocator = allocator,
            .inner = try webgpu.WebGPUBackend.init(allocator, profile, kernel_root),
            .effective_id = id,
            .last_submit_count = null,
            .telemetry = backend_telemetry.default_telemetry(),
        };
        return ptr;
    }

    pub fn asPorts(self: *DawnDelegateBackend, reason: []const u8, policy_hash: []const u8, fallback_used: bool) port_factory.PortBundle {
        self.telemetry = backend_telemetry.forSelection(self.effective_id, reason, fallback_used, policy_hash);
        return provider_adapter.fromDriver(PortDriver, self, self.effective_id);
    }
};

fn cast(ctx: *anyopaque) *DawnDelegateBackend {
    return @as(*DawnDelegateBackend, @ptrCast(@alignCast(ctx)));
}

fn deinit(ctx: *anyopaque) void {
    const self = cast(ctx);
    const allocator = self.allocator;
    self.inner.deinit();
    allocator.destroy(self);
}

fn execute_command_typed(self: *DawnDelegateBackend, command: model.Command) anyerror!webgpu.NativeExecutionResult {
    self.last_submit_count = null;
    const result = try self.inner.executeCommand(command);
    self.last_submit_count = submit_count_policy.selectedCommandSubmitCount(command, result);
    return result;
}

fn execute_command(ctx: *anyopaque, command: model.Command) anyerror!webgpu.NativeExecutionResult {
    return execute_command_typed(cast(ctx), command);
}

fn execute_dispatch(context: compute_contract.ComputeContext, request: compute_contract.DispatchRequest) anyerror!compute_contract.DispatchReport {
    const result = try execute_command_typed(cast(context.state), .{ .kernel_dispatch = request.toCommand() });
    return .{ .execution = result };
}

fn execute_buffer_write_bytes(ctx: *anyopaque, handle: u64, offset: u64, buffer_size: u64, data: []const u8) anyerror!webgpu.NativeExecutionResult {
    const self = cast(ctx);
    self.last_submit_count = null;
    const result = try self.inner.executeBufferWriteBytes(handle, offset, buffer_size, data);
    self.last_submit_count = submit_count_policy.selectedKindSubmitCount(.buffer_write, result);
    return result;
}

pub fn last_submit_count_from_context(ctx: *anyopaque) ?u32 {
    return cast(ctx).last_submit_count;
}

fn set_upload_behavior(ctx: *anyopaque, mode: webgpu.UploadBufferUsageMode, submit_every: u32) void {
    const self = cast(ctx);
    self.inner.setUploadBehavior(mode, submit_every);
}

fn set_queue_wait_mode(ctx: *anyopaque, mode: webgpu.QueueWaitMode) void {
    const self = cast(ctx);
    self.inner.setQueueWaitMode(mode);
}

fn set_webgpu_ffi_queue_wait_timeout_ns(ctx: *anyopaque, timeout_ns: u64) void {
    const self = cast(ctx);
    self.inner.setWebgpuFfiQueueWaitTimeoutNs(timeout_ns);
}

fn set_queue_sync_mode(ctx: *anyopaque, mode: webgpu.QueueSyncMode) void {
    const self = cast(ctx);
    self.inner.setQueueSyncMode(mode);
}

fn set_gpu_timestamp_mode(ctx: *anyopaque, mode: webgpu.GpuTimestampMode) void {
    const self = cast(ctx);
    self.inner.setGpuTimestampMode(mode);
}

fn flush_queue(ctx: *anyopaque) anyerror!u64 {
    const self = cast(ctx);
    return try self.inner.flushQueue();
}

fn prewarm_upload_path(ctx: *anyopaque, max_upload_bytes: u64) anyerror!void {
    const self = cast(ctx);
    try self.inner.prewarmUploadPath(max_upload_bytes);
}

fn prewarm_kernel_dispatch(
    ctx: *anyopaque,
    kernel: []const u8,
    entry_point: ?[]const u8,
    bindings: ?[]const model.KernelBinding,
    initialize_buffers_on_create: bool,
) anyerror!void {
    // Dawn's internal pipeline cache handles repeat-compilation efficiently.
    // Prewarming with layout=null creates pipelines incompatible with bind groups,
    // so prewarm is a no-op for the delegate path.
    _ = ctx;
    _ = kernel;
    _ = entry_point;
    _ = bindings;
    _ = initialize_buffers_on_create;
}

fn capture_buffer(ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8 {
    const self = cast(ctx);
    return try self.inner.captureBuffer(allocator, handle, offset, size);
}

fn telemetry_snapshot(ctx: *anyopaque) runtime_telemetry.RuntimeTelemetry {
    const self = cast(ctx);
    self.telemetry.last_submit_count = self.last_submit_count;
    return self.telemetry;
}

fn backend_id(ctx: *anyopaque) backend_ids.BackendId {
    return cast(ctx).effective_id;
}

pub fn destroyContext(ctx: *anyopaque) void {
    deinit(ctx);
}

const PortDriver = struct {
    pub const backendId = backend_id;
    pub const executeCommand = execute_command;
    pub const executeDispatch = execute_dispatch;
    pub const executeBufferWrite = execute_buffer_write_bytes;
    pub const setUploadBehavior = set_upload_behavior;
    pub const setQueueWaitMode = set_queue_wait_mode;
    pub const setQueueWaitTimeoutNs = set_webgpu_ffi_queue_wait_timeout_ns;
    pub const setQueueSyncMode = set_queue_sync_mode;
    pub const setGpuTimestampMode = set_gpu_timestamp_mode;
    pub const flush = flush_queue;
    pub const prewarmUpload = prewarm_upload_path;
    pub const prewarmKernel = prewarm_kernel_dispatch;
    pub const capture = capture_buffer;
    pub const telemetrySnapshot = telemetry_snapshot;
};
