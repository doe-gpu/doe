const std = @import("std");
const builtin = @import("builtin");
const model_commands = @import("../../model_commands.zig");
const model_profile = @import("../../model_profile.zig");
const model_resource_types = @import("../../model_resource_types.zig");
const model_compute_types = @import("../../model_compute_types.zig");
const model_render_types = @import("../../model_render_types.zig");
const model_texture_types = @import("../../model_texture_types.zig");
const model_surface_control_types = @import("../../model_surface_control_types.zig");
const model_async_types = @import("../../model_async_types.zig");
const webgpu = @import("../runtime_types.zig");
const backend_iface = @import("../backend_iface.zig");
const common_errors = @import("../common/errors.zig");
const capabilities = @import("../common/capabilities.zig");
const artifact_meta = @import("../common/artifact_meta.zig");
const hash_utils = @import("../common/hash_utils.zig");
const artifact_emit = @import("artifact_emit.zig");
const backend_execute = @import("backend_execute.zig");
const host_plan_artifact = @import("metal_host_plan_artifact.zig");
const native_runtime = @import("metal_native_runtime.zig");
const metal_pipeline_cache = @import("metal_pipeline_cache.zig");
const backend_policy = @import("../backend_policy.zig");
const bridge = @import("metal_bridge_decls.zig");

const MANIFEST_PATH_CAPACITY: usize = 256;
const HASH_HEX_SIZE: usize = hash_utils.SHA256_HEX_SIZE;
const MANIFEST_MODULE_CAPACITY: usize = 64;
const MANIFEST_STATUS_CODE_CAPACITY: usize = 256;
const STATUS_MESSAGE_BYTES: usize = 256;
const BOOTSTRAP_MANIFEST_MODULE = "bootstrap";
const BOOTSTRAP_MANIFEST_STATUS_CODE = "backend_initialized";

const model = struct {
    pub const AsyncDiagnosticsCommand = model_async_types.AsyncDiagnosticsCommand;
    pub const BufferWriteCommand = model_resource_types.BufferWriteCommand;
    pub const Command = model_commands.Command;
    pub const CopyCommand = model_resource_types.CopyCommand;
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const DispatchCommand = model_compute_types.DispatchCommand;
    pub const DispatchIndirectCommand = model_compute_types.DispatchIndirectCommand;
    pub const KernelBinding = model_compute_types.KernelBinding;
    pub const KernelDispatchCommand = model_compute_types.KernelDispatchCommand;
    pub const MapAsyncCommand = model_async_types.MapAsyncCommand;
    pub const RenderDrawCommand = model_render_types.RenderDrawCommand;
    pub const SamplerCreateCommand = model_render_types.SamplerCreateCommand;
    pub const SamplerDestroyCommand = model_render_types.SamplerDestroyCommand;
    pub const SurfaceAcquireCommand = model_surface_control_types.SurfaceAcquireCommand;
    pub const SurfaceCapabilitiesCommand = model_surface_control_types.SurfaceCapabilitiesCommand;
    pub const SurfaceConfigureCommand = model_surface_control_types.SurfaceConfigureCommand;
    pub const SurfaceCreateCommand = model_surface_control_types.SurfaceCreateCommand;
    pub const SurfacePresentCommand = model_surface_control_types.SurfacePresentCommand;
    pub const SurfaceReleaseCommand = model_surface_control_types.SurfaceReleaseCommand;
    pub const SurfaceUnconfigureCommand = model_surface_control_types.SurfaceUnconfigureCommand;
    pub const TextureDestroyCommand = model_texture_types.TextureDestroyCommand;
    pub const TextureQueryCommand = model_texture_types.TextureQueryCommand;
    pub const TextureWriteCommand = model_texture_types.TextureWriteCommand;
    pub const UploadCommand = model_resource_types.UploadCommand;
};

pub const ZigMetalBackend = struct {
    allocator: std.mem.Allocator,
    runtime: ?native_runtime.NativeMetalRuntime = null,
    kernel_root_owned: ?[]u8 = null,
    upload_path_policy: backend_policy.UploadPathPolicy = .allow_mapped_shortcuts,

    upload_buffer_usage_mode: webgpu.UploadBufferUsageMode = .copy_dst_copy_src,
    upload_submit_every: u32 = 1,
    queue_wait_mode: webgpu.QueueWaitMode = .process_events,
    queue_sync_mode: webgpu.QueueSyncMode = .per_command,
    gpu_timestamp_mode: webgpu.GpuTimestampMode = .auto,
    pending_upload_commands: u32 = 0,

    capability_set: capabilities.CapabilitySet,
    status_message_storage: [STATUS_MESSAGE_BYTES]u8 = [_]u8{0} ** STATUS_MESSAGE_BYTES,
    status_message_len: usize = 0,

    manifest_emit_count: u64 = 0,
    manifest_path_storage: [MANIFEST_PATH_CAPACITY]u8 = std.mem.zeroes([MANIFEST_PATH_CAPACITY]u8),
    manifest_path_len: usize = 0,
    manifest_hash_storage: [HASH_HEX_SIZE]u8 = std.mem.zeroes([HASH_HEX_SIZE]u8),
    manifest_hash_len: usize = 0,
    host_plan_emit_count: u64 = 0,
    host_plan_path_storage: [MANIFEST_PATH_CAPACITY]u8 = std.mem.zeroes([MANIFEST_PATH_CAPACITY]u8),
    host_plan_path_len: usize = 0,
    host_plan_hash_storage: [HASH_HEX_SIZE]u8 = std.mem.zeroes([HASH_HEX_SIZE]u8),
    host_plan_hash_len: usize = 0,
    last_manifest_meta: ?artifact_meta.ArtifactMeta = null,
    last_manifest_module_storage: [MANIFEST_MODULE_CAPACITY]u8 = std.mem.zeroes([MANIFEST_MODULE_CAPACITY]u8),
    last_manifest_module_len: usize = 0,
    last_manifest_status_storage: [MANIFEST_STATUS_CODE_CAPACITY]u8 = std.mem.zeroes([MANIFEST_STATUS_CODE_CAPACITY]u8),
    last_manifest_status_len: usize = 0,
    pending_artifact_write: bool = false,
    pending_artifact_module: []const u8 = "",
    pending_artifact_meta: artifact_meta.ArtifactMeta = undefined,
    pending_artifact_status_storage: [MANIFEST_STATUS_CODE_CAPACITY]u8 = std.mem.zeroes([MANIFEST_STATUS_CODE_CAPACITY]u8),
    pending_artifact_status_len: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
    ) !*ZigMetalBackend {
        return init_with_selection_policy(
            allocator,
            profile,
            kernel_root,
            backend_policy.default_policy_for_lane(.metal_doe_app),
        );
    }

    pub fn init_with_selection_policy(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
        selection_policy: backend_policy.SelectionPolicy,
    ) !*ZigMetalBackend {
        if (profile.api != .metal) return common_errors.BackendNativeError.UnsupportedFeature;
        if (builtin.os.tag != .macos) return common_errors.BackendNativeError.UnsupportedFeature;

        const owned_root = if (kernel_root) |root| try allocator.dupe(u8, root) else null;
        errdefer if (owned_root) |r| allocator.free(r);

        const ptr = try allocator.create(ZigMetalBackend);
        errdefer allocator.destroy(ptr);

        var runtime = try native_runtime.NativeMetalRuntime.init(allocator, owned_root);
        errdefer runtime.deinit();

        ptr.* = .{
            .allocator = allocator,
            .runtime = runtime,
            .kernel_root_owned = owned_root,
            .upload_path_policy = selection_policy.upload_path_policy,
            .upload_buffer_usage_mode = .copy_dst_copy_src,
            .upload_submit_every = 1,
            .queue_wait_mode = .process_events,
            .queue_sync_mode = .per_command,
            .gpu_timestamp_mode = .auto,
            .pending_upload_commands = 0,
            .capability_set = native_capability_set(),
            .status_message_storage = [_]u8{0} ** STATUS_MESSAGE_BYTES,
            .status_message_len = 0,
            .manifest_emit_count = 0,
            .manifest_path_storage = std.mem.zeroes([MANIFEST_PATH_CAPACITY]u8),
            .manifest_path_len = 0,
            .manifest_hash_storage = std.mem.zeroes([HASH_HEX_SIZE]u8),
            .manifest_hash_len = 0,
            .host_plan_emit_count = 0,
            .host_plan_path_storage = std.mem.zeroes([MANIFEST_PATH_CAPACITY]u8),
            .host_plan_path_len = 0,
            .host_plan_hash_storage = std.mem.zeroes([HASH_HEX_SIZE]u8),
            .host_plan_hash_len = 0,
            .last_manifest_meta = null,
            .last_manifest_module_storage = std.mem.zeroes([MANIFEST_MODULE_CAPACITY]u8),
            .last_manifest_module_len = 0,
            .last_manifest_status_storage = std.mem.zeroes([MANIFEST_STATUS_CODE_CAPACITY]u8),
            .last_manifest_status_len = 0,
            .pending_artifact_write = false,
            .pending_artifact_module = "",
            .pending_artifact_meta = undefined,
            .pending_artifact_status_storage = std.mem.zeroes([MANIFEST_STATUS_CODE_CAPACITY]u8),
            .pending_artifact_status_len = 0,
        };

        ptr.emit_shader_artifact_manifest_for_signature(
            BOOTSTRAP_MANIFEST_MODULE,
            artifact_meta.classify(.native_metal, false, false),
            BOOTSTRAP_MANIFEST_STATUS_CODE,
        ) catch {};

        return ptr;
    }

    pub fn as_iface(
        self: *ZigMetalBackend,
        allocator: std.mem.Allocator,
        reason: []const u8,
        policy_hash: []const u8,
    ) !backend_iface.BackendIface {
        _ = allocator;
        return .{
            .id = .doe_metal,
            .context = self,
            .vtable = &VTABLE,
            .telemetry = .{
                .backend_id = .doe_metal,
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

    fn manifest_path(self: *const ZigMetalBackend) ?[]const u8 {
        return artifact_emit.manifest_path(self);
    }

    fn manifest_hash(self: *const ZigMetalBackend) ?[]const u8 {
        return artifact_emit.manifest_hash(self);
    }

    fn host_plan_path(self: *const ZigMetalBackend) ?[]const u8 {
        return host_plan_artifact.hostPlanPath(self);
    }

    fn host_plan_hash(self: *const ZigMetalBackend) ?[]const u8 {
        return host_plan_artifact.hostPlanHash(self);
    }

    fn flush_pending_artifact(self: *ZigMetalBackend) void {
        artifact_emit.flush_pending_artifact(self);
    }

    fn emit_shader_artifact_manifest_for_signature(
        self: *ZigMetalBackend,
        module: []const u8,
        meta: artifact_meta.ArtifactMeta,
        status_code: []const u8,
    ) common_errors.BackendNativeError!void {
        return artifact_emit.emit_shader_artifact_manifest_for_signature(self, module, meta, status_code);
    }

    pub fn write_status(self: *ZigMetalBackend, comptime fmt: []const u8, args: anytype) []const u8 {
        const rendered = std.fmt.bufPrint(&self.status_message_storage, fmt, args) catch "status_format_error";
        self.status_message_len = rendered.len;
        return self.status_message_storage[0..self.status_message_len];
    }

    pub fn get_runtime(self: *ZigMetalBackend) *native_runtime.NativeMetalRuntime {
        return &self.runtime.?;
    }

    pub fn ok_result(self: *ZigMetalBackend, setup_ns: u64, encode_ns: u64, submit_wait_ns: u64, dispatch_count: u32) webgpu.NativeExecutionResult {
        _ = self;
        return .{
            .status = .ok,
            .status_message = "",
            .setup_ns = setup_ns,
            .encode_ns = encode_ns,
            .submit_wait_ns = submit_wait_ns,
            .dispatch_count = dispatch_count,
            .gpu_timestamp_ns = 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    }

    pub fn gpu_timestamps_wanted(self: *const ZigMetalBackend) bool {
        return self.gpu_timestamp_mode != .off;
    }

    pub fn check_timestamp_requirement(self: *ZigMetalBackend) !void {
        if (self.gpu_timestamp_mode != .require) return;
        const rt = self.get_runtime();
        if (!rt.gpu_timestamps_supported()) return error.UnsupportedFeature;
    }
};

fn native_capability_set() capabilities.CapabilitySet {
    var set = capabilities.CapabilitySet{};
    set.declare_all(&.{
        .compute_dispatch,
        .compute_dispatch_indirect,
        .buffer_upload,
        .buffer_write,
        .buffer_copy,
        .barrier_sync,
        .kernel_dispatch,
        .sampler_lifecycle,
        .texture_write,
        .texture_query,
        .texture_destroy,
        .surface_lifecycle,
        .surface_present,
        .render_draw,
        .render_pass,
        .indirect_draw,
        .indexed_indirect_draw,
        .async_pipeline_diagnostics,
        .async_capability_introspection,
        .async_resource_table_immediates,
        .async_lifecycle_refcount,
        .async_pixel_local_storage,
        .map_async,
        .gpu_timestamps,
        .timestamp_inside_passes,
    });
    return set;
}

fn cast(ctx: *anyopaque) *ZigMetalBackend {
    return @as(*ZigMetalBackend, @ptrCast(@alignCast(ctx)));
}

pub fn manifest_path_from_context(ctx: *anyopaque) ?[]const u8 {
    const self = cast(ctx);
    self.flush_pending_artifact();
    return self.manifest_path();
}

pub fn manifest_hash_from_context(ctx: *anyopaque) ?[]const u8 {
    return cast(ctx).manifest_hash();
}

pub fn host_plan_path_from_context(ctx: *anyopaque) ?[]const u8 {
    return cast(ctx).host_plan_path();
}

pub fn host_plan_hash_from_context(ctx: *anyopaque) ?[]const u8 {
    return cast(ctx).host_plan_hash();
}

pub fn pipeline_cache_warmup_telemetry_from_context(ctx: *anyopaque) metal_pipeline_cache.WarmupTelemetry {
    _ = ctx;
    return metal_pipeline_cache.process_active_cache_warmup_telemetry();
}

pub fn pipeline_cache_active_from_context(ctx: *anyopaque) bool {
    _ = ctx;
    return metal_pipeline_cache.process_active_cache_present();
}

pub fn set_pipeline_cache_disabled(disabled: bool) void {
    metal_pipeline_cache.set_process_pipeline_cache_disabled(disabled);
}

fn deinit(ctx: *anyopaque) void {
    const self = cast(ctx);
    const allocator = self.allocator;
    if (self.runtime) |*rt| {
        rt.deinit();
        self.runtime = null;
    }
    if (self.kernel_root_owned) |r| {
        allocator.free(r);
        self.kernel_root_owned = null;
    }
    allocator.destroy(self);
}

fn execute_command(ctx: *anyopaque, command: model.Command) anyerror!webgpu.NativeExecutionResult {
    return backend_execute.execute_command(cast(ctx), command);
}

fn execute_buffer_write_bytes_iface(ctx: *anyopaque, handle: u64, offset: u64, buffer_size: u64, data: []const u8) anyerror!webgpu.NativeExecutionResult {
    return backend_execute.execute_buffer_write_bytes_iface(cast(ctx), handle, offset, buffer_size, data);
}

fn set_upload_behavior(ctx: *anyopaque, mode: webgpu.UploadBufferUsageMode, submit_every: u32) void {
    backend_execute.set_upload_behavior(cast(ctx), mode, submit_every);
}

fn set_queue_wait_mode(ctx: *anyopaque, mode: webgpu.QueueWaitMode) void {
    backend_execute.set_queue_wait_mode(cast(ctx), mode);
}

fn set_webgpu_ffi_queue_wait_timeout_ns(ctx: *anyopaque, timeout_ns: u64) void {
    _ = ctx;
    _ = timeout_ns;
}

fn set_queue_sync_mode(ctx: *anyopaque, mode: webgpu.QueueSyncMode) void {
    backend_execute.set_queue_sync_mode(cast(ctx), mode);
}

fn set_gpu_timestamp_mode(ctx: *anyopaque, mode: webgpu.GpuTimestampMode) void {
    backend_execute.set_gpu_timestamp_mode(cast(ctx), mode);
}

fn flush_queue(ctx: *anyopaque) anyerror!u64 {
    return backend_execute.flush_queue(cast(ctx));
}

fn prewarm_upload_path(ctx: *anyopaque, max_upload_bytes: u64) anyerror!void {
    return backend_execute.prewarm_upload_path(cast(ctx), max_upload_bytes);
}

fn prewarm_kernel_dispatch(
    ctx: *anyopaque,
    kernel: []const u8,
    entry_point: ?[]const u8,
    bindings: ?[]const model.KernelBinding,
    initialize_buffers_on_create: bool,
) anyerror!void {
    return backend_execute.prewarm_kernel_dispatch(
        cast(ctx),
        kernel,
        entry_point,
        bindings,
        initialize_buffers_on_create,
    );
}

fn capture_buffer(ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8 {
    return backend_execute.capture_buffer(cast(ctx), allocator, handle, offset, size);
}

const VTABLE = backend_iface.BackendVTable{
    .deinit = deinit,
    .execute_command = execute_command,
    .execute_buffer_write_bytes = execute_buffer_write_bytes_iface,
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
