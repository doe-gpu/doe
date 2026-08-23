const std = @import("std");
const builtin = @import("builtin");
const common_timing = @import("../common/timing.zig");
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const model_texture_types = @import("../../contracts/model/model_texture_types.zig");
const model_surface_control_types = @import("../../contracts/model/model_surface_control_types.zig");
const model_async_types = @import("../../contracts/model/model_async_types.zig");
const webgpu = @import("../../contracts/runtime_types.zig");
const async_runtime = @import("metal_async_runtime.zig");
const cleanup = @import("metal_cleanup.zig");
const copy_runtime = @import("metal_copy_runtime.zig");
const deferred_release = @import("metal_deferred_release.zig");
const dispatch_runtime = @import("metal_dispatch_runtime.zig");
const metal_buffer_pool = @import("metal_buffer_pool.zig");
const metal_gpu_timestamps = @import("metal_gpu_timestamps.zig");
const metal_pipeline_cache = @import("metal_pipeline_cache.zig");
const metal_runtime_limits = @import("metal_runtime_limits.zig");
const queue_ops = @import("metal_runtime_queue_ops.zig");
const render_ops = @import("metal_runtime_render_ops.zig");
const metal_upload = @import("metal_upload.zig");
const resource_commands = @import("metal_resource_commands.zig");
const resource_runtime = @import("metal_runtime_resources.zig");
const surface_runtime = @import("metal_surface_runtime.zig");
const kernel_dispatch = @import("metal_kernel_dispatch.zig");
const bridge = @import("metal_bridge_decls.zig");
const HAS_PIPELINE_CACHE = builtin.os.tag == .macos;
const metal_bridge_create_default_device = bridge.metal_bridge_create_default_device;
const metal_bridge_device_new_command_queue = bridge.metal_bridge_device_new_command_queue;
const metal_bridge_device_new_shared_event = bridge.metal_bridge_device_new_shared_event;
const metal_bridge_end_blit_encoding = bridge.metal_bridge_end_blit_encoding;
const metal_bridge_release = bridge.metal_bridge_release;
const metal_bridge_render_encoder_end = bridge.metal_bridge_render_encoder_end;

pub const MAX_UPLOAD_BYTES: u64 = 0; // unused; retained for prewarm clamp only
pub const MAX_BINDING_SLOTS: usize = 32;
pub const SMALL_UPLOAD_CAPACITY: usize = metal_runtime_limits.SMALL_UPLOAD_CAPACITY;
pub const FAST_WAIT_UPLOAD_THRESHOLD: usize = metal_runtime_limits.FAST_WAIT_UPLOAD_THRESHOLD;
pub const MAX_POOL_ENTRIES_PER_SIZE: usize = metal_buffer_pool.MAX_POOL_ENTRIES_PER_SIZE;
pub const DispatchMetrics = kernel_dispatch.DispatchMetrics;
pub const FlushResult = queue_ops.FlushResult;
pub const RenderMetrics = render_ops.RenderMetrics;
pub const KernelPipelineInfo = resource_runtime.KernelPipelineInfo;

pub const PendingUpload = struct {
    src_buffer: ?*anyopaque,
    dst_buffer: ?*anyopaque,
    byte_count: usize,
};

pub const KernelPipeline = struct {
    library: ?*anyopaque,
    pipeline: ?*anyopaque,
    workgroup_size: [3]u32 = .{ 0, 0, 0 },
};

pub const IcbKey = struct {
    draw_count: u32,
    vertex_count: u32,
    instance_count: u32,
    redundant: bool,
};

pub const NativeMetalRuntime = struct {
    allocator: std.mem.Allocator,
    device: ?*anyopaque = null,
    queue: ?*anyopaque = null,
    has_device: bool = false,

    kernel_root: ?[]const u8 = null,
    pipeline_cache_dir: []const u8 = "",
    pipeline_cache_enabled: bool = true,

    has_deferred_submissions: bool = false,

    outstanding_cmd_buf: ?*anyopaque = null,
    deferred_releases: std.ArrayListUnmanaged(?*anyopaque) = .{},

    // Batch deferred release pool — collects texture/sampler destroys and
    // drains them in a tight loop at command buffer boundaries, amortizing
    // per-call CFRelease overhead that causes tail-negative timing under
    // aggregate lane pressure.
    deferred_pool: deferred_release.DeferredReleasePool = .{},

    // Sampler descriptor cache — reuses identical MTLSamplerState objects
    // across create/destroy cycles instead of round-tripping through
    // Metal's alloc/dealloc path for every sampler lifecycle command.
    sampler_cache: deferred_release.SamplerCache = deferred_release.SamplerCache.init(),

    shared_event: ?*anyopaque = null,
    fence_value: u64 = 0,

    streaming_cmd_buf: ?*anyopaque = null,
    streaming_blit_encoder: ?*anyopaque = null,
    streaming_compute_encoder: ?*anyopaque = null,
    streaming_compute_dispatch_count: u32 = 0,
    streaming_render_encoder: ?*anyopaque = null,
    streaming_has_render: bool = false,
    streaming_has_copy: bool = false,
    streaming_max_upload_bytes: usize = 0,
    streaming_uploads: std.ArrayListUnmanaged(PendingUpload) = .{},
    streaming_gpu_timestamps_active: bool = false,

    shared_pool: std.AutoHashMapUnmanaged(usize, std.ArrayListUnmanaged(?*anyopaque)) = .{},
    private_pool: std.AutoHashMapUnmanaged(usize, std.ArrayListUnmanaged(?*anyopaque)) = .{},

    staging_src: ?*anyopaque = null,
    staging_dst: ?*anyopaque = null,
    staging_src_ptr: ?[*]u8 = null, // cached contents pointer
    staging_src_zeroed: bool = false,

    kernel_pipelines: std.StringHashMapUnmanaged(KernelPipeline) = .{},

    compute_buffers: std.AutoHashMapUnmanaged(u64, ?*anyopaque) = .{},
    dispatch_indirect_args_buffer: ?*anyopaque = null,

    textures: std.AutoHashMapUnmanaged(u64, ?*anyopaque) = .{},

    samplers: std.AutoHashMapUnmanaged(u64, ?*anyopaque) = .{},
    surfaces: std.AutoHashMapUnmanaged(u64, surface_runtime.SurfaceState) = .{},

    render_pipeline: ?*anyopaque = null,
    render_pipeline_format: u32 = 0,

    render_target: ?*anyopaque = null,
    render_target_width: u32 = 0,
    render_target_height: u32 = 0,
    render_target_format: u32 = 0,

    cached_icb: ?*anyopaque = null,
    cached_icb_key: IcbKey = .{ .draw_count = 0, .vertex_count = 0, .instance_count = 0, .redundant = false },

    pipeline_binary_cache: ?*anyopaque = null,
    timestamp_state: metal_gpu_timestamps.TimestampState = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        kernel_root: ?[]const u8,
        pipeline_cache_dir: []const u8,
        pipeline_cache_enabled: bool,
    ) !NativeMetalRuntime {
        var self = NativeMetalRuntime{
            .allocator = allocator,
            .kernel_root = kernel_root,
            .pipeline_cache_dir = pipeline_cache_dir,
            .pipeline_cache_enabled = pipeline_cache_enabled,
        };
        errdefer self.deinit();
        try self.bootstrap();
        return self;
    }

    pub fn deinit(self: *NativeMetalRuntime) void {
        _ = self.flush_queue() catch {};
        queue_ops.wait_outstanding(self);
        // Release any remaining streaming uploads (if flush_queue failed).
        for (self.streaming_uploads.items) |item| {
            metal_bridge_release(item.src_buffer);
            metal_bridge_release(item.dst_buffer);
        }
        self.streaming_uploads.deinit(self.allocator);
        if (self.streaming_compute_encoder) |enc| {
            bridge.metal_bridge_end_compute_encoding(enc);
            self.streaming_compute_encoder = null;
        }
        if (self.streaming_render_encoder) |enc| {
            metal_bridge_render_encoder_end(enc);
            metal_bridge_release(enc);
            self.streaming_render_encoder = null;
        }
        if (self.streaming_blit_encoder) |enc| {
            metal_bridge_end_blit_encoding(enc);
            self.streaming_blit_encoder = null;
        }
        if (self.streaming_cmd_buf) |cb| {
            metal_bridge_release(cb);
            self.streaming_cmd_buf = null;
        }
        self.release_deferred_releases();
        self.deferred_releases.deinit(self.allocator);
        // Drain any pending batch releases before tearing down resource maps.
        self.deferred_pool.drain();
        cleanup.release_buffer_pool(self.allocator, &self.shared_pool);
        cleanup.release_buffer_pool(self.allocator, &self.private_pool);
        release_ref(&self.staging_src);
        release_ref(&self.staging_dst);
        self.staging_src_zeroed = false;
        cleanup.release_kernel_pipelines(self);
        cleanup.release_compute_buffers(self);
        release_ref(&self.dispatch_indirect_args_buffer);
        cleanup.release_textures(self);
        // release_samplers coordinates with sampler_cache: cache-managed handles
        // are ref-counted down, non-cached handles are released directly.
        cleanup.release_samplers(self);
        // Deinit sampler cache after map cleanup — releases any cached Metal
        // objects whose ref counts reached zero above.
        self.sampler_cache.deinit();
        cleanup.release_surfaces(self);
        cleanup.release_render_resources(self);
        self.timestamp_state.deinit();
        release_ref(&self.shared_event);
        if (builtin.os.tag == .macos) {
            if (HAS_PIPELINE_CACHE) {
                if (self.pipeline_binary_cache) |c| {
                    const typed: *metal_pipeline_cache.MetalPipelineCache = @ptrCast(@alignCast(c));
                    typed.deinit();
                    self.pipeline_binary_cache = null;
                }
            }
        }
        release_ref(&self.queue);
        release_ref(&self.device);
        self.has_device = false;
    }

    pub fn upload_bytes(self: *NativeMetalRuntime, bytes: u64, mode: webgpu.UploadBufferUsageMode) !void {
        return metal_upload.upload_bytes(self, bytes, mode);
    }

    pub fn flush_queue(self: *NativeMetalRuntime) !u64 {
        return queue_ops.flush_queue(self);
    }

    pub fn flush_queue_timed(self: *NativeMetalRuntime) !FlushResult {
        return queue_ops.flush_queue_timed(self);
    }

    pub fn transition_streaming_submission_deferred(self: *NativeMetalRuntime) !void {
        return queue_ops.transition_streaming_submission_deferred(self);
    }

    pub fn barrier(self: *NativeMetalRuntime, queue_wait_mode: webgpu.QueueWaitMode, queue_sync_mode: webgpu.QueueSyncMode) !u64 {
        return queue_ops.barrier(self, queue_wait_mode, queue_sync_mode);
    }

    pub fn prewarm_upload_path(self: *NativeMetalRuntime, max_upload_bytes: u64, mode: webgpu.UploadBufferUsageMode) !void {
        return queue_ops.prewarm_upload_path(self, max_upload_bytes, mode);
    }

    pub const KernelDispatchResult = kernel_dispatch.KernelDispatchResult;

    pub fn run_kernel_dispatch(
        self: *NativeMetalRuntime,
        kernel: []const u8,
        entry_point: ?[]const u8,
        x: u32,
        y: u32,
        z: u32,
        repeat: u32,
        warmup: u32,
        initialize_buffers_on_create: bool,
        bindings: ?[]const model_compute_types.KernelBinding,
    ) !DispatchMetrics {
        return kernel_dispatch.run_kernel_dispatch(self, kernel, entry_point, x, y, z, repeat, warmup, initialize_buffers_on_create, bindings);
    }

    pub fn run_kernel_dispatch_timed(
        self: *NativeMetalRuntime,
        kernel: []const u8,
        entry_point: ?[]const u8,
        x: u32,
        y: u32,
        z: u32,
        repeat: u32,
        warmup: u32,
        initialize_buffers_on_create: bool,
        bindings: ?[]const model_compute_types.KernelBinding,
        queue_sync_mode: webgpu.QueueSyncMode,
        record_timestamps: bool,
    ) !KernelDispatchResult {
        return kernel_dispatch.run_kernel_dispatch_timed(self, kernel, entry_point, x, y, z, repeat, warmup, initialize_buffers_on_create, bindings, queue_sync_mode, record_timestamps);
    }

    pub fn run_dispatch(self: *NativeMetalRuntime, x: u32, y: u32, z: u32, queue_sync_mode: webgpu.QueueSyncMode) !DispatchMetrics {
        const metrics = try dispatch_runtime.run_dispatch(self, x, y, z, queue_sync_mode);
        return .{ .setup_ns = 0, .encode_ns = metrics.encode_ns, .submit_wait_ns = metrics.submit_wait_ns, .dispatch_count = metrics.dispatch_count };
    }

    pub fn run_dispatch_indirect(self: *NativeMetalRuntime, x: u32, y: u32, z: u32, queue_sync_mode: webgpu.QueueSyncMode) !DispatchMetrics {
        const metrics = try dispatch_runtime.run_dispatch_indirect(self, x, y, z, queue_sync_mode);
        return .{ .setup_ns = 0, .encode_ns = metrics.encode_ns, .submit_wait_ns = metrics.submit_wait_ns, .dispatch_count = metrics.dispatch_count };
    }

    pub fn execute_map_async(self: *NativeMetalRuntime, cmd: model_async_types.MapAsyncCommand) !u64 {
        return async_runtime.execute_map_async(self, cmd);
    }

    pub fn sampler_create(self: *NativeMetalRuntime, cmd: model_render_types.SamplerCreateCommand) !void {
        return resource_commands.sampler_create(self, cmd);
    }

    pub fn sampler_destroy(self: *NativeMetalRuntime, cmd: model_render_types.SamplerDestroyCommand) !void {
        return resource_commands.sampler_destroy(self, cmd);
    }

    pub fn texture_write(self: *NativeMetalRuntime, cmd: model_texture_types.TextureWriteCommand) !void {
        return resource_commands.texture_write(self, cmd);
    }

    pub fn write_buffer(self: *NativeMetalRuntime, cmd: model_resource_types.BufferWriteCommand) !void {
        return resource_runtime.write_compute_buffer_words(self, cmd.handle, cmd.offset, cmd.buffer_size, cmd.data);
    }

    pub fn write_buffer_bytes(self: *NativeMetalRuntime, handle: u64, offset: u64, buffer_size: u64, data: []const u8) !void {
        return resource_runtime.write_compute_buffer_bytes(self, handle, offset, buffer_size, data);
    }

    pub fn stage_buffer_write_bytes(self: *NativeMetalRuntime, handle: u64, offset: u64, buffer_size: u64, data: []const u8) !void {
        const required_size = if (buffer_size > 0)
            @max(buffer_size, offset + data.len)
        else
            offset + data.len;
        const dst_buffer = try resource_runtime.ensure_compute_buffer(self, handle, required_size, false);
        try metal_upload.stage_buffer_write_bytes(self, dst_buffer, offset, data);
    }

    pub fn texture_query(self: *NativeMetalRuntime, cmd: model_texture_types.TextureQueryCommand) !void {
        return resource_commands.texture_query(self, cmd);
    }

    pub fn texture_destroy(self: *NativeMetalRuntime, cmd: model_texture_types.TextureDestroyCommand) !void {
        return resource_commands.texture_destroy(self, cmd);
    }

    pub fn render_draw(self: *NativeMetalRuntime, cmd: model_render_types.RenderDrawCommand, queue_sync_mode: webgpu.QueueSyncMode) !RenderMetrics {
        return render_ops.render_draw(self, cmd, queue_sync_mode);
    }

    pub fn copy_command(self: *NativeMetalRuntime, cmd: model_resource_types.CopyCommand, queue_sync_mode: webgpu.QueueSyncMode) !copy_runtime.CopyMetrics {
        return try copy_runtime.execute_copy(self, cmd, queue_sync_mode);
    }

    pub fn surface_create(self: *NativeMetalRuntime, cmd: model_surface_control_types.SurfaceCreateCommand) !void {
        return try surface_runtime.create_surface(self, cmd);
    }

    pub fn surface_capabilities(self: *NativeMetalRuntime, cmd: model_surface_control_types.SurfaceCapabilitiesCommand) !void {
        return try surface_runtime.surface_capabilities(self, cmd);
    }

    pub fn surface_configure(self: *NativeMetalRuntime, cmd: model_surface_control_types.SurfaceConfigureCommand) !void {
        return try surface_runtime.configure_surface(self, cmd);
    }

    pub fn surface_acquire(self: *NativeMetalRuntime, cmd: model_surface_control_types.SurfaceAcquireCommand) !void {
        return try surface_runtime.acquire_surface(self, cmd);
    }

    pub fn surface_present(self: *NativeMetalRuntime, cmd: model_surface_control_types.SurfacePresentCommand) !u64 {
        return try surface_runtime.present_surface(self, cmd);
    }

    pub fn surface_unconfigure(self: *NativeMetalRuntime, cmd: model_surface_control_types.SurfaceUnconfigureCommand) !void {
        return try surface_runtime.unconfigure_surface(self, cmd);
    }

    pub fn surface_release(self: *NativeMetalRuntime, cmd: model_surface_control_types.SurfaceReleaseCommand) !void {
        return try surface_runtime.release_surface(self, cmd);
    }

    pub fn attach_canvas_layer(self: *NativeMetalRuntime, handle: u64, layer: ?*anyopaque) !void {
        return try surface_runtime.attach_canvas_layer(self, handle, layer);
    }

    pub fn update_surface_size(self: *NativeMetalRuntime, handle: u64, width: u32, height: u32, dpi_scale: f32) !void {
        return try surface_runtime.update_surface_size(self, handle, width, height, dpi_scale);
    }

    fn bootstrap(self: *NativeMetalRuntime) !void {
        self.device = metal_bridge_create_default_device() orelse return error.UnsupportedFeature;
        self.queue = metal_bridge_device_new_command_queue(self.device) orelse return error.InvalidState;
        self.shared_event = metal_bridge_device_new_shared_event(self.device);
        self.has_device = true;
        self.timestamp_state.init_resources(self.device);
        if (builtin.os.tag == .macos) {
            if (HAS_PIPELINE_CACHE and self.pipeline_cache_enabled) {
                const cache_ptr = metal_pipeline_cache.MetalPipelineCache.init(
                    self.allocator,
                    self.device,
                    self.pipeline_cache_dir,
                ) catch null;
                self.pipeline_binary_cache = if (cache_ptr) |c| @ptrCast(c) else null;
                // Phase 3: run startup warmup to pre-load cached pipeline binaries.
                if (cache_ptr) |cache| {
                    const compute_keys = cache.run_warmup();
                    const ct0 = common_timing.now_ns();
                    var compute_warmed: u64 = 0;
                    for (compute_keys) |key| {
                        if (resource_runtime.ensure_kernel_pipeline(self, cache, key, null) catch null) |_| {
                            compute_warmed +%= 1;
                        }
                    }
                    const compute_ns = common_timing.ns_delta(common_timing.now_ns(), ct0);
                    cache.finalize_warmup_telemetry(compute_warmed, compute_ns);
                }
            }
        }
    }

    pub fn release_deferred_releases(self: *NativeMetalRuntime) void {
        cleanup.release_deferred(&self.deferred_releases);
    }

    fn pipelineBinaryCache(self: *NativeMetalRuntime) ?*metal_pipeline_cache.MetalPipelineCache {
        if (!HAS_PIPELINE_CACHE) return null;
        const cache = self.pipeline_binary_cache orelse return null;
        return @ptrCast(@alignCast(cache));
    }

    pub fn pipelineCacheActive(self: *const NativeMetalRuntime) bool {
        return self.pipeline_binary_cache != null;
    }

    pub fn pipelineCacheWarmupTelemetry(self: *NativeMetalRuntime) metal_pipeline_cache.WarmupTelemetry {
        const cache = self.pipelineBinaryCache() orelse return .{};
        return cache.warmupTelemetry();
    }

    pub fn ensure_kernel_pipeline(self: *NativeMetalRuntime, kernel: []const u8, entry_point: ?[]const u8) !?*anyopaque {
        return resource_runtime.ensure_kernel_pipeline(self, self.pipelineBinaryCache(), kernel, entry_point);
    }

    pub fn ensure_kernel_pipeline_info(self: *NativeMetalRuntime, kernel: []const u8, entry_point: ?[]const u8) !KernelPipelineInfo {
        return resource_runtime.ensure_kernel_pipeline_info(self, self.pipelineBinaryCache(), kernel, entry_point);
    }

    pub fn get_kernel_workgroup_size(self: *NativeMetalRuntime, kernel: []const u8, entry_point: ?[]const u8) ![3]u32 {
        return resource_runtime.get_kernel_workgroup_size(self, kernel, entry_point);
    }

    pub fn ensure_compute_buffer(self: *NativeMetalRuntime, handle: u64, size: u64, initialize_buffers_on_create: bool) !?*anyopaque {
        return resource_runtime.ensure_compute_buffer(self, handle, size, initialize_buffers_on_create);
    }

    pub fn ensure_render_pipeline(self: *NativeMetalRuntime, fmt: u32) !void {
        return resource_runtime.ensure_render_pipeline(self, self.pipelineBinaryCache(), fmt);
    }

    pub fn ensure_render_target(self: *NativeMetalRuntime, width: u32, height: u32, fmt: u32) !void {
        return resource_runtime.ensure_render_target(self, width, height, fmt);
    }

    pub fn ensure_streaming_render_encoder(self: *NativeMetalRuntime) !void {
        return resource_runtime.ensure_streaming_render_encoder(self);
    }

    pub fn ensure_icb(self: *NativeMetalRuntime, draw_count: u32, vertex_count: u32, instance_count: u32, redundant_pl: c_int) !?*anyopaque {
        return resource_runtime.ensure_icb(self, draw_count, vertex_count, instance_count, redundant_pl);
    }

    pub fn activate_gpu_timestamps(self: *NativeMetalRuntime) !void {
        return metal_gpu_timestamps.activate_gpu_timestamps(self);
    }

    pub fn gpu_timestamps_supported(self: *const NativeMetalRuntime) bool {
        return metal_gpu_timestamps.gpu_timestamps_supported(self);
    }
};

pub const BufferPool = metal_buffer_pool.BufferPool;

pub const release_ref = cleanup.release_ref;

pub fn pool_pop(pool: *BufferPool, size: usize) ?*anyopaque {
    return metal_buffer_pool.pool_pop(pool, size);
}
