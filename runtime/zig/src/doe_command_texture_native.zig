// doe_command_texture_native.zig — clearBuffer, copyTextureToTexture, writeTexture C-ABI exports.
// Sharded from doe_wgpu_native.zig to keep texture command concerns cohesive.

const builtin = @import("builtin");
const has_vulkan = (builtin.os.tag == .linux);
const std = @import("std");
const model_transfer_types = @import("model_resource_types.zig");
const native_types = @import("doe_native_object_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const native_rt_helpers = @import("doe_native_runtime_helpers.zig");
const resource_ops = @import("backend/dropin_resource_ops.zig");
const bridge = resource_ops.metal_bridge;

const alloc = native_helpers.alloc;
const cast = native_helpers.cast;

const DoeBuffer = native_types.DoeBuffer;
const DoeCommandEncoder = native_types.DoeCommandEncoder;
const DoeQueue = native_types.DoeQueue;
const DoeTexture = native_types.DoeTexture;

// ============================================================
// GPUCommandEncoder.clearBuffer(buffer, offset, size)
// Encodes a zero-fill of [offset, offset+size) in buffer.
// ============================================================

pub export fn doeNativeCommandEncoderClearBuffer(
    enc_raw: ?*anyopaque,
    buffer_raw: ?*anyopaque,
    offset: u64,
    size: u64,
) callconv(.c) void {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return;
    const buf = cast(DoeBuffer, buffer_raw) orelse return;
    if (buf.error_object) return;
    // Resolve WGPU_WHOLE_SIZE sentinel: if size is u64 max, fill to end of buffer.
    const fill_size: u64 = if (size == std.math.maxInt(u64))
        buf.size -| offset
    else
        size;
    if (fill_size == 0) return;
    if (enc.dev.backend == .vulkan) {
        if (comptime has_vulkan) {
            const rt = native_rt_helpers.device_vk_runtime(enc.dev) orelse return;
            if (buf.vk_id != 0) {
                if (rt.compute_buffers.get(buf.vk_id)) |cb| {
                    if (cb.mapped) |ptr| {
                        const n: usize = @intCast(fill_size);
                        const o: usize = @intCast(offset);
                        const d: [*]u8 = @ptrCast(ptr);
                        @memset(d[o .. o + n], 0);
                    }
                }
            }
        }
        return;
    }
    enc.cmds.append(alloc, .{ .clear_buffer = .{
        .buffer = buf.mtl,
        .offset = offset,
        .size = fill_size,
    } }) catch std.debug.panic("doe_command_texture_native: OOM recording clearBuffer command", .{});
}

// ============================================================
// GPUCommandEncoder.copyTextureToTexture(source, destination, copySize)
// Encodes a texture-to-texture blit.
// ============================================================

pub export fn doeNativeCommandEncoderCopyTextureToTexture(
    enc_raw: ?*anyopaque,
    src_texture_raw: ?*anyopaque,
    src_mip: u32,
    src_slice: u32,
    src_x: u32,
    src_y: u32,
    src_z: u32,
    dst_texture_raw: ?*anyopaque,
    dst_mip: u32,
    dst_slice: u32,
    dst_x: u32,
    dst_y: u32,
    dst_z: u32,
    width: u32,
    height: u32,
    depth_or_layers: u32,
) callconv(.c) void {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return;
    const src = cast(DoeTexture, src_texture_raw) orelse return;
    const dst = cast(DoeTexture, dst_texture_raw) orelse return;
    if (src.error_object or dst.error_object) return;
    if (enc.dev.backend == .vulkan) {
        if (comptime has_vulkan) {
            const rt = native_rt_helpers.device_vk_runtime(enc.dev) orelse return;
            if (src.vk_id != 0 and dst.vk_id != 0) {
                rt.texture_copy(.{
                    .src_handle = src.vk_id,
                    .src_mip = src_mip,
                    .src_x = src_x,
                    .src_y = src_y,
                    .src_z = src_z,
                    .dst_handle = dst.vk_id,
                    .dst_mip = dst_mip,
                    .dst_x = dst_x,
                    .dst_y = dst_y,
                    .dst_z = dst_z,
                    .width = width,
                    .height = height,
                    .depth_or_layers = depth_or_layers,
                }) catch |err| {
                    std.log.err("doe_command_texture_native: copyTextureToTexture Vulkan failed: {s}", .{@errorName(err)});
                };
            }
        }
        return;
    }
    enc.cmds.append(alloc, .{ .copy_texture_to_texture = .{
        .src_texture = src.mtl,
        .src_mip = src_mip,
        .src_slice = src_slice,
        .src_x = src_x,
        .src_y = src_y,
        .src_z = src_z,
        .dst_texture = dst.mtl,
        .dst_mip = dst_mip,
        .dst_slice = dst_slice,
        .dst_x = dst_x,
        .dst_y = dst_y,
        .dst_z = dst_z,
        .width = width,
        .height = height,
        .depth_or_layers = depth_or_layers,
    } }) catch std.debug.panic("doe_command_texture_native: OOM recording copyTextureToTexture command", .{});
}

// ============================================================
// GPUQueue.writeTexture(destination, data, dataLayout, size)
// CPU-direct texture upload via Metal replaceRegion (shared unified memory).
// Mirrors writeBuffer: immediate memcpy, no command recording needed.
// ============================================================

pub export fn doeNativeQueueWriteTexture(
    queue_raw: ?*anyopaque,
    texture_raw: ?*anyopaque,
    data_ptr: [*]const u8,
    data_len: usize,
    bytes_per_row: u32,
    rows_per_image: u32,
    dst_x: u32,
    dst_y: u32,
    dst_z: u32,
    dst_mip: u32,
    dst_slice: u32,
    width: u32,
    height: u32,
    depth_or_layers: u32,
) callconv(.c) void {
    const q = cast(DoeQueue, queue_raw);
    if (q != null and q.?.dev.backend == .vulkan) {
        if (comptime has_vulkan) {
            const rt = native_rt_helpers.device_vk_runtime(q.?.dev) orelse return;
            const tex = cast(DoeTexture, texture_raw) orelse return;
            if (tex.error_object) return;
            if (tex.vk_id != 0) {
                const rows = if (rows_per_image > 0) rows_per_image else height;
                const copy_res = model_transfer_types.CopyTextureResource{
                    .handle = tex.vk_id,
                    .kind = .texture,
                    .width = tex.width,
                    .height = tex.height,
                    .depth_or_array_layers = tex.depth_or_array_layers,
                    .format = tex.format,
                    .usage = tex.usage,
                    .dimension = tex.dimension,
                    .mip_level = dst_mip,
                    .sample_count = tex.sample_count,
                    .bytes_per_row = bytes_per_row,
                    .rows_per_image = rows,
                };
                rt.texture_write(.{ .texture = copy_res, .data = data_ptr[0..data_len] }) catch |err| {
                    std.log.err("doe_command_texture_native: writeTexture Vulkan failed: {s}", .{@errorName(err)});
                };
            }
        }
        return;
    }
    const tex = cast(DoeTexture, texture_raw) orelse return;
    if (tex.error_object) return;
    _ = bridge.metal_bridge_texture_write_region(
        tex.mtl,
        @ptrCast(data_ptr),
        bytes_per_row,
        rows_per_image,
        dst_x,
        dst_y,
        dst_z,
        dst_mip,
        dst_slice,
        width,
        height,
        depth_or_layers,
    );
}
