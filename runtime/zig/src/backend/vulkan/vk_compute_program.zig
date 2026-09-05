const std = @import("std");
const c = @import("vk_constants.zig");
const Runtime = @import("native_runtime.zig").NativeVulkanRuntime;
const cache = @import("vk_pipeline_cache.zig");
const pipeline = @import("vk_pipeline.zig");
const upload = @import("vk_upload.zig");
const device = @import("vk_device.zig");

// Prepared programs own their descriptor pools and pipelines. Ordinary cache
// replacement cannot invalidate a command buffer retained by a program.
const ComputeCache = struct {
    active: cache.CachedComputeState = .{},
    hashes: [cache.HOT_COMPUTE_STATE_CACHE_CAPACITY]u64 = [_]u64{0} ** cache.HOT_COMPUTE_STATE_CACHE_CAPACITY,
    states: [cache.HOT_COMPUTE_STATE_CACHE_CAPACITY]cache.CachedComputeState = undefined,
    remaining: std.AutoHashMapUnmanaged(u64, cache.CachedComputeState) = .{},

    fn take(rt: *Runtime) ComputeCache {
        const result = ComputeCache{
            .active = cache.capture_active_compute_state(rt),
            .hashes = rt.hot_compute_state_hashes,
            .states = rt.hot_compute_states,
            .remaining = rt.cached_compute_states,
        };
        cache.clear_active_compute_state(rt);
        rt.hot_compute_state_hashes = [_]u64{0} ** cache.HOT_COMPUTE_STATE_CACHE_CAPACITY;
        rt.hot_compute_states = undefined;
        rt.cached_compute_states = .{};
        return result;
    }

    fn restore(self: *ComputeCache, rt: *Runtime) void {
        cache.restore_active_compute_state(rt, self.active);
        rt.hot_compute_state_hashes = self.hashes;
        rt.hot_compute_states = self.states;
        rt.cached_compute_states = self.remaining;
        self.* = .{};
        pipeline.reset_bound_compute_state(rt);
    }

    fn deinit(self: *ComputeCache, rt: *Runtime) void {
        cache.destroy_cached_compute_state(rt, self.active);
        for (self.hashes, 0..) |hash, index| {
            if (hash != 0) cache.destroy_cached_compute_state(rt, self.states[index]);
        }
        var values = self.remaining.valueIterator();
        while (values.next()) |state| cache.destroy_cached_compute_state(rt, state.*);
        self.remaining.deinit(rt.allocator);
        self.* = .{};
    }
};

pub const ComputeProgram = struct {
    command_pool: c.VkCommandPool = c.VK_NULL_U64,
    command_buffer: c.VkCommandBuffer = null,
    previous: ComputeCache = .{},
    owned: ComputeCache = .{},
    capturing: bool = false,
    ready: bool = false,
    submitted: bool = false,

    pub fn begin(self: *ComputeProgram, rt: *Runtime) !void {
        _ = try rt.flush_queue();
        try upload.flush_streaming_copy_before_dispatch(rt, false, .per_command);
        try device.ensure_submission_state(rt);
        var pool_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = rt.queue_family_index,
        };
        try c.check_vk(c.vkCreateCommandPool(rt.device, &pool_info, null, &self.command_pool));
        var allocation = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        try c.check_vk(c.vkAllocateCommandBuffers(rt.device, &allocation, @ptrCast(&self.command_buffer)));
        var info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        try c.check_vk(c.vkBeginCommandBuffer(self.command_buffer, &info));
        self.previous = ComputeCache.take(rt);
        self.capturing = true;
        rt.recorded_submit_replay_active = true;
        rt.replay_recording_active = true;
        rt.replay_command_buffer = self.command_buffer;
        pipeline.reset_bound_compute_state(rt);
        barrier(self.command_buffer);
    }

    pub fn finish(self: *ComputeProgram, rt: *Runtime) !void {
        if (!self.capturing) return error.InvalidState;
        barrier(self.command_buffer);
        try c.check_vk(c.vkEndCommandBuffer(self.command_buffer));
        self.restore(rt);
        self.ready = true;
    }

    fn restore(self: *ComputeProgram, rt: *Runtime) void {
        self.owned = ComputeCache.take(rt);
        self.previous.restore(rt);
        rt.recorded_submit_replay_active = false;
        rt.replay_recording_active = false;
        rt.replay_command_buffer = null;
        self.capturing = false;
    }

    pub fn submit(self: *ComputeProgram, rt: *Runtime) !void {
        if (!self.ready) return error.InvalidState;
        if (self.submitted and rt.has_deferred_submissions) _ = try rt.flush_queue();
        if (rt.replay_recording_active) try rt.submit_recorded_replay();
        if (rt.hot_pending_upload != null or rt.pending_uploads.items.len != 0) _ = try rt.flush_queue();
        try upload.flush_streaming_copy_before_dispatch(rt, true, .deferred);
        _ = try upload.submit_replay_command_buffer(rt, self.command_buffer);
        self.submitted = true;
    }

    pub fn deinit(self: *ComputeProgram, rt: *Runtime) void {
        if (self.capturing) self.restore(rt);
        if (self.submitted) _ = rt.flush_queue() catch 0;
        if (self.command_pool != c.VK_NULL_U64) c.vkDestroyCommandPool(rt.device, self.command_pool, null);
        self.owned.deinit(rt);
        self.* = .{};
    }
};

fn barrier(command_buffer: c.VkCommandBuffer) void {
    const dependency = c.VkMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT |
            c.VK_ACCESS_TRANSFER_READ_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT | c.VK_ACCESS_HOST_READ_BIT,
    };
    c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | c.VK_PIPELINE_STAGE_HOST_BIT, 0, 1, @ptrCast(&dependency), 0, null, 0, null);
}
