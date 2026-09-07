// doe_bundle_native.zig — C ABI exports for GPURenderBundle and GPURenderBundleEncoder.
// Sharded from doe_wgpu_native.zig to stay under the line-limit policy.

const std = @import("std");
const error_scope = @import("../../runtime/diagnostics/error_scope.zig");
const abi_texture = @import("../../core/abi/wgpu_texture_base_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_cmds = @import("../support/doe_native_command_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const references = @import("../command/doe_command_references.zig");
const leases = @import("../../contracts/resource_lease.zig");
const recording = @import("../command/doe_command_recording.zig");
const recording_contract = @import("../../contracts/command_recording.zig");
const bundle = @import("../../runtime/render/render_bundle.zig");

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const DoeDevice = native_types.DoeDevice;
const DoeBuffer = native_types.DoeBuffer;
const DoeRenderPipeline = native_types.DoeRenderPipeline;
const DoeBindGroup = native_types.DoeBindGroup;
const DoeBindGroupLayout = native_types.DoeBindGroupLayout;
const DoeRenderPass = native_types.DoeRenderPass;

const RenderBundleEncoderDescriptor = @import("../../full/render/wgpu_render_types.zig").RenderBundleEncoderDescriptor;
const RenderBundleDescriptor = @import("../../full/render/wgpu_render_types.zig").RenderBundleDescriptor;

// ============================================================
// Device: createRenderBundleEncoder
// ============================================================

pub export fn doeNativeDeviceCreateRenderBundleEncoder(
    dev_raw: ?*anyopaque,
    desc: ?*const RenderBundleEncoderDescriptor,
) callconv(.c) ?*anyopaque {
    const dev = cast(DoeDevice, dev_raw) orelse return null;
    const d = desc orelse return null;

    const color_fmt: abi_texture.WGPUTextureFormat = if (d.colorFormatCount > 0)
        d.colorFormats[0]
    else
        0;

    const enc = bundle.make_bundle_encoder(
        alloc,
        color_fmt,
        d.depthStencilFormat,
        if (d.sampleCount == 0) 1 else d.sampleCount,
        d.depthReadOnly != 0,
        d.stencilReadOnly != 0,
    ) orelse {
        dev.error_scopes.deliver(error_scope.ERROR_TYPE_OUT_OF_MEMORY, "render bundle encoder allocation failed");
        return null;
    };
    enc.backend = dev.backend;
    native_helpers.object_add_ref(DoeDevice, dev_raw);
    enc.device_lease = .{ .handle = dev_raw, .release = @import("../support/doe_native_exports.zig").doeNativeDeviceRelease };
    return @ptrCast(enc);
}

pub export fn doeNativeRenderBundleEncoderRelease(raw: ?*anyopaque) callconv(.c) void {
    const enc = bundle.cast_bundle_encoder(raw) orelse return;
    if (!native_helpers.object_should_destroy(enc)) return;
    leases.releaseAll(enc.allocator, &enc.references);
    if (enc.device_lease) |lease| lease.release(lease.handle);
    native_helpers.label_store.remove(raw);
    const a = enc.allocator;
    enc.cmds.deinit(a);
    a.destroy(enc);
}

fn failBundle(encoder: *bundle.DoeBundleEncoder, cause: recording_contract.Failure) void {
    _ = encoder.state.fail(cause);
    if (encoder.device_lease) |lease| {
        const device = cast(DoeDevice, lease.handle) orelse return;
        device.error_scopes.deliver(error_scope.zig_error_to_type(cause), switch (cause) {
            error.OutOfMemory => "render bundle recording could not allocate owned storage",
            error.InvalidState => "render bundle recording requires an open encoder",
            error.InvalidArgument => "render bundle recording received an invalid dependency",
        });
    }
}

fn requireBundleOpen(encoder: *bundle.DoeBundleEncoder) bool {
    if (encoder.state == .open) return true;
    if (encoder.state == .finished) failBundle(encoder, error.InvalidState);
    return false;
}

fn reserveBundleReferences(encoder: *bundle.DoeBundleEncoder, count: usize) bool {
    if (!requireBundleOpen(encoder)) return false;
    encoder.references.ensureUnusedCapacity(encoder.allocator, count) catch |err| {
        failBundle(encoder, err);
        return false;
    };
    return true;
}

// ============================================================
// Bundle encoder: record commands
// ============================================================

pub export fn doeNativeRenderBundleEncoderSetPipeline(
    enc_raw: ?*anyopaque,
    pip_raw: ?*anyopaque,
) callconv(.c) void {
    const enc = bundle.cast_bundle_encoder(enc_raw) orelse return;
    if (!requireBundleOpen(enc)) return;
    const pip = cast(DoeRenderPipeline, pip_raw) orelse return;
    if (!reserveBundleReferences(enc, 1)) return;
    references.retainRenderPipelineAssumeCapacity(&enc.references, pip);
    const pipeline_handle = if (enc.backend == .vulkan) toOpaque(pip) else pip.mtl_pso;
    bundle.bundle_encoder_push(enc, .{ .set_pipeline = .{
        .pipeline_handle = pipeline_handle,
        .pipeline_object_handle = toOpaque(pip),
    } }) catch |err| return failBundle(enc, err);
}

pub export fn doeNativeRenderBundleEncoderSetBindGroup(
    enc_raw: ?*anyopaque,
    group_index: u32,
    bg_raw: ?*anyopaque,
    dynamic_offset_count: usize,
    dynamic_offsets: ?[*]const u32,
) callconv(.c) void {
    _ = dynamic_offset_count;
    _ = dynamic_offsets;
    const enc = bundle.cast_bundle_encoder(enc_raw) orelse return;
    if (!requireBundleOpen(enc)) return;
    const bg = cast(DoeBindGroup, bg_raw) orelse return;
    if (!reserveBundleReferences(enc, 1)) return;
    references.retainBindGroupAssumeCapacity(&enc.references, bg);

    var bg_entry = bundle.BundleBindGroup{
        .entries = undefined,
        .count = bg.count,
    };
    const copy_count = @min(@as(usize, bg.count), bundle.MAX_BINDINGS_PER_GROUP);
    for (0..copy_count) |i| {
        bg_entry.entries[i] = .{
            .handle = bg.buffers[i],
            .offset = bg.offsets[i],
        };
    }
    bundle.bundle_encoder_push(enc, .{ .set_bind_group = .{
        .group = group_index,
        .bg_handle = if (enc.backend == .vulkan) toOpaque(bg) else null,
        .bg = bg_entry,
    } }) catch |err| return failBundle(enc, err);
}

pub export fn doeNativeRenderBundleEncoderSetVertexBuffer(
    enc_raw: ?*anyopaque,
    slot: u32,
    buf_raw: ?*anyopaque,
    offset: u64,
    size: u64,
) callconv(.c) void {
    const enc = bundle.cast_bundle_encoder(enc_raw) orelse return;
    if (!requireBundleOpen(enc)) return;
    const buf = cast(DoeBuffer, buf_raw) orelse return;
    if (buf.error_object) return;
    if (!reserveBundleReferences(enc, 1)) return;
    references.retainBufferAssumeCapacity(&enc.references, buf);
    const buffer_handle = if (enc.backend == .vulkan) toOpaque(buf) else buf.mtl;
    bundle.bundle_encoder_push(enc, .{ .set_vertex_buffer = .{
        .slot = slot,
        .buffer_handle = buffer_handle,
        .offset = offset,
        .size = size,
    } }) catch |err| return failBundle(enc, err);
}

pub export fn doeNativeRenderBundleEncoderSetIndexBuffer(
    enc_raw: ?*anyopaque,
    buf_raw: ?*anyopaque,
    format: u32,
    offset: u64,
    size: u64,
) callconv(.c) void {
    const enc = bundle.cast_bundle_encoder(enc_raw) orelse return;
    if (!requireBundleOpen(enc)) return;
    const buf = cast(DoeBuffer, buf_raw) orelse return;
    if (buf.error_object) return;
    if (!reserveBundleReferences(enc, 1)) return;
    references.retainBufferAssumeCapacity(&enc.references, buf);
    const buffer_handle = if (enc.backend == .vulkan) toOpaque(buf) else buf.mtl;
    bundle.bundle_encoder_push(enc, .{ .set_index_buffer = .{
        .buffer_handle = buffer_handle,
        .format = format,
        .offset = offset,
        .size = size,
    } }) catch |err| return failBundle(enc, err);
}

pub export fn doeNativeRenderBundleEncoderDraw(
    enc_raw: ?*anyopaque,
    vertex_count: u32,
    instance_count: u32,
    first_vertex: u32,
    first_instance: u32,
) callconv(.c) void {
    const enc = bundle.cast_bundle_encoder(enc_raw) orelse return;
    if (!requireBundleOpen(enc)) return;
    bundle.bundle_encoder_push(enc, .{ .draw = .{
        .vertex_count = vertex_count,
        .instance_count = instance_count,
        .first_vertex = first_vertex,
        .first_instance = first_instance,
    } }) catch |err| return failBundle(enc, err);
}

pub export fn doeNativeRenderBundleEncoderDrawIndexed(
    enc_raw: ?*anyopaque,
    index_count: u32,
    instance_count: u32,
    first_index: u32,
    base_vertex: i32,
    first_instance: u32,
) callconv(.c) void {
    const enc = bundle.cast_bundle_encoder(enc_raw) orelse return;
    if (!requireBundleOpen(enc)) return;
    bundle.bundle_encoder_push(enc, .{ .draw_indexed = .{
        .index_count = index_count,
        .instance_count = instance_count,
        .first_index = first_index,
        .base_vertex = base_vertex,
        .first_instance = first_instance,
    } }) catch |err| return failBundle(enc, err);
}

pub export fn doeNativeRenderBundleEncoderDrawIndirect(
    enc_raw: ?*anyopaque,
    indirect_buf_raw: ?*anyopaque,
    indirect_offset: u64,
) callconv(.c) void {
    const enc = bundle.cast_bundle_encoder(enc_raw) orelse return;
    if (!requireBundleOpen(enc)) return;
    const ibuf = cast(DoeBuffer, indirect_buf_raw) orelse return;
    if (ibuf.error_object) return;
    if (!reserveBundleReferences(enc, 1)) return;
    references.retainBufferAssumeCapacity(&enc.references, ibuf);
    const buffer_handle = if (enc.backend == .vulkan) toOpaque(ibuf) else ibuf.mtl;
    bundle.bundle_encoder_push(enc, .{ .draw_indirect = .{
        .indirect_buffer = buffer_handle,
        .indirect_offset = indirect_offset,
    } }) catch |err| return failBundle(enc, err);
}

pub export fn doeNativeRenderBundleEncoderDrawIndexedIndirect(
    enc_raw: ?*anyopaque,
    indirect_buf_raw: ?*anyopaque,
    indirect_offset: u64,
) callconv(.c) void {
    const enc = bundle.cast_bundle_encoder(enc_raw) orelse return;
    if (!requireBundleOpen(enc)) return;
    const ibuf = cast(DoeBuffer, indirect_buf_raw) orelse return;
    if (ibuf.error_object) return;
    if (!reserveBundleReferences(enc, 1)) return;
    references.retainBufferAssumeCapacity(&enc.references, ibuf);
    const buffer_handle = if (enc.backend == .vulkan) toOpaque(ibuf) else ibuf.mtl;
    bundle.bundle_encoder_push(enc, .{ .draw_indexed_indirect = .{
        .indirect_buffer = buffer_handle,
        .indirect_offset = indirect_offset,
    } }) catch |err| return failBundle(enc, err);
}

// ============================================================
// Bundle encoder: finish → GPURenderBundle
// ============================================================

pub export fn doeNativeRenderBundleEncoderFinish(
    enc_raw: ?*anyopaque,
    desc: ?*const RenderBundleDescriptor,
) callconv(.c) ?*anyopaque {
    _ = desc;
    const enc = bundle.cast_bundle_encoder(enc_raw) orelse return null;
    _ = requireBundleOpen(enc);
    const b = bundle.bundle_encoder_finish(enc) orelse {
        failBundle(enc, error.OutOfMemory);
        return null;
    };
    if (enc.device_lease) |lease| {
        native_helpers.object_add_ref(DoeDevice, lease.handle);
        b.device_lease = lease;
    }
    return @ptrCast(b);
}

pub export fn doeNativeRenderBundleRelease(raw: ?*anyopaque) callconv(.c) void {
    const b = bundle.cast_bundle(raw) orelse return;
    if (!native_helpers.object_should_destroy(b)) return;
    native_helpers.label_store.remove(raw);
    bundle.destroyReleasedBundle(b);
}

fn bundleAllocationScenario(allocator: std.mem.Allocator) !void {
    var device = DoeDevice{};
    var pipeline = DoeRenderPipeline{};
    var group = DoeBindGroup{};
    var buffer = DoeBuffer{ .size = 64 };
    defer {
        for ([_]u32{ device.ref_count, pipeline.ref_count, group.ref_count, buffer.ref_count }) |count|
            std.testing.expectEqual(@as(u32, 1), count) catch @panic("bundle recording leaked a caller reference");
    }
    const encoder = bundle.make_bundle_encoder(allocator, 0, 0, 1, false, false) orelse return error.OutOfMemory;
    native_helpers.object_add_ref(DoeDevice, toOpaque(&device));
    encoder.device_lease = .{ .handle = toOpaque(&device), .release = @import("../support/doe_native_exports.zig").doeNativeDeviceRelease };
    defer doeNativeRenderBundleEncoderRelease(toOpaque(encoder));
    const repetitions = 17;
    for (0..repetitions) |_| {
        doeNativeRenderBundleEncoderSetPipeline(toOpaque(encoder), toOpaque(&pipeline));
        doeNativeRenderBundleEncoderSetBindGroup(toOpaque(encoder), 0, toOpaque(&group), 0, null);
        doeNativeRenderBundleEncoderSetVertexBuffer(toOpaque(encoder), 0, toOpaque(&buffer), 0, 16);
        doeNativeRenderBundleEncoderSetIndexBuffer(toOpaque(encoder), toOpaque(&buffer), 2, 0, 16);
        doeNativeRenderBundleEncoderDrawIndirect(toOpaque(encoder), toOpaque(&buffer), 0);
    }
    if (encoder.state == .failed) return encoder.state.failed;
    const result = doeNativeRenderBundleEncoderFinish(toOpaque(encoder), null) orelse return error.OutOfMemory;
    defer doeNativeRenderBundleRelease(result);
    try std.testing.expect(!bundle.cast_bundle(result).?.error_object);
    try std.testing.expectEqual(@as(usize, repetitions * 5), bundle.cast_bundle(result).?.cmds.len);
}

test "native bundle recording and finish release dependencies after every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, bundleAllocationScenario, .{});
}

test "failed bundle cannot replay into a valid command recording" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const encoder = bundle.make_bundle_encoder(failing.allocator(), 0, 0, 1, false, false).?;
    defer doeNativeRenderBundleEncoderRelease(toOpaque(encoder));
    failing.fail_index = failing.alloc_index;
    doeNativeRenderBundleEncoderDraw(toOpaque(encoder), 3, 1, 0, 0);
    try std.testing.expectEqual(error.OutOfMemory, encoder.state.failed);
    failing.fail_index = std.math.maxInt(usize);
    const result = doeNativeRenderBundleEncoderFinish(toOpaque(encoder), null).?;
    defer doeNativeRenderBundleRelease(result);
    try std.testing.expect(bundle.cast_bundle(result).?.error_object);
    var device = DoeDevice{};
    var commands = native_types.DoeCommandEncoder{ .dev = &device };
    var pass = DoeRenderPass{ .enc = &commands };
    pass.enc.state = .{ .pass = @intFromPtr(&pass) };
    const bundles = [_]?*anyopaque{result};
    doeNativeRenderPassExecuteBundles(toOpaque(&pass), bundles.len, &bundles);
    try std.testing.expectEqual(error.InvalidArgument, commands.state.failed);
    try std.testing.expectEqual(@as(usize, 0), commands.cmds.items.len);
}

// ============================================================
// Render pipeline: getBindGroupLayout
// Returns a minimal DoeBindGroupLayout seeded with the group index.
// Full reflection requires shader metadata not yet stored on the render pipeline.
// ============================================================

pub export fn doeNativeRenderPipelineGetBindGroupLayout(
    pip_raw: ?*anyopaque,
    group_index: u32,
) callconv(.c) ?*anyopaque {
    _ = cast(DoeRenderPipeline, pip_raw) orelse return null;
    const bgl = make(DoeBindGroupLayout) orelse return null;
    bgl.* = .{ .entry_count = group_index };
    return toOpaque(bgl);
}

// ============================================================
// Debug markers — no-ops in headless runtime; symbols required for API surface completeness.
// ============================================================

pub export fn doeNativeRenderBundleEncoderInsertDebugMarker(
    raw: ?*anyopaque,
    _: ?[*]const u8,
    _: usize,
) callconv(.c) void {
    const object = bundle.cast_bundle_encoder(raw) orelse return;
    _ = requireBundleOpen(object);
}

pub export fn doeNativeRenderBundleEncoderPushDebugGroup(
    raw: ?*anyopaque,
    _: ?[*]const u8,
    _: usize,
) callconv(.c) void {
    const object = bundle.cast_bundle_encoder(raw) orelse return;
    _ = requireBundleOpen(object);
}

pub export fn doeNativeRenderBundleEncoderPopDebugGroup(
    raw: ?*anyopaque,
) callconv(.c) void {
    const object = bundle.cast_bundle_encoder(raw) orelse return;
    _ = requireBundleOpen(object);
}

// ============================================================
// Render pass: executeBundles
// ============================================================

const MAX_BIND = native_shared.MAX_BIND;
const MAX_FLAT_BIND = native_shared.MAX_FLAT_BIND;
const MAX_VERTEX_BUFFERS = native_shared.MAX_VERTEX_BUFFERS;

// Accumulated render state for bundle replay. Tracks pipeline, bind groups,
// vertex buffers, and index buffer across commands within a bundle so that
// each draw emits a fully populated RecordedCmd.render_pass.
const BundleReplayState = struct {
    pso: ?*anyopaque,
    pipeline: ?*DoeRenderPipeline,
    bind_groups: [native_shared.MAX_RENDER_BIND_GROUPS]?*DoeBindGroup,
    bind_buffers: [MAX_FLAT_BIND]?*anyopaque,
    bind_buffer_offsets: [MAX_FLAT_BIND]u64,
    vertex_buffer_objects: [MAX_VERTEX_BUFFERS]?*DoeBuffer,
    vertex_buffers: [MAX_VERTEX_BUFFERS]?*anyopaque,
    vertex_buffer_offsets: [MAX_VERTEX_BUFFERS]u64,
    vertex_buffer_sizes: [MAX_VERTEX_BUFFERS]u64,
    index_buffer_object: ?*DoeBuffer,
    index_buffer: ?*anyopaque,
    index_offset: u64,
    index_size: u64,
    index_format: u32,

    fn init(pass: *const DoeRenderPass) BundleReplayState {
        return .{
            .pso = if (pass.pipeline) |p| p.mtl_pso else null,
            .pipeline = pass.pipeline,
            .bind_groups = pass.bind_groups,
            .bind_buffers = [_]?*anyopaque{null} ** MAX_FLAT_BIND,
            .bind_buffer_offsets = [_]u64{0} ** MAX_FLAT_BIND,
            .vertex_buffer_objects = pass.vertex_buffers,
            .vertex_buffers = [_]?*anyopaque{null} ** MAX_VERTEX_BUFFERS,
            .vertex_buffer_offsets = [_]u64{0} ** MAX_VERTEX_BUFFERS,
            .vertex_buffer_sizes = pass.vertex_buffer_sizes,
            .index_buffer_object = pass.index_buffer,
            .index_buffer = null,
            .index_offset = 0,
            .index_size = 0,
            .index_format = 0x2, // default uint32
        };
    }
};

const SavedVulkanBundlePassState = struct {
    pipeline: ?*DoeRenderPipeline,
    bind_groups: [native_shared.MAX_RENDER_BIND_GROUPS]?*DoeBindGroup,
    vertex_buffers: [MAX_VERTEX_BUFFERS]?*DoeBuffer,
    vertex_buffer_offsets: [MAX_VERTEX_BUFFERS]u64,
    vertex_buffer_sizes: [MAX_VERTEX_BUFFERS]u64,
    index_buffer: ?*DoeBuffer,
    index_offset: u64,
    index_format: u32,
    index_buffer_size: u64,

    fn capture(pass: *const DoeRenderPass) SavedVulkanBundlePassState {
        return .{
            .pipeline = pass.pipeline,
            .bind_groups = pass.bind_groups,
            .vertex_buffers = pass.vertex_buffers,
            .vertex_buffer_offsets = pass.vertex_buffer_offsets,
            .vertex_buffer_sizes = pass.vertex_buffer_sizes,
            .index_buffer = pass.index_buffer,
            .index_offset = pass.index_offset,
            .index_format = pass.index_format,
            .index_buffer_size = pass.index_buffer_size,
        };
    }

    fn restore(saved: SavedVulkanBundlePassState, pass: *DoeRenderPass) void {
        pass.pipeline = saved.pipeline;
        pass.bind_groups = saved.bind_groups;
        pass.vertex_buffers = saved.vertex_buffers;
        pass.vertex_buffer_offsets = saved.vertex_buffer_offsets;
        pass.vertex_buffer_sizes = saved.vertex_buffer_sizes;
        pass.index_buffer = saved.index_buffer;
        pass.index_offset = saved.index_offset;
        pass.index_format = saved.index_format;
        pass.index_buffer_size = saved.index_buffer_size;
    }
};

fn apply_vulkan_bundle_state(pass: *DoeRenderPass, state: *const BundleReplayState) bool {
    const pipeline = state.pipeline orelse return false;
    pass.pipeline = pipeline;
    pass.depth_compare = pipeline.depth_compare;
    pass.depth_write_enabled = pipeline.depth_write_enabled;
    pass.bind_groups = state.bind_groups;
    pass.vertex_buffers = state.vertex_buffer_objects;
    pass.vertex_buffer_offsets = state.vertex_buffer_offsets;
    pass.vertex_buffer_sizes = state.vertex_buffer_sizes;
    pass.index_buffer = state.index_buffer_object;
    pass.index_offset = state.index_offset;
    pass.index_format = state.index_format;
    pass.index_buffer_size = state.index_size;
    return true;
}

// Build a render_pass RecordedCmd with the accumulated bundle state.
fn bundleRenderPassCmd(
    state: *const BundleReplayState,
    pass: *const DoeRenderPass,
) native_cmds.RecordedCmd {
    const pipeline = state.pipeline orelse pass.pipeline;
    return .{ .render_pass = .{
        .pso = state.pso,
        .root_signature = if (pipeline) |p| p.backend_root_signature else null,
        .depth_state = if (pipeline) |p| p.depth_state else null,
        .target = pass.target,
        .resolve_target = pass.resolve_target,
        .depth_target = pass.depth_target,
        .target_view_handle = pass.target_view_handle,
        .resolve_target_view_handle = pass.resolve_target_view_handle,
        .depth_target_view_handle = pass.depth_target_view_handle,
        .target_format = pass.target_format,
        .depth_stencil_format = pass.depth_stencil_format,
        .sample_count = if (pass.sample_count != 0)
            pass.sample_count
        else if (pipeline) |p|
            p.sample_count
        else
            1,
        .depth_slice = pass.depth_slice,
        .depth_read_only = pass.depth_read_only,
        .stencil_read_only = pass.stencil_read_only,
        .pass_start = pass.enc.cmds.items.len == pass.recorded_command_start,
        .pass_end = false,
        .color_load_op = pass.color_load_op,
        .color_store_op = pass.color_store_op,
        .depth_load_op = pass.depth_load_op,
        .depth_store_op = pass.depth_store_op,
        .stencil_load_op = pass.stencil_load_op,
        .stencil_store_op = pass.stencil_store_op,
        .depth_clear_value = pass.depth_clear_value,
        .stencil_clear_value = pass.stencil_clear_value,
        .topology = if (pipeline) |p| p.topology else 0,
        .front_face = if (pipeline) |p| p.front_face else 0,
        .cull_mode = if (pipeline) |p| p.cull_mode else 0,
        .draw_count = 1,
        .vertex_count = 0,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
        .bind_buffers = state.bind_buffers,
        .bind_buffer_offsets = state.bind_buffer_offsets,
        .vertex_buffers = state.vertex_buffers,
        .vertex_buffer_offsets = state.vertex_buffer_offsets,
        .vertex_buffer_sizes = state.vertex_buffer_sizes,
        .viewport_x = pass.viewport_x,
        .viewport_y = pass.viewport_y,
        .viewport_width = pass.viewport_width,
        .viewport_height = pass.viewport_height,
        .viewport_min_depth = pass.viewport_min_depth,
        .viewport_max_depth = pass.viewport_max_depth,
        .scissor_x = pass.scissor_x,
        .scissor_y = pass.scissor_y,
        .scissor_width = pass.scissor_width,
        .scissor_height = pass.scissor_height,
        .blend_constant = pass.blend_constant,
        .stencil_reference = pass.stencil_reference,
        .depth_compare = if (pipeline) |p| p.depth_compare else pass.depth_compare,
        .depth_write_enabled = if (pipeline) |p| p.depth_write_enabled else pass.depth_write_enabled,
        .unclipped_depth = if (pipeline) |p| p.unclipped_depth else false,
        .clear_r = pass.clear_r,
        .clear_g = pass.clear_g,
        .clear_b = pass.clear_b,
        .clear_a = pass.clear_a,
    } };
}

fn require_index_buffer_for_bundle_draw(state: *const BundleReplayState, kind: []const u8) bool {
    _ = kind;
    return state.index_buffer != null;
}

pub export fn doeNativeRenderPassExecuteBundles(
    pass_raw: ?*anyopaque,
    bundle_count: usize,
    bundles: [*]const ?*anyopaque,
) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    const is_vulkan = pass.enc.dev.backend == .vulkan;

    for (bundles[0..bundle_count]) |raw| {
        const b = bundle.cast_bundle(raw) orelse return recording.fail(pass.enc, error.InvalidArgument);
        bundle.check_compatibility(b, pass.target_format, pass.sample_count) catch |err| {
            _ = pass.enc.state.fail(error.InvalidArgument);
            pass.enc.dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, @errorName(err));
            return;
        };
        if (b.depth_stencil_format != pass.depth_stencil_format) {
            _ = pass.enc.state.fail(error.InvalidArgument);
            pass.enc.dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, "render bundle depth/stencil format differs from the render pass");
            return;
        }
        if (!recording.reserve(pass.enc, 0, 1)) return;
        references.retainRenderBundleAssumeCapacity(&pass.enc.references, b);
        const saved_vulkan_state: ?SavedVulkanBundlePassState = if (is_vulkan)
            SavedVulkanBundlePassState.capture(pass)
        else
            null;

        // Each bundle starts with a fresh replay state seeded from the pass.
        var state = BundleReplayState.init(pass);

        for (b.cmds) |cmd| {
            switch (cmd) {
                .set_pipeline => |p| {
                    state.pipeline = cast(DoeRenderPipeline, p.pipeline_object_handle) orelse
                        if (is_vulkan) cast(DoeRenderPipeline, p.pipeline_handle) else null;
                    state.pso = if (state.pipeline) |pipeline|
                        pipeline.mtl_pso
                    else
                        p.pipeline_handle;
                },
                .set_bind_group => |bg_cmd| {
                    if (is_vulkan and bg_cmd.group < native_shared.MAX_RENDER_BIND_GROUPS) {
                        state.bind_groups[@intCast(bg_cmd.group)] = cast(DoeBindGroup, bg_cmd.bg_handle);
                    }
                    const base = @as(usize, bg_cmd.group) * MAX_BIND;
                    const count = @min(@as(usize, bg_cmd.bg.count), bundle.MAX_BINDINGS_PER_GROUP);
                    for (0..count) |i| {
                        if (base + i < MAX_FLAT_BIND) {
                            state.bind_buffers[base + i] = bg_cmd.bg.entries[i].handle;
                            state.bind_buffer_offsets[base + i] = bg_cmd.bg.entries[i].offset;
                        }
                    }
                },
                .set_vertex_buffer => |vb| {
                    const slot = @as(usize, @min(vb.slot, MAX_VERTEX_BUFFERS - 1));
                    state.vertex_buffer_objects[slot] = if (is_vulkan) cast(DoeBuffer, vb.buffer_handle) else null;
                    state.vertex_buffers[slot] = vb.buffer_handle;
                    state.vertex_buffer_offsets[slot] = vb.offset;
                    state.vertex_buffer_sizes[slot] = vb.size;
                },
                .set_index_buffer => |ib| {
                    state.index_buffer_object = if (is_vulkan) cast(DoeBuffer, ib.buffer_handle) else null;
                    state.index_buffer = ib.buffer_handle;
                    state.index_offset = ib.offset;
                    state.index_size = ib.size;
                    state.index_format = ib.format;
                },
                .draw => |d| {
                    if (pass.recorded_draw_count >= pass.max_draw_count) continue;
                    if (is_vulkan) {
                        if (!apply_vulkan_bundle_state(pass, &state)) continue;
                        pass.recorded_draw_count += 1;
                        const vk_render = @import("../vulkan/vulkan_render_native.zig");
                        vk_render.vulkan_render_pass_draw(pass, d.vertex_count, d.instance_count, d.first_vertex, d.first_instance);
                        continue;
                    }
                    pass.recorded_draw_count += 1;
                    var rc = bundleRenderPassCmd(&state, pass);
                    rc.render_pass.vertex_count = d.vertex_count;
                    rc.render_pass.instance_count = d.instance_count;
                    rc.render_pass.first_vertex = d.first_vertex;
                    rc.render_pass.first_instance = d.first_instance;
                    if (!recording.append(pass.enc, rc)) return;
                },
                .draw_indexed => |d| {
                    if (!require_index_buffer_for_bundle_draw(&state, "draw_indexed")) {
                        continue;
                    }
                    if (pass.recorded_draw_count >= pass.max_draw_count) continue;
                    if (is_vulkan) {
                        if (state.index_buffer_object == null or !apply_vulkan_bundle_state(pass, &state)) continue;
                        pass.recorded_draw_count += 1;
                        const vk_render = @import("../vulkan/vulkan_render_native.zig");
                        vk_render.vulkan_render_pass_draw_indexed(pass, d.index_count, d.instance_count, d.first_index, d.base_vertex, d.first_instance);
                        continue;
                    }
                    pass.recorded_draw_count += 1;
                    var rc = bundleRenderPassCmd(&state, pass);
                    rc.render_pass.indexed = true;
                    rc.render_pass.index_buffer = state.index_buffer;
                    rc.render_pass.index_format = state.index_format;
                    rc.render_pass.index_count = d.index_count;
                    rc.render_pass.instance_count = d.instance_count;
                    rc.render_pass.base_vertex = d.base_vertex;
                    rc.render_pass.first_instance = d.first_instance;
                    // first_index converts to a byte offset into the index buffer.
                    const bytes_per_index: u64 = if (state.index_format == 0x1) 2 else 4;
                    rc.render_pass.index_offset = state.index_offset + @as(u64, d.first_index) * bytes_per_index;
                    if (!recording.append(pass.enc, rc)) return;
                },
                .draw_indirect => |d| {
                    if (pass.recorded_draw_count >= pass.max_draw_count) continue;
                    if (is_vulkan) {
                        if (d.indirect_buffer == null or !apply_vulkan_bundle_state(pass, &state)) continue;
                        pass.recorded_draw_count += 1;
                        const vk_render = @import("../vulkan/vulkan_render_native.zig");
                        vk_render.vulkan_render_pass_draw_indirect(pass, d.indirect_buffer, d.indirect_offset);
                        continue;
                    }
                    pass.recorded_draw_count += 1;
                    var rc = bundleRenderPassCmd(&state, pass);
                    rc.render_pass.indirect = true;
                    rc.render_pass.indirect_buffer = d.indirect_buffer;
                    rc.render_pass.indirect_offset = d.indirect_offset;
                    if (!recording.append(pass.enc, rc)) return;
                },
                .draw_indexed_indirect => |d| {
                    if (!require_index_buffer_for_bundle_draw(&state, "draw_indexed_indirect")) {
                        continue;
                    }
                    if (pass.recorded_draw_count >= pass.max_draw_count) continue;
                    if (is_vulkan) {
                        if (state.index_buffer_object == null or d.indirect_buffer == null or !apply_vulkan_bundle_state(pass, &state)) continue;
                        pass.recorded_draw_count += 1;
                        const vk_render = @import("../vulkan/vulkan_render_native.zig");
                        vk_render.vulkan_render_pass_draw_indexed_indirect(pass, d.indirect_buffer, d.indirect_offset);
                        continue;
                    }
                    pass.recorded_draw_count += 1;
                    var rc = bundleRenderPassCmd(&state, pass);
                    rc.render_pass.indexed = true;
                    rc.render_pass.indirect = true;
                    rc.render_pass.index_buffer = state.index_buffer;
                    rc.render_pass.index_offset = state.index_offset;
                    rc.render_pass.index_format = state.index_format;
                    rc.render_pass.indirect_buffer = d.indirect_buffer;
                    rc.render_pass.indirect_offset = d.indirect_offset;
                    if (!recording.append(pass.enc, rc)) return;
                },
            }
        }
        if (saved_vulkan_state) |saved| {
            saved.restore(pass);
        }
    }
}
