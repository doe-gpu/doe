const std = @import("std");
const model_commands = @import("../model_commands.zig");
const model_profile = @import("../model_profile.zig");
const model_transfer_types = @import("../model_compute_types.zig");
const backend_iface = @import("backend_iface.zig");
const backend_policy = @import("backend_policy.zig");
const backend_registry = @import("backend_registry.zig");
const backend_runtime_telemetry = @import("backend_runtime_telemetry.zig");
const backend_selection = @import("backend_selection.zig");
const backend_telemetry = @import("backend_telemetry.zig");
const runtime_types = @import("runtime_types.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const KernelBinding = model_transfer_types.KernelBinding;
};

pub const BackendRuntime = struct {
    allocator: std.mem.Allocator,
    backend: backend_iface.BackendIface,
    owned_policy_hash: ?[]u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
        lane: backend_policy.BackendLane,
    ) !BackendRuntime {
        return try init_with_policy_path(
            allocator,
            profile,
            kernel_root,
            lane,
            backend_policy.DEFAULT_RUNTIME_POLICY_PATH,
        );
    }

    pub fn init_with_policy_path(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
        lane: backend_policy.BackendLane,
        policy_path: []const u8,
    ) !BackendRuntime {
        const loaded_policy = try backend_policy.load_policy_for_lane(
            allocator,
            policy_path,
            lane,
        );
        errdefer allocator.free(loaded_policy.owned_policy_hash);
        const policy = loaded_policy.policy;
        const selected = backend_selection.select_backend(profile, policy);
        var backend = try backend_registry.init_backend(
            allocator,
            policy,
            selected.backend_id,
            profile,
            kernel_root,
            selected.reason,
        );
        backend.telemetry.fallback_used = selected.fallback_used;
        return .{
            .allocator = allocator,
            .backend = backend,
            .owned_policy_hash = loaded_policy.owned_policy_hash,
        };
    }

    pub fn deinit(self: *BackendRuntime) void {
        self.backend.deinit();
        if (self.owned_policy_hash) |value| {
            self.allocator.free(value);
            self.owned_policy_hash = null;
        }
    }

    pub fn execute_command(self: *BackendRuntime, command: model.Command) !runtime_types.NativeExecutionResult {
        return try self.backend.execute_command(command);
    }

    pub fn execute_buffer_write_bytes(self: *BackendRuntime, handle: u64, offset: u64, buffer_size: u64, data: []const u8) !runtime_types.NativeExecutionResult {
        return try self.backend.execute_buffer_write_bytes(handle, offset, buffer_size, data);
    }

    pub fn set_upload_behavior(self: *BackendRuntime, mode: runtime_types.UploadBufferUsageMode, submit_every: u32) void {
        self.backend.set_upload_behavior(mode, submit_every);
    }

    pub fn set_queue_wait_mode(self: *BackendRuntime, mode: runtime_types.QueueWaitMode) void {
        self.backend.set_queue_wait_mode(mode);
    }

    pub fn set_webgpu_ffi_queue_wait_timeout_ns(self: *BackendRuntime, timeout_ns: u64) void {
        self.backend.set_webgpu_ffi_queue_wait_timeout_ns(timeout_ns);
    }

    pub fn set_queue_sync_mode(self: *BackendRuntime, mode: runtime_types.QueueSyncMode) void {
        self.backend.set_queue_sync_mode(mode);
    }

    pub fn set_gpu_timestamp_mode(self: *BackendRuntime, mode: runtime_types.GpuTimestampMode) void {
        self.backend.set_gpu_timestamp_mode(mode);
    }

    pub fn flush_queue(self: *BackendRuntime) !u64 {
        return try self.backend.flush_queue();
    }

    pub fn prewarm_upload_path(self: *BackendRuntime, max_upload_bytes: u64) !void {
        try self.backend.prewarm_upload_path(max_upload_bytes);
    }

    pub fn prewarm_kernel_dispatch(
        self: *BackendRuntime,
        kernel: []const u8,
        entry_point: ?[]const u8,
        bindings: ?[]const model.KernelBinding,
        initialize_buffers_on_create: bool,
    ) !void {
        try self.backend.prewarm_kernel_dispatch(
            kernel,
            entry_point,
            bindings,
            initialize_buffers_on_create,
        );
    }

    pub fn capture_buffer(self: *BackendRuntime, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) ![]u8 {
        return try self.backend.capture_buffer(allocator, handle, offset, size);
    }

    pub fn telemetry(self: *BackendRuntime) backend_telemetry.BackendTelemetry {
        backend_runtime_telemetry.refresh(&self.backend);
        return self.backend.telemetry;
    }
};
