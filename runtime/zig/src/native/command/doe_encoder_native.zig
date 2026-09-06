// doe_encoder_native.zig — Bind group layout, bind group, pipeline layout,
// command encoder, and command buffer exports for Doe native Metal backend.
// Sharded from doe_wgpu_native.zig to stay under the line-limit policy.

const std = @import("std");
const abi_pipeline = @import("../../core/abi/wgpu_pipeline_descriptor_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const query_native = @import("../resource/doe_query_native.zig");
const references = @import("doe_command_references.zig");
const native_exports = @import("../support/doe_native_exports.zig");
const resource_ops = @import("../../backend/dropin_resource_ops.zig");

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
    native_helpers.object_add_ref(DoeDevice, dev_raw);
    enc.* = .{ .dev = dev, .device_ref = dev };
    const result = toOpaque(enc);
    if (desc) |d| label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeCommandEncoderRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeCommandEncoder, raw)) |e| {
        if (!native_helpers.object_should_destroy(e)) return;
        label_store.remove(raw);
        query_native.releaseRecordedCommandReferences(e.cmds.items);
        e.cmds.deinit(alloc);
        references.releaseAll(&e.references);
        if (e.device_ref) |dev| native_exports.doeNativeDeviceRelease(toOpaque(dev));
        alloc.destroy(e);
    }
}

pub export fn doeNativeCommandEncoderBeginComputePass(enc_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUComputePassDescriptor) callconv(.c) ?*anyopaque {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return null;
    const pass = make(DoeComputePass) orelse return null;
    var timestamp_end_query_set: ?*anyopaque = null;
    var timestamp_end_write_index = native_types.UNUSED_PASS_TIMESTAMP_WRITE_INDEX;
    if (desc) |d| {
        if (d.timestampWrites != null) {
            const timestamp_writes: *const abi_pipeline.WGPUPassTimestampWrites = @ptrCast(d.timestampWrites);
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
    native_helpers.object_add_ref(DoeCommandEncoder, enc_raw);
    pass.* = .{
        .enc = enc,
        .owns_encoder = true,
        .timestamp_end_query_set = timestamp_end_query_set,
        .timestamp_end_write_index = timestamp_end_write_index,
    };
    return toOpaque(pass);
}

pub export fn doeNativeCopyBufferToBuffer(enc_raw: ?*anyopaque, src_raw: ?*anyopaque, src_off: u64, dst_raw: ?*anyopaque, dst_off: u64, size: u64) callconv(.c) void {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return;
    const src = cast(DoeBuffer, src_raw) orelse return;
    const dst = cast(DoeBuffer, dst_raw) orelse return;
    if (src.error_object or dst.error_object or src.destroyed or dst.destroyed) return;
    references.retainBuffer(&enc.references, src);
    references.retainBuffer(&enc.references, dst);
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
    if (src_buffer.error_object or src_buffer.destroyed or dst_texture.error_object) return;
    references.retainBuffer(&enc.references, src_buffer);
    references.retainTexture(&enc.references, dst_texture);
    if (resource_ops.handleVulkanCopyBufferToTexture(
        enc,
        src_buffer,
        src_offset,
        src_bytes_per_row,
        src_rows_per_image,
        dst_texture,
        dst_mip_level,
        width,
        height,
        depth_or_array_layers,
    )) {
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
    if (src_texture.error_object or dst_buffer.error_object or dst_buffer.destroyed) return;
    references.retainTexture(&enc.references, src_texture);
    references.retainBuffer(&enc.references, dst_buffer);
    const vulkan = enc.dev.backend == .vulkan;
    enc.cmds.append(alloc, .{ .copy_texture_to_buffer = .{
        .src_texture = if (vulkan) @ptrCast(src_texture) else src_texture.mtl,
        .src_mip_level = src_mip_level,
        .dst_buffer = if (vulkan) @ptrCast(dst_buffer) else dst_buffer.mtl,
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
    native_helpers.object_add_ref(DoeDevice, toOpaque(enc.dev));
    cb.* = .{
        .dev = enc.dev,
        .device_ref = enc.dev,
        .cmds = enc.cmds,
        .references = enc.references,
    };
    enc.cmds = .{}; // Transfer ownership.
    enc.references = .{};
    const result = toOpaque(cb);
    if (desc) |d| label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeCommandBufferRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeCommandBuffer, raw)) |cb| {
        if (!native_helpers.object_should_destroy(cb)) return;
        label_store.remove(raw);
        query_native.releaseRecordedCommandReferences(cb.cmds.items);
        cb.cmds.deinit(alloc);
        references.releaseAll(&cb.references);
        if (cb.device_ref) |dev| native_exports.doeNativeDeviceRelease(toOpaque(dev));
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

test "recorded copies transfer resource ownership to command buffers" {
    var device = DoeDevice{};
    var source = DoeBuffer{ .size = 16 };
    var destination = DoeBuffer{ .size = 16 };
    const encoder = doeNativeDeviceCreateCommandEncoder(toOpaque(&device), null).?;
    doeNativeCopyBufferToBuffer(encoder, toOpaque(&source), 0, toOpaque(&destination), 0, 16);
    try std.testing.expectEqual(@as(u32, 2), source.ref_count);
    try std.testing.expectEqual(@as(u32, 2), destination.ref_count);
    const commands = doeNativeCommandEncoderFinish(encoder, null).?;
    doeNativeCommandEncoderRelease(encoder);
    try std.testing.expectEqual(@as(u32, 2), source.ref_count);
    try std.testing.expectEqual(@as(u32, 2), device.ref_count);
    doeNativeCommandBufferRelease(commands);
    try std.testing.expectEqual(@as(u32, 1), source.ref_count);
    try std.testing.expectEqual(@as(u32, 1), destination.ref_count);
    try std.testing.expectEqual(@as(u32, 1), device.ref_count);
}

test "abandoned encoder releases resources without finishing" {
    var device = DoeDevice{};
    var buffer = DoeBuffer{ .size = 16 };
    const encoder = doeNativeDeviceCreateCommandEncoder(toOpaque(&device), null).?;
    doeNativeCopyBufferToBuffer(encoder, toOpaque(&buffer), 0, toOpaque(&buffer), 0, 16);
    try std.testing.expectEqual(@as(u32, 3), buffer.ref_count);
    doeNativeCommandEncoderRelease(encoder);
    try std.testing.expectEqual(@as(u32, 1), buffer.ref_count);
    try std.testing.expectEqual(@as(u32, 1), device.ref_count);
}

test "compute pass pins encoder and transferred pipeline and binding state" {
    const compute = @import("../compute/doe_compute_ext_native.zig");
    var device = DoeDevice{};
    var pipeline = native_types.DoeComputePipeline{};
    var first_group = DoeBindGroup{};
    var second_group = DoeBindGroup{};
    const encoder = doeNativeDeviceCreateCommandEncoder(toOpaque(&device), null).?;
    const pass = doeNativeCommandEncoderBeginComputePass(encoder, null).?;
    compute.doeNativeComputePassSetPipeline(pass, toOpaque(&pipeline));
    compute.doeNativeComputePassSetBindGroup(pass, 0, toOpaque(&first_group), 0, null);
    compute.doeNativeComputePassDispatch(pass, 1, 1, 1);
    compute.doeNativeComputePassSetBindGroup(pass, 0, toOpaque(&second_group), 0, null);
    compute.doeNativeComputePassDispatch(pass, 1, 1, 1);
    compute.doeNativeComputePassEnd(pass);
    const commands = doeNativeCommandEncoderFinish(encoder, null).?;
    doeNativeCommandEncoderRelease(encoder);
    try std.testing.expectEqual(@as(u32, 1), cast(DoeCommandEncoder, encoder).?.ref_count);
    compute.doeNativeComputePassRelease(pass);
    try std.testing.expectEqual(@as(u32, 2), pipeline.ref_count);
    try std.testing.expectEqual(@as(u32, 2), first_group.ref_count);
    try std.testing.expectEqual(@as(u32, 2), second_group.ref_count);
    doeNativeCommandBufferRelease(commands);
    try std.testing.expectEqual(@as(u32, 1), pipeline.ref_count);
    try std.testing.expectEqual(@as(u32, 1), first_group.ref_count);
    try std.testing.expectEqual(@as(u32, 1), second_group.ref_count);
    try std.testing.expectEqual(@as(u32, 1), device.ref_count);
}
