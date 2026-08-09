const std = @import("std");
const common_errors = @import("../../contracts/execution.zig");
const webgpu = @import("../runtime_types.zig");
const abi_callback = @import("../../core/abi/wgpu_callback_descriptor_types.zig");
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const model_texture_types = @import("../../contracts/model/model_texture_types.zig");
const model_surface_control_types = @import("../../contracts/model/model_surface_control_types.zig");
const model_async_types = @import("../../contracts/model/model_async_types.zig");
const bridge = @import("d3d12_bridge_decls.zig");

const d3d12_texture = @import("resources/d3d12_texture.zig");
const d3d12_sampler = @import("resources/d3d12_sampler.zig");
const d3d12_depth_stencil = @import("resources/d3d12_depth_stencil.zig");
const d3d12_texture_view = @import("resources/d3d12_texture_view.zig");
const d3d12_streaming_copy = @import("commands/d3d12_streaming_copy.zig");
const d3d12_dispatch = @import("commands/d3d12_dispatch.zig");
const d3d12_render = @import("commands/d3d12_render.zig");
const d3d12_surface = @import("surface/d3d12_surface.zig");
const d3d12_async = @import("commands/d3d12_async_diagnostics.zig");
const d3d12_timestamps = @import("commands/d3d12_gpu_timestamps.zig");
const d3d12_map = @import("commands/d3d12_map_async.zig");
const d3d12_query_set = @import("d3d12_query_set.zig");
const d3d12_descriptors = @import("d3d12_descriptors.zig");
const d3d12_device_caps = @import("d3d12_device_caps.zig");
const compute = @import("d3d12_runtime_compute.zig");
const upload = @import("d3d12_runtime_upload.zig");
const render_bundle = @import("../../runtime/render/render_bundle.zig");

pub const MAX_UPLOAD_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_KERNEL_SOURCE_BYTES: usize = compute.MAX_KERNEL_SOURCE_BYTES;
pub const DEFAULT_KERNEL_ROOT: []const u8 = compute.DEFAULT_KERNEL_ROOT;
pub const MAX_POOL_ENTRIES_PER_SIZE: usize = upload.MAX_POOL_ENTRIES_PER_SIZE;
pub const GENERATED_SHADER_DIR: []const u8 = compute.GENERATED_SHADER_DIR;
pub const MAX_DXC_OUTPUT_BYTES: usize = compute.MAX_DXC_OUTPUT_BYTES;
pub const DXC_PROFILE: []const u8 = compute.DXC_PROFILE;
pub const DXC_ENTRYPOINT: []const u8 = compute.DXC_ENTRYPOINT;
pub const HEAP_TYPE_DEFAULT: c_int = 1;

pub const PendingUpload = upload.PendingUpload;
pub const PoolEntry = upload.PoolEntry;
pub const DispatchMetrics = compute.DispatchMetrics;

const PendingSubmitBatch = struct {
    fence_value: u64,
    cmd_allocator: ?*anyopaque,
    cmd_list: ?*anyopaque,
    retained_handles: std.ArrayListUnmanaged(?*anyopaque) = .{},

    fn deinit(self: *PendingSubmitBatch, allocator: std.mem.Allocator) void {
        for (self.retained_handles.items) |maybe_handle| {
            if (maybe_handle) |handle| bridge.c.d3d12_bridge_release(handle);
        }
        self.retained_handles.deinit(allocator);
        if (self.cmd_list) |cmd_list| bridge.c.d3d12_bridge_release(cmd_list);
        if (self.cmd_allocator) |cmd_allocator| bridge.c.d3d12_bridge_release(cmd_allocator);
        self.* = .{
            .fence_value = 0,
            .cmd_allocator = null,
            .cmd_list = null,
            .retained_handles = .{},
        };
    }
};

pub const NativeD3D12Runtime = struct {
    allocator: std.mem.Allocator,
    kernel_root: ?[]const u8 = null,
    device: ?*anyopaque = null,
    queue: ?*anyopaque = null,
    fence: ?*anyopaque = null,
    fence_value: u64 = 0,
    completed_fence_value: u64 = 0,

    has_device: bool = false,
    pending_uploads: std.ArrayListUnmanaged(PendingUpload) = .{},
    has_deferred_submissions: bool = false,
    pending_submit_batches: std.ArrayListUnmanaged(PendingSubmitBatch) = .{},

    upload_pool: upload.D3D12Pool = .{},
    default_pool: upload.D3D12Pool = .{},

    root_signature: ?*anyopaque = null,
    compute_pipeline: ?*anyopaque = null,
    compute_allocator: ?*anyopaque = null,
    compute_cmd_list: ?*anyopaque = null,
    dispatch_info_buffer: ?*anyopaque = null,
    dispatch_info_cbv_index: u32 = 0,
    has_dispatch_info_cbv: bool = false,
    current_shader_hash: u64 = 0,
    has_root_signature: bool = false,
    has_compute_pipeline: bool = false,
    has_compute_cmd: bool = false,

    device_caps: d3d12_device_caps.D3D12DeviceCaps = .{},

    texture_map: d3d12_texture.TextureMap = .{},
    sampler_state: d3d12_sampler.SamplerState = .{},
    depth_stencil_state: d3d12_depth_stencil.DepthStencilState = .{},
    texture_view_state: d3d12_texture_view.TextureViewState = .{},
    streaming_copy_state: d3d12_streaming_copy.StreamingCopyState = .{},
    dispatch_state: d3d12_dispatch.DispatchState = .{},
    render_state: d3d12_render.RenderState = .{},
    surface_state: d3d12_surface.SurfaceState = .{},
    timestamp_state: d3d12_timestamps.TimestampState = .{},
    query_set_state: d3d12_query_set.QuerySetState = .{},
    descriptor_state: d3d12_descriptors.DescriptorHeapState = .{},

    pub fn init(allocator: std.mem.Allocator, kernel_root: ?[]const u8) !NativeD3D12Runtime {
        var self = NativeD3D12Runtime{ .allocator = allocator, .kernel_root = kernel_root };
        errdefer self.deinit();
        try self.bootstrap();
        return self;
    }

    pub fn deinit(self: *NativeD3D12Runtime) void {
        _ = self.flush_queue() catch {};
        self.completed_fence_value = self.fence_value;
        self.releaseCompletedSubmitBatches();
        self.pending_submit_batches.deinit(self.allocator);
        upload.releasePendingUploads(self);
        self.pending_uploads.deinit(self.allocator);
        upload.d3d12ReleasePool(&self.upload_pool, self.allocator);
        upload.d3d12ReleasePool(&self.default_pool, self.allocator);
        self.streaming_copy_state.deinit();
        compute.destroyComputeObjects(self);
        self.timestamp_state.deinit();
        self.query_set_state.deinit(self.allocator);
        self.render_state.deinit();
        self.dispatch_state.deinit();
        self.surface_state.deinit(self.allocator);
        self.sampler_state.deinit(self.allocator);
        self.depth_stencil_state.deinit();
        self.texture_view_state.deinit(self.allocator);
        self.descriptor_state.deinit();
        if (self.dispatch_info_buffer) |buffer| {
            bridge.c.d3d12_bridge_release(buffer);
            self.dispatch_info_buffer = null;
            self.has_dispatch_info_cbv = false;
        }
        d3d12_texture.release_all(&self.texture_map);
        if (self.fence) |f| {
            bridge.c.d3d12_bridge_release(f);
            self.fence = null;
        }
        if (self.queue) |q| {
            bridge.c.d3d12_bridge_release(q);
            self.queue = null;
        }
        if (self.device) |d| {
            bridge.c.d3d12_bridge_release(d);
            self.device = null;
            self.has_device = false;
        }
    }

    pub fn upload_bytes(self: *NativeD3D12Runtime, bytes: u64, _mode: webgpu.UploadBufferUsageMode) !void {
        _ = _mode;
        return upload.uploadBytes(self, bytes, MAX_UPLOAD_BYTES, HEAP_TYPE_DEFAULT);
    }

    pub fn flush_queue(self: *NativeD3D12Runtime) !u64 {
        return upload.flushQueue(self);
    }

    pub fn barrier(self: *NativeD3D12Runtime, queue_wait_mode: webgpu.QueueWaitMode) !u64 {
        _ = queue_wait_mode;
        return upload.barrier(self);
    }

    pub fn prewarm_upload_path(self: *NativeD3D12Runtime, max_upload_bytes: u64, mode: webgpu.UploadBufferUsageMode) !void {
        if (max_upload_bytes == 0) return;
        _ = mode;
        try upload.uploadBytes(self, @min(max_upload_bytes, MAX_UPLOAD_BYTES), MAX_UPLOAD_BYTES, HEAP_TYPE_DEFAULT);
        _ = try upload.flushQueue(self);
    }

    pub fn load_kernel_cso(self: *const NativeD3D12Runtime, alloc: std.mem.Allocator, kernel_name: []const u8) ![]u8 {
        return compute.loadKernelCso(self, alloc, kernel_name);
    }

    pub fn set_compute_shader(self: *NativeD3D12Runtime, bytecode: []const u8) !void {
        return compute.setComputeShader(self, bytecode);
    }

    pub fn run_dispatch(self: *NativeD3D12Runtime, x: u32, y: u32, z: u32, repeat: u32, queue_sync_mode: webgpu.QueueSyncMode) !DispatchMetrics {
        return compute.runDispatch(self, x, y, z, repeat, queue_sync_mode);
    }

    pub fn flush_before_dropin_submit_if_needed(self: *NativeD3D12Runtime) !void {
        if (self.pending_uploads.items.len == 0 and !self.has_deferred_submissions and !self.streaming_copy_state.has_pending()) {
            return;
        }
        _ = try self.flush_queue();
    }

    pub fn trackDropinSubmission(
        self: *NativeD3D12Runtime,
        cmd_allocator: ?*anyopaque,
        cmd_list: ?*anyopaque,
        retained_handles: *std.ArrayListUnmanaged(?*anyopaque),
    ) !void {
        var batch = PendingSubmitBatch{
            .fence_value = self.fence_value,
            .cmd_allocator = cmd_allocator,
            .cmd_list = cmd_list,
            .retained_handles = retained_handles.*,
        };
        self.pending_submit_batches.append(self.allocator, batch) catch |err| {
            bridge.c.d3d12_bridge_fence_wait(self.fence, self.fence_value);
            self.noteCompletedFenceWait();
            batch.deinit(self.allocator);
            return err;
        };
        retained_handles.* = .{};
    }

    pub fn trackDeferredCommandBatch(
        self: *NativeD3D12Runtime,
        cmd_allocator: ?*anyopaque,
        cmd_list: ?*anyopaque,
    ) !void {
        var retained_handles: std.ArrayListUnmanaged(?*anyopaque) = .{};
        errdefer retained_handles.deinit(self.allocator);
        try self.trackDropinSubmission(cmd_allocator, cmd_list, &retained_handles);
    }

    pub fn noteCompletedFenceWait(self: *NativeD3D12Runtime) void {
        self.completed_fence_value = self.fence_value;
        self.releaseCompletedSubmitBatches();
    }

    // --- Forwarding to sub-modules ---

    pub fn texture_write(self: *NativeD3D12Runtime, cmd: model_texture_types.TextureWriteCommand) !u64 {
        return d3d12_texture.texture_write(self.device, self.queue, &self.texture_map, self.allocator, cmd);
    }

    pub fn texture_query(self: *const NativeD3D12Runtime, cmd: model_texture_types.TextureQueryCommand) !u64 {
        return d3d12_texture.texture_query(&self.texture_map, cmd);
    }

    pub fn texture_destroy(self: *NativeD3D12Runtime, cmd: model_texture_types.TextureDestroyCommand) !u64 {
        return d3d12_texture.texture_destroy(&self.texture_map, cmd);
    }

    pub fn sampler_create(self: *NativeD3D12Runtime, cmd: model_render_types.SamplerCreateCommand) !u64 {
        return self.sampler_state.sampler_create(self.device, self.allocator, cmd);
    }

    pub fn sampler_destroy(self: *NativeD3D12Runtime, cmd: model_render_types.SamplerDestroyCommand) !u64 {
        return self.sampler_state.sampler_destroy(cmd);
    }

    pub fn execute_compute_dispatch(self: *NativeD3D12Runtime, cmd: model_compute_types.DispatchCommand, queue_sync_mode: webgpu.QueueSyncMode) !d3d12_dispatch.DispatchMetrics {
        const submission = try self.dispatch_state.execute_dispatch(self.device, self.queue, self.fence, &self.fence_value, cmd, queue_sync_mode);
        if (submission.cmd_allocator != null or submission.cmd_list != null) {
            try self.trackDeferredCommandBatch(submission.cmd_allocator, submission.cmd_list);
        }
        const metrics = submission.metrics;
        if (metrics.submit_wait_ns != 0) self.noteCompletedFenceWait();
        return metrics;
    }

    pub fn execute_dispatch_indirect(self: *NativeD3D12Runtime, cmd: model_compute_types.DispatchIndirectCommand, queue_sync_mode: webgpu.QueueSyncMode) !d3d12_dispatch.DispatchMetrics {
        const submission = try self.dispatch_state.execute_dispatch_indirect(self.device, self.queue, self.fence, &self.fence_value, cmd, queue_sync_mode);
        if (submission.cmd_allocator != null or submission.cmd_list != null) {
            try self.trackDeferredCommandBatch(submission.cmd_allocator, submission.cmd_list);
        }
        const metrics = submission.metrics;
        if (metrics.submit_wait_ns != 0) self.noteCompletedFenceWait();
        return metrics;
    }

    pub fn execute_copy(self: *NativeD3D12Runtime, cmd: model_resource_types.CopyCommand, queue_sync_mode: webgpu.QueueSyncMode) !d3d12_streaming_copy.CopyMetrics {
        var metrics = try self.streaming_copy_state.record_copy(self.device, &self.texture_map, self.allocator, cmd);
        self.has_deferred_submissions = true;
        if (queue_sync_mode == .per_command) {
            metrics.submit_wait_ns = try self.streaming_copy_state.flush(self.queue, self.fence, &self.fence_value);
            self.has_deferred_submissions = false;
            if (metrics.submit_wait_ns != 0) self.noteCompletedFenceWait();
        }
        return metrics;
    }

    pub fn execute_render_draw(self: *NativeD3D12Runtime, cmd: model_render_types.RenderDrawCommand, is_indirect: bool, is_indexed_indirect: bool, queue_sync_mode: webgpu.QueueSyncMode) !d3d12_render.RenderMetrics {
        const submission = try self.render_state.execute_render_draw(self.device, self.queue, self.fence, &self.fence_value, cmd, is_indirect, is_indexed_indirect, queue_sync_mode, &self.descriptor_state);
        if (submission.cmd_allocator != null or submission.cmd_list != null) {
            try self.trackDeferredCommandBatch(submission.cmd_allocator, submission.cmd_list);
        }
        const metrics = submission.metrics;
        if (metrics.submit_wait_ns != 0) self.noteCompletedFenceWait();
        return metrics;
    }

    pub fn execute_render_bundles(
        self: *NativeD3D12Runtime,
        bundles: []const *const render_bundle.DoeRenderBundle,
        target_width: u32,
        target_height: u32,
        color_format: u32,
        sample_count: u32,
        queue_sync_mode: webgpu.QueueSyncMode,
    ) !d3d12_render.RenderMetrics {
        if (self.has_deferred_submissions or self.pending_uploads.items.len > 0)
            _ = try self.flush_queue();
        const submission = try self.render_state.execute_render_bundles(self.device, self.queue, self.fence, &self.fence_value, bundles, target_width, target_height, color_format, sample_count, queue_sync_mode);
        if (submission.cmd_allocator != null or submission.cmd_list != null) {
            try self.trackDeferredCommandBatch(submission.cmd_allocator, submission.cmd_list);
        }
        const metrics = submission.metrics;
        if (metrics.submit_wait_ns != 0) self.noteCompletedFenceWait();
        return metrics;
    }

    pub fn surface_create(self: *NativeD3D12Runtime, cmd: model_surface_control_types.SurfaceCreateCommand) !u64 {
        return self.surface_state.create_surface(self.allocator, cmd);
    }

    pub fn surface_capabilities(self: *NativeD3D12Runtime, cmd: model_surface_control_types.SurfaceCapabilitiesCommand) !u64 {
        return self.surface_state.surface_capabilities(self.allocator, cmd);
    }

    pub fn surface_configure(self: *NativeD3D12Runtime, cmd: model_surface_control_types.SurfaceConfigureCommand) !u64 {
        return self.surface_state.configure_surface(self.device, self.queue, self.allocator, cmd);
    }

    pub fn surface_acquire(self: *NativeD3D12Runtime, cmd: model_surface_control_types.SurfaceAcquireCommand) !u64 {
        return self.surface_state.acquire_surface(self.allocator, cmd);
    }

    pub fn surface_present(self: *NativeD3D12Runtime, cmd: model_surface_control_types.SurfacePresentCommand) !u64 {
        return self.surface_state.present_surface(cmd);
    }

    pub fn surface_unconfigure(self: *NativeD3D12Runtime, cmd: model_surface_control_types.SurfaceUnconfigureCommand) !u64 {
        return self.surface_state.unconfigure_surface(self.allocator, cmd);
    }

    pub fn surface_release(self: *NativeD3D12Runtime, cmd: model_surface_control_types.SurfaceReleaseCommand) !u64 {
        return self.surface_state.release_surface(cmd);
    }

    pub fn execute_async_diagnostics(self: *NativeD3D12Runtime, cmd: model_async_types.AsyncDiagnosticsCommand) !d3d12_async.AsyncDiagnosticsMetrics {
        return d3d12_async.execute_async_diagnostics(self.device, cmd);
    }

    pub fn execute_map_async(self: *NativeD3D12Runtime, cmd: model_async_types.MapAsyncCommand) !u64 {
        return d3d12_map.execute_map_async(self.device, cmd);
    }

    pub fn init_timestamps(self: *NativeD3D12Runtime) !void {
        try self.timestamp_state.init_resources(self.device, self.queue);
    }

    // Flush outstanding GPU work before reporting completion to the caller.
    pub fn on_submitted_work_done(self: *NativeD3D12Runtime) !u64 {
        if (self.has_deferred_submissions or self.pending_uploads.items.len > 0 or self.pending_submit_batches.items.len > 0) {
            return try self.flush_queue();
        }
        return 0;
    }

    pub fn has_feature(self: *const NativeD3D12Runtime, feature: u32) bool {
        if (self.has_device) {
            return d3d12_device_caps.d3d12_device_has_feature_with_caps(feature, self.device_caps);
        }
        return d3d12_device_caps.d3d12_device_has_feature(feature);
    }

    pub fn get_limits(self: *const NativeD3D12Runtime, limits: *abi_callback.WGPULimits) void {
        _ = self;
        d3d12_device_caps.d3d12_device_get_limits(limits);
    }

    pub fn create_query_set(self: *NativeD3D12Runtime, handle: u64, query_type: d3d12_query_set.QueryType, count: u32) !u64 {
        return self.query_set_state.create(self.allocator, self.device, self.queue, handle, query_type, count);
    }

    pub fn destroy_query_set(self: *NativeD3D12Runtime, handle: u64) void {
        self.query_set_state.destroy(handle);
    }

    pub fn ensure_descriptor_heaps(self: *NativeD3D12Runtime) !void {
        try self.descriptor_state.ensure_heaps(self.device);
    }

    pub fn create_depth_stencil(self: *NativeD3D12Runtime, width: u32, height: u32, format: u32) !void {
        try self.depth_stencil_state.ensure_depth_texture(self.device, width, height, format);
    }

    // --- Private ---

    fn bootstrap(self: *NativeD3D12Runtime) !void {
        self.device = bridge.c.d3d12_bridge_create_device() orelse return error.UnsupportedFeature;
        self.queue = bridge.c.d3d12_bridge_device_create_command_queue(self.device) orelse return error.InvalidState;
        self.fence = bridge.c.d3d12_bridge_device_create_fence(self.device) orelse return error.InvalidState;
        self.has_device = true;
        self.device_caps = d3d12_device_caps.query_device_caps(self.device);
    }

    fn releaseCompletedSubmitBatches(self: *NativeD3D12Runtime) void {
        var i: usize = 0;
        while (i < self.pending_submit_batches.items.len) {
            if (self.pending_submit_batches.items[i].fence_value <= self.completed_fence_value) {
                var batch = self.pending_submit_batches.swapRemove(i);
                batch.deinit(self.allocator);
                continue;
            }
            i += 1;
        }
    }
};
