const recording = @import("doe_command_recording.zig");
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
    const enc = createEncoder(alloc, dev) catch {
        dev.error_scopes.deliver(@import("../../runtime/diagnostics/error_scope.zig").ERROR_TYPE_OUT_OF_MEMORY, "command encoder allocation failed");
        return null;
    };
    const result = toOpaque(enc);
    if (desc) |d| label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub fn createEncoder(allocator: std.mem.Allocator, device: *DoeDevice) !*DoeCommandEncoder {
    const encoder = try native_helpers.create(DoeCommandEncoder, allocator);
    native_helpers.object_add_ref(DoeDevice, toOpaque(device));
    encoder.* = .{ .allocator = allocator, .dev = device, .device_ref = device };
    return encoder;
}

pub export fn doeNativeCommandEncoderRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeCommandEncoder, raw)) |e| {
        if (!native_helpers.object_should_destroy(e)) return;
        label_store.remove(raw);
        query_native.releaseRecordedCommandReferences(e.cmds.items);
        e.cmds.deinit(e.allocator);
        @import("../../contracts/resource_lease.zig").releaseAll(e.allocator, &e.references);
        if (e.device_ref) |dev| native_exports.doeNativeDeviceRelease(toOpaque(dev));
        const allocator = e.allocator;
        allocator.destroy(e);
    }
}

pub export fn doeNativeCommandEncoderBeginComputePass(enc_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUComputePassDescriptor) callconv(.c) ?*anyopaque {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return null;
    if (!recording.requireOpen(enc)) return null;
    const pass = native_helpers.create(DoeComputePass, enc.allocator) catch |err| {
        recording.fail(enc, err);
        return null;
    };
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
    if (!recording.requireOpen(enc)) return;
    const src = cast(DoeBuffer, src_raw) orelse return;
    const dst = cast(DoeBuffer, dst_raw) orelse return;
    if (src.error_object or dst.error_object or src.destroyed or dst.destroyed) return;
    if (!recording.reserve(enc, 0, 1)) return;
    references.retainBufferAssumeCapacity(&enc.references, src);
    if (!recording.reserve(enc, 0, 1)) return;
    references.retainBufferAssumeCapacity(&enc.references, dst);
    if (!recording.append(enc, .{ .copy_buf = .{
        .src = @ptrCast(src),
        .src_off = src_off,
        .dst = @ptrCast(dst),
        .dst_off = dst_off,
        .size = size,
    } })) return;
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
    if (!recording.requireOpen(enc)) return;
    const src_buffer = cast(DoeBuffer, src_buffer_raw) orelse return;
    const dst_texture = cast(DoeTexture, dst_texture_raw) orelse return;
    if (src_buffer.error_object or src_buffer.destroyed or dst_texture.error_object) return;
    if (!recording.reserve(enc, 0, 1)) return;
    references.retainBufferAssumeCapacity(&enc.references, src_buffer);
    if (!recording.reserve(enc, 0, 1)) return;
    references.retainTextureAssumeCapacity(&enc.references, dst_texture);
    const vulkan = enc.dev.backend == .vulkan;
    if (!recording.append(enc, .{ .copy_buffer_to_texture = .{
        .src_buffer = if (vulkan) toOpaque(src_buffer) else src_buffer.mtl,
        .src_offset = src_offset,
        .src_bytes_per_row = src_bytes_per_row,
        .src_rows_per_image = src_rows_per_image,
        .dst_texture = if (vulkan) toOpaque(dst_texture) else dst_texture.mtl,
        .dst_mip_level = dst_mip_level,
        .width = width,
        .height = height,
        .depth_or_array_layers = depth_or_array_layers,
    } })) return;
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
    if (!recording.requireOpen(enc)) return;
    const src_texture = cast(DoeTexture, src_texture_raw) orelse return;
    const dst_buffer = cast(DoeBuffer, dst_buffer_raw) orelse return;
    if (src_texture.error_object or dst_buffer.error_object or dst_buffer.destroyed) return;
    if (!recording.reserve(enc, 0, 1)) return;
    references.retainTextureAssumeCapacity(&enc.references, src_texture);
    if (!recording.reserve(enc, 0, 1)) return;
    references.retainBufferAssumeCapacity(&enc.references, dst_buffer);
    const vulkan = enc.dev.backend == .vulkan;
    if (!recording.append(enc, .{ .copy_texture_to_buffer = .{
        .src_texture = if (vulkan) @ptrCast(src_texture) else src_texture.mtl,
        .src_mip_level = src_mip_level,
        .dst_buffer = if (vulkan) @ptrCast(dst_buffer) else dst_buffer.mtl,
        .dst_offset = dst_offset,
        .dst_bytes_per_row = dst_bytes_per_row,
        .dst_rows_per_image = dst_rows_per_image,
        .width = width,
        .height = height,
        .depth_or_array_layers = depth_or_array_layers,
    } })) return;
}

pub export fn doeNativeCommandEncoderFinish(enc_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUCommandBufferDescriptor) callconv(.c) ?*anyopaque {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return null;
    const valid = recording.requireOpen(enc);
    const cb = native_helpers.create(DoeCommandBuffer, enc.allocator) catch |err| {
        recording.fail(enc, err);
        return null;
    };
    native_helpers.object_add_ref(DoeDevice, toOpaque(enc.dev));
    cb.* = .{
        .allocator = enc.allocator,
        .error_object = !valid,
        .dev = enc.dev,
        .device_ref = enc.dev,
        .cmds = enc.cmds,
        .references = enc.references,
    };
    enc.cmds = .{}; // Transfer ownership.
    enc.references = .{};
    enc.state = .finished;
    const result = toOpaque(cb);
    if (desc) |d| label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeCommandBufferRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeCommandBuffer, raw)) |cb| {
        if (!native_helpers.object_should_destroy(cb)) return;
        label_store.remove(raw);
        query_native.releaseRecordedCommandReferences(cb.cmds.items);
        cb.cmds.deinit(cb.allocator);
        @import("../../contracts/resource_lease.zig").releaseAll(cb.allocator, &cb.references);
        if (cb.device_ref) |dev| native_exports.doeNativeDeviceRelease(toOpaque(dev));
        const allocator = cb.allocator;
        allocator.destroy(cb);
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

test "render recording retains caller-released state until command buffer release" {
    const render = @import("../render/doe_render_native.zig");
    var device = DoeDevice{};
    // The fixture's extra reference observes the count after command cleanup.
    var pipeline = native_types.DoeRenderPipeline{ .ref_count = 2 };
    var group = DoeBindGroup{ .ref_count = 2 };
    var vertex = DoeBuffer{ .size = 16, .ref_count = 2 };
    var index = DoeBuffer{ .size = 16, .ref_count = 2 };
    var indirect = DoeBuffer{ .size = 16, .ref_count = 2 };
    const encoder = doeNativeDeviceCreateCommandEncoder(toOpaque(&device), null).?;
    const pass = render.doeNativeCommandEncoderBeginRenderPass(encoder, null).?;
    render.doeNativeRenderPassSetPipeline(pass, toOpaque(&pipeline));
    render.doeNativeRenderPassSetBindGroup(pass, 0, toOpaque(&group), 0, null);
    render.doeNativeRenderPassSetVertexBuffer(pass, 0, toOpaque(&vertex), 0, 16);
    render.doeNativeRenderPassSetIndexBuffer(pass, toOpaque(&index), 2, 0, 16);
    render.doeNativeRenderPassDrawIndirect(pass, toOpaque(&indirect), 0);
    native_exports.doeNativeRenderPipelineRelease(toOpaque(&pipeline));
    native_exports.doeNativeBindGroupRelease(toOpaque(&group));
    native_exports.doeNativeBufferRelease(toOpaque(&vertex));
    native_exports.doeNativeBufferRelease(toOpaque(&index));
    native_exports.doeNativeBufferRelease(toOpaque(&indirect));
    try std.testing.expectEqual(@as(u32, 2), pipeline.ref_count);
    render.doeNativeRenderPassEnd(pass);
    const commands = doeNativeCommandEncoderFinish(encoder, null).?;
    doeNativeCommandEncoderRelease(encoder);
    try std.testing.expectEqual(@as(u32, 1), cast(DoeCommandEncoder, encoder).?.ref_count);
    render.doeNativeRenderPassRelease(pass);
    try std.testing.expectEqual(@as(u32, 2), pipeline.ref_count);
    doeNativeCommandBufferRelease(commands);
    try std.testing.expectEqual(@as(u32, 1), pipeline.ref_count);
    try std.testing.expectEqual(@as(u32, 1), group.ref_count);
    try std.testing.expectEqual(@as(u32, 1), vertex.ref_count);
    try std.testing.expectEqual(@as(u32, 1), index.ref_count);
    try std.testing.expectEqual(@as(u32, 1), indirect.ref_count);
    try std.testing.expectEqual(@as(u32, 1), device.ref_count);
}

const RecordingFixture = enum { compute, render, copy, query };

fn recordingAllocationScenario(allocator: std.mem.Allocator, fixture: RecordingFixture) !void {
    const compute = @import("../compute/doe_compute_ext_native.zig");
    const render = @import("../render/doe_render_native.zig");
    var device = DoeDevice{};
    var pipeline = native_types.DoeComputePipeline{};
    var render_pipeline = native_types.DoeRenderPipeline{};
    var group = DoeBindGroup{};
    var buffer = DoeBuffer{ .size = 512 };
    var texture = DoeTexture{};
    var view = native_types.DoeTextureView{ .tex = &texture };
    var query = query_native.DoeQuerySet{ .count = 2 };
    defer {
        for ([_]u32{ device.ref_count, pipeline.ref_count, render_pipeline.ref_count, group.ref_count, buffer.ref_count, texture.ref_count, view.ref_count, query.ref_count }) |count|
            std.testing.expectEqual(@as(u32, 1), count) catch @panic("ordinary recording leaked a caller reference");
    }
    const encoder = try createEncoder(allocator, &device);
    defer doeNativeCommandEncoderRelease(toOpaque(encoder));
    const repetitions = 17;
    switch (fixture) {
        .compute => {
            const pass = doeNativeCommandEncoderBeginComputePass(toOpaque(encoder), null) orelse return error.OutOfMemory;
            defer compute.doeNativeComputePassRelease(pass);
            for (0..repetitions) |index| {
                compute.doeNativeComputePassSetPipeline(pass, toOpaque(&pipeline));
                compute.doeNativeComputePassSetBindGroup(pass, 0, toOpaque(&group), 0, null);
                compute.doeNativeComputePassDispatch(pass, @intCast(index + 1), 1, 1);
            }
            compute.doeNativeComputePassEnd(pass);
        },
        .render => {
            var attachment = std.mem.zeroes(abi_pipeline.WGPURenderPassColorAttachment);
            attachment.view = @ptrCast(&view);
            var descriptor = std.mem.zeroes(abi_pipeline.WGPURenderPassDescriptor);
            descriptor.colorAttachmentCount = 1;
            descriptor.colorAttachments = @ptrCast(&attachment);
            const pass = render.doeNativeCommandEncoderBeginRenderPass(toOpaque(encoder), &descriptor) orelse return error.OutOfMemory;
            defer render.doeNativeRenderPassRelease(pass);
            for (0..repetitions) |_| {
                render.doeNativeRenderPassSetPipeline(pass, toOpaque(&render_pipeline));
                render.doeNativeRenderPassSetBindGroup(pass, 0, toOpaque(&group), 0, null);
                render.doeNativeRenderPassSetVertexBuffer(pass, 0, toOpaque(&buffer), 0, 16);
                render.doeNativeRenderPassSetIndexBuffer(pass, toOpaque(&buffer), 2, 0, 16);
                render.doeNativeRenderPassDrawIndirect(pass, toOpaque(&buffer), 0);
            }
            render.doeNativeRenderPassEnd(pass);
        },
        .copy => for (0..repetitions) |_| {
            doeNativeCopyBufferToBuffer(toOpaque(encoder), toOpaque(&buffer), 0, toOpaque(&buffer), 16, 16);
            doeNativeCommandEncoderCopyBufferToTexture(toOpaque(encoder), toOpaque(&buffer), 0, 256, 1, toOpaque(&texture), 0, 1, 1, 1);
            doeNativeCommandEncoderCopyTextureToBuffer(toOpaque(encoder), toOpaque(&texture), 0, toOpaque(&buffer), 0, 256, 1, 1, 1, 1);
        },
        .query => for (0..repetitions) |_| {
            query_native.doeNativeCommandEncoderWriteTimestamp(toOpaque(encoder), toOpaque(&query), 0);
            query_native.doeNativeCommandEncoderResolveQuerySet(toOpaque(encoder), toOpaque(&query), 0, 1, toOpaque(&buffer), 0);
        },
    }
    if (encoder.state == .failed) return encoder.state.failed;
    const commands = doeNativeCommandEncoderFinish(toOpaque(encoder), null) orelse return error.OutOfMemory;
    defer doeNativeCommandBufferRelease(commands);
    try std.testing.expect(!cast(DoeCommandBuffer, commands).?.error_object);
    try std.testing.expect(cast(DoeCommandBuffer, commands).?.cmds.items.len >= repetitions);
}

test "ordinary command recording cleans up every allocation failure across command families" {
    for (std.enums.values(RecordingFixture)) |fixture|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, recordingAllocationScenario, .{fixture});
}

test "failed recording finishes as an error object and cannot submit or resume" {
    const errors = @import("../../runtime/diagnostics/error_scope.zig");
    const Capture = struct {
        kind: u32 = errors.ERROR_TYPE_NO_ERROR,
        fn receive(kind: u32, _: @import("../../core/abi/wgpu_handle_types.zig").WGPUStringView, userdata: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.kind = kind;
        }
    };
    var device = DoeDevice{};
    var queue = native_types.DoeQueue{ .dev = &device };
    var buffer = DoeBuffer{ .size = 32 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const encoder = try createEncoder(failing.allocator(), &device);
    defer doeNativeCommandEncoderRelease(toOpaque(encoder));
    device.error_scopes.push(errors.FILTER_OUT_OF_MEMORY);
    failing.fail_index = failing.alloc_index;
    doeNativeCopyBufferToBuffer(toOpaque(encoder), toOpaque(&buffer), 0, toOpaque(&buffer), 16, 16);
    try std.testing.expectEqual(error.OutOfMemory, encoder.state.failed);
    var capture = Capture{};
    try std.testing.expect(device.error_scopes.pop(.{ .callback = Capture.receive, .userdata1 = &capture }));
    try std.testing.expectEqual(errors.ERROR_TYPE_OUT_OF_MEMORY, capture.kind);
    failing.fail_index = std.math.maxInt(usize);
    const invalid = doeNativeCommandEncoderFinish(toOpaque(encoder), null).?;
    defer doeNativeCommandBufferRelease(invalid);
    try std.testing.expect(cast(DoeCommandBuffer, invalid).?.error_object);
    const valid_encoder = try createEncoder(std.testing.allocator, &device);
    defer doeNativeCommandEncoderRelease(toOpaque(valid_encoder));
    const valid = doeNativeCommandEncoderFinish(toOpaque(valid_encoder), null).?;
    defer doeNativeCommandBufferRelease(valid);
    device.error_scopes.push(errors.FILTER_VALIDATION);
    const submitted = [_]?*anyopaque{ valid, invalid };
    @import("../queue/doe_queue_submit_native.zig").doeNativeQueueSubmit(toOpaque(&queue), submitted.len, &submitted);
    try std.testing.expect(device.error_scopes.pop(.{ .callback = Capture.receive, .userdata1 = &capture }));
    try std.testing.expectEqual(errors.ERROR_TYPE_VALIDATION, capture.kind);
    doeNativeCopyBufferToBuffer(toOpaque(valid_encoder), toOpaque(&buffer), 0, toOpaque(&buffer), 16, 16);
    try std.testing.expectEqual(error.InvalidState, valid_encoder.state.failed);
    try std.testing.expectEqual(@as(usize, 0), valid_encoder.cmds.items.len);
    try std.testing.expectEqual(@as(u32, 1), buffer.ref_count);
}
