const recording = @import("../command/doe_command_recording.zig");
// doe_render_native.zig — Render Pass C ABI exports for the Doe native backend.
// Texture/Sampler ops sharded to doe_texture_sampler_native.zig.
// Render Pipeline ops sharded to doe_render_pipeline_native.zig.

const std = @import("std");
const abi_core = @import("../../core/abi/wgpu_core_base_types.zig");
const abi_texture = @import("../../core/abi/wgpu_texture_base_types.zig");
const abi_pipeline = @import("../../core/abi/wgpu_pipeline_descriptor_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_cmds = @import("../support/doe_native_command_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const label_store = native_helpers.label_store;

// D3D12 texture view swizzle classification for descriptor binding.
pub const D3D12TextureViewSwizzleMode = enum { identity, swizzled_sampled, unsupported_storage };

pub fn d3d12TextureViewSwizzleMode(
    usage: u64,
    swizzle_r: u32,
    swizzle_g: u32,
    swizzle_b: u32,
    swizzle_a: u32,
) D3D12TextureViewSwizzleMode {
    const is_identity = (swizzle_r == abi_texture.WGPUTextureComponentSwizzle_Red or swizzle_r == 0) and
        (swizzle_g == abi_texture.WGPUTextureComponentSwizzle_Green or swizzle_g == 0) and
        (swizzle_b == abi_texture.WGPUTextureComponentSwizzle_Blue or swizzle_b == 0) and
        (swizzle_a == abi_texture.WGPUTextureComponentSwizzle_Alpha or swizzle_a == 0);
    const wants_storage = (usage & abi_texture.WGPUTextureUsage_StorageBinding) != 0 and
        (usage & abi_texture.WGPUTextureUsage_TextureBinding) == 0;
    if (wants_storage and !is_identity) return .unsupported_storage;
    if (is_identity) return .identity;
    return .swizzled_sampled;
}

const DoeDevice = native_types.DoeDevice;
const DoeBuffer = native_types.DoeBuffer;
const DoeTexture = native_types.DoeTexture;
const DoeTextureView = native_types.DoeTextureView;
const DoeBindGroup = native_types.DoeBindGroup;
const DoeRenderPipeline = native_types.DoeRenderPipeline;
const DoeRenderPass = native_types.DoeRenderPass;
const DoeCommandEncoder = native_types.DoeCommandEncoder;
const RecordedRenderCmd = std.meta.TagPayloadByName(native_cmds.RecordedCmd, "render_pass");

const texture_sampler = @import("../resource/doe_texture_sampler_native.zig");
const render_pipeline = @import("doe_render_pipeline_native.zig");
const references = @import("../command/doe_command_references.zig");
const native_exports = @import("../support/doe_native_exports.zig");
const query_native = @import("../resource/doe_query_native.zig");

// Re-export texture/sampler symbols for callers that import doe_render_native.
pub const doeNativeDeviceCreateTexture = texture_sampler.doeNativeDeviceCreateTexture;
pub const doeNativeDeviceValidateTextureDescriptor = texture_sampler.doeNativeDeviceValidateTextureDescriptor;
pub const doeNativeTextureCreateView = texture_sampler.doeNativeTextureCreateView;
pub const doeNativeTextureDestroy = texture_sampler.doeNativeTextureDestroy;
pub const doeNativeTextureRelease = texture_sampler.doeNativeTextureRelease;
pub const doeNativeTextureViewRelease = texture_sampler.doeNativeTextureViewRelease;
pub const doeNativeDeviceCreateSampler = texture_sampler.doeNativeDeviceCreateSampler;
pub const doeNativeSamplerRelease = texture_sampler.doeNativeSamplerRelease;

// Re-export render pipeline symbols.
pub const doeNativeDeviceCreateRenderPipeline = render_pipeline.doeNativeDeviceCreateRenderPipeline;
pub const doeNativeRenderPipelineRelease = render_pipeline.doeNativeRenderPipelineRelease;

const DEFAULT_MAX_DRAW_COUNT: u64 = 50_000_000;

fn renderPassMaxDrawCount(desc: *const abi_pipeline.WGPURenderPassDescriptor) u64 {
    var chain = desc.nextInChain;
    while (chain != null) {
        const item: *const abi_pipeline.WGPUChainedStruct = @ptrCast(chain);
        if (item.sType == abi_core.WGPUSType_RenderPassMaxDrawCount) {
            const extension: *const abi_pipeline.WGPURenderPassMaxDrawCount = @ptrCast(item);
            return if (extension.maxDrawCount == 0) DEFAULT_MAX_DRAW_COUNT else extension.maxDrawCount;
        }
        chain = item.next;
    }
    return DEFAULT_MAX_DRAW_COUNT;
}

fn reserve_render_draw(pass: *DoeRenderPass) bool {
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return false;
    if (pass.recorded_draw_count >= pass.max_draw_count) {
        std.log.err("doe: render pass draw rejected: maxDrawCount={} exhausted", .{pass.max_draw_count});
        return false;
    }
    pass.recorded_draw_count += 1;
    return true;
}

// ============================================================
// Render Pass
// ============================================================

pub export fn doeNativeCommandEncoderBeginRenderPass(enc_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPURenderPassDescriptor) callconv(.c) ?*anyopaque {
    const enc = cast(DoeCommandEncoder, enc_raw) orelse return null;
    if (!recording.requireOpen(enc)) return null;
    const pass = native_helpers.create(DoeRenderPass, enc.allocator) catch |err| {
        recording.fail(enc, err);
        return null;
    };
    native_helpers.object_add_ref(DoeCommandEncoder, enc_raw);
    pass.* = .{
        .enc = enc,
        .owns_encoder = true,
        .recorded_command_start = enc.cmds.items.len,
    };
    enc.state = .{ .pass = @intFromPtr(pass) };
    if (desc) |d| {
        pass.max_draw_count = renderPassMaxDrawCount(d);
        pass.occlusion_query_set = d.occlusionQuerySet;
        query_native.retainRecordedReference(enc, d.occlusionQuerySet);
        if (d.colorAttachmentCount > 0) {
            if (d.colorAttachments) |attachments| {
                const att = attachments[0];
                const tv = cast(DoeTextureView, att.view);
                if (tv) |v| {
                    if (!recording.reserve(enc, 0, 1)) return toOpaque(pass);
                    references.retainTextureViewAssumeCapacity(&enc.references, v);
                    pass.target = if (texture_sampler.d3d12_texture_view_registry.contains(att.view))
                        v.tex.mtl
                    else if (v.handle) |handle|
                        handle
                    else
                        v.tex.mtl;
                    pass.target_view_handle = @intFromPtr(v);
                    pass.target_format = if (v.format != 0) v.format else v.tex.format;
                    pass.sample_count = if (v.tex.sample_count != 0) v.tex.sample_count else 1;
                }
                if (cast(DoeTextureView, att.resolveTarget)) |resolve_view| {
                    if (!recording.reserve(enc, 0, 1)) return toOpaque(pass);
                    references.retainTextureViewAssumeCapacity(&enc.references, resolve_view);
                    pass.resolve_target = resolve_view.tex.mtl;
                    pass.resolve_target_view_handle = @intFromPtr(resolve_view);
                }
                pass.depth_slice = att.depthSlice;
                pass.color_load_op = att.loadOp;
                pass.color_store_op = att.storeOp;
                pass.clear_r = att.clearValue.r;
                pass.clear_g = att.clearValue.g;
                pass.clear_b = att.clearValue.b;
                pass.clear_a = att.clearValue.a;
            }
        }
        if (d.depthStencilAttachment != null) {
            const depth_att: *const abi_pipeline.WGPURenderPassDepthStencilAttachment = @ptrCast(d.depthStencilAttachment);
            if (cast(DoeTextureView, depth_att.view)) |v| {
                if (!recording.reserve(enc, 0, 1)) return toOpaque(pass);
                references.retainTextureViewAssumeCapacity(&enc.references, v);
                pass.depth_target = if (texture_sampler.d3d12_texture_view_registry.contains(depth_att.view))
                    v.tex.mtl
                else if (v.handle) |handle|
                    handle
                else
                    v.tex.mtl;
                pass.depth_target_view_handle = @intFromPtr(v);
                pass.depth_stencil_format = if (v.format != 0) v.format else v.tex.format;
            }
            pass.depth_read_only = depth_att.depthReadOnly != 0;
            pass.stencil_read_only = depth_att.stencilReadOnly != 0;
            pass.depth_load_op = depth_att.depthLoadOp;
            pass.depth_store_op = depth_att.depthStoreOp;
            pass.stencil_load_op = depth_att.stencilLoadOp;
            pass.stencil_store_op = depth_att.stencilStoreOp;
            pass.depth_clear_value = depth_att.depthClearValue;
            pass.stencil_clear_value = depth_att.stencilClearValue;
        }
    }
    return toOpaque(pass);
}

pub export fn doeNativeRenderPassSetPipeline(pass_raw: ?*anyopaque, pip_raw: ?*anyopaque) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    pass.pipeline = cast(DoeRenderPipeline, pip_raw);
    if (pass.pipeline) |pipeline| {
        if (!recording.reserve(pass.enc, 0, 1)) return;
        references.retainRenderPipelineAssumeCapacity(&pass.enc.references, pipeline);
        pass.depth_compare = pipeline.depth_compare;
        pass.depth_write_enabled = pipeline.depth_write_enabled;
    }
}

pub export fn doeNativeRenderPassRecordViewportState(
    pass_raw: ?*anyopaque,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    min_depth: f64,
    max_depth: f64,
) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    pass.viewport_x = @floatCast(x);
    pass.viewport_y = @floatCast(y);
    pass.viewport_width = @floatCast(width);
    pass.viewport_height = @floatCast(height);
    pass.viewport_min_depth = @floatCast(min_depth);
    pass.viewport_max_depth = @floatCast(max_depth);
}

pub export fn doeNativeRenderPassRecordScissorState(
    pass_raw: ?*anyopaque,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    pass.scissor_x = x;
    pass.scissor_y = y;
    pass.scissor_width = width;
    pass.scissor_height = height;
}

pub export fn doeNativeRenderPassRecordBlendConstantState(
    pass_raw: ?*anyopaque,
    r: f64,
    g: f64,
    b: f64,
    a: f64,
) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    pass.blend_constant = .{
        @floatCast(r),
        @floatCast(g),
        @floatCast(b),
        @floatCast(a),
    };
}

pub export fn doeNativeRenderPassRecordStencilReferenceState(
    pass_raw: ?*anyopaque,
    reference: u32,
) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    pass.stencil_reference = reference;
}

pub export fn doeNativeRenderPassDraw(pass_raw: ?*anyopaque, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    if (!reserve_render_draw(pass)) return;
    if (pass.enc.dev.backend == .vulkan) {
        const vk_render = @import("../vulkan/vulkan_render_native.zig");
        vk_render.vulkan_render_pass_draw(pass, vertex_count, instance_count, first_vertex, first_instance);
        return;
    }
    const pip = pass.pipeline orelse return;
    var cmd = base_render_cmd(pass, pip);
    cmd.vertex_count = vertex_count;
    cmd.instance_count = instance_count;
    cmd.first_vertex = first_vertex;
    cmd.first_instance = first_instance;
    const recorded = native_cmds.RecordedCmd{ .render_pass = cmd };
    if (!native_cmds.tryMergeRenderDrawIntoLast(&pass.enc.cmds, &recorded)) {
        if (!recording.append(pass.enc, recorded)) return;
    }
}

pub export fn doeNativeRenderPassSetVertexBuffer(pass_raw: ?*anyopaque, slot: u32, buffer_raw: ?*anyopaque, offset: u64, size: u64) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    if (slot >= native_shared.MAX_VERTEX_BUFFERS) return;
    const buffer = cast(DoeBuffer, buffer_raw);
    if (buffer != null and buffer.?.error_object) return;
    if (buffer) |value| {
        if (!recording.reserve(pass.enc, 0, 1)) return;
        references.retainBufferAssumeCapacity(&pass.enc.references, value);
    }
    pass.vertex_buffers[slot] = buffer;
    pass.vertex_buffer_offsets[slot] = offset;
    pass.vertex_buffer_sizes[slot] = size;
}

pub export fn doeNativeRenderPassSetIndexBuffer(pass_raw: ?*anyopaque, buffer_raw: ?*anyopaque, format: u32, offset: u64, size: u64) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    const buffer = cast(DoeBuffer, buffer_raw);
    if (buffer != null and buffer.?.error_object) return;
    if (buffer) |value| {
        if (!recording.reserve(pass.enc, 0, 1)) return;
        references.retainBufferAssumeCapacity(&pass.enc.references, value);
    }
    pass.index_buffer = buffer;
    pass.index_format = format;
    pass.index_offset = offset;
    pass.index_buffer_size = size;
}

pub export fn doeNativeRenderPassSetBindGroup(pass_raw: ?*anyopaque, group_index: u32, group_raw: ?*anyopaque, dynamic_offset_count: usize, dynamic_offsets: ?[*]const u32) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    if (group_index >= native_shared.MAX_RENDER_BIND_GROUPS) return;
    pass.bind_groups[group_index] = cast(DoeBindGroup, group_raw);
    if (pass.bind_groups[group_index]) |group| {
        if (!recording.reserve(pass.enc, 0, 1)) return;
        references.retainBindGroupAssumeCapacity(&pass.enc.references, group);
    }
    _ = dynamic_offset_count;
    _ = dynamic_offsets;
}

pub export fn doeNativeRenderPassDrawIndexed(pass_raw: ?*anyopaque, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    if (!reserve_render_draw(pass)) return;
    if (pass.enc.dev.backend == .vulkan) {
        const vk_render = @import("../vulkan/vulkan_render_native.zig");
        vk_render.vulkan_render_pass_draw_indexed(pass, index_count, instance_count, first_index, base_vertex, first_instance);
        return;
    }
    const pip = pass.pipeline orelse return;
    var cmd = base_render_cmd(pass, pip);
    cmd.instance_count = instance_count;
    cmd.first_instance = first_instance;
    cmd.indexed = true;
    cmd.index_buffer = if (pass.index_buffer) |buffer| buffer.mtl else null;
    cmd.index_offset = pass.index_offset;
    cmd.index_format = pass.index_format;
    cmd.index_buffer_size = pass.index_buffer_size;
    cmd.index_count = index_count;
    cmd.first_index = first_index;
    cmd.base_vertex = base_vertex;
    if (!recording.append(pass.enc, .{ .render_pass = cmd })) return;
}

fn populate_render_bindings(
    bind_groups: []const ?*DoeBindGroup,
    cmd: *RecordedRenderCmd,
) void {
    std.debug.assert(bind_groups.len <= native_shared.MAX_RENDER_BIND_GROUPS);
    for (bind_groups, 0..) |maybe_group, group_index| {
        const group = maybe_group orelse continue;
        const count = @min(@as(usize, @intCast(group.count)), native_shared.MAX_BIND);
        for (0..count) |binding_index| {
            const slot = group_index * native_shared.MAX_BIND + binding_index;
            cmd.bind_buffers[slot] = group.buffers[binding_index];
            cmd.bind_buffer_offsets[slot] = group.offsets[binding_index];
            cmd.bind_textures[slot] = group.textures[binding_index];
            cmd.bind_samplers[slot] = group.samplers[binding_index];
        }
    }
}

fn base_render_cmd(pass: *DoeRenderPass, pip: ?*DoeRenderPipeline) RecordedRenderCmd {
    var cmd: RecordedRenderCmd = .{
        .pso = if (pip) |value| value.mtl_pso else null,
        .root_signature = if (pip) |value| value.backend_root_signature else null,
        .depth_state = if (pip) |value| value.depth_state else null,
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
        else if (pip) |value|
            value.sample_count
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
        .topology = if (pip) |value| value.topology else 0,
        .front_face = if (pip) |value| value.front_face else 0,
        .cull_mode = if (pip) |value| value.cull_mode else 0,
        .draw_count = if (pip == null) 0 else 1,
        .vertex_count = 0,
        .instance_count = 0,
        .first_vertex = 0,
        .first_instance = 0,
        .vertex_buffers = blk: {
            var buffers: [native_shared.MAX_VERTEX_BUFFERS]?*anyopaque = [_]?*anyopaque{null} ** native_shared.MAX_VERTEX_BUFFERS;
            var i: usize = 0;
            while (i < native_shared.MAX_VERTEX_BUFFERS) : (i += 1) {
                buffers[i] = if (pass.vertex_buffers[i]) |buffer| buffer.mtl else null;
            }
            break :blk buffers;
        },
        .vertex_buffer_offsets = pass.vertex_buffer_offsets,
        .vertex_buffer_sizes = pass.vertex_buffer_sizes,
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
        .depth_compare = pass.depth_compare,
        .depth_write_enabled = pass.depth_write_enabled,
        .unclipped_depth = if (pip) |value| value.unclipped_depth else false,
        .clear_r = pass.clear_r,
        .clear_g = pass.clear_g,
        .clear_b = pass.clear_b,
        .clear_a = pass.clear_a,
    };
    populate_render_bindings(pass.bind_groups[0..], &cmd);
    return cmd;
}

pub export fn doeNativeRenderPassDrawIndirect(pass_raw: ?*anyopaque, indirect_buffer_raw: ?*anyopaque, indirect_offset: u64) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    if (!reserve_render_draw(pass)) return;
    if (cast(DoeBuffer, indirect_buffer_raw)) |buffer| {
        if (!recording.reserve(pass.enc, 0, 1)) return;
        references.retainBufferAssumeCapacity(&pass.enc.references, buffer);
    }
    if (pass.enc.dev.backend == .vulkan) {
        const vk_render = @import("../vulkan/vulkan_render_native.zig");
        vk_render.vulkan_render_pass_draw_indirect(pass, indirect_buffer_raw, indirect_offset);
        return;
    }
    const pip = pass.pipeline orelse return;
    const indirect_buffer = cast(DoeBuffer, indirect_buffer_raw) orelse return;
    if (indirect_buffer.error_object) return;
    var cmd = base_render_cmd(pass, pip);
    cmd.indirect = true;
    cmd.indirect_buffer = indirect_buffer.mtl;
    cmd.indirect_offset = indirect_offset;
    if (!recording.append(pass.enc, .{ .render_pass = cmd })) return;
}

pub export fn doeNativeRenderPassDrawIndexedIndirect(pass_raw: ?*anyopaque, indirect_buffer_raw: ?*anyopaque, indirect_offset: u64) callconv(.c) void {
    const pass = cast(DoeRenderPass, pass_raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    if (!reserve_render_draw(pass)) return;
    if (cast(DoeBuffer, indirect_buffer_raw)) |buffer| {
        if (!recording.reserve(pass.enc, 0, 1)) return;
        references.retainBufferAssumeCapacity(&pass.enc.references, buffer);
    }
    if (pass.enc.dev.backend == .vulkan) {
        const vk_render = @import("../vulkan/vulkan_render_native.zig");
        vk_render.vulkan_render_pass_draw_indexed_indirect(pass, indirect_buffer_raw, indirect_offset);
        return;
    }
    const pip = pass.pipeline orelse return;
    const indirect_buffer = cast(DoeBuffer, indirect_buffer_raw) orelse return;
    if (indirect_buffer.error_object) return;
    var cmd = base_render_cmd(pass, pip);
    cmd.indirect = true;
    cmd.indexed = true;
    cmd.indirect_buffer = indirect_buffer.mtl;
    cmd.indirect_offset = indirect_offset;
    cmd.index_buffer = if (pass.index_buffer) |buffer| buffer.mtl else null;
    cmd.index_offset = pass.index_offset;
    cmd.index_format = pass.index_format;
    cmd.index_buffer_size = pass.index_buffer_size;
    if (!recording.append(pass.enc, .{ .render_pass = cmd })) return;
}

pub export fn doeNativeRenderPassEnd(raw: ?*anyopaque) callconv(.c) void {
    const pass = cast(DoeRenderPass, raw) orelse return;
    if (!recording.requirePass(pass.enc, @intFromPtr(pass))) return;
    defer recording.endPass(pass.enc, @intFromPtr(pass));
    if (pass.enc.dev.backend == .vulkan) {
        const vk_render = @import("../vulkan/vulkan_render_native.zig");
        vk_render.vulkan_render_pass_end(pass);
        return;
    }
    if (pass.enc.cmds.items.len == pass.recorded_command_start) {
        if (pass.enc.dev.backend == .metal) {
            var cmd = base_render_cmd(pass, null);
            cmd.pass_start = true;
            cmd.pass_end = true;
            if (!recording.append(pass.enc, .{ .render_pass = cmd })) return;
        }
        return;
    }
    const final_cmd = &pass.enc.cmds.items[pass.enc.cmds.items.len - 1];
    switch (final_cmd.*) {
        .render_pass => |*cmd| cmd.pass_end = true,
        else => std.log.err("doe: render pass ended after a non-render command", .{}),
    }
}

pub export fn doeNativeRenderPassRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeRenderPass, raw)) |p| {
        if (!native_helpers.object_should_destroy(p)) return;
        label_store.remove(raw);
        const allocator = p.enc.allocator;
        if (p.owns_encoder) native_exports.doeNativeCommandEncoderRelease(toOpaque(p.enc));
        allocator.destroy(p);
    }
}

test "Metal render commands flatten bind groups into shader slots" {
    const sampler: ?*anyopaque = @ptrFromInt(0x1000);
    const texture: ?*anyopaque = @ptrFromInt(0x2000);
    const buffer: ?*anyopaque = @ptrFromInt(0x3000);
    var group0: DoeBindGroup = .{};
    group0.count = 2;
    group0.samplers[0] = sampler;
    group0.textures[1] = texture;
    var group1: DoeBindGroup = .{};
    group1.count = 3;
    group1.buffers[2] = buffer;
    group1.offsets[2] = 64;
    var groups = [_]?*DoeBindGroup{ &group0, &group1, null, null };
    var cmd: RecordedRenderCmd = .{
        .pso = null,
        .depth_state = null,
        .target = null,
        .depth_target = null,
        .topology = 0,
        .front_face = 0,
        .cull_mode = 0,
        .draw_count = 1,
        .vertex_count = 0,
        .instance_count = 0,
        .first_vertex = 0,
        .first_instance = 0,
    };

    populate_render_bindings(groups[0..], &cmd);

    try std.testing.expectEqual(sampler, cmd.bind_samplers[0]);
    try std.testing.expectEqual(texture, cmd.bind_textures[1]);
    try std.testing.expectEqual(buffer, cmd.bind_buffers[native_shared.MAX_BIND + 2]);
    try std.testing.expectEqual(@as(u64, 64), cmd.bind_buffer_offsets[native_shared.MAX_BIND + 2]);
}

test "Metal render commands snapshot logical dynamic state" {
    var dev: native_types.DoeDevice = .{};
    var enc: DoeCommandEncoder = .{ .dev = &dev };
    defer enc.cmds.deinit(alloc);
    var pass: DoeRenderPass = .{ .enc = &enc };
    enc.state = .{ .pass = @intFromPtr(&pass) };

    doeNativeRenderPassRecordViewportState(toOpaque(&pass), 1, 2, 31, 29, 0.25, 0.75);
    doeNativeRenderPassRecordScissorState(toOpaque(&pass), 3, 4, 23, 19);
    doeNativeRenderPassRecordBlendConstantState(toOpaque(&pass), 0.1, 0.2, 0.3, 0.4);
    doeNativeRenderPassRecordStencilReferenceState(toOpaque(&pass), 17);

    const cmd = base_render_cmd(&pass, null);
    try std.testing.expectEqual(@as(f32, 1), cmd.viewport_x);
    try std.testing.expectEqual(@as(f32, 2), cmd.viewport_y);
    try std.testing.expectEqual(@as(?f32, 31), cmd.viewport_width);
    try std.testing.expectEqual(@as(?f32, 29), cmd.viewport_height);
    try std.testing.expectEqual(@as(f32, 0.25), cmd.viewport_min_depth);
    try std.testing.expectEqual(@as(f32, 0.75), cmd.viewport_max_depth);
    try std.testing.expectEqual(@as(u32, 3), cmd.scissor_x);
    try std.testing.expectEqual(@as(u32, 4), cmd.scissor_y);
    try std.testing.expectEqual(@as(?u32, 23), cmd.scissor_width);
    try std.testing.expectEqual(@as(?u32, 19), cmd.scissor_height);
    try std.testing.expectEqual(@as([4]f32, .{ 0.1, 0.2, 0.3, 0.4 }), cmd.blend_constant);
    try std.testing.expectEqual(@as(u32, 17), cmd.stencil_reference);
}

// Ensure sharded modules' C ABI exports reach the final shared library.
comptime {
    _ = texture_sampler;
    _ = render_pipeline;
}

// Full render state: viewport, scissor, blend, MSAA, stencil, depth/stencil pipeline.
const render_state = @import("doe_render_state_native.zig");
comptime {
    _ = render_state;
}
