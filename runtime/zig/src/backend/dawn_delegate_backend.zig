const std = @import("std");
const model_commands = @import("../contracts/model/model_commands.zig");
const model_profile = @import("../contracts/model/model_profile.zig");
const model_transfer_types = @import("../contracts/model/model_compute_types.zig");
const webgpu = @import("webgpu_backend.zig");
const backend_ids = @import("backend_ids.zig");
const backend_iface = @import("backend_iface.zig");
const backend_telemetry = @import("backend_telemetry.zig");
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
        };
        return ptr;
    }

    pub fn as_iface(self: *DawnDelegateBackend, allocator: std.mem.Allocator, reason: []const u8, policy_hash: []const u8) !backend_iface.BackendIface {
        _ = allocator;
        return .{
            .id = self.effective_id,
            .context = self,
            .vtable = &VTABLE,
            .telemetry = .{
                .backend_id = self.effective_id,
                .backend_selection_reason = reason,
                .fallback_used = false,
                .selection_policy_hash = policy_hash,
                .shader_artifact_manifest_path = null,
                .shader_artifact_manifest_hash = null,
                .host_plan_artifact_path = null,
                .host_plan_artifact_hash = null,
                .adapter_ordinal = null,
                .queue_family_index = null,
                .present_capable = null,
            },
        };
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

fn execute_command(ctx: *anyopaque, command: model.Command) anyerror!webgpu.NativeExecutionResult {
    const self = cast(ctx);
    self.last_submit_count = null;
    const result = try self.inner.executeCommand(command);
    self.last_submit_count = submit_count_policy.selectedCommandSubmitCount(command, result);
    return result;
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

const VTABLE = backend_iface.BackendVTable{
    .deinit = deinit,
    .execute_command = execute_command,
    .execute_buffer_write_bytes = execute_buffer_write_bytes,
    .set_upload_behavior = set_upload_behavior,
    .set_queue_wait_mode = set_queue_wait_mode,
    .set_webgpu_ffi_queue_wait_timeout_ns = set_webgpu_ffi_queue_wait_timeout_ns,
    .set_queue_sync_mode = set_queue_sync_mode,
    .set_gpu_timestamp_mode = set_gpu_timestamp_mode,
    .flush_queue = flush_queue,
    .prewarm_upload_path = prewarm_upload_path,
    .prewarm_kernel_dispatch = prewarm_kernel_dispatch,
    .capture_buffer = capture_buffer,
};
