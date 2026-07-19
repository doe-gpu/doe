const common_timing = @import("../common/timing.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const webgpu = @import("../runtime_types.zig");

const c = @import("vk_constants.zig");
const vk_device = @import("vk_device.zig");
const vk_compute_sync = @import("vk_compute_sync.zig");
const vk_metrics = @import("vk_metrics.zig");
const vk_pipeline = @import("vk_pipeline.zig");
const vk_upload = @import("vk_upload.zig");
const vk_timing = @import("vulkan_timing.zig");

const VK_NULL_U64 = c.VK_NULL_U64;

pub fn run(
    self: anytype,
    x: u32,
    y: u32,
    z: u32,
    repeat_count: u32,
    repeat_synchronization: model_compute_types.KernelDispatchRepeatSynchronization,
    queue_wait_mode: webgpu.QueueWaitMode,
    gpu_timestamp_mode: webgpu.GpuTimestampMode,
) !vk_metrics.DispatchMetrics {
    if (repeat_count == 0) return error.InvalidArgument;
    if (repeat_count == 1) {
        return self.run_dispatch(x, y, z, .per_command, queue_wait_mode, gpu_timestamp_mode);
    }

    return run_batch(self, x, y, z, repeat_count, repeat_synchronization, gpu_timestamp_mode);
}

fn run_batch(
    self: anytype,
    x: u32,
    y: u32,
    z: u32,
    batch_count: u32,
    repeat_synchronization: model_compute_types.KernelDispatchRepeatSynchronization,
    gpu_timestamp_mode: webgpu.GpuTimestampMode,
) !vk_metrics.DispatchMetrics {
    if (batch_count == 0) return error.InvalidArgument;
    if (x == 0 or y == 0 or z == 0) return error.InvalidArgument;
    if (!self.has_pipeline) return error.Unsupported;
    if (self.streaming_copy_active) try self.flush_streaming_copy(true);
    if (self.has_deferred_submissions) _ = try self.flush_queue();
    try vk_device.ensure_submission_state(self);
    if (gpu_timestamp_mode != .off) {
        try vk_device.ensure_timestamp_query_pool(self);
    }

    const want_timestamps = gpu_timestamp_mode != .off and
        self.has_device and
        self.queue != null and
        self.queue_family_index_value_cache != null and
        self.timestamp_query_supported_value and
        self.timestamp_query_pool != VK_NULL_U64;

    const encode_start = common_timing.now_ns();
    self.deferred_command_buffer_index = 0;
    var command_buffer = self.primary_command_buffer;
    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try c.check_vk(c.vkBeginCommandBuffer(command_buffer, &begin_info));

    if (want_timestamps) {
        c.vkCmdResetQueryPool(command_buffer, self.timestamp_query_pool, 0, 2);
        c.vkCmdWriteTimestamp(command_buffer, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, self.timestamp_query_pool, 0);
    }
    vk_compute_sync.make_prior_transfer_writes_visible(self, command_buffer);
    vk_compute_sync.make_prior_compute_writes_visible_for_current_bindings(self, command_buffer);
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
    vk_pipeline.bind_descriptor_sets(self, command_buffer);
    const needs_inter_dispatch_barrier = repeat_synchronization == .dependent;
    var repeat_barrier: c.VkMemoryBarrier = undefined;
    if (needs_inter_dispatch_barrier) {
        repeat_barrier = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
        };
    }
    var dispatch_index: u32 = 0;
    while (dispatch_index < batch_count) : (dispatch_index += 1) {
        c.vkCmdDispatch(command_buffer, x, y, z);
        if (needs_inter_dispatch_barrier and dispatch_index != batch_count - 1) {
            c.vkCmdPipelineBarrier(
                command_buffer,
                c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                0,
                1,
                @ptrCast(&repeat_barrier),
                0,
                null,
                0,
                null,
            );
        }
    }
    if (want_timestamps) {
        c.vkCmdWriteTimestamp(command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, self.timestamp_query_pool, 1);
    }
    try c.check_vk(c.vkEndCommandBuffer(command_buffer));
    const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);

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
    try c.check_vk(c.vkResetFences(self.device, 1, @ptrCast(&self.fence)));
    try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), self.fence));
    try vk_upload.wait_for_fence_fast(self, self.fence);
    const submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_start);

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
            gpu_timestamp_ns = vk_timing.computeElapsedNs(results[0], results[1], self.timestamp_period);
            gpu_timestamp_valid = gpu_timestamp_ns > 0;
        }
        if (gpu_timestamp_mode == .require and !gpu_timestamp_valid) return error.TimingPolicyMismatch;
    } else if (gpu_timestamp_mode == .require) {
        return error.TimingPolicyMismatch;
    }

    vk_compute_sync.remember_current_compute_writes(self);
    return .{
        .encode_ns = encode_ns,
        .submit_wait_ns = submit_wait_ns,
        .submit_count = 1,
        .gpu_timestamp_ns = gpu_timestamp_ns,
        .gpu_timestamp_attempted = gpu_timestamp_attempted,
        .gpu_timestamp_valid = gpu_timestamp_valid,
    };
}
