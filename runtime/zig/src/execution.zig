const std = @import("std");
const model_commands = @import("model_commands.zig");
const model_profile = @import("model_profile.zig");
const model_transfer_types = @import("model_compute_types.zig");
const backend_runtime = @import("backend/backend_runtime.zig");
const backend_ids = @import("backend/backend_ids.zig");
const backend_policy = @import("backend/backend_policy.zig");
const backend_telemetry = @import("backend/backend_telemetry.zig");
const runtime_types = @import("backend/runtime_types.zig");
const wgpu_loader = @import("core/abi/wgpu_loader.zig");
const semantic_trace = @import("semantic_trace.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const KernelBinding = model_transfer_types.KernelBinding;
    pub const SemVer = model_profile.SemVer;
};

pub const BackendMode = enum {
    trace,
    native,
};

pub const DEFAULT_WEBGPU_FFI_QUEUE_WAIT_TIMEOUT_NS: u64 = wgpu_loader.QUEUE_WAIT_TIMEOUT_NS;

pub const ExecutionStatus = enum {
    skipped,
    ok,
    unsupported,
    @"error",
};

pub const ExecutionResult = struct {
    backend: []const u8,
    status: ExecutionStatus,
    status_code: []const u8,
    duration_ns: u64,
    setup_ns: u64,
    encode_ns: u64,
    submit_wait_ns: u64,
    dispatch_count: u32,
    submit_count: u32,
    gpu_timestamp_ns: u64,
    gpu_timestamp_attempted: bool,
    gpu_timestamp_valid: bool,
    backend_selection_reason: ?[]const u8,
    fallback_used: ?bool,
    selection_policy_hash: ?[]const u8,
    shader_artifact_manifest_path: ?[]const u8,
    shader_artifact_manifest_hash: ?[]const u8,
    host_plan_artifact_path: ?[]const u8,
    host_plan_artifact_hash: ?[]const u8,
    backend_lane: ?[]const u8,
    adapter_ordinal: ?u32,
    queue_family_index: ?u32,
    present_capable: ?bool,
    queue_family_policy: ?[]const u8 = null,
    queue_family_kind: ?[]const u8 = null,
    queue_family_queue_count: ?u32 = null,
    queue_family_timestamp_valid_bits: ?u32 = null,
    queue_family_supports_graphics: ?bool = null,
    semantic: semantic_trace.SemanticContext = .{},
};

pub const ExecutionContext = struct {
    allocator: std.mem.Allocator,
    mode: BackendMode,
    backend_lane: backend_policy.BackendLane,
    backend: ?backend_runtime.BackendRuntime,

    pub fn init(
        allocator: std.mem.Allocator,
        mode: BackendMode,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
        lane: backend_policy.BackendLane,
    ) !ExecutionContext {
        switch (mode) {
            .trace => {
                return .{
                    .allocator = allocator,
                    .mode = .trace,
                    .backend_lane = lane,
                    .backend = null,
                };
            },
            .native => {
                const native_backend = try backend_runtime.BackendRuntime.init(allocator, profile, kernel_root, lane);
                return .{
                    .allocator = allocator,
                    .mode = .native,
                    .backend_lane = lane,
                    .backend = native_backend,
                };
            },
        }
    }

    pub fn deinit(self: *ExecutionContext) void {
        if (self.backend) |*backend| {
            backend.deinit();
        }
        _ = self.allocator;
        self.backend = null;
    }

    pub fn telemetry(self: *ExecutionContext) ?backend_telemetry.BackendTelemetry {
        if (self.backend) |*backend| {
            return backend.telemetry();
        }
        return null;
    }

    pub fn execute(self: *ExecutionContext, command: model.Command) !ExecutionResult {
        return try self.execute_with_semantic(command, .{});
    }

    pub fn execute_buffer_write_bytes_with_semantic(
        self: *ExecutionContext,
        handle: u64,
        offset: u64,
        buffer_size: u64,
        data: []const u8,
        semantic: semantic_trace.SemanticContext,
    ) !ExecutionResult {
        const mode_name = executionModeName(self.mode);
        if (self.mode == .trace) {
            return .{
                .backend = mode_name,
                .status = .skipped,
                .status_code = "disabled",
                .duration_ns = 0,
                .setup_ns = 0,
                .encode_ns = 0,
                .submit_wait_ns = 0,
                .dispatch_count = 0,
                .submit_count = 0,
                .gpu_timestamp_ns = 0,
                .gpu_timestamp_attempted = false,
                .gpu_timestamp_valid = false,
                .backend_selection_reason = null,
                .fallback_used = null,
                .selection_policy_hash = null,
                .shader_artifact_manifest_path = null,
                .shader_artifact_manifest_hash = null,
                .host_plan_artifact_path = null,
                .host_plan_artifact_hash = null,
                .backend_lane = null,
                .adapter_ordinal = null,
                .queue_family_index = null,
                .present_capable = null,
                .semantic = semantic,
            };
        }
        if (self.backend == null) {
            return .{
                .backend = mode_name,
                .status = .@"error",
                .status_code = "missing-backend",
                .duration_ns = 0,
                .setup_ns = 0,
                .encode_ns = 0,
                .submit_wait_ns = 0,
                .dispatch_count = 0,
                .submit_count = 0,
                .gpu_timestamp_ns = 0,
                .gpu_timestamp_attempted = false,
                .gpu_timestamp_valid = false,
                .backend_selection_reason = null,
                .fallback_used = null,
                .selection_policy_hash = null,
                .shader_artifact_manifest_path = null,
                .shader_artifact_manifest_hash = null,
                .host_plan_artifact_path = null,
                .host_plan_artifact_hash = null,
                .backend_lane = backendLaneName(self.backend_lane),
                .adapter_ordinal = null,
                .queue_family_index = null,
                .present_capable = null,
                .semantic = semantic,
            };
        }

        if (self.backend) |*backend| {
            const backend_telemetry_snapshot = backend.telemetry();
            const command_start = std.time.nanoTimestamp();
            const status = backend.execute_buffer_write_bytes(handle, offset, buffer_size, data) catch |err| {
                const command_end = std.time.nanoTimestamp();
                const elapsed_ns = if (command_end > command_start)
                    @as(u64, @intCast(command_end - command_start))
                else
                    0;
                const command_telemetry = backend.telemetry();
                return .{
                    .backend = backend_id_name(backend_telemetry_snapshot.backend_id),
                    .status = .@"error",
                    .status_code = @errorName(err),
                    .duration_ns = elapsed_ns,
                    .setup_ns = 0,
                    .encode_ns = 0,
                    .submit_wait_ns = 0,
                    .dispatch_count = 0,
                    .submit_count = 0,
                    .gpu_timestamp_ns = 0,
                    .gpu_timestamp_attempted = false,
                    .gpu_timestamp_valid = false,
                    .backend_selection_reason = command_telemetry.backend_selection_reason,
                    .fallback_used = command_telemetry.fallback_used,
                    .selection_policy_hash = command_telemetry.selection_policy_hash,
                    .shader_artifact_manifest_path = command_telemetry.shader_artifact_manifest_path,
                    .shader_artifact_manifest_hash = command_telemetry.shader_artifact_manifest_hash,
                    .host_plan_artifact_path = command_telemetry.host_plan_artifact_path,
                    .host_plan_artifact_hash = command_telemetry.host_plan_artifact_hash,
                    .backend_lane = backendLaneName(self.backend_lane),
                    .adapter_ordinal = command_telemetry.adapter_ordinal,
                    .queue_family_index = command_telemetry.queue_family_index,
                    .present_capable = command_telemetry.present_capable,
                    .queue_family_policy = command_telemetry.queue_family_policy,
                    .queue_family_kind = command_telemetry.queue_family_kind,
                    .queue_family_queue_count = command_telemetry.queue_family_queue_count,
                    .queue_family_timestamp_valid_bits = command_telemetry.queue_family_timestamp_valid_bits,
                    .queue_family_supports_graphics = command_telemetry.queue_family_supports_graphics,
                    .semantic = semantic,
                };
            };
            const command_end = std.time.nanoTimestamp();
            const elapsed_ns = if (command_end > command_start)
                @as(u64, @intCast(command_end - command_start))
            else
                0;
            const command_telemetry = backend.telemetry();
            const submit_count = command_telemetry.last_submit_count orelse 0;

            return .{
                .backend = backend_id_name(backend_telemetry_snapshot.backend_id),
                .status = if (status.status == .ok) .ok else if (status.status == .@"error") .@"error" else .unsupported,
                .status_code = status.status_message,
                .duration_ns = elapsed_ns,
                .setup_ns = status.setup_ns,
                .encode_ns = status.encode_ns,
                .submit_wait_ns = status.submit_wait_ns,
                .dispatch_count = status.dispatch_count,
                .submit_count = submit_count,
                .gpu_timestamp_ns = status.gpu_timestamp_ns,
                .gpu_timestamp_attempted = status.gpu_timestamp_attempted,
                .gpu_timestamp_valid = status.gpu_timestamp_valid,
                .backend_selection_reason = command_telemetry.backend_selection_reason,
                .fallback_used = command_telemetry.fallback_used,
                .selection_policy_hash = command_telemetry.selection_policy_hash,
                .shader_artifact_manifest_path = command_telemetry.shader_artifact_manifest_path,
                .shader_artifact_manifest_hash = command_telemetry.shader_artifact_manifest_hash,
                .host_plan_artifact_path = command_telemetry.host_plan_artifact_path,
                .host_plan_artifact_hash = command_telemetry.host_plan_artifact_hash,
                .backend_lane = backendLaneName(self.backend_lane),
                .adapter_ordinal = command_telemetry.adapter_ordinal,
                .queue_family_index = command_telemetry.queue_family_index,
                .present_capable = command_telemetry.present_capable,
                .queue_family_policy = command_telemetry.queue_family_policy,
                .queue_family_kind = command_telemetry.queue_family_kind,
                .queue_family_queue_count = command_telemetry.queue_family_queue_count,
                .queue_family_timestamp_valid_bits = command_telemetry.queue_family_timestamp_valid_bits,
                .queue_family_supports_graphics = command_telemetry.queue_family_supports_graphics,
                .semantic = semantic,
            };
        }

        return .{
            .backend = mode_name,
            .status = .@"error",
            .status_code = "missing-backend",
            .duration_ns = 0,
            .setup_ns = 0,
            .encode_ns = 0,
            .submit_wait_ns = 0,
            .dispatch_count = 0,
            .submit_count = 0,
            .gpu_timestamp_ns = 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
            .backend_selection_reason = null,
            .fallback_used = null,
            .selection_policy_hash = null,
            .shader_artifact_manifest_path = null,
            .shader_artifact_manifest_hash = null,
            .host_plan_artifact_path = null,
            .host_plan_artifact_hash = null,
            .backend_lane = backendLaneName(self.backend_lane),
            .adapter_ordinal = null,
            .queue_family_index = null,
            .present_capable = null,
            .semantic = semantic,
        };
    }

    pub fn execute_with_semantic(
        self: *ExecutionContext,
        command: model.Command,
        semantic: semantic_trace.SemanticContext,
    ) !ExecutionResult {
        const mode_name = executionModeName(self.mode);
        const mode_result = ExecutionResult{
            .backend = mode_name,
            .status = .skipped,
            .status_code = "disabled",
            .duration_ns = 0,
            .setup_ns = 0,
            .encode_ns = 0,
            .submit_wait_ns = 0,
            .dispatch_count = 0,
            .submit_count = 0,
            .gpu_timestamp_ns = 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
            .backend_selection_reason = null,
            .fallback_used = null,
            .selection_policy_hash = null,
            .shader_artifact_manifest_path = null,
            .shader_artifact_manifest_hash = null,
            .host_plan_artifact_path = null,
            .host_plan_artifact_hash = null,
            .backend_lane = null,
            .adapter_ordinal = null,
            .queue_family_index = null,
            .present_capable = null,
            .semantic = semantic,
        };

        if (self.mode == .trace) return mode_result;
        if (self.backend == null) {
            return .{
                .backend = mode_name,
                .status = .@"error",
                .status_code = "missing-backend",
                .duration_ns = 0,
                .setup_ns = 0,
                .encode_ns = 0,
                .submit_wait_ns = 0,
                .dispatch_count = 0,
                .submit_count = 0,
                .gpu_timestamp_ns = 0,
                .gpu_timestamp_attempted = false,
                .gpu_timestamp_valid = false,
                .backend_selection_reason = null,
                .fallback_used = null,
                .selection_policy_hash = null,
                .shader_artifact_manifest_path = null,
                .shader_artifact_manifest_hash = null,
                .host_plan_artifact_path = null,
                .host_plan_artifact_hash = null,
                .backend_lane = backendLaneName(self.backend_lane),
                .adapter_ordinal = null,
                .queue_family_index = null,
                .present_capable = null,
                .semantic = semantic,
            };
        }

        if (self.backend) |*backend| {
            const backend_telemetry_snapshot = backend.telemetry();
            const command_start = std.time.nanoTimestamp();
            const status = backend.execute_command(command) catch |err| {
                const command_end = std.time.nanoTimestamp();
                const elapsed_ns = if (command_end > command_start)
                    @as(u64, @intCast(command_end - command_start))
                else
                    0;
                const command_telemetry = backend.telemetry();
                return .{
                    .backend = backend_id_name(backend_telemetry_snapshot.backend_id),
                    .status = .@"error",
                    .status_code = @errorName(err),
                    .duration_ns = elapsed_ns,
                    .setup_ns = 0,
                    .encode_ns = 0,
                    .submit_wait_ns = 0,
                    .dispatch_count = 0,
                    .submit_count = 0,
                    .gpu_timestamp_ns = 0,
                    .gpu_timestamp_attempted = false,
                    .gpu_timestamp_valid = false,
                    .backend_selection_reason = command_telemetry.backend_selection_reason,
                    .fallback_used = command_telemetry.fallback_used,
                    .selection_policy_hash = command_telemetry.selection_policy_hash,
                    .shader_artifact_manifest_path = command_telemetry.shader_artifact_manifest_path,
                    .shader_artifact_manifest_hash = command_telemetry.shader_artifact_manifest_hash,
                    .host_plan_artifact_path = command_telemetry.host_plan_artifact_path,
                    .host_plan_artifact_hash = command_telemetry.host_plan_artifact_hash,
                    .backend_lane = backendLaneName(self.backend_lane),
                    .adapter_ordinal = command_telemetry.adapter_ordinal,
                    .queue_family_index = command_telemetry.queue_family_index,
                    .present_capable = command_telemetry.present_capable,
                    .queue_family_policy = command_telemetry.queue_family_policy,
                    .queue_family_kind = command_telemetry.queue_family_kind,
                    .queue_family_queue_count = command_telemetry.queue_family_queue_count,
                    .queue_family_timestamp_valid_bits = command_telemetry.queue_family_timestamp_valid_bits,
                    .queue_family_supports_graphics = command_telemetry.queue_family_supports_graphics,
                    .semantic = semantic,
                };
            };
            const command_end = std.time.nanoTimestamp();
            const elapsed_ns = if (command_end > command_start)
                @as(u64, @intCast(command_end - command_start))
            else
                0;
            const command_telemetry = backend.telemetry();
            const submit_count = command_telemetry.last_submit_count orelse 0;

            return .{
                .backend = backend_id_name(backend_telemetry_snapshot.backend_id),
                .status = if (status.status == .ok) .ok else if (status.status == .@"error") .@"error" else .unsupported,
                .status_code = status.status_message,
                .duration_ns = elapsed_ns,
                .setup_ns = status.setup_ns,
                .encode_ns = status.encode_ns,
                .submit_wait_ns = status.submit_wait_ns,
                .dispatch_count = status.dispatch_count,
                .submit_count = submit_count,
                .gpu_timestamp_ns = status.gpu_timestamp_ns,
                .gpu_timestamp_attempted = status.gpu_timestamp_attempted,
                .gpu_timestamp_valid = status.gpu_timestamp_valid,
                .backend_selection_reason = command_telemetry.backend_selection_reason,
                .fallback_used = command_telemetry.fallback_used,
                .selection_policy_hash = command_telemetry.selection_policy_hash,
                .shader_artifact_manifest_path = command_telemetry.shader_artifact_manifest_path,
                .shader_artifact_manifest_hash = command_telemetry.shader_artifact_manifest_hash,
                .host_plan_artifact_path = command_telemetry.host_plan_artifact_path,
                .host_plan_artifact_hash = command_telemetry.host_plan_artifact_hash,
                .backend_lane = backendLaneName(self.backend_lane),
                .adapter_ordinal = command_telemetry.adapter_ordinal,
                .queue_family_index = command_telemetry.queue_family_index,
                .present_capable = command_telemetry.present_capable,
                .queue_family_policy = command_telemetry.queue_family_policy,
                .queue_family_kind = command_telemetry.queue_family_kind,
                .queue_family_queue_count = command_telemetry.queue_family_queue_count,
                .queue_family_timestamp_valid_bits = command_telemetry.queue_family_timestamp_valid_bits,
                .queue_family_supports_graphics = command_telemetry.queue_family_supports_graphics,
                .semantic = semantic,
            };
        }

        return .{
            .backend = mode_name,
            .status = .@"error",
            .status_code = "missing-backend",
            .duration_ns = 0,
            .setup_ns = 0,
            .encode_ns = 0,
            .submit_wait_ns = 0,
            .dispatch_count = 0,
            .submit_count = 0,
            .gpu_timestamp_ns = 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
            .backend_selection_reason = null,
            .fallback_used = null,
            .selection_policy_hash = null,
            .shader_artifact_manifest_path = null,
            .shader_artifact_manifest_hash = null,
            .host_plan_artifact_path = null,
            .host_plan_artifact_hash = null,
            .backend_lane = backendLaneName(self.backend_lane),
            .adapter_ordinal = null,
            .queue_family_index = null,
            .present_capable = null,
            .semantic = semantic,
        };
    }

    pub fn configureUploadBehavior(
        self: *ExecutionContext,
        usage_mode: UploadBufferUsageMode,
        submit_every: u32,
    ) void {
        if (self.mode != .native) return;
        if (self.backend) |*backend| {
            backend.set_upload_behavior(usage_mode, submit_every);
        }
    }

    pub fn configureQueueWaitMode(
        self: *ExecutionContext,
        wait_mode: QueueWaitMode,
    ) void {
        if (self.mode != .native) return;
        if (self.backend) |*backend| {
            backend.set_queue_wait_mode(wait_mode);
        }
    }

    pub fn configureWebgpuFfiQueueWaitTimeoutNs(
        self: *ExecutionContext,
        timeout_ns: u64,
    ) void {
        if (self.mode != .native) return;
        if (self.backend) |*backend| {
            backend.set_webgpu_ffi_queue_wait_timeout_ns(timeout_ns);
        }
    }

    pub fn configureQueueSyncMode(
        self: *ExecutionContext,
        sync_mode: QueueSyncMode,
    ) void {
        if (self.mode != .native) return;
        if (self.backend) |*backend| {
            backend.set_queue_sync_mode(sync_mode);
        }
    }

    pub fn configureGpuTimestampMode(
        self: *ExecutionContext,
        timestamp_mode: GpuTimestampMode,
    ) void {
        if (self.mode != .native) return;
        if (self.backend) |*backend| {
            backend.set_gpu_timestamp_mode(timestamp_mode);
        }
    }

    pub fn flushQueue(self: *ExecutionContext) !u64 {
        if (self.mode != .native) return 0;
        if (self.backend) |*backend| {
            return try backend.flush_queue();
        }
        return 0;
    }

    pub fn prewarmUploadPath(
        self: *ExecutionContext,
        max_upload_bytes: u64,
    ) !void {
        if (self.mode != .native) return;
        if (self.backend) |*backend| {
            try backend.prewarm_upload_path(max_upload_bytes);
        }
    }

    pub fn prewarmKernelDispatch(
        self: *ExecutionContext,
        kernel: []const u8,
        entry_point: ?[]const u8,
        bindings: ?[]const model.KernelBinding,
        initialize_buffers_on_create: bool,
    ) !void {
        if (self.mode != .native) return;
        if (self.backend) |*backend| {
            try backend.prewarm_kernel_dispatch(
                kernel,
                entry_point,
                bindings,
                initialize_buffers_on_create,
            );
        }
    }

    pub fn captureBuffer(
        self: *ExecutionContext,
        allocator: std.mem.Allocator,
        handle: u64,
        offset: u64,
        size: u64,
    ) ![]u8 {
        if (self.mode != .native) return error.UnsupportedFeature;
        if (self.backend) |*backend| {
            return try backend.capture_buffer(allocator, handle, offset, size);
        }
        return error.UnsupportedFeature;
    }
};

pub const UploadBufferUsageMode = runtime_types.UploadBufferUsageMode;
pub const QueueWaitMode = runtime_types.QueueWaitMode;
pub const QueueSyncMode = runtime_types.QueueSyncMode;
pub const GpuTimestampMode = runtime_types.GpuTimestampMode;

pub fn parseUploadBufferUsage(raw: []const u8) ?UploadBufferUsageMode {
    if (std.ascii.eqlIgnoreCase(raw, "copy-dst-copy-src")) return .copy_dst_copy_src;
    if (std.ascii.eqlIgnoreCase(raw, "copy-dst")) return .copy_dst;
    return null;
}

pub fn parseQueueWaitMode(raw: []const u8) ?QueueWaitMode {
    if (std.ascii.eqlIgnoreCase(raw, "process-events")) return .process_events;
    if (std.ascii.eqlIgnoreCase(raw, "wait-any")) return .wait_any;
    return null;
}

pub fn queueWaitModeName(mode: QueueWaitMode) []const u8 {
    return switch (mode) {
        .process_events => "process-events",
        .wait_any => "wait-any",
    };
}

pub fn parseQueueSyncMode(raw: []const u8) ?QueueSyncMode {
    if (std.ascii.eqlIgnoreCase(raw, "per-command")) return .per_command;
    if (std.ascii.eqlIgnoreCase(raw, "deferred")) return .deferred;
    return null;
}

pub fn queueSyncModeName(mode: QueueSyncMode) []const u8 {
    return switch (mode) {
        .per_command => "per-command",
        .deferred => "deferred",
    };
}

pub fn parseGpuTimestampMode(raw: []const u8) ?GpuTimestampMode {
    if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(raw, "require")) return .require;
    return null;
}

pub fn parseBackend(raw: []const u8) ?BackendMode {
    if (std.ascii.eqlIgnoreCase(raw, "trace")) return .trace;
    if (std.ascii.eqlIgnoreCase(raw, "native")) return .native;
    if (std.ascii.eqlIgnoreCase(raw, "webgpu")) return .native;
    return null;
}

pub fn parseBackendLane(raw: []const u8) ?backend_policy.BackendLane {
    return backend_policy.parse_lane(raw);
}

pub fn defaultBackendLane(profile: model.DeviceProfile) backend_policy.BackendLane {
    return switch (profile.api) {
        .metal => .metal_doe_app,
        .d3d12 => .d3d12_doe_app,
        else => .vulkan_doe_app,
    };
}

pub fn backendLaneName(lane: backend_policy.BackendLane) []const u8 {
    return backend_policy.lane_name(lane);
}

pub fn backend_id_name(id: backend_ids.BackendId) []const u8 {
    return backend_ids.backend_id_name(id);
}

pub fn executionModeName(mode: BackendMode) []const u8 {
    return switch (mode) {
        .trace => "trace",
        .native => "webgpu-ffi",
    };
}

pub fn executionStatusName(status: ExecutionStatus) []const u8 {
    return @tagName(status);
}

// --- Inline tests ---

const testing = std.testing;

test "executionModeName returns correct strings for all modes" {
    try testing.expectEqualStrings("trace", executionModeName(.trace));
    try testing.expectEqualStrings("webgpu-ffi", executionModeName(.native));
}

test "executionStatusName returns correct strings for all statuses" {
    try testing.expectEqualStrings("skipped", executionStatusName(.skipped));
    try testing.expectEqualStrings("ok", executionStatusName(.ok));
    try testing.expectEqualStrings("unsupported", executionStatusName(.unsupported));
    try testing.expectEqualStrings("error", executionStatusName(.@"error"));
}

test "parseBackend accepts valid modes and rejects unknown input" {
    try testing.expectEqual(BackendMode.trace, parseBackend("trace").?);
    try testing.expectEqual(BackendMode.native, parseBackend("native").?);
    try testing.expectEqual(BackendMode.native, parseBackend("webgpu").?);
    // case-insensitive
    try testing.expectEqual(BackendMode.trace, parseBackend("TRACE").?);
    try testing.expectEqual(BackendMode.native, parseBackend("Native").?);
    try testing.expectEqual(BackendMode.native, parseBackend("WebGPU").?);
    // unknown returns null
    try testing.expect(parseBackend("opengl") == null);
    try testing.expect(parseBackend("") == null);
}

test "parseUploadBufferUsage accepts valid modes and rejects unknown input" {
    try testing.expectEqual(UploadBufferUsageMode.copy_dst_copy_src, parseUploadBufferUsage("copy-dst-copy-src").?);
    try testing.expectEqual(UploadBufferUsageMode.copy_dst, parseUploadBufferUsage("copy-dst").?);
    // case-insensitive
    try testing.expectEqual(UploadBufferUsageMode.copy_dst, parseUploadBufferUsage("COPY-DST").?);
    // unknown
    try testing.expect(parseUploadBufferUsage("map-write") == null);
    try testing.expect(parseUploadBufferUsage("") == null);
}

test "parseQueueWaitMode accepts valid modes and rejects unknown input" {
    try testing.expectEqual(QueueWaitMode.process_events, parseQueueWaitMode("process-events").?);
    try testing.expectEqual(QueueWaitMode.wait_any, parseQueueWaitMode("wait-any").?);
    // case-insensitive
    try testing.expectEqual(QueueWaitMode.wait_any, parseQueueWaitMode("Wait-Any").?);
    // unknown
    try testing.expect(parseQueueWaitMode("spin") == null);
}

test "queueWaitModeName returns CLI spellings" {
    try testing.expectEqualStrings("process-events", queueWaitModeName(.process_events));
    try testing.expectEqualStrings("wait-any", queueWaitModeName(.wait_any));
}

test "parseQueueSyncMode accepts valid modes and rejects unknown input" {
    try testing.expectEqual(QueueSyncMode.per_command, parseQueueSyncMode("per-command").?);
    try testing.expectEqual(QueueSyncMode.deferred, parseQueueSyncMode("deferred").?);
    // case-insensitive
    try testing.expectEqual(QueueSyncMode.deferred, parseQueueSyncMode("DEFERRED").?);
    // unknown
    try testing.expect(parseQueueSyncMode("batch") == null);
}

test "queueSyncModeName returns CLI spellings" {
    try testing.expectEqualStrings("per-command", queueSyncModeName(.per_command));
    try testing.expectEqualStrings("deferred", queueSyncModeName(.deferred));
}

test "parseGpuTimestampMode accepts valid modes and rejects unknown input" {
    try testing.expectEqual(GpuTimestampMode.auto, parseGpuTimestampMode("auto").?);
    try testing.expectEqual(GpuTimestampMode.off, parseGpuTimestampMode("off").?);
    try testing.expectEqual(GpuTimestampMode.require, parseGpuTimestampMode("require").?);
    // case-insensitive
    try testing.expectEqual(GpuTimestampMode.require, parseGpuTimestampMode("REQUIRE").?);
    // unknown
    try testing.expect(parseGpuTimestampMode("maybe") == null);
}

test "parseBackendLane accepts snake_case and kebab-case variants" {
    // metal lanes
    try testing.expectEqual(backend_policy.BackendLane.metal_doe_app, parseBackendLane("metal_doe_app").?);
    try testing.expectEqual(backend_policy.BackendLane.metal_doe_app, parseBackendLane("metal-doe-app").?);
    try testing.expectEqual(backend_policy.BackendLane.metal_dawn_release, parseBackendLane("metal-dawn-release").?);
    try testing.expectEqual(backend_policy.BackendLane.metal_doe_comparable, parseBackendLane("metal_doe_comparable").?);
    try testing.expectEqual(backend_policy.BackendLane.metal_webkit_comparable, parseBackendLane("metal_webkit_comparable").?);
    try testing.expectEqual(backend_policy.BackendLane.metal_webkit_comparable, parseBackendLane("metal-webkit-comparable").?);
    // vulkan lanes
    try testing.expectEqual(backend_policy.BackendLane.vulkan_doe_app, parseBackendLane("vulkan-doe-app").?);
    try testing.expectEqual(backend_policy.BackendLane.vulkan_doe_compute_only_fence_diagnostic, parseBackendLane("vulkan-doe-compute-only-fence-diagnostic").?);
    try testing.expectEqual(backend_policy.BackendLane.vulkan_dawn_release, parseBackendLane("vulkan-dawn-release").?);
    // d3d12 lanes
    try testing.expectEqual(backend_policy.BackendLane.d3d12_doe_app, parseBackendLane("d3d12_doe_app").?);
    try testing.expectEqual(backend_policy.BackendLane.d3d12_dawn_release, parseBackendLane("d3d12-dawn-release").?);
    // unknown
    try testing.expect(parseBackendLane("opengl_doe_app") == null);
    try testing.expect(parseBackendLane("") == null);
}

test "backendLaneName round-trips with parseBackendLane for all lanes" {
    const lanes = [_]backend_policy.BackendLane{
        .metal_doe_app,
        .metal_doe_directional,
        .metal_doe_comparable,
        .metal_doe_release,
        .metal_dawn_release,
        .metal_webkit_release,
        .metal_webkit_comparable,
        .vulkan_doe_app,
        .vulkan_doe_comparable,
        .vulkan_doe_compute_only_diagnostic,
        .vulkan_doe_compute_only_fence_diagnostic,
        .vulkan_doe_release,
        .vulkan_dawn_release,
        .d3d12_doe_app,
        .d3d12_doe_directional,
        .d3d12_doe_comparable,
        .d3d12_doe_release,
        .d3d12_dawn_release,
    };
    for (lanes) |lane| {
        const name = backendLaneName(lane);
        const parsed = parseBackendLane(name);
        try testing.expect(parsed != null);
        try testing.expectEqual(lane, parsed.?);
    }
}

test "defaultBackendLane selects correct lane per API" {
    const base_ver = model.SemVer{ .major = 1, .minor = 0, .patch = 0 };
    const metal_profile = model.DeviceProfile{
        .vendor = "apple",
        .api = .metal,
        .driver_version = base_ver,
    };
    const vulkan_profile = model.DeviceProfile{
        .vendor = "nvidia",
        .api = .vulkan,
        .driver_version = base_ver,
    };
    const d3d12_profile = model.DeviceProfile{
        .vendor = "amd",
        .api = .d3d12,
        .driver_version = base_ver,
    };
    const webgpu_profile = model.DeviceProfile{
        .vendor = "generic",
        .api = .webgpu,
        .driver_version = base_ver,
    };
    try testing.expectEqual(backend_policy.BackendLane.metal_doe_app, defaultBackendLane(metal_profile));
    try testing.expectEqual(backend_policy.BackendLane.d3d12_doe_app, defaultBackendLane(d3d12_profile));
    try testing.expectEqual(backend_policy.BackendLane.vulkan_doe_app, defaultBackendLane(vulkan_profile));
    // webgpu falls to the else branch -> vulkan_doe_app
    try testing.expectEqual(backend_policy.BackendLane.vulkan_doe_app, defaultBackendLane(webgpu_profile));
}
