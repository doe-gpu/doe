const recording = @import("../command/doe_command_recording.zig");
// doe_query_native.zig — QuerySet (GPU timestamp query) support for Doe Metal and Vulkan backends.
//
// Metal: Uses MTLCounterSampleBuffer for GPU timeline timestamps.
// Vulkan: Uses VkQueryPool with VK_QUERY_TYPE_TIMESTAMP.
//
// Timestamps are sampled at command recording time and resolved to a
// destination buffer after GPU completion.

const std = @import("std");
const builtin = @import("builtin");
const references = @import("../command/doe_command_references.zig");
const has_vulkan = (builtin.os.tag == .linux);
const resource_ops = @import("../../backend/dropin_resource_ops.zig");
const backend_contract = @import("../../contracts/backend.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_cmds = @import("../support/doe_native_command_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_exports = @import("../support/doe_native_exports.zig");
const native_rt_helpers = @import("../support/doe_native_runtime_helpers.zig");
const vulkan_lifetime = @import("../vulkan/vulkan_lifetime.zig");
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
    device_ref: ?*native_types.DoeDevice = null,
    destroyed: bool = false,
    count: u32 = 0,
    query_type: u32 = WGPU_QUERY_TYPE_TIMESTAMP,
    backend: backend_contract.NativeBackendKind = .metal,
    /// Metal: opaque handle to MTLCounterSampleBuffer for GPU timestamp sampling.
    counter_sample_buffer: ?*anyopaque = null,
    /// Vulkan: VkQueryPool handle for timestamp queries.
    vk_query_pool: c.VkQueryPool = c.VK_NULL_U64,
    /// Vulkan: VkDevice reference needed for pool destruction and result retrieval.
    vk_device: c.VkDevice = null,
    /// Vulkan: back-reference to NativeVulkanRuntime for command buffer access.
    vk_runtime_ref: ?*anyopaque = null,
    vk_timestamp_resolve: if (has_vulkan) resource_ops.vk_timestamp.Resolve else void = if (has_vulkan) .{} else {},
};

fn vulkanTimestampStage(position: native_cmds.TimestampWritePosition) u32 {
    return switch (position) {
        .pass_begin => c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        .pass_end, .command => c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
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
    const raw = createQuerySet(dev_raw, query_type, count) orelse return null;
    native_helpers.cast(DoeQuerySet, raw).?.device_ref = native_helpers.cast(native_types.DoeDevice, dev_raw).?;
    native_helpers.object_add_ref(native_types.DoeDevice, dev_raw);
    return raw;
}

fn createQuerySet(dev_raw: ?*anyopaque, query_type: u32, count: u32) ?*anyopaque {
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
    if (!recording.requireOpen(enc)) return;
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return;
    if (qs.destroyed or query_index >= qs.count) return;
    if (!recording.reserve(enc, 1, 1)) return;
    native_helpers.object_add_ref(DoeQuerySet, qs_raw);

    if (comptime has_vulkan) {
        if (qs.backend == .vulkan) {
            if (!recording.append(enc, .{ .write_timestamp = .{
                .counter_buffer = null,
                .query_set = qs_raw,
                .query_index = query_index,
                .position = position,
            } })) return;
            return;
        }
    }

    // Metal: record for deferred execution at submit.
    if (!recording.append(enc, .{ .write_timestamp = .{
        .counter_buffer = qs.counter_sample_buffer,
        .query_set = qs_raw,
        .query_index = query_index,
        .position = position,
    } })) return;
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
    if (!recording.requireOpen(enc)) return;
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return;
    const dst = native_helpers.cast(native_types.DoeBuffer, dst_raw) orelse return;
    if (qs.destroyed or dst.error_object or dst.destroyed) return;

    if (first_query + query_count > qs.count) return;

    const copy_bytes = @as(usize, query_count) * TIMESTAMP_BYTES;
    const d_off: usize = @intCast(dst_offset);
    if (d_off + copy_bytes > @as(usize, @intCast(dst.size))) return;
    if (!recording.reserve(enc, 1, 1)) return;
    native_helpers.object_add_ref(DoeQuerySet, qs_raw);

    if (!recording.reserve(enc, 0, 1)) return;
    references.retainBufferAssumeCapacity(&enc.references, dst);

    if (comptime has_vulkan) {
        if (qs.backend == .vulkan) {
            if (!recording.append(enc, .{ .resolve_query_set = .{
                .counter_buffer = null,
                .query_set = qs_raw,
                .first_query = first_query,
                .query_count = query_count,
                .dst_mtl = null,
                .dst_buffer = dst_raw,
                .dst_offset = dst_offset,
            } })) return;
            return;
        }
    }

    // Metal: record for deferred execution at submit.
    if (!recording.append(enc, .{ .resolve_query_set = .{
        .counter_buffer = qs.counter_sample_buffer,
        .query_set = qs_raw,
        .first_query = first_query,
        .query_count = query_count,
        .dst_mtl = dst.mtl,
        .dst_buffer = dst_raw,
        .dst_offset = dst_offset,
    } })) return;
}

pub fn vulkanRecordWriteTimestamp(
    rt: *native_shared.NativeVulkanRuntime,
    qs_raw: ?*anyopaque,
    query_index: u32,
    position: native_cmds.TimestampWritePosition,
) !void {
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return error.InvalidArgument;
    if (qs.destroyed or qs.backend != .vulkan or query_index >= qs.count or
        qs.vk_runtime_ref != @as(?*anyopaque, @ptrCast(rt))) return error.InvalidArgument;
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
    if (qs.destroyed or qs.backend != .vulkan or dst.error_object or
        qs.vk_runtime_ref != @as(?*anyopaque, @ptrCast(rt)) or
        dst.vk_runtime_ref != @as(?*anyopaque, @ptrCast(rt))) return error.InvalidArgument;
    if (try std.math.add(u32, first_query, query_count) > qs.count) return error.InvalidArgument;
    if (query_count == 0) return;
    if (try std.math.add(u64, dst_offset, @as(u64, query_count) * TIMESTAMP_BYTES) > dst.size) return error.InvalidArgument;
    const destination = rt.compute_buffers.get(dst.vk_id) orelse return error.InvalidArgument;
    if (qs.query_type == WGPU_QUERY_TYPE_TIMESTAMP) {
        try qs.vk_timestamp_resolve.record(rt, qs.vk_query_pool, first_query, query_count, destination, dst_offset);
        return;
    }
    const command_buffer = try rt.begin_prepared_dispatch_replay();
    c.vkCmdCopyQueryPoolResults(
        command_buffer,
        qs.vk_query_pool,
        first_query,
        query_count,
        destination.buffer,
        dst_offset,
        TIMESTAMP_BYTES,
        c.VK_QUERY_RESULT_64_BIT | c.VK_QUERY_RESULT_WAIT_BIT,
    );
    rt.has_pending_transfer_writes = true;
}

// ============================================================
// destroyQuerySet
// ============================================================

fn releaseQuerySetResources(qs: *DoeQuerySet) void {
    if (comptime has_vulkan) {
        if (qs.backend == .vulkan) {
            vulkan_lifetime.flushBeforeDestroy(qs.vk_runtime_ref);
            if (qs.vk_runtime_ref) |raw| {
                const rt: *native_shared.NativeVulkanRuntime = @ptrCast(@alignCast(raw));
                qs.vk_timestamp_resolve.deinit(rt);
            }
            if (qs.vk_query_pool != c.VK_NULL_U64) {
                c.vkDestroyQueryPool(qs.vk_device, qs.vk_query_pool, null);
                qs.vk_query_pool = c.VK_NULL_U64;
            }
            return;
        }
    }

    if (qs.counter_sample_buffer) |csb| {
        bridge.metal_bridge_destroy_counter_sample_buffer(csb);
        qs.counter_sample_buffer = null;
    }
}

pub export fn doeNativeQuerySetDestroy(qs_raw: ?*anyopaque) callconv(.c) void {
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return;
    if (qs.destroyed) return;
    qs.destroyed = true;
    if (@atomicLoad(u32, &qs.ref_count, .acquire) == 1) releaseQuerySetResources(qs);
}

pub export fn doeNativeQuerySetRelease(qs_raw: ?*anyopaque) callconv(.c) void {
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return;
    if (!native_helpers.object_should_destroy(qs)) return;
    const device = qs.device_ref;
    defer if (device) |dev| native_exports.doeNativeDeviceRelease(native_helpers.toOpaque(dev));
    releaseQuerySetResources(qs);
    native_helpers.label_store.remove(qs_raw);
    native_helpers.alloc.destroy(qs);
}

pub fn releaseRecordedCommandReferences(cmds: []const native_cmds.RecordedCmd) void {
    for (cmds) |cmd| {
        const query_set = switch (cmd) {
            .write_timestamp => |timestamp| timestamp.query_set,
            .resolve_query_set => |resolve| resolve.query_set,
            else => null,
        };
        if (query_set != null) doeNativeQuerySetRelease(query_set);
    }
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

    if (query_type == WGPU_QUERY_TYPE_TIMESTAMP) {
        qs.vk_timestamp_resolve.init(rt, count) catch |err| {
            std.log.err("doe_query_native: timestamp normalization preparation failed: {s}", .{@errorName(err)});
            c.vkDestroyQueryPool(rt.device, query_pool, null);
            native_helpers.alloc.destroy(qs);
            return null;
        };
    }

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
    if (!recording.requireOpen(pass.enc)) return;
    const qs_raw = pass.occlusion_query_set orelse return;
    const qs = native_helpers.cast(DoeQuerySet, qs_raw) orelse return;
    if (qs.query_type != WGPU_QUERY_TYPE_OCCLUSION) return;
    if (query_index >= qs.count) return;
    pass.occlusion_query_active = true;
    pass.occlusion_query_index = query_index;
}

pub fn retainRecordedReference(enc: *native_types.DoeCommandEncoder, raw: ?*anyopaque) void {
    _ = native_helpers.cast(DoeQuerySet, raw) orelse return;
    if (!recording.reserve(enc, 0, 1)) return;
    enc.references.appendAssumeCapacity(.{ .handle = raw, .release = doeNativeQuerySetRelease });
    native_helpers.object_add_ref(DoeQuerySet, raw);
}

pub export fn doeNativeRenderPassEndOcclusionQuery(
    pass_raw: ?*anyopaque,
) callconv(.c) void {
    const pass = native_helpers.cast(native_types.DoeRenderPass, pass_raw) orelse return;
    if (!recording.requireOpen(pass.enc)) return;
    pass.occlusion_query_active = false;
}
const log = std.log.scoped(.doe_query_native);
