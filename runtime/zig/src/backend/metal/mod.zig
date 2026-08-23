const std = @import("std");
const builtin = @import("builtin");
const model_commands = @import("../../contracts/command.zig");
const model_profile = @import("../../contracts/model/model_profile.zig");
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const compute_contract = @import("../../contracts/compute.zig");
const prepared = @import("../../contracts/prepared_operation.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const model_texture_types = @import("../../contracts/model/model_texture_types.zig");
const model_surface_control_types = @import("../../contracts/model/model_surface_control_types.zig");
const model_async_types = @import("../../contracts/model/model_async_types.zig");
const webgpu = @import("../../contracts/runtime_types.zig");
const runtime_configuration = @import("../../contracts/runtime_configuration.zig");
const runtime_telemetry = @import("../../contracts/runtime_telemetry.zig");
const backend_telemetry = @import("../backend_telemetry.zig");
const port_factory = @import("../ports/factory.zig");
const provider_adapter = @import("../ports/provider_adapter.zig");
const common_errors = @import("../../contracts/execution.zig");
const capabilities = @import("../../contracts/capability.zig");
const artifact_meta = @import("../../contracts/artifact.zig");
const hash_utils = @import("../../contracts/artifact.zig");
const artifact_emit = @import("artifact_emit.zig");
const backend_execute = @import("backend_execute.zig");
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
    pipeline_cache_dir_owned: ?[]u8 = null,
    upload_path_policy: backend_policy.UploadPathPolicy = .allow_mapped_shortcuts,

    upload_buffer_usage_mode: webgpu.UploadBufferUsageMode = .copy_dst_copy_src,
    upload_submit_every: u32 = 1,
    queue_wait_mode: webgpu.QueueWaitMode = .process_events,
    queue_sync_mode: webgpu.QueueSyncMode = .per_command,
    gpu_timestamp_mode: webgpu.GpuTimestampMode = .auto,
    pending_upload_commands: u32 = 0,
    last_submit_count: ?u32 = null,
    telemetry: runtime_telemetry.RuntimeTelemetry = backend_telemetry.default_telemetry(),

    capability_set: capabilities.CapabilitySet,
    status_message_storage: [STATUS_MESSAGE_BYTES]u8 = [_]u8{0} ** STATUS_MESSAGE_BYTES,
    status_message_len: usize = 0,

    manifest_emit_count: u64 = 0,
    manifest_path_storage: [MANIFEST_PATH_CAPACITY]u8 = std.mem.zeroes([MANIFEST_PATH_CAPACITY]u8),
    manifest_path_len: usize = 0,
    manifest_hash_storage: [HASH_HEX_SIZE]u8 = std.mem.zeroes([HASH_HEX_SIZE]u8),
    manifest_hash_len: usize = 0,
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
        return init_with_selection_policy_and_cache(
            allocator,
            profile,
            kernel_root,
            "",
            backend_policy.default_policy_for_lane(.metal_doe_app),
        );
    }

    pub fn init_with_selection_policy(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
        selection_policy: backend_policy.SelectionPolicy,
    ) !*ZigMetalBackend {
        return init_with_selection_policy_and_cache(
            allocator,
            profile,
            kernel_root,
            "",
            selection_policy,
        );
    }

    pub fn init_with_selection_policy_and_cache(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
        pipeline_cache_dir: []const u8,
        selection_policy: backend_policy.SelectionPolicy,
    ) !*ZigMetalBackend {
        return init_with_selection_policy_and_cache_configuration(
            allocator,
            profile,
            kernel_root,
            .{ .directory = pipeline_cache_dir },
            selection_policy,
        );
    }

    pub fn init_with_selection_policy_and_cache_configuration(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
        pipeline_cache: runtime_configuration.PipelineCacheConfiguration,
        selection_policy: backend_policy.SelectionPolicy,
    ) !*ZigMetalBackend {
        if (profile.api != .metal) return common_errors.BackendNativeError.UnsupportedFeature;
        if (builtin.os.tag != .macos) return common_errors.BackendNativeError.UnsupportedFeature;

        const owned_root = if (kernel_root) |root| try allocator.dupe(u8, root) else null;
        errdefer if (owned_root) |r| allocator.free(r);
        const owned_cache_dir = if (pipeline_cache.directory.len > 0)
            try allocator.dupe(u8, pipeline_cache.directory)
        else
            null;
        errdefer if (owned_cache_dir) |dir| allocator.free(dir);

        const ptr = try allocator.create(ZigMetalBackend);
        errdefer allocator.destroy(ptr);

        var runtime = try native_runtime.NativeMetalRuntime.init(
            allocator,
            owned_root,
            owned_cache_dir orelse "",
            pipeline_cache.enabled,
        );
        errdefer runtime.deinit();

        ptr.* = .{
            .allocator = allocator,
            .runtime = runtime,
            .kernel_root_owned = owned_root,
            .pipeline_cache_dir_owned = owned_cache_dir,
            .upload_path_policy = selection_policy.upload_path_policy,
            .upload_buffer_usage_mode = .copy_dst_copy_src,
            .upload_submit_every = 1,
            .queue_wait_mode = .process_events,
            .queue_sync_mode = .per_command,
            .gpu_timestamp_mode = .auto,
            .pending_upload_commands = 0,
            .last_submit_count = null,
            .telemetry = backend_telemetry.default_telemetry(),
            .capability_set = native_capability_set(),
            .status_message_storage = [_]u8{0} ** STATUS_MESSAGE_BYTES,
            .status_message_len = 0,
            .manifest_emit_count = 0,
            .manifest_path_storage = std.mem.zeroes([MANIFEST_PATH_CAPACITY]u8),
            .manifest_path_len = 0,
            .manifest_hash_storage = std.mem.zeroes([HASH_HEX_SIZE]u8),
            .manifest_hash_len = 0,
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

    pub fn asPorts(
        self: *ZigMetalBackend,
        reason: []const u8,
        policy_hash: []const u8,
        fallback_used: bool,
    ) port_factory.PortBundle {
        self.telemetry = backend_telemetry.forSelection(.doe_metal, reason, fallback_used, policy_hash);
        return provider_adapter.fromDriver(PortDriver, self, .doe_metal);
    }

    fn manifest_path(self: *const ZigMetalBackend) ?[]const u8 {
        return artifact_emit.manifest_path(self);
    }

    fn manifest_hash(self: *const ZigMetalBackend) ?[]const u8 {
        return artifact_emit.manifest_hash(self);
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

pub fn pipeline_cache_warmup_telemetry_from_context(ctx: *anyopaque) metal_pipeline_cache.WarmupTelemetry {
    const self = cast(ctx);
    if (self.runtime) |*runtime| return runtime.pipelineCacheWarmupTelemetry();
    return .{};
}

pub fn pipeline_cache_active_from_context(ctx: *anyopaque) bool {
    const self = cast(ctx);
    if (self.runtime) |*runtime| return runtime.pipelineCacheActive();
    return false;
}

pub fn last_submit_count_from_context(ctx: *anyopaque) ?u32 {
    return cast(ctx).last_submit_count;
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
    if (self.pipeline_cache_dir_owned) |dir| {
        allocator.free(dir);
        self.pipeline_cache_dir_owned = null;
    }
    allocator.destroy(self);
}

fn execute_command(ctx: *anyopaque, command: model.Command) anyerror!webgpu.NativeExecutionResult {
    return backend_execute.execute_command(cast(ctx), command);
}

fn execute_prepared_compute(ctx: *anyopaque, operation: prepared.PreparedComputeOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.toCommand());
}

fn execute_prepared_transfer(ctx: *anyopaque, operation: prepared.PreparedTransferOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.operation.toCommand().?);
}

fn execute_prepared_render(ctx: *anyopaque, operation: prepared.PreparedRenderOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.operation.toCommand());
}

fn execute_prepared_resource(ctx: *anyopaque, operation: prepared.PreparedResourceOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.operation.toCommand());
}

fn execute_prepared_surface(ctx: *anyopaque, operation: prepared.PreparedSurfaceOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.operation.toCommand());
}

fn execute_prepared_lifecycle(ctx: *anyopaque, operation: prepared.PreparedLifecycleOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.toCommand());
}

fn execute_dispatch(context: compute_contract.ComputeContext, request: compute_contract.DispatchRequest) anyerror!compute_contract.DispatchReport {
    const result = try backend_execute.execute_dispatch_request(ZigMetalBackend, cast(context.state), request);
    return .{ .execution = result };
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

fn telemetry_snapshot(ctx: *anyopaque) runtime_telemetry.RuntimeTelemetry {
    const self = cast(ctx);
    self.telemetry.shader_artifact_manifest_path = manifest_path_from_context(ctx);
    self.telemetry.shader_artifact_manifest_hash = manifest_hash_from_context(ctx);
    const cache = pipeline_cache_warmup_telemetry_from_context(ctx);
    self.telemetry.pipeline_cache_warmup_count = cache.count;
    self.telemetry.pipeline_cache_warmup_ns = cache.ns;
    self.telemetry.pipeline_cache_active = pipeline_cache_active_from_context(ctx);
    self.telemetry.last_submit_count = last_submit_count_from_context(ctx);
    return self.telemetry;
}

fn backend_id(ctx: *anyopaque) @import("../../contracts/backend.zig").BackendId {
    _ = ctx;
    return .doe_metal;
}

pub fn destroyContext(ctx: *anyopaque) void {
    deinit(ctx);
}

const PortDriver = struct {
    pub const backendId = backend_id;
    pub const executePreparedCompute = execute_prepared_compute;
    pub const executePreparedTransfer = execute_prepared_transfer;
    pub const executePreparedRender = execute_prepared_render;
    pub const executePreparedResource = execute_prepared_resource;
    pub const executePreparedSurface = execute_prepared_surface;
    pub const executePreparedLifecycle = execute_prepared_lifecycle;
    pub const executeDispatch = execute_dispatch;
    pub const executeBufferWrite = execute_buffer_write_bytes_iface;
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
