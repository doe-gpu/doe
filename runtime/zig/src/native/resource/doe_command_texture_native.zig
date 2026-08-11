// doe_command_texture_native.zig — clearBuffer, copyTextureToTexture, writeTexture C-ABI exports.
// Sharded from doe_wgpu_native.zig to keep texture command concerns cohesive.

const std = @import("std");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const resource_ops = @import("../../backend/dropin_resource_ops.zig");
const bridge = resource_ops.metal_bridge;

const alloc = native_helpers.alloc;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;

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
    if (resource_ops.handleVulkanClearBuffer(enc, buf, offset, fill_size)) {
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
    enc.cmds.append(alloc, .{ .copy_texture_to_texture = .{
        .src_texture = if (enc.dev.backend == .vulkan) toOpaque(src) else src.mtl,
        .src_mip = src_mip,
        .src_slice = src_slice,
        .src_x = src_x,
        .src_y = src_y,
        .src_z = src_z,
        .dst_texture = if (enc.dev.backend == .vulkan) toOpaque(dst) else dst.mtl,
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
    const tex = cast(DoeTexture, texture_raw) orelse return;
    if (tex.error_object) return;
    if (resource_ops.handleVulkanQueueWriteTexture(q, tex, .{
        .data_ptr = data_ptr,
        .data_len = data_len,
        .bytes_per_row = bytes_per_row,
        .rows_per_image = rows_per_image,
        .dst_mip = dst_mip,
        .height = height,
    })) {
        return;
    }
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
