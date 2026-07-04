// doe_query_native.zig — QuerySet (GPU timestamp query) support for Doe Metal and Vulkan backends.
//
// Metal: Uses MTLCounterSampleBuffer for GPU timeline timestamps.
// Vulkan: Uses VkQueryPool with VK_QUERY_TYPE_TIMESTAMP.
//
// Timestamps are sampled at command recording time and resolved to a
// destination buffer after GPU completion.

const std = @import("std");
const builtin = @import("builtin");
const has_vulkan = (builtin.os.tag == .linux);
const resource_ops = @import("backend/dropin_resource_ops.zig");
const native_types = @import("doe_native_object_types.zig");
const native_shared = @import("doe_native_shared_types.zig");
const native_cmds = @import("doe_native_command_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const native_rt_helpers = @import("doe_native_runtime_helpers.zig");
const vulkan_lifetime = @import("doe_vulkan_lifetime.zig");
const bridge = resource_ops.metal_bridge;
const c = if (has_vulkan) resource_ops.vk_constants else struct {
    // Minimal type stubs so DoeQuerySet struct fields compile on non-Linux.
    pub const VkQueryPool = u64;
    pub const VkDevice = ?*anyopaque;
    pub const VK_NULL_U64: u64 = 0;
};

const MAGIC_QUERY_SET: u32 = 0xD0E1_0020;
const TIMESTAMP_BYTES: usize = @sizeOf(u64);
const WGPU_QUERY_TYPE_OCCLUSION: u32 = 0x00000001;
const WGPU_QUERY_TYPE_TIMESTAMP: u32 = 0x00000002;
const VK_QUERY_TYPE_OCCLUSION: u32 = 1;

pub const DoeQuerySet = struct {
    pub const TYPE_MAGIC = MAGIC_QUERY_SET;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    count: u32 = 0,
    query_type: u32 = WGPU_QUERY_TYPE_TIMESTAMP,
    backend: native_shared.BackendKind = .metal,
    /// Metal: opaque handle to MTLCounterSampleBuffer for GPU timestamp sampling.
    counter_sample_buffer: ?*anyopaque = null,
    /// Vulkan: VkQueryPool handle for timestamp queries.
    vk_query_pool: c.VkQueryPool = c.VK_NULL_U64,
    /// Vulkan: VkDevice reference needed for pool destruction and result retrieval.
    vk_device: c.VkDevice = null,
    /// Vulkan: back-reference to NativeVulkanRuntime for command buffer access.
    vk_runtime_ref: ?*anyopaque = null,
};

fn vulkanTimestampStage(position: native_cmds.TimestampWritePosition) u32 {
    return switch (position) {
        .pass_begin => c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        .pass_end => c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        .command => c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
    };
}

// ============================================================
// createQuerySet
// ============================================================

pub export fn doeNativeDeviceCreateQuerySet(
    dev_raw: ?*anyopaque,
    query_type: u32,
    count: u32,
) callconv(.c) ?*anyopaque {
    if (query_type != WGPU_QUERY_TYPE_TIMESTAMP and query_type != WGPU_QUERY_TYPE_OCCLUSION) return null;
    if (count == 0) return null;

    const dev = native_helpers.cast(native_types.DoeDevice, dev_raw) orelse return null;

    if (comptime has_vulkan) {
        if (dev.backend == .vulkan) {
            return vulkan_create_query_set(dev, query_type, count);
        }
    }

    if (query_type != WGPU_QUERY_TYPE_TIMESTAMP) {
        return null;
    }

    // Metal path.
    const qs = native_helpers.make(DoeQuerySet) orelse return null;
    qs.* = .{ .count = count, .query_type = query_type, .backend = .metal };

    qs.counter_sample_buffer = bridge.metal_bridge_create_counter_sample_buffer(dev.mtl_device, count);
    if (qs.counter_sample_buffer == null) {
        native_helpers.alloc.destroy(qs);
        return null;
    }

    return native_helpers.toOpaque(qs);
}

// ============================================================
// writeTimestamp
// ============================================================

pub export fn doeNativeCommandEncoderWriteTimestamp(
    enc_raw: ?*anyopaque,
    qs_raw: ?*anyopaque,
    query_index: u32,
) callconv(.c) void {
    doeNativeCommandEncoderWriteTimestampWithPosition(enc_raw, qs_raw, query_index, .command);
}

pub fn doeNativeCommandEncoderWriteTimestampWithPosition(
    enc_raw: ?*anyopaque,
    qs_raw: ?*anyopaque,
    query_index: u32,
    position: native_cmds.TimestampWritePosition,
) void {
    const enc = native_helpers.cast(native_types.DoeCommandEncoder, enc_raw) orelse return;
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return;
    if (query_index >= qs.count) return;

    if (comptime has_vulkan) {
        if (qs.backend == .vulkan) {
            enc.cmds.append(native_helpers.alloc, .{ .write_timestamp = .{
                .counter_buffer = null,
                .query_set = qs_raw,
                .query_index = query_index,
                .position = position,
            } }) catch std.debug.panic("doe_query_native: OOM recording vulkan write_timestamp", .{});
            return;
        }
    }

    // Metal: record for deferred execution at submit.
    enc.cmds.append(native_helpers.alloc, .{ .write_timestamp = .{
        .counter_buffer = qs.counter_sample_buffer,
        .query_set = qs_raw,
        .query_index = query_index,
        .position = position,
    } }) catch std.debug.panic("doe_query_native: OOM recording write_timestamp", .{});
}

// ============================================================
// resolveQuerySet
// ============================================================

pub export fn doeNativeCommandEncoderResolveQuerySet(
    enc_raw: ?*anyopaque,
    qs_raw: ?*anyopaque,
    first_query: u32,
    query_count: u32,
    dst_raw: ?*anyopaque,
    dst_offset: u64,
) callconv(.c) void {
    const enc = native_helpers.cast(native_types.DoeCommandEncoder, enc_raw) orelse return;
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return;
    const dst = native_helpers.cast(native_types.DoeBuffer, dst_raw) orelse return;
    if (dst.error_object) return;

    if (first_query + query_count > qs.count) return;

    const copy_bytes = @as(usize, query_count) * TIMESTAMP_BYTES;
    const d_off: usize = @intCast(dst_offset);
    if (d_off + copy_bytes > @as(usize, @intCast(dst.size))) return;

    if (comptime has_vulkan) {
        if (qs.backend == .vulkan) {
            enc.cmds.append(native_helpers.alloc, .{ .resolve_query_set = .{
                .counter_buffer = null,
                .query_set = qs_raw,
                .first_query = first_query,
                .query_count = query_count,
                .dst_mtl = null,
                .dst_buffer = dst_raw,
                .dst_offset = dst_offset,
            } }) catch std.debug.panic("doe_query_native: OOM recording vulkan resolve_query_set", .{});
            return;
        }
    }

    // Metal: record for deferred execution at submit.
    enc.cmds.append(native_helpers.alloc, .{ .resolve_query_set = .{
        .counter_buffer = qs.counter_sample_buffer,
        .query_set = qs_raw,
        .first_query = first_query,
        .query_count = query_count,
        .dst_mtl = dst.mtl,
        .dst_buffer = dst_raw,
        .dst_offset = dst_offset,
    } }) catch std.debug.panic("doe_query_native: OOM recording resolve_query_set", .{});
}

pub fn vulkanRecordWriteTimestamp(
    rt: *native_shared.NativeVulkanRuntime,
    qs_raw: ?*anyopaque,
    query_index: u32,
    position: native_cmds.TimestampWritePosition,
) !void {
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return error.InvalidArgument;
    if (qs.backend != .vulkan or query_index >= qs.count) return error.InvalidArgument;
    const command_buffer = try rt.begin_prepared_dispatch_replay();
    c.vkCmdResetQueryPool(command_buffer, qs.vk_query_pool, query_index, 1);
    c.vkCmdWriteTimestamp(command_buffer, vulkanTimestampStage(position), qs.vk_query_pool, query_index);
}

pub fn vulkanRecordResolveQuerySet(
    rt: *native_shared.NativeVulkanRuntime,
    qs_raw: ?*anyopaque,
    first_query: u32,
    query_count: u32,
    dst_raw: ?*anyopaque,
    dst_offset: u64,
) !void {
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return error.InvalidArgument;
    const dst = native_helpers.cast(native_types.DoeBuffer, dst_raw) orelse return error.InvalidArgument;
    if (qs.backend != .vulkan or dst.error_object) return error.InvalidArgument;
    if (first_query + query_count > qs.count) return error.InvalidArgument;
    const dst_vk_buf = vk_buffer_from_doe_buffer(rt, dst) orelse return error.InvalidArgument;
    const command_buffer = try rt.begin_prepared_dispatch_replay();
    c.vkCmdCopyQueryPoolResults(
        command_buffer,
        qs.vk_query_pool,
        first_query,
        query_count,
        dst_vk_buf,
        dst_offset,
        TIMESTAMP_BYTES,
        c.VK_QUERY_RESULT_64_BIT | c.VK_QUERY_RESULT_WAIT_BIT,
    );
    rt.has_pending_transfer_writes = true;
}

pub fn vulkanCopyQueryResultsToMappedBuffer(
    rt: *native_shared.NativeVulkanRuntime,
    qs_raw: ?*anyopaque,
    first_query: u32,
    query_count: u32,
    dst_raw: ?*anyopaque,
    dst_offset: u64,
) !void {
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return error.InvalidArgument;
    const dst = native_helpers.cast(native_types.DoeBuffer, dst_raw) orelse return error.InvalidArgument;
    if (qs.backend != .vulkan or dst.error_object or rt.device == null or rt.queue == null) return error.InvalidArgument;
    const query_end = std.math.add(u32, first_query, query_count) catch return error.InvalidArgument;
    if (query_end > qs.count) return error.InvalidArgument;
    const dst_compute_buffer = rt.compute_buffers.get(dst.vk_id) orelse return error.InvalidArgument;
    const mapped = dst_compute_buffer.mapped orelse return;
    const result_count: usize = @intCast(query_count);
    const result_bytes = std.math.mul(usize, result_count, TIMESTAMP_BYTES) catch return error.InvalidArgument;
    const d_off: usize = @intCast(dst_offset);
    if (d_off + result_bytes > @as(usize, @intCast(dst.size))) return error.InvalidArgument;

    const results = try native_helpers.alloc.alloc(u64, result_count);
    defer native_helpers.alloc.free(results);
    @memset(results, 0);
    try c.check_vk(c.vkQueueWaitIdle(rt.queue));
    try c.check_vk(c.vkGetQueryPoolResults(
        rt.device,
        qs.vk_query_pool,
        first_query,
        query_count,
        result_bytes,
        results.ptr,
        TIMESTAMP_BYTES,
        c.VK_QUERY_RESULT_64_BIT | c.VK_QUERY_RESULT_WAIT_BIT,
    ));
    const dst_bytes: [*]u8 = @ptrCast(mapped);
    @memcpy(dst_bytes[d_off .. d_off + result_bytes], std.mem.sliceAsBytes(results));
}

// ============================================================
// destroyQuerySet
// ============================================================

pub export fn doeNativeQuerySetDestroy(qs_raw: ?*anyopaque) callconv(.c) void {
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return;
    if (!native_helpers.object_should_destroy(qs)) return;
    native_helpers.label_store.remove(qs_raw);

    if (comptime has_vulkan) {
        if (qs.backend == .vulkan) {
            vulkan_lifetime.flushBeforeDestroy(qs.vk_runtime_ref);
            if (qs.vk_query_pool != c.VK_NULL_U64) {
                c.vkDestroyQueryPool(qs.vk_device, qs.vk_query_pool, null);
            }
            native_helpers.alloc.destroy(qs);
            return;
        }
    }

    // Metal path.
    if (qs.counter_sample_buffer) |csb| bridge.metal_bridge_destroy_counter_sample_buffer(csb);
    native_helpers.alloc.destroy(qs);
}

pub export fn doeNativeQuerySetRelease(qs_raw: ?*anyopaque) callconv(.c) void {
    doeNativeQuerySetDestroy(qs_raw);
}

pub export fn doeNativeQuerySetGetCount(qs_raw: ?*anyopaque) callconv(.c) u32 {
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return 0;
    return qs.count;
}

pub export fn doeNativeQuerySetGetType(qs_raw: ?*anyopaque) callconv(.c) u32 {
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return 0;
    return qs.query_type;
}

// ============================================================
// Vulkan implementation
// ============================================================

const WAIT_TIMEOUT_NS: u64 = std.math.maxInt(u64);

fn vulkan_create_query_set(dev: *native_types.DoeDevice, query_type: u32, count: u32) ?*anyopaque {
    const rt = native_rt_helpers.device_vk_runtime(dev) orelse return null;
    if (!rt.has_device) return null;

    var query_pool: c.VkQueryPool = c.VK_NULL_U64;
    var create_info = c.VkQueryPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queryType = if (query_type == WGPU_QUERY_TYPE_OCCLUSION) VK_QUERY_TYPE_OCCLUSION else c.VK_QUERY_TYPE_TIMESTAMP,
        .queryCount = count,
        .pipelineStatistics = 0,
    };
    const result = c.vkCreateQueryPool(rt.device, &create_info, null, &query_pool);
    if (result != c.VK_SUCCESS) {
        std.log.err("doe_query_native: vkCreateQueryPool failed (result={})", .{result});
        return null;
    }

    const qs = native_helpers.make(DoeQuerySet) orelse {
        c.vkDestroyQueryPool(rt.device, query_pool, null);
        return null;
    };
    qs.* = .{
        .count = count,
        .query_type = query_type,
        .backend = .vulkan,
        .vk_query_pool = query_pool,
        .vk_device = rt.device,
        .vk_runtime_ref = @ptrCast(rt),
    };

    if (query_type != WGPU_QUERY_TYPE_TIMESTAMP) {
        vk_reset_query_pool(rt, query_pool, 0, count) catch |err| {
            std.log.err("doe_query_native: initial query pool reset failed: {s}", .{@errorName(err)});
            c.vkDestroyQueryPool(rt.device, query_pool, null);
            native_helpers.alloc.destroy(qs);
            return null;
        };
    }

    return native_helpers.toOpaque(qs);
}

/// Reset query pool entries via a transient one-shot command buffer.
/// The query helpers allocate their own command buffer so they do not borrow
/// or mutate the runtime's primary command buffer.
fn vk_reset_query_pool(
    rt: *native_shared.NativeVulkanRuntime,
    query_pool: c.VkQueryPool,
    first_query: u32,
    query_count: u32,
) !void {
    _ = rt.flush_queue() catch |err| {
        log.warn("flush before reset_query_pool: {s}", .{@errorName(err)});
    };
    const command_buffer = try begin_one_shot_command_buffer(rt);
    c.vkCmdResetQueryPool(command_buffer, query_pool, first_query, query_count);
    try submit_one_shot_command_buffer(rt, command_buffer);
}

/// Vulkan writeTimestamp: reset the query slot, then record vkCmdWriteTimestamp
/// in a one-shot command buffer, submit, and wait for completion.
fn vulkan_write_timestamp(qs: *DoeQuerySet, query_index: u32) void {
    const rt = vk_runtime_from_qs(qs) orelse return;
    if (!rt.has_command_pool or !rt.has_fence) return;

    // Flush any pending work to avoid command pool conflicts.
    _ = rt.flush_queue() catch |err| {
        log.warn("flush before write_timestamp: {s}", .{@errorName(err)});
    };
    const command_buffer = begin_one_shot_command_buffer(rt) catch |err| {
        std.log.err("doe_query_native: begin one-shot query command buffer failed: {s}", .{@errorName(err)});
        return;
    };

    // Reset the single query index before writing.
    c.vkCmdResetQueryPool(command_buffer, qs.vk_query_pool, query_index, 1);
    // Write GPU timestamp at the bottom of the pipeline (all prior work is complete).
    c.vkCmdWriteTimestamp(command_buffer, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, qs.vk_query_pool, query_index);

    submit_one_shot_command_buffer(rt, command_buffer) catch |err| {
        std.log.err("doe_query_native: submit one-shot query timestamp failed: {s}", .{@errorName(err)});
    };
}

/// Vulkan resolveQuerySet: copy query pool results into the destination VkBuffer
/// using vkCmdCopyQueryPoolResults in a one-shot command buffer.
fn vulkan_resolve_query_set(
    qs: *DoeQuerySet,
    first_query: u32,
    query_count: u32,
    dst: *native_types.DoeBuffer,
    dst_offset: u64,
) void {
    const rt = vk_runtime_from_qs(qs) orelse return;
    if (!rt.has_command_pool or !rt.has_fence) return;

    // Look up the destination VkBuffer from the runtime's buffer map.
    const dst_vk_buf = vk_buffer_from_doe_buffer(rt, dst) orelse {
        std.log.err("doe_query_native: resolveQuerySet destination buffer not found in Vulkan runtime", .{});
        return;
    };

    // Flush any pending work to avoid command pool conflicts.
    _ = rt.flush_queue() catch |err| {
        log.warn("flush before resolve_query_set: {s}", .{@errorName(err)});
    };

    const command_buffer = begin_one_shot_command_buffer(rt) catch |err| {
        std.log.err("doe_query_native: begin one-shot query command buffer failed: {s}", .{@errorName(err)});
        return;
    };

    // Copy results as 64-bit values, waiting for query availability.
    c.vkCmdCopyQueryPoolResults(
        command_buffer,
        qs.vk_query_pool,
        first_query,
        query_count,
        dst_vk_buf,
        dst_offset,
        TIMESTAMP_BYTES,
        c.VK_QUERY_RESULT_64_BIT | c.VK_QUERY_RESULT_WAIT_BIT,
    );

    submit_one_shot_command_buffer(rt, command_buffer) catch |err| {
        std.log.err("doe_query_native: submit one-shot query resolve failed: {s}", .{@errorName(err)});
    };
}

// ============================================================
// Vulkan helpers
// ============================================================

/// Extract NativeVulkanRuntime from a DoeQuerySet's vk_runtime_ref.
fn vk_runtime_from_qs(qs: *const DoeQuerySet) ?*native_shared.NativeVulkanRuntime {
    const ptr = qs.vk_runtime_ref orelse return null;
    return @as(*native_shared.NativeVulkanRuntime, @ptrCast(@alignCast(ptr)));
}

/// Look up the VkBuffer handle for a DoeBuffer via the runtime's compute_buffers map.
fn vk_buffer_from_doe_buffer(rt: *native_shared.NativeVulkanRuntime, buf: *const native_types.DoeBuffer) ?c.VkBuffer {
    if (buf.error_object) return null;
    if (buf.vk_id == 0) return null;
    const cb = rt.compute_buffers.get(buf.vk_id) orelse return null;
    return cb.buffer;
}

fn begin_one_shot_command_buffer(rt: *native_shared.NativeVulkanRuntime) !c.VkCommandBuffer {
    if (!rt.has_command_pool or !rt.has_fence or rt.device == null or rt.queue == null) return error.InvalidState;

    var command_buffer: c.VkCommandBuffer = null;
    var alloc_info = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = rt.command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    try c.check_vk(c.vkAllocateCommandBuffers(rt.device, &alloc_info, @ptrCast(&command_buffer)));

    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    errdefer c.vkFreeCommandBuffers(rt.device, rt.command_pool, 1, @ptrCast(&command_buffer));
    try c.check_vk(c.vkBeginCommandBuffer(command_buffer, &begin_info));
    return command_buffer;
}

fn submit_one_shot_command_buffer(rt: *native_shared.NativeVulkanRuntime, command_buffer: c.VkCommandBuffer) !void {
    if (!rt.has_fence or rt.device == null or rt.queue == null) return error.InvalidState;

    defer c.vkFreeCommandBuffers(rt.device, rt.command_pool, 1, @ptrCast(&command_buffer));

    try c.check_vk(c.vkEndCommandBuffer(command_buffer));

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
    try c.check_vk(c.vkResetFences(rt.device, 1, @ptrCast(&rt.fence)));
    try c.check_vk(c.vkQueueSubmit(rt.queue, 1, @ptrCast(&submit_info), rt.fence));
    try c.check_vk(c.vkWaitForFences(rt.device, 1, @ptrCast(&rt.fence), c.VK_TRUE, WAIT_TIMEOUT_NS));
}

pub export fn doeNativeRenderPassBeginOcclusionQuery(
    pass_raw: ?*anyopaque,
    query_index: u32,
) callconv(.c) void {
    const pass = native_helpers.cast(native_types.DoeRenderPass, pass_raw) orelse return;
    const qs_raw = pass.occlusion_query_set orelse return;
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return;
    if (qs.query_type != WGPU_QUERY_TYPE_OCCLUSION) return;
    if (query_index >= qs.count) return;
    pass.occlusion_query_active = true;
    pass.occlusion_query_index = query_index;
}

pub export fn doeNativeRenderPassEndOcclusionQuery(
    pass_raw: ?*anyopaque,
) callconv(.c) void {
    const pass = native_helpers.cast(native_types.DoeRenderPass, pass_raw) orelse return;
    pass.occlusion_query_active = false;
}
const log = std.log.scoped(.doe_query_native);
