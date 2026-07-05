const std = @import("std");
const builtin = @import("builtin");
const model_commands = @import("../../model_commands.zig");
const model_profile = @import("../../model_profile.zig");
const model_resource_types = @import("../../model_resource_types.zig");
const model_compute_types = @import("../../model_compute_types.zig");
const model_render_types = @import("../../model_render_types.zig");
const model_async_types = @import("../../model_async_types.zig");
const webgpu = @import("../runtime_types.zig");
const backend_iface = @import("../backend_iface.zig");
const backend_policy = @import("../backend_policy.zig");
const common_errors = @import("../common/errors.zig");
const command_info = @import("../common/command_info.zig");
const capabilities = @import("../common/capabilities.zig");
const artifact_meta = @import("../common/artifact_meta.zig");
const artifact_policy = @import("../common/artifact_policy.zig");
const hash_utils = @import("../common/hash_utils.zig");
const artifact_emit = @import("artifact_emit.zig");
const backend_execute = @import("backend_execute.zig");
const native_runtime = @import("native_runtime.zig");
const vk_pipeline_cache_persistent = @import("vk_pipeline_cache_persistent.zig");

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
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const KernelBinding = model_compute_types.KernelBinding;
    pub const KernelDispatchCommand = model_compute_types.KernelDispatchCommand;
    pub const RenderDrawCommand = model_render_types.RenderDrawCommand;
    pub const UploadCommand = model_resource_types.UploadCommand;
};

// Uploads accumulate and flush lazily: flush_pending_uploads_if_required fires
// once before the first non-upload command that needs to see the written data.
// This matches Dawn's batched-upload behavior and eliminates per-upload fence overhead.
const UPLOAD_BATCH_LAZY: u32 = std.math.maxInt(u32);

pub const ZigVulkanBackend = struct {
    allocator: std.mem.Allocator,
    kernel_root_owned: ?[]u8 = null,
    runtime: ?native_runtime.NativeVulkanRuntime = null,

    upload_path_policy: backend_policy.UploadPathPolicy = .allow_mapped_shortcuts,
    upload_buffer_usage_mode: webgpu.UploadBufferUsageMode = .copy_dst_copy_src,
    upload_submit_every: u32 = UPLOAD_BATCH_LAZY,
    queue_family_policy: webgpu.QueueFamilyPolicy = .prefer_graphics_compute,
    deferred_submission_sync_policy: webgpu.DeferredSubmissionSyncPolicy = .prefer_timeline_semaphore,
    vulkan_subgroup_size_policy: backend_policy.VulkanSubgroupSizePolicy = .fixed_32_when_supported,
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

    pub fn init(allocator: std.mem.Allocator, profile: model.DeviceProfile, kernel_root: ?[]const u8) !*ZigVulkanBackend {
        return init_with_upload_path_policy(allocator, profile, kernel_root, .allow_mapped_shortcuts);
    }

    pub fn init_with_selection_policy(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
        selection_policy: backend_policy.SelectionPolicy,
    ) !*ZigVulkanBackend {
        return init_with_backend_policy(
            allocator,
            profile,
            kernel_root,
            selection_policy.upload_path_policy,
            selection_policy.queue_family_policy,
            selection_policy.deferred_submission_sync_policy,
            selection_policy.vulkan_subgroup_size_policy,
        );
    }

    fn init_with_upload_path_policy(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
        upload_path_policy: backend_policy.UploadPathPolicy,
    ) !*ZigVulkanBackend {
        return init_with_backend_policy(allocator, profile, kernel_root, upload_path_policy, .prefer_graphics_compute, .prefer_timeline_semaphore, .fixed_32_when_supported);
    }

    fn init_with_backend_policy(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
        upload_path_policy: backend_policy.UploadPathPolicy,
        queue_family_policy: webgpu.QueueFamilyPolicy,
        deferred_submission_sync_policy: webgpu.DeferredSubmissionSyncPolicy,
        vulkan_subgroup_size_policy: backend_policy.VulkanSubgroupSizePolicy,
    ) !*ZigVulkanBackend {
        if (profile.api != .vulkan) return error.UnsupportedFeature;

        const owned_kernel_root = if (kernel_root) |root| try allocator.dupe(u8, root) else null;

        const ptr = try allocator.create(ZigVulkanBackend);
        errdefer allocator.destroy(ptr);

        ptr.* = .{
            .allocator = allocator,
            .kernel_root_owned = owned_kernel_root,
            .runtime = null,
            .upload_path_policy = upload_path_policy,
            .upload_buffer_usage_mode = .copy_dst_copy_src,
            .upload_submit_every = UPLOAD_BATCH_LAZY,
            .queue_family_policy = queue_family_policy,
            .deferred_submission_sync_policy = deferred_submission_sync_policy,
            .vulkan_subgroup_size_policy = vulkan_subgroup_size_policy,
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
            artifact_meta.classify(.native_vulkan, false, false),
            BOOTSTRAP_MANIFEST_STATUS_CODE,
        ) catch {};

        return ptr;
    }

    pub fn as_iface(self: *ZigVulkanBackend, allocator: std.mem.Allocator, reason: []const u8, policy_hash: []const u8) !backend_iface.BackendIface {
        _ = allocator;
        return .{
            .id = .doe_vulkan,
            .context = self,
            .vtable = &VTABLE,
            .telemetry = .{
                .backend_id = .doe_vulkan,
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
                .queue_family_policy = null,
                .queue_family_kind = null,
                .queue_family_queue_count = null,
                .queue_family_timestamp_valid_bits = null,
                .queue_family_supports_graphics = null,
            },
        };
    }

    fn manifest_path(self: *const ZigVulkanBackend) ?[]const u8 {
        return artifact_emit.manifest_path(self);
    }

    fn manifest_hash(self: *const ZigVulkanBackend) ?[]const u8 {
        return artifact_emit.manifest_hash(self);
    }

    fn flush_pending_artifact(self: *ZigVulkanBackend) void {
        artifact_emit.flush_pending_artifact(self);
    }

    fn emit_shader_artifact_manifest_for_signature(
        self: *ZigVulkanBackend,
        module: []const u8,
        meta: artifact_meta.ArtifactMeta,
        status_code: []const u8,
    ) common_errors.BackendNativeError!void {
        return artifact_emit.emit_shader_artifact_manifest_for_signature(self, module, meta, status_code);
    }

    pub fn write_status(self: *ZigVulkanBackend, comptime fmt: []const u8, args: anytype) []const u8 {
        const rendered = std.fmt.bufPrint(&self.status_message_storage, fmt, args) catch "status_format_error";
        self.status_message_len = rendered.len;
        return self.status_message_storage[0..self.status_message_len];
    }

    pub fn ensure_runtime_bootstrapped(self: *ZigVulkanBackend) !*native_runtime.NativeVulkanRuntime {
        if (self.runtime == null) {
            self.runtime = try native_runtime.NativeVulkanRuntime.init_with_backend_policy(
                self.allocator,
                self.kernel_root_owned,
                self.queue_family_policy,
                self.deferred_submission_sync_policy,
                self.vulkan_subgroup_size_policy,
            );
        }
        return &self.runtime.?;
    }

    fn reset_last_submit_count(self: *ZigVulkanBackend) void {
        if (self.runtime) |*runtime| {
            runtime.last_submit_count = null;
        }
    }

    /// Shader-artifact-manifest integration: expose the most recently compiled
    /// SPIR-V bytes so the manifest emitter can write a sibling .spv file and
    /// record its path in the ir_to_spirv stage record. Declared on the struct
    /// so `@hasDecl` on the backend type resolves to this method.
    pub fn pending_spirv_bytes_view(self: *ZigVulkanBackend) ?[]const u8 {
        const runtime = &(self.runtime orelse return null);
        const bytes = runtime.pending_spirv_bytes_owned orelse return null;
        if (bytes.len == 0) return null;
        return bytes;
    }

    /// Frees the SPIR-V bytes stashed on the runtime. Ownership of the allocation
    /// stays with the backend's allocator; the runtime only holds the slice.
    pub fn release_pending_spirv_bytes(self: *ZigVulkanBackend) void {
        const runtime = &(self.runtime orelse return);
        if (runtime.pending_spirv_bytes_owned) |bytes| {
            self.allocator.free(bytes);
            runtime.pending_spirv_bytes_owned = null;
        }
    }

    pub fn annotate_result(self: *ZigVulkanBackend, command: model.Command, result: webgpu.NativeExecutionResult) webgpu.NativeExecutionResult {
        var out = result;
        const meta = artifact_meta.classify(
            .native_vulkan,
            out.gpu_timestamp_valid,
            out.gpu_timestamp_attempted,
        );
        if (out.status == .ok or out.status_message.len == 0) {
            out.status_message = self.write_status(
                "{s} timing={s} comparability={s}",
                .{ command_info.manifest_module(command), meta.timing_source.name(), meta.comparability.name() },
            );
        }

        if (artifact_policy.should_emit_shader_artifact(command)) {
            const status_code = artifact_policy.artifact_status_code(out);
            const copy_len = @min(status_code.len, self.pending_artifact_status_storage.len);
            std.mem.copyForwards(u8, self.pending_artifact_status_storage[0..copy_len], status_code[0..copy_len]);
            self.pending_artifact_status_len = copy_len;
            self.pending_artifact_module = command_info.shader_artifact_module(command);
            self.pending_artifact_meta = meta;
            self.pending_artifact_write = true;
        }

        return out;
    }
};

fn native_capability_set() capabilities.CapabilitySet {
    var set = capabilities.CapabilitySet{};
    set.declare_all(&.{
        .kernel_dispatch,
        .compute_dispatch,
        .compute_dispatch_indirect,
        .buffer_upload,
        .buffer_write,
        .buffer_copy,
        .barrier_sync,
        .sampler_lifecycle,
        .render_draw,
        .render_pass,
        .texture_write,
        .texture_query,
        .texture_destroy,
        .surface_lifecycle,
        .surface_present,
        .async_pipeline_diagnostics,
        .async_capability_introspection,
        .async_resource_table_immediates,
        .async_lifecycle_refcount,
        .async_pixel_local_storage,
        .gpu_timestamps,
        .render_bundle,
        .indirect_draw,
        .indexed_indirect_draw,
        .depth_stencil,
        .descriptor_binding,
    });
    return set;
}

fn cast(ctx: *anyopaque) *ZigVulkanBackend {
    return @as(*ZigVulkanBackend, @ptrCast(@alignCast(ctx)));
}

pub fn manifest_path_from_context(ctx: *anyopaque) ?[]const u8 {
    const self = cast(ctx);
    self.flush_pending_artifact();
    return self.manifest_path();
}

pub fn manifest_hash_from_context(ctx: *anyopaque) ?[]const u8 {
    return cast(ctx).manifest_hash();
}

pub fn adapter_ordinal_from_context(ctx: *anyopaque) ?u32 {
    const self = cast(ctx);
    if (self.runtime) |*runtime| {
        return runtime.adapter_ordinal_value;
    }
    return null;
}

pub fn queue_family_index_from_context(ctx: *anyopaque) ?u32 {
    const self = cast(ctx);
    if (self.runtime) |*runtime| {
        return runtime.queue_family_index_value_cache;
    }
    return null;
}

pub fn present_capable_from_context(ctx: *anyopaque) ?bool {
    const self = cast(ctx);
    if (self.runtime) |*runtime| {
        return runtime.present_capable_value;
    }
    return null;
}

pub fn queue_family_policy_from_context(ctx: *anyopaque) ?[]const u8 {
    const self = cast(ctx);
    if (self.runtime) |*runtime| {
        return runtime.queue_family_policy.name();
    }
    return self.queue_family_policy.name();
}

pub fn queue_family_kind_from_context(ctx: *anyopaque) ?[]const u8 {
    const self = cast(ctx);
    if (self.runtime) |*runtime| {
        const kind = runtime.queue_family_kind_value_cache orelse return null;
        return kind.name();
    }
    return null;
}

pub fn queue_family_queue_count_from_context(ctx: *anyopaque) ?u32 {
    const self = cast(ctx);
    if (self.runtime) |*runtime| {
        return runtime.queue_family_queue_count_value_cache;
    }
    return null;
}

pub fn queue_family_timestamp_valid_bits_from_context(ctx: *anyopaque) ?u32 {
    const self = cast(ctx);
    if (self.runtime) |*runtime| {
        return runtime.queue_family_timestamp_valid_bits_value_cache;
    }
    return null;
}

pub fn queue_family_supports_graphics_from_context(ctx: *anyopaque) ?bool {
    const self = cast(ctx);
    if (self.runtime) |*runtime| {
        return runtime.queue_family_supports_graphics_value_cache;
    }
    return null;
}

pub fn pipeline_cache_active_from_context(ctx: *anyopaque) bool {
    _ = ctx;
    return vk_pipeline_cache_persistent.process_active_cache_present();
}

pub fn pipeline_cache_warmup_telemetry_from_context(ctx: *anyopaque) vk_pipeline_cache_persistent.WarmupTelemetry {
    _ = ctx;
    return vk_pipeline_cache_persistent.process_active_cache_warmup_telemetry();
}

pub fn last_submit_count_from_context(ctx: *anyopaque) ?u32 {
    const self = cast(ctx);
    if (self.runtime) |*runtime| {
        return runtime.last_submit_count;
    }
    return null;
}

pub fn set_pipeline_cache_disabled(disabled: bool) void {
    vk_pipeline_cache_persistent.set_process_pipeline_cache_disabled(disabled);
}

pub fn set_pipeline_cache_dir(dir: []const u8) void {
    vk_pipeline_cache_persistent.set_process_pipeline_cache_dir(dir);
}

fn deinit(ctx: *anyopaque) void {
    const self = cast(ctx);
    const allocator = self.allocator;
    if (self.runtime) |*runtime| {
        runtime.deinit();
        self.runtime = null;
    }

    if (self.kernel_root_owned) |kernel_root| {
        allocator.free(kernel_root);
        self.kernel_root_owned = null;
    }

    allocator.destroy(self);
}

fn execute_command(ctx: *anyopaque, command: model.Command) anyerror!webgpu.NativeExecutionResult {
    const self = cast(ctx);
    self.reset_last_submit_count();
    return backend_execute.execute_command(self, command);
}

fn execute_buffer_write_bytes_iface(ctx: *anyopaque, handle: u64, offset: u64, buffer_size: u64, data: []const u8) anyerror!webgpu.NativeExecutionResult {
    const self = cast(ctx);
    self.reset_last_submit_count();
    return backend_execute.execute_buffer_write_bytes_iface(self, handle, offset, buffer_size, data);
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
