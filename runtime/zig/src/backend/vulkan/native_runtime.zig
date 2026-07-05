// NativeVulkanRuntime: top-level struct and public API for the Doe Vulkan backend.

const std = @import("std");
const model_compute_types = @import("../../model_compute_types.zig");
const model_render_types = @import("../../model_render_types.zig");
const model_texture_types = @import("../../model_texture_types.zig");
const backend_policy = @import("../backend_policy.zig");
const common_timing = @import("../common/timing.zig");
const webgpu = @import("../runtime_types.zig");

const c = @import("vk_constants.zig");
const probe_ops = @import("vk_runtime_probe_ops.zig");
const vk_device = @import("vk_device.zig");
const vk_sync = @import("vk_sync.zig");
const vk_upload = @import("vk_upload.zig");
const vk_pipeline = @import("vk_pipeline.zig");
const vk_pipeline_cache_persistent = @import("vk_pipeline_cache_persistent.zig");
const vk_resources = @import("vk_resources.zig");
const vk_compute_sync = @import("vk_compute_sync.zig");
const vk_render = @import("vk_render.zig");
const vk_dispatch_repeat = @import("vk_dispatch_repeat.zig");
const vk_metrics = @import("vk_metrics.zig");
const vk_command_buffers = @import("vk_command_buffers.zig");
const surface_ops = @import("vk_runtime_surface_ops.zig");
const render_bundle = @import("../../render_bundle.zig");
const vk_texture_commands = @import("vk_texture_commands.zig");

const VK_NULL_U64 = c.VK_NULL_U64;

// Re-export public helpers used by mod.zig
pub const upload_uses_fast_path = vk_upload.upload_uses_fast_path;
pub const upload_uses_direct_path = vk_upload.upload_uses_direct_path;

pub const DispatchMetrics = vk_metrics.DispatchMetrics;
pub const AsyncProbeResult = probe_ops.AsyncProbeResult;

pub const NativeVulkanRuntime = struct {
    allocator: std.mem.Allocator,
    kernel_root: ?[]const u8,

    instance: c.VkInstance = null,
    physical_device: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    queue: c.VkQueue = null,

    adapter_ordinal_value: ?u32 = null,
    queue_family_index: u32 = 0,
    queue_family_index_value_cache: ?u32 = null,
    queue_family_policy: webgpu.QueueFamilyPolicy = .prefer_graphics_compute,
    deferred_submission_sync_policy: webgpu.DeferredSubmissionSyncPolicy = .prefer_timeline_semaphore,
    vulkan_subgroup_size_policy: backend_policy.VulkanSubgroupSizePolicy = .fixed_32_when_supported,
    queue_family_kind_value_cache: ?webgpu.QueueFamilyKind = null,
    required_compute_subgroup_size: u32 = 0,
    queue_family_queue_count_value_cache: ?u32 = null,
    queue_family_timestamp_valid_bits_value_cache: ?u32 = null,
    queue_family_supports_graphics_value_cache: ?bool = null,
    present_capable_value: ?bool = null,
    timestamp_query_supported_value: bool = false,
    timestamp_query_pool: c.VkQueryPool = VK_NULL_U64,
    timestamp_period: f32 = 1.0,
    command_pool: c.VkCommandPool = VK_NULL_U64,
    primary_command_buffer: c.VkCommandBuffer = null,
    fence: c.VkFence = VK_NULL_U64,
    fence_pool_state: vk_sync.FencePool = .{},
    timeline_semaphore: vk_sync.TimelineSemaphore = .{},
    timeline_semaphore_probe_done: bool = false,
    streaming_copy_buffer: c.VkCommandBuffer = null,
    streaming_copy_buffers: std.ArrayListUnmanaged(c.VkCommandBuffer) = .{},
    streaming_copy_pending_count: usize = 0,
    streaming_copy_active: bool = false,
    streaming_copy_count: u32 = 0,

    shader_module: c.VkShaderModule = VK_NULL_U64,
    pipeline_layout: c.VkPipelineLayout = VK_NULL_U64,
    pipeline: c.VkPipeline = VK_NULL_U64,
    descriptor_pool: c.VkDescriptorPool = VK_NULL_U64,
    descriptor_set_layouts: [c.MAX_DESCRIPTOR_SETS]c.VkDescriptorSetLayout = [_]c.VkDescriptorSetLayout{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS,
    descriptor_sets: [c.MAX_DESCRIPTOR_SETS]c.VkDescriptorSet = [_]c.VkDescriptorSet{VK_NULL_U64} ** c.MAX_DESCRIPTOR_SETS,
    descriptor_set_count: u32 = 0,
    current_pipeline_hash: u64 = 0,
    current_layout_hash: u64 = 0,
    current_descriptor_bindings_hash: u64 = 0,
    bound_compute_pipeline: c.VkPipeline = VK_NULL_U64,
    bound_compute_pipeline_layout: c.VkPipelineLayout = VK_NULL_U64,
    bound_descriptor_bindings_hash: u64 = 0,
    current_entry_point_owned: ?[:0]u8 = null,
    current_descriptor_state_cache: std.AutoHashMapUnmanaged(u64, vk_pipeline.CachedDescriptorState) = .{},
    hot_descriptor_state_hashes: [vk_pipeline.HOT_DESCRIPTOR_STATE_CACHE_CAPACITY]u64 = [_]u64{0} ** vk_pipeline.HOT_DESCRIPTOR_STATE_CACHE_CAPACITY,
    hot_descriptor_states: [vk_pipeline.HOT_DESCRIPTOR_STATE_CACHE_CAPACITY]vk_pipeline.CachedDescriptorState = undefined,
    retired_pipeline_states: std.ArrayListUnmanaged(vk_pipeline.RetiredPipelineState) = .{},
    retired_descriptor_states: std.ArrayListUnmanaged(vk_pipeline.RetiredDescriptorState) = .{},
    hot_compute_state_hashes: [vk_pipeline.HOT_COMPUTE_STATE_CACHE_CAPACITY]u64 = [_]u64{0} ** vk_pipeline.HOT_COMPUTE_STATE_CACHE_CAPACITY,
    hot_compute_states: [vk_pipeline.HOT_COMPUTE_STATE_CACHE_CAPACITY]vk_pipeline.CachedComputeState = undefined,
    cached_compute_states: std.AutoHashMapUnmanaged(u64, vk_pipeline.CachedComputeState) = .{},
    kernel_spirv_cache: std.StringHashMapUnmanaged([]const u32) = .{},
    fast_upload_buffer: c.VkBuffer = VK_NULL_U64,
    fast_upload_memory: c.VkDeviceMemory = VK_NULL_U64,
    fast_upload_capacity: u64 = 0,
    fast_upload_mapped: ?*anyopaque = null,
    buffer_write_staging_buffer: ?vk_resources.ComputeBuffer = null,
    buffer_write_staging_capacity: u64 = 0,
    buffer_write_staging_offset: u64 = 0,
    dispatch_indirect_args_buffer: ?vk_resources.ComputeBuffer = null,

    pending_uploads: std.ArrayListUnmanaged(vk_upload.PendingUpload) = .{},
    // Single-entry fast slot for the common case of one upload between flushes.
    // Avoids ArrayList append/iterate/clear overhead on the hot path.
    hot_pending_upload: ?vk_upload.PendingUpload = null,
    surfaces: std.AutoHashMapUnmanaged(u64, surface_ops.SurfaceState) = .{},

    src_pool: vk_upload.VkPool = .{},
    dst_pool: vk_upload.VkPool = .{},
    direct_upload_pool: vk_upload.VkPool = .{},
    hot_src_pool_entry: ?vk_upload.VkPoolEntry = null,
    hot_src_pool_size: u64 = 0,
    hot_dst_pool_entry: ?vk_upload.VkPoolEntry = null,
    hot_dst_pool_size: u64 = 0,
    compute_buffers: std.AutoHashMapUnmanaged(u64, vk_resources.ComputeBuffer) = .{},
    textures: std.AutoHashMapUnmanaged(u64, vk_resources.TextureResource) = .{},
    samplers: std.AutoHashMapUnmanaged(u64, c.VkSampler) = .{},

    has_instance: bool = false,
    has_device: bool = false,
    has_command_pool: bool = false,
    has_primary_command_buffer: bool = false,
    has_fence: bool = false,
    has_fence_pool: bool = false,
    has_timeline_semaphore: bool = false,
    has_shader_module: bool = false,
    has_pipeline_layout: bool = false,
    has_pipeline: bool = false,
    has_descriptor_pool: bool = false,
    has_current_descriptor_bindings_hash: bool = false,
    has_bound_descriptor_bindings_hash: bool = false,
    has_deferred_submissions: bool = false,
    has_depth_clip_enable_ext: bool = false,
    has_subgroup_size_control_ext: bool = false,
    has_pending_compute_writes: bool = false,
    has_pending_transfer_writes: bool = false,
    recorded_submit_replay_active: bool = false,
    pending_compute_write_tracking_complete: bool = true,
    pending_compute_write_buffer_handles: [vk_compute_sync.MAX_TRACKED_COMPUTE_BINDINGS]u64 = [_]u64{0} ** vk_compute_sync.MAX_TRACKED_COMPUTE_BINDINGS,
    pending_compute_write_buffer_count: u32 = 0,
    current_compute_bindings: [vk_compute_sync.MAX_TRACKED_COMPUTE_BINDINGS]vk_compute_sync.ComputeBindingAccess = [_]vk_compute_sync.ComputeBindingAccess{.{}} ** vk_compute_sync.MAX_TRACKED_COMPUTE_BINDINGS,
    current_compute_binding_count: u32 = 0,
    current_compute_binding_tracking_complete: bool = true,
    last_submit_count: ?u32 = null,
    replay_recording_active: bool = false,
    replay_command_buffer: c.VkCommandBuffer = null,
    replay_prefix_copy_buffer: c.VkCommandBuffer = null,
    replay_prefix_copy_pending: bool = false,
    upload_recording_active: bool = false,
    deferred_command_buffers: std.ArrayListUnmanaged(c.VkCommandBuffer) = .{},
    deferred_command_buffer_index: usize = 0,

    /// Last-compiled SPIR-V bytes awaiting shader-artifact-manifest emission.
    /// Allocator-owned. Transferred to the manifest emitter which writes a
    /// sibling .spv file for `shader_artifact_gate.py --require-spirv-validation`
    /// to validate with spirv-val, then frees the allocation.
    pending_spirv_bytes_owned: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, kernel_root: ?[]const u8) !NativeVulkanRuntime {
        return init_with_backend_policy(allocator, kernel_root, .prefer_graphics_compute, .prefer_timeline_semaphore, .fixed_32_when_supported);
    }

    pub fn init_with_backend_policy(
        allocator: std.mem.Allocator,
        kernel_root: ?[]const u8,
        queue_family_policy: webgpu.QueueFamilyPolicy,
        deferred_submission_sync_policy: webgpu.DeferredSubmissionSyncPolicy,
        vulkan_subgroup_size_policy: backend_policy.VulkanSubgroupSizePolicy,
    ) !NativeVulkanRuntime {
        var self = NativeVulkanRuntime{
            .allocator = allocator,
            .kernel_root = kernel_root,
            .queue_family_policy = queue_family_policy,
            .deferred_submission_sync_policy = deferred_submission_sync_policy,
            .vulkan_subgroup_size_policy = vulkan_subgroup_size_policy,
        };
        errdefer self.deinit();
        try vk_device.bootstrap(&self);
        return self;
    }

    pub fn deinit(self: *NativeVulkanRuntime) void {
        if (self.pending_spirv_bytes_owned) |bytes| {
            self.allocator.free(bytes);
            self.pending_spirv_bytes_owned = null;
        }
        _ = self.flush_queue() catch {};
        vk_pipeline.release_retired_states(self);
        vk_upload.release_pending_uploads(self);
        self.pending_uploads.deinit(self.allocator);
        self.retired_pipeline_states.deinit(self.allocator);
        self.retired_descriptor_states.deinit(self.allocator);
        self.streaming_copy_buffers.deinit(self.allocator);
        self.deferred_command_buffers.deinit(self.allocator);
        surface_ops.release_all_surfaces(self);
        vk_upload.release_pool_entry(self.device, self.hot_src_pool_entry);
        vk_upload.release_pool_entry(self.device, self.hot_dst_pool_entry);
        self.hot_src_pool_entry = null;
        self.hot_dst_pool_entry = null;
        vk_upload.vk_release_pool(&self.src_pool, self.allocator, self.device);
        vk_upload.vk_release_pool(&self.dst_pool, self.allocator, self.device);
        vk_upload.vk_release_pool(&self.direct_upload_pool, self.allocator, self.device);
        vk_upload.release_fast_upload_buffer(self);
        if (self.buffer_write_staging_buffer) |buffer| {
            vk_resources.destroy_host_visible_buffer(self, buffer);
            self.buffer_write_staging_buffer = null;
            self.buffer_write_staging_capacity = 0;
            self.buffer_write_staging_offset = 0;
        }
        if (self.dispatch_indirect_args_buffer) |buffer| {
            vk_resources.destroy_host_visible_buffer(self, buffer);
            self.dispatch_indirect_args_buffer = null;
        }
        vk_pipeline.release_cached_compute_states(self);
        vk_pipeline.release_descriptor_state_cache(self);
        vk_pipeline.release_kernel_spirv_cache(self);
        vk_pipeline.destroy_pipeline_objects(self);
        vk_pipeline.destroy_descriptor_state(self);
        vk_resources.release_compute_buffers(self);
        vk_resources.release_textures(self);
        vk_resources.release_samplers(self);
        if (self.has_timeline_semaphore) {
            self.timeline_semaphore.deinit(self.device);
            self.has_timeline_semaphore = false;
        }
        self.timeline_semaphore_probe_done = false;
        if (self.has_fence_pool) {
            self.fence_pool_state.deinit(self.device);
            self.has_fence_pool = false;
        }
        if (self.timestamp_query_pool != VK_NULL_U64) {
            c.vkDestroyQueryPool(self.device, self.timestamp_query_pool, null);
            self.timestamp_query_pool = VK_NULL_U64;
        }
        if (self.has_fence) {
            c.vkDestroyFence(self.device, self.fence, null);
            self.has_fence = false;
            self.fence = VK_NULL_U64;
        }
        if (self.has_command_pool) {
            c.vkDestroyCommandPool(self.device, self.command_pool, null);
            self.has_command_pool = false;
            self.has_primary_command_buffer = false;
            self.command_pool = VK_NULL_U64;
            self.primary_command_buffer = null;
        }
        if (self.has_device) {
            vk_pipeline_cache_persistent.destroy_process_pipeline_cache(self.device);
            c.vkDestroyDevice(self.device, null);
            self.has_device = false;
            self.device = null;
            self.queue = null;
        }
        if (self.has_instance) {
            c.vkDestroyInstance(self.instance, null);
            self.has_instance = false;
            self.instance = null;
            self.physical_device = null;
        }
    }

    // --- Kernel/shader API ---

    pub fn load_kernel_source(self: *const NativeVulkanRuntime, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u8 {
        return vk_pipeline.load_kernel_source(self, allocator, kernel_name);
    }

    pub fn load_kernel_spirv(self: *const NativeVulkanRuntime, allocator: std.mem.Allocator, kernel_name: []const u8) ![]u32 {
        return vk_pipeline.load_kernel_spirv(self, allocator, kernel_name);
    }

    pub fn load_kernel_spirv_cached(self: *NativeVulkanRuntime, kernel_name: []const u8) ![]const u32 {
        return vk_pipeline.ensure_kernel_spirv_cached(self, kernel_name);
    }

    pub fn ensure_kernel_spirv_cached(self: *NativeVulkanRuntime, kernel_name: []const u8) ![]const u32 {
        return vk_pipeline.ensure_kernel_spirv_cached(self, kernel_name);
    }

    pub fn set_compute_shader_spirv(
        self: *NativeVulkanRuntime,
        words: []const u32,
        entry_point: ?[]const u8,
        bindings: ?[]const model_compute_types.KernelBinding,
        initialize_buffers_on_create: bool,
    ) !void {
        return vk_pipeline.set_compute_shader_spirv(self, words, entry_point, bindings, initialize_buffers_on_create);
    }

    pub fn set_compute_shader_spirv_prehashed(
        self: *NativeVulkanRuntime,
        words: []const u32,
        spirv_hash: u64,
        entry_point: ?[]const u8,
        bindings: ?[]const model_compute_types.KernelBinding,
        initialize_buffers_on_create: bool,
    ) !void {
        return vk_pipeline.set_compute_shader_spirv_prehashed(self, words, spirv_hash, entry_point, bindings, initialize_buffers_on_create);
    }

    pub fn set_compute_shader_spirv_with_hashes(
        self: *NativeVulkanRuntime,
        words: []const u32,
        pipeline_hash: u64,
        layout_hash: u64,
        descriptor_bindings_hash: ?u64,
        entry_point: ?[]const u8,
        bindings: ?[]const model_compute_types.KernelBinding,
        initialize_buffers_on_create: bool,
    ) !void {
        return vk_pipeline.set_compute_shader_spirv_with_hashes(self, words, pipeline_hash, layout_hash, descriptor_bindings_hash, entry_point, bindings, initialize_buffers_on_create);
    }

    pub fn rebuild_compute_shader_spirv(self: *NativeVulkanRuntime, words: []const u32) !void {
        return vk_pipeline.rebuild_compute_shader_spirv(self, words);
    }

    // --- Upload API ---

    pub fn upload_bytes(
        self: *NativeVulkanRuntime,
        bytes: u64,
        mode: webgpu.UploadBufferUsageMode,
        upload_path_policy: backend_policy.UploadPathPolicy,
    ) !void {
        if (bytes == 0) return error.InvalidArgument;

        switch (vk_upload.classify_upload_path(upload_path_policy, mode, bytes)) {
            .fast_mapped => {
                try vk_upload.ensure_fast_upload_buffer(self, bytes);
                if (self.fast_upload_mapped) |raw| {
                    const fill_len = vk_upload.bounded_upload_fill_len(bytes);
                    @memset(@as([*]u8, @ptrCast(raw))[0..fill_len], 0);
                }
                return;
            },
            .direct_mapped => {
                if (try vk_upload.try_direct_upload(self, bytes, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT)) {
                    return;
                }
            },
            .staged_copy => {},
        }

        const dst_usage: u32 = switch (mode) {
            .copy_dst_copy_src => c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .copy_dst => c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        };

        const upload = try vk_upload.record_upload_copy(self, bytes, dst_usage);
        errdefer vk_upload.release_upload(self, upload);
        // Fast slot for the common single-upload-per-flush case: avoids
        // ArrayList append/iterate/clear overhead on the tiny-buffer hot path.
        if (self.hot_pending_upload == null and self.pending_uploads.items.len == 0) {
            self.hot_pending_upload = upload;
        } else {
            if (self.hot_pending_upload) |hot| {
                try self.pending_uploads.append(self.allocator, hot);
                self.hot_pending_upload = null;
            }
            try self.pending_uploads.append(self.allocator, upload);
        }
        self.has_deferred_submissions = true;
    }

    pub fn barrier(self: *NativeVulkanRuntime, queue_wait_mode: webgpu.QueueWaitMode) !u64 {
        const start_ns = common_timing.now_ns();
        switch (queue_wait_mode) {
            .process_events, .wait_any => {
                if (self.has_deferred_submissions or self.hot_pending_upload != null or self.pending_uploads.items.len > 0) {
                    _ = try self.flush_queue();
                }
            },
        }
        const end_ns = common_timing.now_ns();
        return common_timing.ns_delta(end_ns, start_ns);
    }

    // --- Dispatch ---

    pub fn run_dispatch(
        self: *NativeVulkanRuntime,
        x: u32,
        y: u32,
        z: u32,
        queue_sync_mode: webgpu.QueueSyncMode,
        queue_wait_mode: webgpu.QueueWaitMode,
        gpu_timestamp_mode: webgpu.GpuTimestampMode,
    ) !DispatchMetrics {
        if (x == 0 or y == 0 or z == 0) return error.InvalidArgument;
        if (!self.has_pipeline) return error.Unsupported;
        const replay_deferred = queue_sync_mode == .deferred and self.recorded_submit_replay_active;
        try vk_upload.flush_streaming_copy_before_dispatch(self, replay_deferred, queue_sync_mode);
        try vk_device.ensure_submission_state(self);
        if (gpu_timestamp_mode != .off and queue_sync_mode == .per_command) {
            try vk_device.ensure_timestamp_query_pool(self);
        }

        const want_timestamps = gpu_timestamp_mode != .off and
            queue_sync_mode == .per_command and
            self.timestamp_query_supported() and
            self.timestamp_query_pool != VK_NULL_U64;

        const encode_start = common_timing.now_ns();
        var command_buffer: c.VkCommandBuffer = null;

        if (queue_sync_mode == .per_command) {
            if (self.has_deferred_submissions) _ = try self.flush_queue();
            self.deferred_command_buffer_index = 0;
            command_buffer = self.primary_command_buffer;
        } else if (replay_deferred) {
            command_buffer = try vk_command_buffers.begin_recorded_submit_replay(self);
        } else {
            command_buffer = try vk_command_buffers.acquire_deferred_command_buffer(self);
        }
        if (!replay_deferred) {
            var begin_info = c.VkCommandBufferBeginInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                .pNext = null,
                .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
                .pInheritanceInfo = null,
            };
            try c.check_vk(c.vkBeginCommandBuffer(command_buffer, &begin_info));
            vk_pipeline.reset_bound_compute_state(self);
        }
        if (want_timestamps) {
            c.vkCmdResetQueryPool(command_buffer, self.timestamp_query_pool, 0, 2);
            c.vkCmdWriteTimestamp(command_buffer, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, self.timestamp_query_pool, 0);
        }
        vk_compute_sync.make_prior_transfer_writes_visible(self, command_buffer);
        vk_compute_sync.make_prior_compute_writes_visible_for_current_bindings(self, command_buffer);
        vk_pipeline.bind_compute_pipeline_if_needed(self, command_buffer);
        vk_pipeline.bind_descriptor_sets_if_needed(self, command_buffer);
        c.vkCmdDispatch(command_buffer, x, y, z);
        if (want_timestamps) {
            c.vkCmdWriteTimestamp(command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, self.timestamp_query_pool, 1);
        }
        if (!replay_deferred) {
            try c.check_vk(c.vkEndCommandBuffer(command_buffer));
        }

        const encode_end = common_timing.now_ns();
        const encode_ns = common_timing.ns_delta(encode_end, encode_start);
        if (replay_deferred) {
            vk_compute_sync.remember_current_compute_writes(self);
            return .{
                .encode_ns = encode_ns,
                .submit_wait_ns = 0,
                .submit_count = 0,
                .gpu_timestamp_ns = 0,
                .gpu_timestamp_attempted = false,
                .gpu_timestamp_valid = false,
            };
        }

        var submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast(&command_buffer),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };

        const submit_start = common_timing.now_ns();
        if (queue_sync_mode == .per_command) {
            _ = queue_wait_mode;
            try c.check_vk(c.vkResetFences(self.device, 1, @ptrCast(&self.fence)));
            try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), self.fence));
            try vk_upload.wait_for_fence_fast(self, self.fence);
        } else {
            try vk_device.ensure_deferred_submission_state(self);
            if (self.has_timeline_semaphore) {
                var tsi = vk_sync.TimelineSubmitHelper.prepare(&self.timeline_semaphore);
                tsi.patch();
                submit_info.pNext = @ptrCast(&tsi.timeline_info);
                submit_info.signalSemaphoreCount = 1;
                submit_info.pSignalSemaphores = @ptrCast(&tsi.semaphore);
                try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), VK_NULL_U64));
                self.has_deferred_submissions = true;
            } else {
                const deferred_fence = if (self.has_fence_pool)
                    try self.fence_pool_state.acquire(self.device)
                else
                    VK_NULL_U64;
                try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), deferred_fence));
                self.has_deferred_submissions = true;
            }
        }
        const submit_end = common_timing.now_ns();

        var gpu_timestamp_ns: u64 = 0;
        var gpu_timestamp_attempted = false;
        var gpu_timestamp_valid = false;
        if (want_timestamps) {
            gpu_timestamp_attempted = true;
            var results: [2]u64 = .{ 0, 0 };
            try c.check_vk(c.vkGetQueryPoolResults(
                self.device,
                self.timestamp_query_pool,
                0,
                2,
                @sizeOf(@TypeOf(results)),
                &results,
                @sizeOf(u64),
                c.VK_QUERY_RESULT_64_BIT | c.VK_QUERY_RESULT_WAIT_BIT,
            ));
            if (results[1] > results[0]) {
                const vk_timing = @import("vulkan_timing.zig");
                gpu_timestamp_ns = vk_timing.computeElapsedNs(results[0], results[1], self.timestamp_period);
                gpu_timestamp_valid = gpu_timestamp_ns > 0;
            }
            if (gpu_timestamp_mode == .require and !gpu_timestamp_valid) return error.TimingPolicyMismatch;
        } else if (gpu_timestamp_mode != .off) {
            if (queue_sync_mode != .per_command and gpu_timestamp_mode == .require) return error.TimingPolicyMismatch;
            if (queue_sync_mode == .per_command and gpu_timestamp_mode == .require) return error.TimingPolicyMismatch;
        }
        vk_compute_sync.remember_current_compute_writes(self);
        return .{
            .encode_ns = encode_ns,
            .submit_wait_ns = common_timing.ns_delta(submit_end, submit_start),
            .submit_count = 1,
            .gpu_timestamp_ns = gpu_timestamp_ns,
            .gpu_timestamp_attempted = gpu_timestamp_attempted,
            .gpu_timestamp_valid = gpu_timestamp_valid,
        };
    }

    pub fn record_prepared_dispatch_replay(
        self: *NativeVulkanRuntime,
        x: u32,
        y: u32,
        z: u32,
    ) !void {
        const command_buffer = try self.begin_prepared_dispatch_replay();
        try self.record_prepared_dispatch_replay_on(command_buffer, x, y, z);
    }

    pub fn begin_prepared_dispatch_replay(self: *NativeVulkanRuntime) !c.VkCommandBuffer {
        if (!self.recorded_submit_replay_active) return error.InvalidState;
        if (self.replay_recording_active) return self.replay_command_buffer;
        try vk_upload.flush_streaming_copy_before_dispatch(self, true, .deferred);
        try vk_device.ensure_submission_state(self);
        return vk_command_buffers.begin_recorded_submit_replay(self);
    }

    pub fn record_prepared_dispatch_replay_on(
        self: *NativeVulkanRuntime,
        command_buffer: c.VkCommandBuffer,
        x: u32,
        y: u32,
        z: u32,
    ) !void {
        if (x == 0 or y == 0 or z == 0) return error.InvalidArgument;
        if (!self.has_pipeline) return error.Unsupported;
        if (command_buffer == null) return error.InvalidState;
        vk_compute_sync.make_prior_transfer_writes_visible(self, command_buffer);
        vk_compute_sync.make_prior_compute_writes_visible_for_current_bindings(self, command_buffer);
        vk_pipeline.bind_compute_pipeline_if_needed(self, command_buffer);
        vk_pipeline.bind_descriptor_sets_if_needed(self, command_buffer);
        c.vkCmdDispatch(command_buffer, x, y, z);
        vk_compute_sync.remember_current_compute_writes(self);
    }

    pub fn run_dispatch_repeat(
        self: *NativeVulkanRuntime,
        x: u32,
        y: u32,
        z: u32,
        repeat_count: u32,
        repeat_synchronization: model_compute_types.KernelDispatchRepeatSynchronization,
        queue_wait_mode: webgpu.QueueWaitMode,
        gpu_timestamp_mode: webgpu.GpuTimestampMode,
    ) !DispatchMetrics {
        return vk_dispatch_repeat.run(self, x, y, z, repeat_count, repeat_synchronization, queue_wait_mode, gpu_timestamp_mode);
    }

    pub fn run_dispatch_indirect(
        self: *NativeVulkanRuntime,
        x: u32,
        y: u32,
        z: u32,
        queue_sync_mode: webgpu.QueueSyncMode,
        queue_wait_mode: webgpu.QueueWaitMode,
    ) !DispatchMetrics {
        if (x == 0 or y == 0 or z == 0) return error.InvalidArgument;
        if (!self.has_pipeline) return error.Unsupported;
        const replay_deferred = queue_sync_mode == .deferred and self.recorded_submit_replay_active;
        try vk_upload.flush_streaming_copy_before_dispatch(self, replay_deferred, queue_sync_mode);
        try vk_device.ensure_submission_state(self);

        const indirect_args = try vk_command_buffers.ensure_dispatch_indirect_args_buffer(self);
        const encode_start = common_timing.now_ns();
        try vk_command_buffers.write_dispatch_indirect_args(indirect_args, x, y, z);

        var command_buffer: c.VkCommandBuffer = null;
        if (queue_sync_mode == .per_command) {
            if (self.has_deferred_submissions) _ = try self.flush_queue();
            self.deferred_command_buffer_index = 0;
            command_buffer = self.primary_command_buffer;
        } else if (replay_deferred) {
            command_buffer = try vk_command_buffers.begin_recorded_submit_replay(self);
        } else {
            command_buffer = try vk_command_buffers.acquire_deferred_command_buffer(self);
        }
        if (!replay_deferred) {
            var begin_info = c.VkCommandBufferBeginInfo{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                .pNext = null,
                .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
                .pInheritanceInfo = null,
            };
            try c.check_vk(c.vkBeginCommandBuffer(command_buffer, &begin_info));
            vk_pipeline.reset_bound_compute_state(self);
        }
        vk_compute_sync.make_prior_transfer_writes_visible(self, command_buffer);
        vk_compute_sync.make_prior_compute_writes_visible_for_current_bindings(self, command_buffer);
        vk_pipeline.bind_compute_pipeline_if_needed(self, command_buffer);
        vk_pipeline.bind_descriptor_sets_if_needed(self, command_buffer);
        c.vkCmdDispatchIndirect(command_buffer, indirect_args.buffer, 0);
        if (!replay_deferred) {
            try c.check_vk(c.vkEndCommandBuffer(command_buffer));
        }

        const encode_end = common_timing.now_ns();
        const encode_ns = common_timing.ns_delta(encode_end, encode_start);
        if (replay_deferred) {
            vk_compute_sync.remember_current_compute_writes(self);
            return .{
                .encode_ns = encode_ns,
                .submit_wait_ns = 0,
                .submit_count = 0,
                .gpu_timestamp_ns = 0,
                .gpu_timestamp_attempted = false,
                .gpu_timestamp_valid = false,
            };
        }

        var submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast(&command_buffer),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };

        const submit_start = common_timing.now_ns();
        if (queue_sync_mode == .per_command) {
            _ = queue_wait_mode;
            try c.check_vk(c.vkResetFences(self.device, 1, @ptrCast(&self.fence)));
            try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), self.fence));
            try vk_upload.wait_for_fence_fast(self, self.fence);
        } else {
            try vk_device.ensure_deferred_submission_state(self);
            if (self.has_timeline_semaphore) {
                var tsi = vk_sync.TimelineSubmitHelper.prepare(&self.timeline_semaphore);
                tsi.patch();
                submit_info.pNext = @ptrCast(&tsi.timeline_info);
                submit_info.signalSemaphoreCount = 1;
                submit_info.pSignalSemaphores = @ptrCast(&tsi.semaphore);
                try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), VK_NULL_U64));
                self.has_deferred_submissions = true;
            } else {
                const deferred_fence = if (self.has_fence_pool)
                    try self.fence_pool_state.acquire(self.device)
                else
                    VK_NULL_U64;
                try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), deferred_fence));
                self.has_deferred_submissions = true;
            }
        }
        const submit_end = common_timing.now_ns();

        vk_compute_sync.remember_current_compute_writes(self);
        return .{
            .encode_ns = encode_ns,
            .submit_wait_ns = common_timing.ns_delta(submit_end, submit_start),
            .submit_count = 1,
            .gpu_timestamp_ns = 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    }

    // --- Render ---

    pub fn run_render_draw(self: *NativeVulkanRuntime, cmd: model_render_types.RenderDrawCommand) !DispatchMetrics {
        return vk_render.execute_render_draw(self, cmd);
    }

    pub fn run_render_clear(self: *NativeVulkanRuntime, cmd: model_render_types.RenderDrawCommand) !DispatchMetrics {
        return vk_render.execute_render_clear(self, cmd);
    }

    pub fn run_execute_bundles(
        self: *NativeVulkanRuntime,
        bundles: []const *const render_bundle.DoeRenderBundle,
        target_width: u32,
        target_height: u32,
        color_format: u32,
        sample_count: u32,
    ) !DispatchMetrics {
        return vk_render.execute_render_bundles(self, bundles, target_width, target_height, color_format, sample_count);
    }

    // --- Queue management ---

    pub fn flush_queue(self: *NativeVulkanRuntime) !u64 {
        if (self.streaming_copy_active) {
            try self.flush_streaming_copy(true);
        }
        const waited_ns = try vk_upload.flush_queue(self);
        const cleanup_start = common_timing.now_ns();
        vk_pipeline.release_retired_states(self);
        vk_upload.mark_streaming_copy_submissions_drained(self);
        if (!self.streaming_copy_active and self.deferred_command_buffer_index > 0) {
            // Deferred command buffers are implicitly reset by vkBeginCommandBuffer.
            self.deferred_command_buffer_index = 0;
        }
        return waited_ns +| common_timing.ns_delta(common_timing.now_ns(), cleanup_start);
    }

    pub fn has_pending_compute_write_for_buffer(self: *const NativeVulkanRuntime, resource_handle: u64) bool {
        return vk_compute_sync.pending_compute_write_buffer_contains(self, resource_handle);
    }

    pub fn make_compute_writes_visible_for_capture(
        self: *NativeVulkanRuntime,
        memory_kind: vk_resources.ComputeBufferMemoryKind,
    ) !void {
        if (!self.has_pending_compute_writes) return;
        if (self.streaming_copy_active or self.has_deferred_submissions or self.hot_pending_upload != null or self.pending_uploads.items.len > 0) {
            _ = try self.flush_queue();
        }
        try vk_device.ensure_submission_state(self);
        try c.check_vk(c.vkResetCommandPool(self.device, self.command_pool, 0));

        var begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try c.check_vk(c.vkBeginCommandBuffer(self.primary_command_buffer, &begin_info));

        const dst_access_mask: u32 = switch (memory_kind) {
            .host_visible => c.VK_ACCESS_HOST_READ_BIT,
            .device_local => c.VK_ACCESS_TRANSFER_READ_BIT,
        };
        const dst_stage_mask: u32 = switch (memory_kind) {
            .host_visible => c.VK_PIPELINE_STAGE_HOST_BIT,
            .device_local => c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        };
        const visibility_barrier = c.VkMemoryBarrier{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = dst_access_mask,
        };
        c.vkCmdPipelineBarrier(
            self.primary_command_buffer,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            dst_stage_mask,
            0,
            1,
            @ptrCast(&visibility_barrier),
            0,
            null,
            0,
            null,
        );
        try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));

        var submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast(&self.primary_command_buffer),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        try c.check_vk(c.vkResetFences(self.device, 1, @ptrCast(&self.fence)));
        try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), self.fence));
        try vk_upload.wait_for_fence_fast(self, self.fence);
        vk_compute_sync.clear_pending_compute_writes(self);
    }

    // --- Streaming copy API ---

    pub fn begin_streaming_copy(self: *NativeVulkanRuntime) !void {
        return vk_upload.begin_streaming_copy(self);
    }

    pub fn streaming_copy_buffer_to_buffer(self: *NativeVulkanRuntime, src: c.VkBuffer, dst: c.VkBuffer, size: u64) !void {
        return vk_upload.streaming_copy_buffer_to_buffer(self, src, dst, size);
    }

    pub fn flush_streaming_copy(self: *NativeVulkanRuntime, wait: bool) !void {
        try vk_upload.flush_streaming_copy(self, wait);
        if (wait) {
            self.buffer_write_staging_offset = 0;
        }
    }

    pub fn submit_recorded_replay(self: *NativeVulkanRuntime) !void {
        return vk_upload.submit_recorded_replay(self);
    }

    pub fn submit_recorded_replay_timed(self: *NativeVulkanRuntime) !vk_upload.RecordedReplaySubmitTimings {
        return vk_upload.submit_recorded_replay_timed(self);
    }

    /// Query whether the timeline semaphore extension is available.
    pub fn timeline_semaphore_available(self: *const NativeVulkanRuntime) bool {
        return self.has_timeline_semaphore;
    }

    pub fn prewarm_upload_path(
        self: *NativeVulkanRuntime,
        max_upload_bytes: u64,
        mode: webgpu.UploadBufferUsageMode,
        upload_path_policy: backend_policy.UploadPathPolicy,
    ) !void {
        if (max_upload_bytes == 0) return;
        const prewarm_bytes = if (vk_upload.MAX_UPLOAD_BYTES == 0)
            max_upload_bytes
        else
            @min(max_upload_bytes, vk_upload.MAX_UPLOAD_BYTES);
        switch (vk_upload.classify_upload_path(upload_path_policy, mode, prewarm_bytes)) {
            .fast_mapped => {
                try vk_upload.ensure_fast_upload_buffer(self, prewarm_bytes);
                if (self.fast_upload_mapped) |raw| {
                    const fill_len = vk_upload.bounded_upload_fill_len(prewarm_bytes);
                    @memset(@as([*]u8, @ptrCast(raw))[0..fill_len], 0);
                }
                return;
            },
            .direct_mapped => {
                const dst_usage: u32 = switch (mode) {
                    .copy_dst_copy_src => c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                    .copy_dst => c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                };
                if (try vk_upload.try_direct_upload(self, prewarm_bytes, dst_usage)) {
                    return;
                }
            },
            .staged_copy => {
                const dst_usage: u32 = switch (mode) {
                    .copy_dst_copy_src => c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                    .copy_dst => c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                };
                try vk_upload.prewarm_staged_upload_pool(self, prewarm_bytes, dst_usage);
                return;
            },
        }
    }

    pub fn prewarm_execution_bootstrap(
        self: *NativeVulkanRuntime,
        gpu_timestamp_mode: webgpu.GpuTimestampMode,
    ) !void {
        try vk_device.ensure_submission_state(self);
        if (gpu_timestamp_mode != .off) {
            try vk_device.ensure_timestamp_query_pool(self);
        }
    }

    // --- Async diagnostics probes ---

    pub fn lifecycle_probe(self: *NativeVulkanRuntime, iterations: u32) !u64 {
        return probe_ops.lifecycle_probe(self, iterations);
    }

    pub fn pipeline_async_probe(self: *NativeVulkanRuntime, allocator: std.mem.Allocator, kernel_name: []const u8, iterations: u32) !u64 {
        return probe_ops.pipeline_async_probe(self, allocator, kernel_name, iterations);
    }

    pub fn resource_table_immediates_emulation_probe(
        self: *NativeVulkanRuntime,
        iterations: u32,
        upload_path_policy: backend_policy.UploadPathPolicy,
    ) !u64 {
        return probe_ops.resource_table_immediates_emulation_probe(self, iterations, upload_path_policy);
    }

    pub fn pixel_local_storage_emulation_probe(
        self: *NativeVulkanRuntime,
        iterations: u32,
        upload_path_policy: backend_policy.UploadPathPolicy,
    ) !u64 {
        return probe_ops.pixel_local_storage_emulation_probe(self, iterations, upload_path_policy);
    }

    pub fn resource_table_immediates_probe(
        self: *NativeVulkanRuntime,
        iterations: u32,
    ) !AsyncProbeResult {
        return probe_ops.resource_table_immediates_probe(self, iterations);
    }

    pub fn pixel_local_storage_probe(
        self: *NativeVulkanRuntime,
        iterations: u32,
        target_format: probe_ops.WGPUTextureFormat,
    ) !AsyncProbeResult {
        return probe_ops.pixel_local_storage_probe(self, iterations, target_format);
    }

    // --- Texture commands (delegated to vk_texture_commands.zig) ---

    pub fn texture_write(self: *NativeVulkanRuntime, cmd_arg: model_texture_types.TextureWriteCommand) !void {
        return vk_texture_commands.texture_write(self, cmd_arg);
    }
    pub fn texture_read(self: *NativeVulkanRuntime, args: anytype) !void {
        return vk_texture_commands.texture_read(self, .{ .handle = args.handle, .mip_level = args.mip_level, .width = args.width, .height = args.height, .format = args.format, .dst_buffer = args.dst_buffer, .dst_offset = args.dst_offset, .dst_bytes_per_row = args.dst_bytes_per_row, .dst_rows_per_image = args.dst_rows_per_image });
    }
    pub fn texture_copy(self: *NativeVulkanRuntime, args: anytype) !void {
        return vk_texture_commands.texture_copy(self, .{ .src_handle = args.src_handle, .src_mip = args.src_mip, .src_x = args.src_x, .src_y = args.src_y, .src_z = args.src_z, .dst_handle = args.dst_handle, .dst_mip = args.dst_mip, .dst_x = args.dst_x, .dst_y = args.dst_y, .dst_z = args.dst_z, .width = args.width, .height = args.height, .depth_or_layers = args.depth_or_layers });
    }
    pub fn texture_query(self: *NativeVulkanRuntime, cmd_arg: model_texture_types.TextureQueryCommand) !void {
        return vk_texture_commands.texture_query(self, cmd_arg);
    }
    pub fn texture_destroy(self: *NativeVulkanRuntime, cmd_arg: model_texture_types.TextureDestroyCommand) !void {
        return vk_texture_commands.texture_destroy(self, cmd_arg);
    }
    pub fn sampler_create(self: *NativeVulkanRuntime, cmd: model_render_types.SamplerCreateCommand) !void {
        return vk_texture_commands.sampler_create(self, cmd);
    }
    pub fn sampler_destroy(self: *NativeVulkanRuntime, cmd: model_render_types.SamplerDestroyCommand) !void {
        return vk_texture_commands.sampler_destroy(self, cmd);
    }

    // --- Surface lifecycle ---

    pub fn create_surface(self: *NativeVulkanRuntime, handle: u64) !void {
        return surface_ops.create_surface(self, handle);
    }

    pub fn get_surface_capabilities(self: *NativeVulkanRuntime, handle: u64) !void {
        return surface_ops.get_surface_capabilities(self, handle);
    }

    pub fn preferred_canvas_format(self: *NativeVulkanRuntime) surface_ops.WGPUTextureFormat {
        return surface_ops.preferred_canvas_format(self);
    }

    pub fn configure_surface(self: *NativeVulkanRuntime, cmd_arg: surface_ops.SurfaceConfigureCommand) !void {
        return surface_ops.configure_surface(self, cmd_arg);
    }

    pub fn acquire_surface(self: *NativeVulkanRuntime, handle: u64) !void {
        return surface_ops.acquire_surface(self, handle);
    }

    pub fn present_surface(self: *NativeVulkanRuntime, handle: u64) !void {
        return surface_ops.present_surface(self, handle);
    }

    pub fn unconfigure_surface(self: *NativeVulkanRuntime, handle: u64) !void {
        return surface_ops.unconfigure_surface(self, handle);
    }

    pub fn release_surface(self: *NativeVulkanRuntime, handle: u64) !void {
        return surface_ops.release_surface(self, handle);
    }

    // --- Internal ---

    fn timestamp_query_supported(self: *const NativeVulkanRuntime) bool {
        if (!self.has_device or self.queue == null) return false;
        return self.queue_family_index_value_cache != null and self.timestamp_query_supported_value;
    }
};
