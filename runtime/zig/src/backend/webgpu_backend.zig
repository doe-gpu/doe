const std = @import("std");
const model_commands = @import("../contracts/model/model_commands.zig");
const model_profile = @import("../contracts/model/model_profile.zig");
const model_transfer_types = @import("../contracts/model/model_compute_types.zig");
const abi_callback = @import("../core/abi/wgpu_callback_descriptor_types.zig");
const abi_core = @import("../core/abi/wgpu_core_base_types.zig");
const abi_feature = @import("../core/abi/wgpu_feature_base_types.zig");
const abi_handle = @import("../core/abi/wgpu_handle_types.zig");
const backend_types = @import("webgpu_backend_types.zig");
const lifecycle = @import("webgpu_backend_lifecycle.zig");
const ops = @import("webgpu_backend_ops.zig");
const support = @import("webgpu_backend_support.zig");
const runtime_types = @import("runtime_types.zig");
const loader = @import("../core/abi/wgpu_loader.zig");
const p1_capability_procs_mod = @import("../core/abi/procs/wgpu_p1_capability_procs.zig");
const p1_resource_table_procs_mod = @import("../core/abi/procs/wgpu_p1_resource_table_procs.zig");
const p2_lifecycle_procs_mod = @import("../core/abi/procs/wgpu_p2_lifecycle_procs.zig");
const commands = @import("../full/command/wgpu_commands.zig");
const copy_commands = @import("../core/resource/wgpu_commands_copy.zig");
const env_flags = @import("../runtime/env_flags.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const KernelBinding = model_transfer_types.KernelBinding;
};

pub const NativeExecutionStatus = runtime_types.NativeExecutionStatus;
pub const NativeExecutionResult = runtime_types.NativeExecutionResult;
const QUEUE_SYNC_RETRY_LIMIT: u32 = 3;
const QUEUE_SYNC_RETRY_BACKOFF_NS: u64 = 1_000_000;
const TIMESTAMP_MAP_RETRY_LIMIT: u32 = 3;
const TIMESTAMP_MAP_RETRY_BACKOFF_NS: u64 = 1_000_000;
pub const UploadBufferUsageMode = runtime_types.UploadBufferUsageMode;
pub const QueueWaitMode = runtime_types.QueueWaitMode;
pub const QueueSyncMode = runtime_types.QueueSyncMode;
pub const GpuTimestampMode = runtime_types.GpuTimestampMode;
pub const ManagedSurface = backend_types.ManagedSurface;
pub const CoreWebGPUBackend = backend_types.CoreWebGPUBackend;
pub const FullWebGPUBackendState = backend_types.FullWebGPUBackendState;

pub const WebGPUBackend = struct {
    const Self = @This();

    core: CoreWebGPUBackend,
    full: FullWebGPUBackendState,

    pub fn init(allocator: std.mem.Allocator, profile: model.DeviceProfile, kernel_root: ?[]const u8) !Self {
        var self = Self{
            .core = .{
                .allocator = allocator,
                .buffers = std.AutoHashMap(u64, backend_types.BufferRecord).init(allocator),
                .textures = std.AutoHashMap(u64, backend_types.TextureRecord).init(allocator),
                .pipeline_cache = std.AutoHashMap(u64, backend_types.PipelineCacheEntry).init(allocator),
                .kernel_root = kernel_root,
                .library_error = "",
                .requested_backend_type = lifecycle.preferredBackendType(profile),
            },
            .full = .{
                .render_pipeline_cache = std.AutoHashMap(u32, backend_types.RenderPipelineCacheEntry).init(allocator),
                .render_target_view_cache = std.AutoHashMap(u64, backend_types.RenderTextureViewCacheEntry).init(allocator),
                .render_depth_view_cache = std.AutoHashMap(u64, backend_types.RenderTextureViewCacheEntry).init(allocator),
                .samplers = std.AutoHashMap(u64, abi_handle.WGPUSampler).init(allocator),
                .surfaces = std.AutoHashMap(u64, ManagedSurface).init(allocator),
            },
        };
        errdefer self.deinit();
        self.core.timestamp_debug = env_flags.enabled(allocator, "DOE_WGPU_TIMESTAMP_DEBUG");
        self.core.dyn_lib = try loader.openLibrary();
        self.core.procs = try loader.loadProcs(self.core.dyn_lib.?);
        self.core.capability_procs = p1_capability_procs_mod.loadCapabilityProcs(self.core.dyn_lib);
        self.core.resource_table_procs = p1_resource_table_procs_mod.loadResourceTableProcs(self.core.dyn_lib);
        self.core.lifecycle_procs = p2_lifecycle_procs_mod.loadLifecycleProcs(self.core.dyn_lib);
        if (self.core.procs) |procs| {
            self.core.instance = procs.wgpuCreateInstance(null);
            if (self.core.instance == null) return error.NativeInstanceUnavailable;
            // Bootstrap only from the stable feature/limit path; richer capability
            // introspection stays behind the explicit diagnostics entrypoint.
            self.core.adapter = try lifecycle.requestAdapter(&self);
            self.core.adapter_has_timestamp_query = procs.wgpuAdapterHasFeature(self.core.adapter.?, abi_feature.WGPUFeatureName_TimestampQuery) != abi_core.WGPU_FALSE;
            self.core.adapter_has_multi_draw_indirect = procs.wgpuAdapterHasFeature(self.core.adapter.?, abi_feature.WGPUFeatureName_MultiDrawIndirect) != abi_core.WGPU_FALSE;
            self.core.adapter_has_pixel_local_storage_coherent = procs.wgpuAdapterHasFeature(self.core.adapter.?, abi_feature.WGPUFeatureName_PixelLocalStorageCoherent) != abi_core.WGPU_FALSE;
            self.core.adapter_has_pixel_local_storage_non_coherent = procs.wgpuAdapterHasFeature(self.core.adapter.?, abi_feature.WGPUFeatureName_PixelLocalStorageNonCoherent) != abi_core.WGPU_FALSE;
            self.core.adapter_has_shader_f16 = procs.wgpuAdapterHasFeature(self.core.adapter.?, abi_feature.WGPUFeatureName_ShaderF16) != abi_core.WGPU_FALSE;
            self.core.has_timestamp_query = self.core.adapter_has_timestamp_query;
            self.core.has_multi_draw_indirect = self.core.adapter_has_multi_draw_indirect;
            self.core.has_pixel_local_storage_coherent = self.core.adapter_has_pixel_local_storage_coherent;
            self.core.has_pixel_local_storage_non_coherent = self.core.adapter_has_pixel_local_storage_non_coherent;
            self.core.has_shader_f16 = self.core.adapter_has_shader_f16;
            self.core.has_timestamp_inside_passes = procs.wgpuAdapterHasFeature(self.core.adapter.?, abi_feature.WGPUFeatureName_ChromiumExperimentalTimestampQueryInsidePasses) != abi_core.WGPU_FALSE;
            try lifecycle.captureAdapterLimits(&self);
            self.core.device = try lifecycle.requestDevice(&self);
            if (procs.wgpuDeviceHasFeature) |device_has_feature| {
                self.core.has_timestamp_query = device_has_feature(self.core.device.?, abi_feature.WGPUFeatureName_TimestampQuery) != abi_core.WGPU_FALSE;
                self.core.has_multi_draw_indirect = device_has_feature(self.core.device.?, abi_feature.WGPUFeatureName_MultiDrawIndirect) != abi_core.WGPU_FALSE;
                self.core.has_pixel_local_storage_coherent = device_has_feature(self.core.device.?, abi_feature.WGPUFeatureName_PixelLocalStorageCoherent) != abi_core.WGPU_FALSE;
                self.core.has_pixel_local_storage_non_coherent = device_has_feature(self.core.device.?, abi_feature.WGPUFeatureName_PixelLocalStorageNonCoherent) != abi_core.WGPU_FALSE;
                self.core.has_shader_f16 = device_has_feature(self.core.device.?, abi_feature.WGPUFeatureName_ShaderF16) != abi_core.WGPU_FALSE;
            }
            self.core.queue = procs.wgpuDeviceGetQueue(self.core.device.?);
            if (self.core.queue == null) return error.NativeQueueUnavailable;
            try lifecycle.captureDeviceLimits(&self);
            lifecycle.timestampLog(
                &self,
                "init_features adapter_ts={} device_ts={} inside_passes={} adapter_multi_draw={} device_multi_draw={} adapter_pls_coherent={} adapter_pls_noncoherent={} device_pls_coherent={} device_pls_noncoherent={} adapter_shader_f16={} device_shader_f16={}\n",
                .{
                    self.core.adapter_has_timestamp_query,
                    self.core.has_timestamp_query,
                    self.core.has_timestamp_inside_passes,
                    self.core.adapter_has_multi_draw_indirect,
                    self.core.has_multi_draw_indirect,
                    self.core.adapter_has_pixel_local_storage_coherent,
                    self.core.adapter_has_pixel_local_storage_non_coherent,
                    self.core.has_pixel_local_storage_coherent,
                    self.core.has_pixel_local_storage_non_coherent,
                    self.core.adapter_has_shader_f16,
                    self.core.has_shader_f16,
                },
            );
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        return lifecycle.deinit(self);
    }

    pub fn backendAvailable(self: Self) bool {
        return support.backendAvailable(self);
    }

    pub fn executeCommand(self: *Self, command: model.Command) !NativeExecutionResult {
        return commands.executeCommand(self, command);
    }

    pub fn executeBufferWriteBytes(
        self: *Self,
        handle: u64,
        offset: u64,
        buffer_size: u64,
        data: []const u8,
    ) !NativeExecutionResult {
        if (!self.backendAvailable()) {
            return .{
                .status = .@"error",
                .status_message = "backend-not-initialized",
            };
        }

        self.clearUncapturedError();
        const result = try copy_commands.executeBufferWriteBytes(
            self,
            handle,
            offset,
            buffer_size,
            data,
        );
        if (self.takeUncapturedError()) |error_type| {
            return .{
                .status = .@"error",
                .status_message = support.uncapturedErrorStatusMessage(error_type),
                .setup_ns = result.setup_ns,
                .encode_ns = result.encode_ns,
                .submit_wait_ns = result.submit_wait_ns,
                .dispatch_count = result.dispatch_count,
                .gpu_timestamp_ns = result.gpu_timestamp_ns,
                .gpu_timestamp_attempted = result.gpu_timestamp_attempted,
                .gpu_timestamp_valid = result.gpu_timestamp_valid,
            };
        }
        return result;
    }

    pub fn runCapabilityIntrospection(self: *Self) !void {
        return support.runCapabilityIntrospection(self);
    }

    pub fn getResourceTableProcs(self: Self) ?p1_resource_table_procs_mod.ResourceTableProcs {
        return support.getResourceTableProcs(self);
    }

    pub fn getLifecycleProcs(self: Self) ?p2_lifecycle_procs_mod.LifecycleProcs {
        return support.getLifecycleProcs(self);
    }

    pub fn setUploadBehavior(
        self: *Self,
        usage_mode: UploadBufferUsageMode,
        submit_every: u32,
    ) void {
        return support.setUploadBehavior(self, usage_mode, submit_every);
    }

    pub fn setQueueWaitMode(self: *Self, wait_mode: QueueWaitMode) void {
        return support.setQueueWaitMode(self, wait_mode);
    }

    pub fn setWebgpuFfiQueueWaitTimeoutNs(self: *Self, timeout_ns: u64) void {
        return support.setWebgpuFfiQueueWaitTimeoutNs(self, timeout_ns);
    }

    pub fn setQueueSyncMode(self: *Self, sync_mode: QueueSyncMode) void {
        return support.setQueueSyncMode(self, sync_mode);
    }

    pub fn setGpuTimestampMode(self: *Self, timestamp_mode: GpuTimestampMode) void {
        return support.setGpuTimestampMode(self, timestamp_mode);
    }

    pub fn gpuTimestampsEnabled(self: *const Self) bool {
        return support.gpuTimestampsEnabled(self);
    }

    pub fn gpuTimestampsRequired(self: *const Self) bool {
        return support.gpuTimestampsRequired(self);
    }

    pub fn clearUncapturedError(self: *Self) void {
        return support.clearUncapturedError(self);
    }

    pub fn takeUncapturedError(self: *Self) ?abi_callback.WGPUErrorType {
        return support.takeUncapturedError(self);
    }

    pub fn uncapturedErrorStatusMessage(error_type: abi_callback.WGPUErrorType) []const u8 {
        return support.uncapturedErrorStatusMessage(error_type);
    }

    pub fn effectiveLimits(self: *const Self) ?*const abi_callback.WGPULimits {
        return support.effectiveLimits(self);
    }

    pub fn releaseFullTextureViewsForTexture(self: *Self, texture: abi_handle.WGPUTexture) void {
        return support.releaseFullTextureViewsForTexture(self, texture);
    }

    pub const syncAfterSubmit = ops.syncAfterSubmit;
    pub const submitEmpty = ops.submitEmpty;
    pub const submitCommandBuffers = ops.submitCommandBuffers;
    pub const submitInternal = ops.submitInternal;
    pub const flushQueue = ops.flushQueue;
    pub const captureBuffer = ops.captureBuffer;
    pub const waitForQueue = ops.waitForQueue;
    pub const waitForQueueOnce = ops.waitForQueueOnce;
    pub const shouldRetryQueueWait = ops.shouldRetryQueueWait;
    pub const waitForQueueProcessEvents = ops.waitForQueueProcessEvents;
    pub const waitForQueueWaitAny = ops.waitForQueueWaitAny;
    pub const readTimestampBuffer = ops.readTimestampBuffer;
    pub const readTimestampBufferOnce = ops.readTimestampBufferOnce;
    pub const shouldRetryTimestampMap = ops.shouldRetryTimestampMap;
    pub const processEventsUntil = ops.processEventsUntil;
    pub const createSurface = ops.createSurface;
    pub const getSurfaceCapabilities = ops.getSurfaceCapabilities;
    pub const freeSurfaceCapabilities = ops.freeSurfaceCapabilities;
    pub const configureSurface = ops.configureSurface;
    pub const getCurrentSurfaceTexture = ops.getCurrentSurfaceTexture;
    pub const presentSurface = ops.presentSurface;
    pub const unconfigureSurface = ops.unconfigureSurface;
    pub const releaseSurface = ops.releaseSurface;
    pub fn prewarmUploadPath(self: *Self, max_upload_bytes: u64) !void {
        return ops.prewarmUploadPath(self, max_upload_bytes);
    }

    pub fn prewarmKernelPipeline(self: *Self, kernel: []const u8, bindings: ?[]const model.KernelBinding) !void {
        return ops.prewarmKernelPipeline(self, kernel, bindings);
    }

    pub fn timestampLog(self: *Self, comptime fmt: []const u8, args: anytype) void {
        return lifecycle.timestampLog(self, fmt, args);
    }
};
