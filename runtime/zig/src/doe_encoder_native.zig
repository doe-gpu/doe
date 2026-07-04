// doe_encoder_native.zig — Bind group layout, bind group, pipeline layout,
// command encoder, and command buffer exports for Doe native Metal backend.
// Sharded from doe_wgpu_native.zig to stay under the line-limit policy.

const builtin = @import("builtin");
const has_vulkan = (builtin.os.tag == .linux);
const std = @import("std");
const model_transfer_types = @import("model_resource_types.zig");
const abi_pipeline = @import("core/abi/wgpu_pipeline_descriptor_types.zig");
const native_types = @import("doe_native_object_types.zig");
const native_shared = @import("doe_native_shared_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const native_rt_helpers = @import("doe_native_runtime_helpers.zig");
const query_native = @import("doe_query_native.zig");

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const MAX_BIND = native_shared.MAX_BIND;
const label_store = native_helpers.label_store;

const DoeDevice = native_types.DoeDevice;
const DoeBuffer = native_types.DoeBuffer;
const DoeBindGroup = native_types.DoeBindGroup;
const DoeCommandEncoder = native_types.DoeCommandEncoder;
const DoeCommandBuffer = native_types.DoeCommandBuffer;
const DoeComputePass = native_types.DoeComputePass;
const DoeTexture = native_types.DoeTexture;

// ============================================================
// Command Encoder / Command Buffer

pub export fn doeNativeDeviceCreateCommandEncoder(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUCommandEncoderDescriptor) callconv(.c) ?*anyopaque {
    const dev = cast(DoeDevice, dev_raw) orelse return null;
    const enc = make(DoeCommandEncoder) orelse return null;
    enc.* = .{ .dev = dev };
    const result = toOpaque(enc);
    if (desc) |d| label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeCommandEncoderRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeCommandEncoder, raw)) |e| {
        if (!native_helpers.object_should_destroy(e)) return;
        label_store.remove(raw);
        e.cmds.deinit(alloc);
        alloc.destroy(e);
    }
}

pub export fn doeNativeCommandEncoderBeginComputePass(enc_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUComputePassDescriptor) callconv(.c) ?*anyopaque {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return null;
    const pass = make(DoeComputePass) orelse return null;
    var timestamp_end_query_set: ?*anyopaque = null;
    var timestamp_end_write_index = native_types.UNUSED_PASS_TIMESTAMP_WRITE_INDEX;
    if (desc) |d| {
        if (d.timestampWrites) |timestamp_writes| {
            if (cast(query_native.DoeQuerySet, timestamp_writes.querySet)) |query_set| {
                const query_set_raw = toOpaque(query_set);
                if (timestamp_writes.beginningOfPassWriteIndex != native_types.UNUSED_PASS_TIMESTAMP_WRITE_INDEX) {
                    query_native.doeNativeCommandEncoderWriteTimestampWithPosition(
                        enc_raw,
                        query_set_raw,
                        timestamp_writes.beginningOfPassWriteIndex,
                        .pass_begin,
                    );
                }
                if (timestamp_writes.endOfPassWriteIndex != native_types.UNUSED_PASS_TIMESTAMP_WRITE_INDEX) {
                    native_helpers.object_add_ref(query_native.DoeQuerySet, query_set_raw);
                    timestamp_end_query_set = query_set_raw;
                    timestamp_end_write_index = timestamp_writes.endOfPassWriteIndex;
                }
            }
        }
    }
    pass.* = .{
        .enc = enc,
        .timestamp_end_query_set = timestamp_end_query_set,
        .timestamp_end_write_index = timestamp_end_write_index,
    };
    return toOpaque(pass);
}

pub export fn doeNativeCopyBufferToBuffer(enc_raw: ?*anyopaque, src_raw: ?*anyopaque, src_off: u64, dst_raw: ?*anyopaque, dst_off: u64, size: u64) callconv(.c) void {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return;
    const src = cast(DoeBuffer, src_raw) orelse return;
    const dst = cast(DoeBuffer, dst_raw) orelse return;
    if (src.error_object or dst.error_object) return;
    enc.cmds.append(alloc, .{ .copy_buf = .{
        .src = @ptrCast(src),
        .src_off = src_off,
        .dst = @ptrCast(dst),
        .dst_off = dst_off,
        .size = size,
    } }) catch std.debug.panic("doe_encoder_native: OOM recording copy command", .{});
}

pub export fn doeNativeCommandEncoderCopyBufferToTexture(
    enc_raw: ?*anyopaque,
    src_buffer_raw: ?*anyopaque,
    src_offset: u64,
    src_bytes_per_row: u32,
    src_rows_per_image: u32,
    dst_texture_raw: ?*anyopaque,
    dst_mip_level: u32,
    width: u32,
    height: u32,
    depth_or_array_layers: u32,
) callconv(.c) void {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return;
    const src_buffer = cast(DoeBuffer, src_buffer_raw) orelse return;
    const dst_texture = cast(DoeTexture, dst_texture_raw) orelse return;
    if (src_buffer.error_object or dst_texture.error_object) return;
    if (enc.dev.backend == .vulkan) {
        if (comptime has_vulkan) {
            const rt = native_rt_helpers.device_vk_runtime(enc.dev) orelse return;
            if (src_buffer.vk_id != 0 and dst_texture.vk_id != 0) {
                if (rt.compute_buffers.get(src_buffer.vk_id)) |scb| {
                    if (scb.mapped) |mapped_ptr| {
                        const rows = if (src_rows_per_image > 0) src_rows_per_image else height;
                        const byte_count: usize = @intCast(@as(u64, src_bytes_per_row) * rows * depth_or_array_layers);
                        const base_off: usize = @intCast(src_offset);
                        const raw: [*]const u8 = @ptrCast(mapped_ptr);
                        const copy_res = model_transfer_types.CopyTextureResource{
                            .handle = dst_texture.vk_id,
                            .kind = .texture,
                            .width = dst_texture.width,
                            .height = dst_texture.height,
                            .depth_or_array_layers = dst_texture.depth_or_array_layers,
                            .format = dst_texture.format,
                            .usage = dst_texture.usage,
                            .dimension = dst_texture.dimension,
                            .mip_level = dst_mip_level,
                            .sample_count = dst_texture.sample_count,
                            .bytes_per_row = src_bytes_per_row,
                            .rows_per_image = rows,
                        };
                        rt.texture_write(.{ .texture = copy_res, .data = raw[base_off .. base_off + byte_count] }) catch |err| {
                            std.log.err("doe_encoder_native: copyBufferToTexture Vulkan failed: {s}", .{@errorName(err)});
                        };
                    }
                }
            }
        }
        return;
    }
    enc.cmds.append(alloc, .{ .copy_buffer_to_texture = .{
        .src_buffer = src_buffer.mtl,
        .src_offset = src_offset,
        .src_bytes_per_row = src_bytes_per_row,
        .src_rows_per_image = src_rows_per_image,
        .dst_texture = dst_texture.mtl,
        .dst_mip_level = dst_mip_level,
        .width = width,
        .height = height,
        .depth_or_array_layers = depth_or_array_layers,
    } }) catch std.debug.panic("doe_encoder_native: OOM recording buffer-to-texture copy command", .{});
}

pub export fn doeNativeCommandEncoderCopyTextureToBuffer(
    enc_raw: ?*anyopaque,
    src_texture_raw: ?*anyopaque,
    src_mip_level: u32,
    dst_buffer_raw: ?*anyopaque,
    dst_offset: u64,
    dst_bytes_per_row: u32,
    dst_rows_per_image: u32,
    width: u32,
    height: u32,
    depth_or_array_layers: u32,
) callconv(.c) void {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return;
    const src_texture = cast(DoeTexture, src_texture_raw) orelse return;
    const dst_buffer = cast(DoeBuffer, dst_buffer_raw) orelse return;
    if (src_texture.error_object or dst_buffer.error_object) return;
    if (enc.dev.backend == .vulkan) {
        if (comptime has_vulkan) {
            const rt = native_rt_helpers.device_vk_runtime(enc.dev) orelse return;
            if (src_texture.vk_id != 0 and dst_buffer.vk_id != 0) {
                if (rt.compute_buffers.get(dst_buffer.vk_id)) |dcb| {
                    if (dcb.mapped) |mapped_ptr| {
                        rt.texture_read(.{
                            .handle = src_texture.vk_id,
                            .mip_level = src_mip_level,
                            .width = width,
                            .height = height,
                            .format = src_texture.format,
                            .dst_buffer = @as(*anyopaque, @ptrCast(mapped_ptr)),
                            .dst_offset = dst_offset,
                            .dst_bytes_per_row = dst_bytes_per_row,
                            .dst_rows_per_image = dst_rows_per_image,
                        }) catch |err| {
                            std.log.err("doe_encoder_native: copyTextureToBuffer Vulkan failed: {s}", .{@errorName(err)});
                        };
                    }
                }
            }
        }
        return;
    }
    enc.cmds.append(alloc, .{ .copy_texture_to_buffer = .{
        .src_texture = src_texture.mtl,
        .src_mip_level = src_mip_level,
        .dst_buffer = dst_buffer.mtl,
        .dst_offset = dst_offset,
        .dst_bytes_per_row = dst_bytes_per_row,
        .dst_rows_per_image = dst_rows_per_image,
        .width = width,
        .height = height,
        .depth_or_array_layers = depth_or_array_layers,
    } }) catch std.debug.panic("doe_encoder_native: OOM recording texture copy command", .{});
}

pub export fn doeNativeCommandEncoderFinish(enc_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUCommandBufferDescriptor) callconv(.c) ?*anyopaque {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return null;
    const cb = make(DoeCommandBuffer) orelse return null;
    cb.* = .{ .dev = enc.dev, .cmds = enc.cmds };
    enc.cmds = .{}; // Transfer ownership.
    const result = toOpaque(cb);
    if (desc) |d| label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeCommandBufferRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeCommandBuffer, raw)) |cb| {
        if (!native_helpers.object_should_destroy(cb)) return;
        label_store.remove(raw);
        cb.cmds.deinit(alloc);
        alloc.destroy(cb);
    }
}

// ============================================================
// Debug markers — no-ops in headless runtime; symbols required for API surface completeness.
// ============================================================

pub export fn doeNativeCommandEncoderInsertDebugMarker(
    _: ?*anyopaque,
    _: ?[*]const u8,
    _: usize,
) callconv(.c) void {}

pub export fn doeNativeCommandEncoderPushDebugGroup(
    _: ?*anyopaque,
    _: ?[*]const u8,
    _: usize,
) callconv(.c) void {}

pub export fn doeNativeCommandEncoderPopDebugGroup(
    _: ?*anyopaque,
) callconv(.c) void {}
