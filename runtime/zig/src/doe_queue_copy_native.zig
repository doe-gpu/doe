const builtin = @import("builtin");
const std = @import("std");
const abi_copy = @import("core/abi/wgpu_copy_descriptor_types.zig");
const abi_texture = @import("core/abi/wgpu_texture_base_types.zig");
const queue_submit_ops = @import("backend/dropin_queue_submit.zig");
const resource_ops = @import("backend/dropin_resource_ops.zig");
const native_types = @import("doe_native_object_types.zig");
const native_cmds = @import("doe_native_command_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const native_rt_helpers = @import("doe_native_runtime_helpers.zig");
const native_exports = @import("doe_native_exports.zig");
const texture_sampler = @import("doe_texture_sampler_native.zig");
const error_scope = @import("error_scope.zig");
const shared = @import("doe_queue_submit_shared.zig");
const queue_flush_breakdown = @import("doe_queue_flush_breakdown.zig");

const has_vulkan = (builtin.os.tag == .linux);
const vk_resources = if (has_vulkan) resource_ops.vk_resources else struct {};
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const DoeBuffer = native_types.DoeBuffer;
const DoeQueue = native_types.DoeQueue;
const DoeTexture = native_types.DoeTexture;
const bridge = queue_submit_ops.metal_bridge;

extern fn doeNativeQueueSubmit(q_raw: ?*anyopaque, count: usize, cmd_bufs: [*]const ?*anyopaque) callconv(.c) void;

const SMALL_STAGED_WRITE_CAPACITY: usize = 64 * 1024;
const LARGE_STAGED_WRITE_CAPACITY: usize = 128 * 1024 * 1024;
const STAGED_WRITE_ALIGNMENT: usize = 16;

const StagedWriteRegion = struct {
    buffer: ?*anyopaque,
    offset: usize,
    ptr: [*]u8,
};

fn alignForwardPow2(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn stagedWriteCapacity(required_size: usize) usize {
    if (required_size <= SMALL_STAGED_WRITE_CAPACITY) return SMALL_STAGED_WRITE_CAPACITY;
    return @max(required_size, LARGE_STAGED_WRITE_CAPACITY);
}

fn reserveDeferredMetalRelease(q: *DoeQueue) bool {
    if (q.deferred_release_count < native_cmds.MAX_DEFERRED_RELEASES) return true;
    shared.flush_pending_work(q);
    return q.deferred_release_count < native_cmds.MAX_DEFERRED_RELEASES;
}

fn appendDeferredMetalRelease(q: *DoeQueue, obj: ?*anyopaque) void {
    if (obj == null) return;
    if (!reserveDeferredMetalRelease(q)) return;
    q.deferred_releases[q.deferred_release_count] = obj;
    q.deferred_release_count += 1;
}

fn flushBeforeStartingStagedWriteIfNeeded(q: *DoeQueue) void {
    if (q.staged_write_cmd != null) return;
    if (q.mtl_event == null and q.pending_cmd != null) {
        shared.flush_pending_work(q);
        return;
    }
    if (q.deferred_copy_count != 0 or q.deferred_resolve_count != 0) {
        shared.flush_pending_work(q);
    }
}

fn discardOpenStagedWriteBuffer(q: *DoeQueue) void {
    if (q.staged_write_buffer) |buffer| bridge.metal_bridge_release(buffer);
    q.staged_write_buffer = null;
    q.staged_write_contents = null;
    q.staged_write_capacity = 0;
    q.staged_write_offset = 0;
}

fn ensureStagedWriteBlit(q: *DoeQueue) ?*anyopaque {
    if (q.staged_write_blit) |blit| return blit;
    flushBeforeStartingStagedWriteIfNeeded(q);
    if (q.staged_write_cmd == null) {
        q.staged_write_cmd = bridge.metal_bridge_create_command_buffer(q.dev.mtl_queue) orelse {
            shared.deliverInternalError(q.dev, "doe_queue_write_buffer: metal command buffer allocation failed", .{});
            return null;
        };
    }
    q.staged_write_blit = bridge.metal_bridge_cmd_buf_blit_encoder(q.staged_write_cmd) orelse {
        if (q.staged_write_cmd) |cmd| bridge.metal_bridge_release(cmd);
        q.staged_write_cmd = null;
        shared.deliverInternalError(q.dev, "doe_queue_write_buffer: metal blit encoder allocation failed", .{});
        return null;
    };
    return q.staged_write_blit;
}

fn reserveStagedWriteRegion(q: *DoeQueue, size: usize) ?StagedWriteRegion {
    flushBeforeStartingStagedWriteIfNeeded(q);
    var aligned_offset = alignForwardPow2(q.staged_write_offset, STAGED_WRITE_ALIGNMENT);
    var write_end = std.math.add(usize, aligned_offset, size) catch return null;
    if (q.staged_write_buffer == null or write_end > q.staged_write_capacity) {
        queue_flush_breakdown.commitStagedWriteBlits(q);
        if (!reserveDeferredMetalRelease(q)) return null;
        const capacity = stagedWriteCapacity(size);
        const buffer = bridge.metal_bridge_device_new_buffer_shared(q.dev.mtl_device, capacity) orelse return null;
        const contents = bridge.metal_bridge_buffer_contents(buffer) orelse {
            bridge.metal_bridge_release(buffer);
            return null;
        };
        q.staged_write_buffer = buffer;
        q.staged_write_contents = contents;
        q.staged_write_capacity = capacity;
        q.staged_write_offset = 0;
        aligned_offset = 0;
        write_end = size;
    }
    const ptr = q.staged_write_contents orelse return null;
    q.staged_write_offset = write_end;
    return .{
        .buffer = q.staged_write_buffer,
        .offset = aligned_offset,
        .ptr = ptr + aligned_offset,
    };
}

fn writeMetalBufferThroughStaging(q: *DoeQueue, buf: *DoeBuffer, offset: u64, data: [*]const u8, size: usize) void {
    if (size == 0) return;
    const region = reserveStagedWriteRegion(q, size) orelse {
        shared.deliverInternalError(q.dev, "doe_queue_write_buffer: metal staging region allocation failed", .{});
        return;
    };
    const blit = ensureStagedWriteBlit(q) orelse {
        discardOpenStagedWriteBuffer(q);
        shared.deliverInternalError(q.dev, "doe_queue_write_buffer: metal staging buffer is not host visible", .{});
        return;
    };
    @memcpy(region.ptr[0..size], data[0..size]);
    bridge.metal_bridge_blit_encoder_copy_region(blit, region.buffer, @intCast(region.offset), buf.mtl, offset, @intCast(size));
    q.staged_write_count += 1;
}

fn writeBufferValidated(q: *DoeQueue, buf: *DoeBuffer, offset: u64, data: [*]const u8, size: usize) bool {
    if (buf.error_object) {
        q.dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, "wgpuQueueWriteBuffer cannot write an error buffer");
        return false;
    }
    const size_u64: u64 = @intCast(size);
    const write_end = std.math.add(u64, offset, size_u64) catch {
        q.dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, "wgpuQueueWriteBuffer range exceeds buffer size");
        return false;
    };
    if (write_end > buf.size) {
        q.dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, "wgpuQueueWriteBuffer range exceeds buffer size");
        return false;
    }
    if (q.dev.backend == .vulkan) {
        if (comptime has_vulkan) {
            if (buf.vk_id != 0) {
                const rt = native_rt_helpers.device_vk_runtime(q.dev) orelse {
                    shared.deliverInternalError(q.dev, "doe_queue_write_buffer: vulkan runtime unavailable", .{});
                    return false;
                };
                if (rt.compute_buffers.get(buf.vk_id)) |cb| {
                    vk_resources.stage_compute_buffer_write(rt, cb, offset, data[0..size], .allow_mapped_shortcuts) catch |err| {
                        shared.deliverInternalError(
                            q.dev,
                            "doe_queue_write_buffer: vulkan stage buffer write: {s}",
                            .{@errorName(err)},
                        );
                    };
                }
            }
        }
        return true;
    }
    const contents = buf.metal_mapped_ptr orelse bridge.metal_bridge_buffer_contents(buf.mtl) orelse {
        writeMetalBufferThroughStaging(q, buf, offset, data, size);
        return true;
    };
    const dst = (contents + @as(usize, @intCast(offset)))[0..size];
    @memcpy(dst, data[0..size]);
    return true;
}

pub fn doeNativeQueueWriteBuffer(q_raw: ?*anyopaque, buf_raw: ?*anyopaque, offset: u64, data: [*]const u8, size: usize) void {
    const q = cast(DoeQueue, q_raw) orelse return;
    const buf = cast(DoeBuffer, buf_raw) orelse return;
    _ = writeBufferValidated(q, buf, offset, data, size);
}

pub fn doeNativeQueueWriteBufferBatch(
    q_raw: ?*anyopaque,
    count: usize,
    buf_raws: [*]const ?*anyopaque,
    offsets: [*]const u64,
    sizes: [*]const u32,
    data: [*]const u8,
) void {
    const q = cast(DoeQueue, q_raw) orelse return;
    var data_offset: usize = 0;
    for (0..count) |index| {
        const size: usize = @intCast(sizes[index]);
        const buf = cast(DoeBuffer, buf_raws[index]) orelse return;
        const next_data_offset = std.math.add(usize, data_offset, size) catch return;
        if (!writeBufferValidated(q, buf, offsets[index], data + data_offset, size)) return;
        data_offset = next_data_offset;
    }
}

pub fn doeNativeQueueWriteBufferBatchDataPtrs(
    q_raw: ?*anyopaque,
    count: usize,
    buf_raws: [*]const ?*anyopaque,
    offsets: [*]const u64,
    sizes: [*]const u32,
    data_ptrs: [*]const ?*const anyopaque,
) void {
    const q = cast(DoeQueue, q_raw) orelse return;
    for (0..count) |index| {
        const size: usize = @intCast(sizes[index]);
        const buf = cast(DoeBuffer, buf_raws[index]) orelse return;
        const data_raw = data_ptrs[index] orelse return;
        const data: [*]const u8 = @ptrCast(data_raw);
        if (!writeBufferValidated(q, buf, offsets[index], data, size)) return;
    }
}

fn copy_texture_for_browser_passthrough(
    q: *DoeQueue,
    source: *const abi_copy.WGPUTexelCopyTextureInfo,
    destination: *const abi_copy.WGPUTexelCopyTextureInfo,
    copy_size: *const abi_copy.WGPUExtent3D,
    options: ?*const abi_copy.WGPUCopyTextureForBrowserOptions,
) void {
    const src_texture = texture_sampler.registeredTexture(source.texture) orelse return;
    const dst_texture = texture_sampler.registeredTexture(destination.texture) orelse return;
    if (src_texture.error_object or dst_texture.error_object) return;
    const flip_y = if (options) |browser_options| browser_options.flipY != 0 else false;

    if (q.dev.backend == .vulkan) {
        if (comptime has_vulkan) {
            const rt = native_rt_helpers.device_vk_runtime(q.dev) orelse return;
            if (src_texture.vk_id == 0 or dst_texture.vk_id == 0) return;
            var row: u32 = 0;
            const rows = if (flip_y and copy_size.height > 1) copy_size.height else 1;
            while (row < rows) : (row += 1) {
                const copy_height: u32 = if (flip_y and copy_size.height > 1) 1 else copy_size.height;
                const src_y = if (flip_y and copy_size.height > 1)
                    source.origin.y + (copy_size.height - 1 - row)
                else
                    source.origin.y;
                const dst_y = if (flip_y and copy_size.height > 1)
                    destination.origin.y + row
                else
                    destination.origin.y;
                rt.texture_copy(.{
                    .src_handle = src_texture.vk_id,
                    .src_mip = source.mipLevel,
                    .src_x = source.origin.x,
                    .src_y = src_y,
                    .src_z = source.origin.z,
                    .dst_handle = dst_texture.vk_id,
                    .dst_mip = destination.mipLevel,
                    .dst_x = destination.origin.x,
                    .dst_y = dst_y,
                    .dst_z = destination.origin.z,
                    .width = copy_size.width,
                    .height = copy_height,
                    .depth_or_layers = copy_size.depthOrArrayLayers,
                }) catch |err| {
                    shared.deliverInternalError(q.dev, "doe_queue_submit: texture copy: {s}", .{@errorName(err)});
                    return;
                };
            }
        }
        return;
    }

    const encoder = native_exports.doeNativeDeviceCreateCommandEncoder(toOpaque(q.dev), null) orelse return;
    defer native_exports.doeNativeCommandEncoderRelease(encoder);

    var row: u32 = 0;
    const rows = if (flip_y and copy_size.height > 1) copy_size.height else 1;
    while (row < rows) : (row += 1) {
        const copy_height: u32 = if (flip_y and copy_size.height > 1) 1 else copy_size.height;
        const src_y = if (flip_y and copy_size.height > 1)
            source.origin.y + (copy_size.height - 1 - row)
        else
            source.origin.y;
        const dst_y = if (flip_y and copy_size.height > 1)
            destination.origin.y + row
        else
            destination.origin.y;
        @import("doe_command_texture_native.zig").doeNativeCommandEncoderCopyTextureToTexture(
            encoder,
            source.texture,
            source.mipLevel,
            source.origin.z,
            source.origin.x,
            src_y,
            source.origin.z,
            destination.texture,
            destination.mipLevel,
            destination.origin.z,
            destination.origin.x,
            dst_y,
            destination.origin.z,
            copy_size.width,
            copy_height,
            copy_size.depthOrArrayLayers,
        );
    }

    const command_buffer = native_exports.doeNativeCommandEncoderFinish(encoder, null) orelse return;
    defer native_exports.doeNativeCommandBufferRelease(command_buffer);
    var command_buffers = [1]?*anyopaque{command_buffer};
    doeNativeQueueSubmit(toOpaque(q), command_buffers.len, &command_buffers);
}

pub fn doeNativeQueueCopyTextureForBrowser(
    queue_raw: ?*anyopaque,
    source_raw: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    destination_raw: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    copy_size_raw: ?*const abi_copy.WGPUExtent3D,
    options_raw: ?*const abi_copy.WGPUCopyTextureForBrowserOptions,
) void {
    const queue = cast(DoeQueue, queue_raw) orelse return;
    const source = source_raw orelse return;
    const destination = destination_raw orelse return;
    const copy_size = copy_size_raw orelse return;
    copy_texture_for_browser_passthrough(queue, source, destination, copy_size, options_raw);
}

const ext_texture_mod = @import("doe_external_texture_native.zig");
const DoeExternalTexture = ext_texture_mod.DoeExternalTexture;

fn copy_external_texture_to_dst(
    queue: *DoeQueue,
    ext: *const DoeExternalTexture,
    origin: abi_copy.WGPUOrigin3D,
    destination: *const abi_copy.WGPUTexelCopyTextureInfo,
    copy_size: *const abi_copy.WGPUExtent3D,
    options: ?*const abi_copy.WGPUCopyTextureForBrowserOptions,
) void {
    if (ext_texture_mod.resolvePlane0DoeTexture(ext)) |src_tex| {
        const source_copy = abi_copy.WGPUTexelCopyTextureInfo{
            .texture = native_helpers.toOpaque(src_tex),
            .mipLevel = 0,
            .origin = origin,
            .aspect = abi_texture.WGPUTextureAspect_All,
        };
        copy_texture_for_browser_passthrough(queue, &source_copy, destination, copy_size, options);
        return;
    }
    const src_mtl = ext_texture_mod.resolvePlane0MtlHandle(ext) orelse return;
    const dst_texture = texture_sampler.registeredTexture(destination.texture) orelse return;
    if (dst_texture.error_object) return;
    const dst_mtl = dst_texture.mtl orelse return;
    if (queue.dev.backend != .metal) return;
    const cmd_buf = bridge.metal_bridge_create_command_buffer(queue.dev.mtl_queue);
    if (cmd_buf == null) return;
    const blit = bridge.metal_bridge_cmd_buf_blit_encoder(cmd_buf);
    if (blit == null) {
        bridge.metal_bridge_release(cmd_buf);
        return;
    }
    bridge.metal_bridge_blit_encoder_copy_texture_to_texture(
        blit,
        src_mtl,
        0,
        dst_mtl,
        destination.mipLevel,
        copy_size.width,
        copy_size.height,
        copy_size.depthOrArrayLayers,
    );
    bridge.metal_bridge_end_blit_encoding(blit);
    bridge.metal_bridge_command_buffer_commit(cmd_buf);
    bridge.metal_bridge_command_buffer_wait_completed(cmd_buf);
    bridge.metal_bridge_release(cmd_buf);
}

pub fn doeNativeQueueCopyExternalImageToTexture(
    queue_raw: ?*anyopaque,
    source_raw: ?*const abi_copy.WGPUImageCopyExternalTexture,
    destination_raw: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    copy_size_raw: ?*const abi_copy.WGPUExtent3D,
) void {
    const source = source_raw orelse return;
    const destination = destination_raw orelse return;
    const copy_size = copy_size_raw orelse return;
    const ext = ext_texture_mod.cast(source.externalTexture) orelse return;
    if (ext.expired) return;
    const queue = cast(DoeQueue, queue_raw) orelse return;
    copy_external_texture_to_dst(queue, ext, source.origin, destination, copy_size, null);
}

pub fn doeNativeQueueCopyExternalTextureForBrowser(
    queue_raw: ?*anyopaque,
    source_raw: ?*const abi_copy.WGPUImageCopyExternalTexture,
    destination_raw: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    copy_size_raw: ?*const abi_copy.WGPUExtent3D,
    options_raw: ?*const abi_copy.WGPUCopyTextureForBrowserOptions,
) void {
    const source = source_raw orelse return;
    const destination = destination_raw orelse return;
    const copy_size = copy_size_raw orelse return;
    const ext = ext_texture_mod.cast(source.externalTexture) orelse return;
    if (ext.expired) return;
    const queue = cast(DoeQueue, queue_raw) orelse return;
    copy_external_texture_to_dst(queue, ext, source.origin, destination, copy_size, options_raw);
}
