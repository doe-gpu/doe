const model_render_types = @import("../../contracts/model/model_render_types.zig");
const binding_contract = @import("../../contracts/binding.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const query_native = @import("../resource/doe_query_native.zig");
const std = @import("std");
const upstream = @import("../../core/abi/generated/webgpu_upstream.zig").c;
const shared = @import("vulkan_render_shared.zig");

const RESOURCE_KIND_STORAGE_TEXTURE = binding_contract.layoutResourceKindCode(.storage_texture);

fn vulkan_texture_view_key(view: *shared.DoeTextureView) u64 {
    if (view.handle) |handle| return @intFromPtr(handle);
    return view.tex.vk_id;
}

fn populate_draw_cmd_from_pass(cmd: *model_render_types.RenderDrawCommand, pass: *shared.DoeRenderPass) void {
    if (pass.pipeline) |pip| {
        cmd.vertex_spirv = pip.vertex_spirv_data;
        cmd.fragment_spirv = pip.fragment_spirv_data;
        cmd.vertex_entry_point = pip.vertex_entry_point;
        cmd.fragment_entry_point = pip.fragment_entry_point;
        cmd.vertex_layout_count = pip.vertex_buffer_count;
        cmd.vertex_buffer_strides = pip.vertex_buffer_strides;
        cmd.vertex_step_modes = pip.vertex_step_modes;
        cmd.vertex_attribute_count = pip.vertex_attribute_count;
        cmd.vertex_attribute_formats = pip.vertex_attribute_formats;
        cmd.vertex_attribute_offsets = pip.vertex_attribute_offsets;
        cmd.vertex_attribute_locations = pip.vertex_attribute_locations;
        cmd.vertex_attribute_buffer_slots = pip.vertex_attribute_buffer_slots;
    }

    if (pass.target_view_handle != 0) {
        if (native_helpers.cast(shared.DoeTextureView, @ptrFromInt(pass.target_view_handle))) |tv| {
            cmd.target_handle = tv.tex.vk_id;
            cmd.target_view_handle = if (tv.handle) |h| @intFromPtr(h) else tv.tex.vk_id;
            cmd.target_width = @max(1, tv.tex.width >> @intCast(tv.base_mip_level));
            cmd.target_height = @max(1, tv.tex.height >> @intCast(tv.base_mip_level));
        }
    }
    cmd.target_format = pass.target_format;
    cmd.sample_count = if (pass.sample_count != 0) pass.sample_count else cmd.sample_count;
    cmd.clear_color = .{
        @floatCast(pass.clear_r),
        @floatCast(pass.clear_g),
        @floatCast(pass.clear_b),
        @floatCast(pass.clear_a),
    };
    cmd.color_load = if (pass.attachments_started or pass.color_load_op == upstream.WGPULoadOp_Load)
        .load
    else
        .clear;
    if (pass.depth_target_view_handle != 0) {
        if (native_helpers.cast(shared.DoeTextureView, @ptrFromInt(pass.depth_target_view_handle))) |view| {
            cmd.depth_target_handle = view.tex.vk_id;
            cmd.depth_target_view_handle = if (view.handle) |handle| @intFromPtr(handle) else view.tex.vk_id;
            cmd.depth_stencil_format = pass.depth_stencil_format;
        }
    }
    cmd.depth_load = if (pass.attachments_started or pass.depth_read_only or pass.depth_load_op == upstream.WGPULoadOp_Load) .load else .clear;
    cmd.stencil_load = if (pass.attachments_started or pass.stencil_read_only or pass.stencil_load_op == upstream.WGPULoadOp_Load) .load else .clear;
    cmd.depth_clear_value = pass.depth_clear_value;
    cmd.stencil_clear_value = pass.stencil_clear_value;

    var bound_vertex_count: u32 = 0;
    var bound_slot: usize = 0;
    while (bound_slot < native_shared.MAX_VERTEX_BUFFERS) : (bound_slot += 1) {
        if (pass.vertex_buffers[bound_slot]) |buffer| {
            cmd.vertex_buffer_handles[bound_slot] = buffer.vk_id;
            cmd.vertex_buffer_offsets[bound_slot] = pass.vertex_buffer_offsets[bound_slot];
            bound_vertex_count = @intCast(bound_slot + 1);
        }
    }
    cmd.vertex_buffer_count = bound_vertex_count;

    if (pass.index_buffer) |buffer| {
        cmd.index_buffer_handle = buffer.vk_id;
        cmd.index_buffer_offset = pass.index_offset;
        cmd.index_format = pass.index_format;
    }

    var tex_count: u32 = 0;
    var samp_count: u32 = 0;
    var buffer_count: u32 = 0;
    for (pass.bind_groups) |maybe_bg| {
        const bg = maybe_bg orelse continue;
        var binding: usize = 0;
        while (binding < native_shared.MAX_BIND and buffer_count < model_render_types.MAX_RENDER_BIND_ENTRIES) : (binding += 1) {
            const mask = @as(u64, 1) << @intCast(binding);
            if ((bg.vk_buffer_binding_mask & mask) == 0) continue;
            const handle = bg.vk_buffer_handles[binding];
            if (handle == 0) continue;
            cmd.bind_buffer_handles[buffer_count] = handle;
            cmd.bind_buffer_bindings[buffer_count] = @intCast(binding);
            cmd.bind_buffer_types[buffer_count] = bg.vk_buffer_binding_types[binding];
            cmd.bind_buffer_offsets[buffer_count] = bg.offsets[binding];
            cmd.bind_buffer_sizes[buffer_count] = bg.buffer_sizes[binding];
            buffer_count += 1;
        }
        const texture_count = @min(
            @as(usize, @intCast(bg.render_texture_view_count)),
            model_render_types.MAX_RENDER_BIND_ENTRIES,
        );
        for (bg.render_texture_views[0..texture_count], 0..) |maybe_tv, texture_index| {
            if (maybe_tv == null) continue;
            const view = native_helpers.cast(shared.DoeTextureView, maybe_tv.?) orelse continue;
            const texture_key = vulkan_texture_view_key(view);
            if (texture_key == 0) continue;
            if (tex_count < model_render_types.MAX_RENDER_BIND_ENTRIES) {
                cmd.bind_texture_handles[tex_count] = texture_key;
                cmd.bind_texture_bindings[tex_count] = bg.render_texture_bindings[texture_index];
                cmd.bind_texture_storage[tex_count] = bg.render_texture_resource_kinds[texture_index] == RESOURCE_KIND_STORAGE_TEXTURE;
                tex_count += 1;
            }
        }
        const sampler_count = @min(
            @as(usize, @intCast(bg.render_sampler_count)),
            model_render_types.MAX_RENDER_BIND_ENTRIES,
        );
        for (bg.render_samplers[0..sampler_count], 0..) |maybe_s, sampler_index| {
            if (maybe_s == null) continue;
            if (samp_count < model_render_types.MAX_RENDER_BIND_ENTRIES) {
                cmd.bind_sampler_handles[samp_count] = @intFromPtr(maybe_s.?);
                cmd.bind_sampler_bindings[samp_count] = bg.render_sampler_bindings[sampler_index];
                samp_count += 1;
            }
        }
    }
    cmd.bind_texture_count = tex_count;
    cmd.bind_sampler_count = samp_count;
    cmd.bind_buffer_count = buffer_count;
}

fn base_vulkan_render_cmd(pass: *shared.DoeRenderPass) model_render_types.RenderDrawCommand {
    const occlusion_qs = if (pass.occlusion_query_active and pass.occlusion_query_set != null)
        native_helpers.cast(query_native.DoeQuerySet, pass.occlusion_query_set)
    else
        null;
    const pip_unclipped = if (pass.pipeline) |pip| pip.unclipped_depth else false;
    return .{
        .draw_count = 1,
        .vertex_count = 0,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
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
        .vertex_layout_count = if (pass.pipeline) |pip| pip.vertex_layout_count else 0,
        .vertex_layouts = if (pass.pipeline) |pip| if (pip.vertex_layout_count > 0) pip.vertex_layouts[0..@intCast(pip.vertex_layout_count)] else null else null,
        .topology = if (pass.pipeline) |pip| pip.topology else 0x00000004,
        .front_face = if (pass.pipeline) |pip| pip.front_face else 0x00000001,
        .cull_mode = if (pass.pipeline) |pip| pip.cull_mode else 0x00000001,
        .blend_enabled = if (pass.pipeline) |pip| pip.blend_enabled else false,
        .color_operation = if (pass.pipeline) |pip| pip.color_operation else 1,
        .color_src_factor = if (pass.pipeline) |pip| pip.color_src_factor else 2,
        .color_dst_factor = if (pass.pipeline) |pip| pip.color_dst_factor else 1,
        .alpha_operation = if (pass.pipeline) |pip| pip.alpha_operation else 1,
        .alpha_src_factor = if (pass.pipeline) |pip| pip.alpha_src_factor else 2,
        .alpha_dst_factor = if (pass.pipeline) |pip| pip.alpha_dst_factor else 1,
        .color_write_mask = if (pass.pipeline) |pip| pip.color_write_mask else 0xF,
        .sample_count = if (pass.pipeline) |pip| pip.sample_count else 1,
        .blend_constant = pass.blend_constant,
        .stencil_reference = pass.stencil_reference,
        .occlusion_query_pool = if (occlusion_qs) |qs| qs.vk_query_pool else 0,
        .occlusion_query_index = if (occlusion_qs != null) pass.occlusion_query_index else null,
        .depth_stencil_format = if (pass.pipeline) |pip| pip.depth_stencil_format else 0,
        .depth_compare = if (pass.pipeline) |pip| pip.depth_compare else pass.depth_compare,
        .depth_write_enabled = if (pass.pipeline) |pip| pip.depth_write_enabled else pass.depth_write_enabled,
        .stencil_front_compare = if (pass.pipeline) |pip| pip.stencil_front_compare else 0x00000008,
        .stencil_front_fail_op = if (pass.pipeline) |pip| pip.stencil_front_fail_op else 0,
        .stencil_front_depth_fail_op = if (pass.pipeline) |pip| pip.stencil_front_depth_fail_op else 0,
        .stencil_front_pass_op = if (pass.pipeline) |pip| pip.stencil_front_pass_op else 0,
        .stencil_back_compare = if (pass.pipeline) |pip| pip.stencil_back_compare else 0x00000008,
        .stencil_back_fail_op = if (pass.pipeline) |pip| pip.stencil_back_fail_op else 0,
        .stencil_back_depth_fail_op = if (pass.pipeline) |pip| pip.stencil_back_depth_fail_op else 0,
        .stencil_back_pass_op = if (pass.pipeline) |pip| pip.stencil_back_pass_op else 0,
        .stencil_read_mask = if (pass.pipeline) |pip| pip.stencil_read_mask else 0xFFFF_FFFF,
        .stencil_write_mask = if (pass.pipeline) |pip| pip.stencil_write_mask else 0xFFFF_FFFF,
        .unclipped_depth = pip_unclipped,
    };
}

fn recordRender(pass: *shared.DoeRenderPass, cmd: model_render_types.RenderDrawCommand, clear_only: bool) void {
    pass.enc.cmds.append(native_helpers.alloc, .{ .vulkan_render = .{
        .command = cmd,
        .pipeline = if (pass.pipeline) |pipeline| native_helpers.toOpaque(pipeline) else null,
        .clear_only = clear_only,
    } }) catch std.debug.panic("Vulkan render: OOM recording draw state", .{});
    pass.attachments_started = true;
}

pub fn vulkan_render_pass_draw(pass: *shared.DoeRenderPass, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
    var cmd = base_vulkan_render_cmd(pass);
    cmd.vertex_count = vertex_count;
    cmd.instance_count = instance_count;
    cmd.first_vertex = first_vertex;
    cmd.first_instance = first_instance;
    populate_draw_cmd_from_pass(&cmd, pass);
    recordRender(pass, cmd, false);
}

pub fn vulkan_render_pass_draw_indexed(pass: *shared.DoeRenderPass, index_count: u32, instance_count: u32, first_index: u32, base_vertex: i32, first_instance: u32) void {
    var cmd = base_vulkan_render_cmd(pass);
    cmd.instance_count = instance_count;
    cmd.first_instance = first_instance;
    cmd.index_count = index_count;
    cmd.first_index = first_index;
    cmd.base_vertex = base_vertex;
    populate_draw_cmd_from_pass(&cmd, pass);
    recordRender(pass, cmd, false);
}

pub fn vulkan_render_pass_draw_indirect(pass: *shared.DoeRenderPass, indirect_buffer_raw: ?*anyopaque, indirect_offset: u64) void {
    const indirect = native_helpers.cast(shared.DoeBuffer, indirect_buffer_raw) orelse return;
    if (indirect.error_object or indirect.vk_id == 0) return;
    var cmd = base_vulkan_render_cmd(pass);
    cmd.indirect_buffer_handle = indirect.vk_id;
    cmd.indirect_offset = indirect_offset;
    populate_draw_cmd_from_pass(&cmd, pass);
    recordRender(pass, cmd, false);
}

pub fn vulkan_render_pass_draw_indexed_indirect(pass: *shared.DoeRenderPass, indirect_buffer_raw: ?*anyopaque, indirect_offset: u64) void {
    const indirect = native_helpers.cast(shared.DoeBuffer, indirect_buffer_raw) orelse return;
    if (indirect.error_object or indirect.vk_id == 0) return;
    var cmd = base_vulkan_render_cmd(pass);
    cmd.indirect_buffer_handle = indirect.vk_id;
    cmd.indirect_offset = indirect_offset;
    cmd.index_count = 0;
    populate_draw_cmd_from_pass(&cmd, pass);
    recordRender(pass, cmd, false);
}

pub fn vulkan_render_pass_end(pass: *shared.DoeRenderPass) void {
    if (pass.attachments_started) return;
    var cmd = base_vulkan_render_cmd(pass);
    populate_draw_cmd_from_pass(&cmd, pass);
    recordRender(pass, cmd, true);
}
