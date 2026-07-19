const std = @import("std");
const model_render_types = @import("../../../contracts/model/model_render_types.zig");
const bridge = @import("../d3d12_bridge_decls.zig");

pub const ResolvedVertexAttribute = struct {
    format: u32,
    offset: u64,
    shader_location: u32,
    buffer_slot: u32,
};

pub const PipelineKey = struct {
    target_format: u32 = 0,
    depth_stencil_format: u32 = 0,
    sample_count: u32 = 1,
    topology: u32 = 0x00000004,
    front_face: u32 = 0x00000001,
    cull_mode: u32 = 0x00000001,
    blend_enabled: bool = false,
    color_operation: u32 = 1,
    color_src_factor: u32 = 2,
    color_dst_factor: u32 = 1,
    alpha_operation: u32 = 1,
    alpha_src_factor: u32 = 2,
    alpha_dst_factor: u32 = 1,
    color_write_mask: u32 = 0xF,
    depth_compare: u32 = 0x00000008,
    depth_write_enabled: bool = false,
    stencil_front_compare: u32 = 0x00000008,
    stencil_front_fail_op: u32 = 0,
    stencil_front_depth_fail_op: u32 = 0,
    stencil_front_pass_op: u32 = 0,
    stencil_back_compare: u32 = 0x00000008,
    stencil_back_fail_op: u32 = 0,
    stencil_back_depth_fail_op: u32 = 0,
    stencil_back_pass_op: u32 = 0,
    stencil_read_mask: u32 = 0xFFFF_FFFF,
    stencil_write_mask: u32 = 0xFFFF_FFFF,
    depth_bias: i32 = 0,
    depth_bias_slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
    unclipped_depth: bool = false,
    vertex_buffer_count: u32 = 0,
    vertex_buffer_strides: [model_render_types.MAX_VERTEX_BUFFERS]u64 = [_]u64{0} ** model_render_types.MAX_VERTEX_BUFFERS,
    vertex_step_modes: [model_render_types.MAX_VERTEX_BUFFERS]u32 = [_]u32{0} ** model_render_types.MAX_VERTEX_BUFFERS,
    vertex_attribute_count: u32 = 0,
    vertex_attribute_formats: [model_render_types.MAX_VERTEX_ATTRIBUTES]u32 = [_]u32{0} ** model_render_types.MAX_VERTEX_ATTRIBUTES,
    vertex_attribute_offsets: [model_render_types.MAX_VERTEX_ATTRIBUTES]u64 = [_]u64{0} ** model_render_types.MAX_VERTEX_ATTRIBUTES,
    vertex_attribute_locations: [model_render_types.MAX_VERTEX_ATTRIBUTES]u32 = [_]u32{0} ** model_render_types.MAX_VERTEX_ATTRIBUTES,
    vertex_attribute_buffer_slots: [model_render_types.MAX_VERTEX_ATTRIBUTES]u32 = [_]u32{0} ** model_render_types.MAX_VERTEX_ATTRIBUTES,
};

pub fn build_pipeline_key(cmd: model_render_types.RenderDrawCommand) PipelineKey {
    var key = PipelineKey{
        .target_format = cmd.target_format,
        .depth_stencil_format = cmd.depth_stencil_format,
        .sample_count = if (cmd.sample_count == 0) 1 else cmd.sample_count,
        .topology = cmd.topology,
        .front_face = cmd.front_face,
        .cull_mode = cmd.cull_mode,
        .blend_enabled = cmd.blend_enabled,
        .color_operation = cmd.color_operation,
        .color_src_factor = cmd.color_src_factor,
        .color_dst_factor = cmd.color_dst_factor,
        .alpha_operation = cmd.alpha_operation,
        .alpha_src_factor = cmd.alpha_src_factor,
        .alpha_dst_factor = cmd.alpha_dst_factor,
        .color_write_mask = cmd.color_write_mask,
        .depth_compare = cmd.depth_compare,
        .depth_write_enabled = cmd.depth_write_enabled,
        .stencil_front_compare = cmd.stencil_front_compare,
        .stencil_front_fail_op = cmd.stencil_front_fail_op,
        .stencil_front_depth_fail_op = cmd.stencil_front_depth_fail_op,
        .stencil_front_pass_op = cmd.stencil_front_pass_op,
        .stencil_back_compare = cmd.stencil_back_compare,
        .stencil_back_fail_op = cmd.stencil_back_fail_op,
        .stencil_back_depth_fail_op = cmd.stencil_back_depth_fail_op,
        .stencil_back_pass_op = cmd.stencil_back_pass_op,
        .stencil_read_mask = cmd.stencil_read_mask,
        .stencil_write_mask = cmd.stencil_write_mask,
        .depth_bias = cmd.depth_bias,
        .depth_bias_slope_scale = cmd.depth_bias_slope_scale,
        .depth_bias_clamp = cmd.depth_bias_clamp,
        .unclipped_depth = cmd.unclipped_depth,
        .vertex_buffer_count = resolve_vertex_buffer_count(cmd),
        .vertex_attribute_count = resolve_vertex_attribute_count(cmd),
    };

    var slot: u32 = 0;
    while (slot < key.vertex_buffer_count and slot < @as(u32, model_render_types.MAX_VERTEX_BUFFERS)) : (slot += 1) {
        key.vertex_buffer_strides[slot] = resolve_vertex_buffer_stride_fallback(cmd, slot);
        key.vertex_step_modes[slot] = resolve_vertex_step_mode(cmd, slot);
    }
    fill_vertex_attributes_into_key(cmd, &key);
    return key;
}

pub fn resolve_vertex_attribute(cmd: model_render_types.RenderDrawCommand, index: u32) ?ResolvedVertexAttribute {
    if (index < cmd.vertex_attribute_count) {
        return .{
            .format = cmd.vertex_attribute_formats[index],
            .offset = cmd.vertex_attribute_offsets[index],
            .shader_location = cmd.vertex_attribute_locations[index],
            .buffer_slot = cmd.vertex_attribute_buffer_slots[index],
        };
    }
    if (cmd.vertex_layouts) |layouts| {
        var base: u32 = 0;
        var slot: usize = 0;
        while (slot < @min(layouts.len, model_render_types.MAX_VERTEX_BUFFERS)) : (slot += 1) {
            const layout = layouts[slot];
            if (index < base + layout.attribute_count) {
                const attr = layout.attributes[index - base];
                return .{
                    .format = attr.format,
                    .offset = attr.offset,
                    .shader_location = attr.shader_location,
                    .buffer_slot = @intCast(slot),
                };
            }
            base += layout.attribute_count;
        }
    }
    return null;
}

fn fill_vertex_attributes_into_key(cmd: model_render_types.RenderDrawCommand, key: *PipelineKey) void {
    var i: u32 = 0;
    while (i < key.vertex_attribute_count and i < @as(u32, model_render_types.MAX_VERTEX_ATTRIBUTES)) : (i += 1) {
        const attr = resolve_vertex_attribute(cmd, i) orelse break;
        key.vertex_attribute_formats[i] = attr.format;
        key.vertex_attribute_offsets[i] = attr.offset;
        key.vertex_attribute_locations[i] = attr.shader_location;
        key.vertex_attribute_buffer_slots[i] = attr.buffer_slot;
    }
}

pub fn resolve_vertex_buffer_count(cmd: model_render_types.RenderDrawCommand) u32 {
    if (cmd.vertex_buffer_count != 0) return @min(cmd.vertex_buffer_count, @as(u32, model_render_types.MAX_VERTEX_BUFFERS));
    if (cmd.vertex_binding_count != 0) return @min(cmd.vertex_binding_count, @as(u32, model_render_types.MAX_VERTEX_BUFFERS));
    if (cmd.vertex_layout_count != 0) return @min(cmd.vertex_layout_count, @as(u32, model_render_types.MAX_VERTEX_BUFFERS));
    if (cmd.vertex_layouts) |layouts| return @min(@as(u32, @intCast(layouts.len)), @as(u32, model_render_types.MAX_VERTEX_BUFFERS));
    return 0;
}

pub fn resolve_vertex_attribute_count(cmd: model_render_types.RenderDrawCommand) u32 {
    if (cmd.vertex_attribute_count != 0) return @min(cmd.vertex_attribute_count, @as(u32, model_render_types.MAX_VERTEX_ATTRIBUTES));
    if (cmd.vertex_layouts) |layouts| {
        var total: u32 = 0;
        var i: usize = 0;
        while (i < @min(layouts.len, model_render_types.MAX_VERTEX_BUFFERS)) : (i += 1) total += layouts[i].attribute_count;
        return @min(total, @as(u32, model_render_types.MAX_VERTEX_ATTRIBUTES));
    }
    return 0;
}

pub fn resolve_vertex_buffer_handle(cmd: model_render_types.RenderDrawCommand, slot: u32) ?*anyopaque {
    if (slot < cmd.vertex_buffer_count and cmd.vertex_buffer_handles[slot] != 0) {
        return @ptrFromInt(cmd.vertex_buffer_handles[slot]);
    }
    if (cmd.vertex_bindings) |bindings| {
        for (bindings) |binding| {
            if (binding.slot == slot) return binding.handle;
        }
    }
    return null;
}

pub fn resolve_vertex_buffer_offset(cmd: model_render_types.RenderDrawCommand, slot: u32) u64 {
    if (slot < cmd.vertex_buffer_count and cmd.vertex_buffer_handles[slot] != 0) {
        return cmd.vertex_buffer_offsets[slot];
    }
    if (cmd.vertex_bindings) |bindings| {
        for (bindings) |binding| {
            if (binding.slot == slot) return binding.offset;
        }
    }
    return 0;
}

pub fn resolve_vertex_step_mode(cmd: model_render_types.RenderDrawCommand, slot: u32) u32 {
    const fallback = resolve_vertex_step_mode_fallback(cmd, slot);
    return if (fallback != 0) fallback else model_render_types.WGPUVertexStepMode_Vertex;
}

fn resolve_vertex_step_mode_fallback(cmd: model_render_types.RenderDrawCommand, slot: u32) u32 {
    if (slot < cmd.vertex_layout_count and cmd.vertex_step_modes[slot] != 0) {
        return cmd.vertex_step_modes[slot];
    }
    if (cmd.vertex_layouts) |layouts| {
        if (slot < layouts.len) return layouts[slot].step_mode;
    }
    return 0;
}

pub fn resolve_vertex_buffer_stride_fallback(cmd: model_render_types.RenderDrawCommand, slot: u32) u64 {
    if (slot < cmd.vertex_layout_count and cmd.vertex_buffer_strides[slot] != 0) {
        return cmd.vertex_buffer_strides[slot];
    }
    if (cmd.vertex_layouts) |layouts| {
        if (slot < layouts.len) return layouts[slot].array_stride;
    }
    return 0;
}

pub fn resolve_vertex_buffer_stride(cmd: model_render_types.RenderDrawCommand, slot: u32) !u32 {
    var stride = resolve_vertex_buffer_stride_fallback(cmd, slot);
    if (stride == 0) {
        const attribute_count = resolve_vertex_attribute_count(cmd);
        var i: u32 = 0;
        while (i < attribute_count) : (i += 1) {
            const attr = resolve_vertex_attribute(cmd, i) orelse continue;
            if (attr.buffer_slot != slot) continue;
            stride = @max(stride, attr.offset + try vertex_format_size(attr.format));
        }
    }
    if (stride == 0 or stride > std.math.maxInt(u32)) return error.UnsupportedFeature;
    return @intCast(stride);
}

pub fn resolve_index_buffer_handle(cmd: model_render_types.RenderDrawCommand) ?*anyopaque {
    if (cmd.index_buffer_handle != 0) return @ptrFromInt(cmd.index_buffer_handle);
    if (cmd.index_binding) |binding| return binding.handle;
    return null;
}

pub fn resolve_index_buffer_offset(cmd: model_render_types.RenderDrawCommand) u64 {
    if (cmd.index_buffer_handle != 0) return cmd.index_buffer_offset;
    if (cmd.index_binding) |binding| return binding.offset;
    return 0;
}

pub fn resolve_index_format(cmd: model_render_types.RenderDrawCommand) ?u32 {
    if (cmd.index_format != 0) return cmd.index_format;
    if (cmd.index_binding) |binding| return binding.format;
    return null;
}

pub fn vertex_format_size(format: u32) !u64 {
    return switch (format) {
        0x00000001, 0x00000004, 0x00000007, 0x0000000A => 1,
        0x00000002, 0x00000005, 0x00000008, 0x0000000B, 0x0000000D, 0x00000010, 0x00000013, 0x00000016, 0x0000001D, 0x00000021, 0x00000025 => 2,
        0x00000003, 0x00000006, 0x00000009, 0x0000000C, 0x0000000E, 0x00000011, 0x00000014, 0x00000017, 0x00000019, 0x00000029, 0x0000002A => 4,
        0x0000000F, 0x00000012, 0x00000015, 0x00000018, 0x0000001A, 0x0000001E, 0x00000022, 0x00000026 => 8,
        0x0000001B, 0x00000023, 0x00000027 => 12,
        0x0000001C, 0x0000001F, 0x00000024, 0x00000028 => 16,
        else => error.UnsupportedFeature,
    };
}

// --- Tests ---

test "PipelineKey defaults" {
    const key = PipelineKey{};
    try std.testing.expectEqual(@as(u32, 0), key.target_format);
    try std.testing.expectEqual(@as(u32, 1), key.sample_count);
    try std.testing.expect(!key.blend_enabled);
    try std.testing.expectEqual(@as(u32, 0), key.vertex_buffer_count);
    try std.testing.expectEqual(@as(u32, 0), key.vertex_attribute_count);
}

test "build_pipeline_key from default RenderDrawCommand" {
    const cmd = model_render_types.RenderDrawCommand{ .draw_count = 1 };
    const key = build_pipeline_key(cmd);
    try std.testing.expectEqual(cmd.target_format, key.target_format);
    try std.testing.expectEqual(@as(u32, 1), key.sample_count);
    try std.testing.expectEqual(@as(u32, 0), key.vertex_buffer_count);
}

test "resolve_vertex_buffer_count returns 0 for default" {
    const cmd = model_render_types.RenderDrawCommand{ .draw_count = 1 };
    try std.testing.expectEqual(@as(u32, 0), resolve_vertex_buffer_count(cmd));
}

test "resolve_vertex_attribute_count returns 0 for default" {
    const cmd = model_render_types.RenderDrawCommand{ .draw_count = 1 };
    try std.testing.expectEqual(@as(u32, 0), resolve_vertex_attribute_count(cmd));
}

test "vertex_format_size returns correct sizes" {
    try std.testing.expectEqual(@as(u64, 4), try vertex_format_size(0x00000003));
    try std.testing.expectEqual(@as(u64, 8), try vertex_format_size(0x0000000F));
    try std.testing.expectEqual(@as(u64, 16), try vertex_format_size(0x0000001C));
}

test "vertex_format_size returns error for unknown" {
    try std.testing.expectError(error.UnsupportedFeature, vertex_format_size(0xDEAD));
}
