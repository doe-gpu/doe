const std = @import("std");
const model_gpu_types = @import("../../../contracts/model/model_texture_value_types.zig");
const abi_texture = @import("../../../core/abi/wgpu_texture_base_types.zig");
const native_cmds = @import("../../../native/support/doe_native_command_types.zig");
const native_types = @import("../../../native/support/doe_native_object_types.zig");
const native_helpers = @import("../../../native/support/doe_native_object_helpers.zig");
const dc = @import("../d3d12_constants.zig");
const d3d12_descriptors = @import("../d3d12_descriptors.zig");
const d3d12_texture_view = @import("../resources/d3d12_texture_view.zig");
const d3d12_sampler = @import("../resources/d3d12_sampler.zig");
const d3d12_render_bind_groups = @import("d3d12_render_bind_groups.zig");
const bridge = @import("../d3d12_bridge_decls.zig");

const RecordedRenderPass = std.meta.TagPayload(native_cmds.RecordedCmd, .render_pass);
const DoeTextureView = native_types.DoeTextureView;
const DoeTexture = native_types.DoeTexture;

pub fn record_render_pass_command(
    allocator: std.mem.Allocator,
    retained_handles: *std.ArrayListUnmanaged(?*anyopaque),
    device: ?*anyopaque,
    cmd_list: ?*anyopaque,
    cmd: RecordedRenderPass,
    descriptor_state: *d3d12_descriptors.DescriptorHeapState,
    texture_view_state: *const d3d12_texture_view.TextureViewState,
    sampler_state: *const d3d12_sampler.SamplerState,
) !void {
    const target_view = texture_view_from_handle(cmd.target_view_handle) orelse return error.InvalidArgument;
    const target_texture = target_view.tex;
    const target_format = resolve_view_format(target_view, cmd.target_format);
    const target_dimension = resolve_render_view_dimension(target_view);
    const rtv_heap = bridge.c.d3d12_bridge_device_create_rtv_heap(device, 1) orelse return error.InvalidState;
    try retained_handles.append(allocator, rtv_heap);
    bridge.c.d3d12_bridge_device_create_rtv_view(
        device,
        cmd.target,
        rtv_heap,
        0,
        target_format,
        target_dimension,
        target_view.base_mip_level,
        target_view.base_array_layer,
        resolved_layer_count(target_view),
        cmd.depth_slice,
    );

    var dsv_heap: ?*anyopaque = null;
    if (cmd.depth_target != null) {
        const depth_view = texture_view_from_handle(cmd.depth_target_view_handle) orelse return error.InvalidArgument;
        dsv_heap = bridge.c.d3d12_bridge_device_create_dsv_heap(device, 1) orelse return error.InvalidState;
        try retained_handles.append(allocator, dsv_heap);
        bridge.c.d3d12_bridge_device_create_dsv_view(
            device,
            cmd.depth_target,
            dsv_heap,
            0,
            resolve_view_format(depth_view, cmd.depth_stencil_format),
            resolve_depth_view_dimension(depth_view),
            depth_view.base_mip_level,
            depth_view.base_array_layer,
            resolved_layer_count(depth_view),
            if (cmd.depth_read_only) 1 else 0,
            if (cmd.stencil_read_only) 1 else 0,
        );
    }

    // Bind texture and sampler descriptors if present
    const bind_result = try bind_textures_and_samplers(
        device,
        descriptor_state,
        texture_view_state,
        sampler_state,
        &cmd.bind_textures,
        &cmd.bind_samplers,
    );

    // Use the bind group root signature if textures/samplers are bound,
    // otherwise fall back to the pipeline root signature.
    const active_root_sig = bind_result.root_signature orelse cmd.root_signature;
    bridge.c.d3d12_bridge_command_list_set_graphics_root_signature(cmd_list, active_root_sig);
    if (bind_result.root_signature) |rs| {
        try retained_handles.append(allocator, rs);
    }

    bridge.c.d3d12_bridge_command_list_set_pipeline_state(cmd_list, cmd.pso);
    bridge.c.d3d12_bridge_command_list_set_render_targets(cmd_list, rtv_heap, 0, dsv_heap, 0);

    // Set descriptor tables for texture/sampler bindings
    d3d12_render_bind_groups.set_render_pass_descriptor_tables(
        cmd_list,
        descriptor_state,
        bind_result,
    );

    const vp_width: f32 = @floatFromInt(view_mip_extent(target_texture.width, target_view.base_mip_level));
    const vp_height: f32 = @floatFromInt(view_mip_extent(target_texture.height, target_view.base_mip_level));
    bridge.c.d3d12_bridge_command_list_set_viewport(cmd_list, 0, 0, vp_width, vp_height, 0, 1);
    bridge.c.d3d12_bridge_command_list_set_scissor(
        cmd_list,
        0,
        0,
        @intCast(view_mip_extent(target_texture.width, target_view.base_mip_level)),
        @intCast(view_mip_extent(target_texture.height, target_view.base_mip_level)),
    );
    bridge.c.d3d12_bridge_command_list_ia_set_primitive_topology(cmd_list, map_topology(cmd.topology));
    bridge.c.d3d12_bridge_command_list_set_blend_factor(cmd_list, &cmd.blend_constant);
    bridge.c.d3d12_bridge_command_list_set_stencil_ref(cmd_list, cmd.stencil_reference);

    bind_vertex_buffers(cmd_list, cmd);
    bind_index_buffer(cmd_list, cmd);

    var draw_i: u32 = 0;
    while (draw_i < cmd.draw_count) : (draw_i += 1) {
        if (cmd.indexed) {
            bridge.c.d3d12_bridge_command_list_draw_indexed_instanced(
                cmd_list,
                cmd.index_count,
                cmd.instance_count,
                cmd.first_index,
                cmd.base_vertex,
                cmd.first_instance,
            );
        } else {
            bridge.c.d3d12_bridge_command_list_draw_instanced(
                cmd_list,
                cmd.vertex_count,
                cmd.instance_count,
                cmd.first_vertex,
                cmd.first_instance,
            );
        }
    }

    try maybe_record_resolve(cmd_list, cmd, target_view);
}

fn bind_textures_and_samplers(
    device: ?*anyopaque,
    descriptor_state: *d3d12_descriptors.DescriptorHeapState,
    texture_view_state: *const d3d12_texture_view.TextureViewState,
    sampler_state: *const d3d12_sampler.SamplerState,
    bind_textures: []const ?*anyopaque,
    bind_samplers: []const ?*anyopaque,
) !d3d12_render_bind_groups.RenderBindResult {
    return d3d12_render_bind_groups.bind_render_pass_textures_and_samplers(
        device,
        descriptor_state,
        texture_view_state,
        sampler_state,
        bind_textures,
        bind_samplers,
    );
}

fn maybe_record_resolve(
    cmd_list: ?*anyopaque,
    cmd: RecordedRenderPass,
    target_view: *const DoeTextureView,
) !void {
    if (cmd.resolve_target == null or cmd.resolve_target_view_handle == 0) return;
    if (cmd.sample_count <= 1) return error.InvalidArgument;

    const resolve_view = texture_view_from_handle(cmd.resolve_target_view_handle) orelse return error.InvalidArgument;
    if (resolve_render_view_dimension(target_view) == model_gpu_types.WGPUTextureViewDimension_3D or
        resolve_render_view_dimension(resolve_view) == model_gpu_types.WGPUTextureViewDimension_3D)
    {
        return error.UnsupportedFeature;
    }

    const layer_count = resolved_layer_count(target_view);
    var layer: u32 = 0;
    while (layer < layer_count) : (layer += 1) {
        const src_subresource = texture_subresource_index(target_view, layer);
        const dst_subresource = texture_subresource_index(resolve_view, layer);
        bridge.c.d3d12_bridge_command_list_resource_barrier_transition(cmd_list, cmd.target, dc.RESOURCE_STATE_RENDER_TARGET, dc.RESOURCE_STATE_RESOLVE_SOURCE);
        bridge.c.d3d12_bridge_command_list_resource_barrier_transition(cmd_list, cmd.resolve_target, dc.RESOURCE_STATE_RENDER_TARGET, dc.RESOURCE_STATE_RESOLVE_DEST);
        bridge.c.d3d12_bridge_command_list_resolve_subresource(
            cmd_list,
            cmd.resolve_target,
            dst_subresource,
            cmd.target,
            src_subresource,
            resolve_view_format(target_view, cmd.target_format),
        );
        bridge.c.d3d12_bridge_command_list_resource_barrier_transition(cmd_list, cmd.resolve_target, dc.RESOURCE_STATE_RESOLVE_DEST, dc.RESOURCE_STATE_RENDER_TARGET);
        bridge.c.d3d12_bridge_command_list_resource_barrier_transition(cmd_list, cmd.target, dc.RESOURCE_STATE_RESOLVE_SOURCE, dc.RESOURCE_STATE_RENDER_TARGET);
    }
}

fn bind_vertex_buffers(cmd_list: ?*anyopaque, cmd: RecordedRenderPass) void {
    for (cmd.vertex_buffers, cmd.vertex_buffer_offsets, cmd.vertex_buffer_sizes, 0..) |maybe_buf, offset, size, slot| {
        if (maybe_buf == null or size == 0 or size > std.math.maxInt(u32)) continue;
        bridge.c.d3d12_bridge_command_list_ia_set_vertex_buffers(
            cmd_list,
            @intCast(slot),
            1,
            maybe_buf,
            @intCast(size),
            0,
            offset,
        );
    }
}

fn bind_index_buffer(cmd_list: ?*anyopaque, cmd: RecordedRenderPass) void {
    if (!cmd.indexed) return;
    if (cmd.index_buffer == null or cmd.index_buffer_size == 0 or cmd.index_buffer_size > std.math.maxInt(u32)) return;
    bridge.c.d3d12_bridge_command_list_ia_set_index_buffer(
        cmd_list,
        cmd.index_buffer,
        cmd.index_format,
        @intCast(cmd.index_buffer_size),
        cmd.index_offset,
    );
}

fn texture_view_from_handle(handle: u64) ?*const DoeTextureView {
    if (handle == 0) return null;
    return native_helpers.cast(DoeTextureView, @ptrFromInt(handle));
}

fn resolved_layer_count(view: *const DoeTextureView) u32 {
    if (view.array_layer_count != 0) return view.array_layer_count;
    return switch (view.dimension) {
        model_gpu_types.WGPUTextureViewDimension_2DArray, model_gpu_types.WGPUTextureViewDimension_CubeArray => blk: {
            if (view.tex.depth_or_array_layers <= view.base_array_layer) break :blk 1;
            break :blk view.tex.depth_or_array_layers - view.base_array_layer;
        },
        else => 1,
    };
}

fn resolve_view_format(view: *const DoeTextureView, fallback: u32) u32 {
    if (view.format != 0) return view.format;
    if (view.tex.format != 0) return view.tex.format;
    return fallback;
}

fn resolve_render_view_dimension(view: *const DoeTextureView) u32 {
    if (view.dimension != 0) return view.dimension;
    return if (view.tex.dimension == model_gpu_types.WGPUTextureDimension_3D)
        model_gpu_types.WGPUTextureViewDimension_3D
    else if (view.base_array_layer > 0 or resolved_layer_count(view) > 1)
        model_gpu_types.WGPUTextureViewDimension_2DArray
    else
        model_gpu_types.WGPUTextureViewDimension_2D;
}

fn resolve_depth_view_dimension(view: *const DoeTextureView) u32 {
    return switch (resolve_render_view_dimension(view)) {
        model_gpu_types.WGPUTextureViewDimension_2DArray => abi_texture.WGPUTextureViewDimension_2DArrayDepth,
        else => abi_texture.WGPUTextureViewDimension_2DDepth,
    };
}

fn view_mip_extent(base_extent: u32, mip_level: u32) u32 {
    if (base_extent == 0) return 1;
    const shift: u5 = @intCast(@min(mip_level, @as(u32, 31)));
    return @max(@as(u32, 1), base_extent >> shift);
}

fn texture_subresource_index(view: *const DoeTextureView, relative_layer: u32) u32 {
    const layer = view.base_array_layer + relative_layer;
    return view.base_mip_level + (layer * view.tex.mip_level_count);
}

fn map_topology(topology: u32) c_int {
    return switch (topology) {
        0x00000001 => dc.D3D_PRIMITIVE_TOPOLOGY_POINTLIST,
        0x00000002 => dc.D3D_PRIMITIVE_TOPOLOGY_LINELIST,
        0x00000003 => dc.D3D_PRIMITIVE_TOPOLOGY_LINESTRIP,
        0x00000005 => dc.D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,
        else => dc.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,
    };
}

test "resolved_layer_count respects explicit and implicit view layers" {
    var tex = DoeTexture{ .depth_or_array_layers = 6 };
    var view = DoeTextureView{
        .tex = &tex,
        .dimension = model_gpu_types.WGPUTextureViewDimension_2DArray,
        .base_array_layer = 2,
        .array_layer_count = 0,
    };
    try std.testing.expectEqual(@as(u32, 4), resolved_layer_count(&view));
    view.array_layer_count = 3;
    try std.testing.expectEqual(@as(u32, 3), resolved_layer_count(&view));
}

test "texture_subresource_index uses mip and base array layer" {
    var tex = DoeTexture{ .mip_level_count = 4 };
    var view = DoeTextureView{
        .tex = &tex,
        .base_mip_level = 1,
        .base_array_layer = 2,
    };
    try std.testing.expectEqual(@as(u32, 9), texture_subresource_index(&view, 0));
    try std.testing.expectEqual(@as(u32, 13), texture_subresource_index(&view, 1));
}
