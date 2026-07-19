const std = @import("std");
const log = std.log.scoped(.d3d12_render);
const model_render_types = @import("../../../contracts/model/model_render_types.zig");
const common_timing = @import("../../common/timing.zig");
const webgpu = @import("../../runtime_types.zig");
const dc = @import("../d3d12_constants.zig");
const d3d12_formats = @import("../d3d12_formats.zig");
const d3d12_depth_stencil = @import("../resources/d3d12_depth_stencil.zig");
const d3d12_descriptors = @import("../d3d12_descriptors.zig");
const d3d12_render_vertex = @import("d3d12_render_vertex.zig");
const render_bundle = @import("../../../runtime/render/render_bundle.zig");
const bridge = @import("../d3d12_bridge_decls.zig");

const PipelineKey = d3d12_render_vertex.PipelineKey;
const build_pipeline_key = d3d12_render_vertex.build_pipeline_key;
const resolve_vertex_buffer_count = d3d12_render_vertex.resolve_vertex_buffer_count;
const resolve_vertex_attribute_count = d3d12_render_vertex.resolve_vertex_attribute_count;
const resolve_vertex_buffer_handle = d3d12_render_vertex.resolve_vertex_buffer_handle;
const resolve_vertex_buffer_offset = d3d12_render_vertex.resolve_vertex_buffer_offset;
const resolve_vertex_buffer_stride = d3d12_render_vertex.resolve_vertex_buffer_stride;
const resolve_vertex_buffer_stride_fallback = d3d12_render_vertex.resolve_vertex_buffer_stride_fallback;
const resolve_vertex_step_mode = d3d12_render_vertex.resolve_vertex_step_mode;
const resolve_vertex_attribute = d3d12_render_vertex.resolve_vertex_attribute;
const resolve_index_buffer_handle = d3d12_render_vertex.resolve_index_buffer_handle;
const resolve_index_buffer_offset = d3d12_render_vertex.resolve_index_buffer_offset;
const resolve_index_format = d3d12_render_vertex.resolve_index_format;
const vertex_format_size = d3d12_render_vertex.vertex_format_size;

const D3D12InputElementDesc = bridge.D3D12InputElementDesc;
const D3D12GraphicsPipelineDesc = bridge.D3D12GraphicsPipelineDesc;

const RENDER_ATTACHMENT_USAGE: u32 = 0x00000010;
const DRAW_INDIRECT_ARG_BYTES: usize = 16;
const DRAW_INDEXED_INDIRECT_ARG_BYTES: usize = 20;
const D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA = dc.INPUT_CLASSIFICATION_PER_VERTEX_DATA;
const D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA = dc.INPUT_CLASSIFICATION_PER_INSTANCE_DATA;

const passthrough_vs_source =
    \\struct VSOutput {
    \\    float4 position : SV_Position;
    \\    float4 color : COLOR0;
    \\};
    \\VSOutput main_vertex(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID) {
    \\    static const float2 positions[3] = {
    \\        float2(-0.5f, -0.5f),
    \\        float2( 0.5f, -0.5f),
    \\        float2( 0.0f,  0.5f)
    \\    };
    \\    VSOutput output;
    \\    float2 p = positions[vertex_id % 3];
    \\    output.position = float4(p, 0.0f, 1.0f);
    \\    output.color = float4((instance_id & 1u) ? 0.75f : 0.25f, 0.5f, 0.9f, 1.0f);
    \\    return output;
    \\}
;

const passthrough_ps_source =
    \\float4 main_fragment(float4 position : SV_Position, float4 color : COLOR0) : SV_Target0 {
    \\    return color;
    \\}
;

pub const RenderMetrics = struct {
    setup_ns: u64 = 0,
    encode_ns: u64 = 0,
    submit_wait_ns: u64 = 0,
    draw_count: u32 = 0,
};

pub const RenderSubmission = struct {
    metrics: RenderMetrics = .{},
    cmd_allocator: ?*anyopaque = null,
    cmd_list: ?*anyopaque = null,
};

pub const RenderState = struct {
    root_signature: ?*anyopaque = null,
    graphics_pipeline: ?*anyopaque = null,
    render_target: ?*anyopaque = null,
    rtv_heap: ?*anyopaque = null,
    depth_stencil: d3d12_depth_stencil.DepthStencilState = .{},
    cmd_allocator: ?*anyopaque = null,
    cmd_list: ?*anyopaque = null,
    has_cmd: bool = false,
    cached_format: u32 = 0,
    cached_width: u32 = 0,
    cached_height: u32 = 0,
    cached_pipeline_key: PipelineKey = .{},
    has_cached_pipeline_key: bool = false,
    draw_cmd_sig: ?*anyopaque = null,
    draw_indexed_cmd_sig: ?*anyopaque = null,
    indirect_arg_buffer: ?*anyopaque = null,

    pub fn execute_render_draw(
        self: *RenderState,
        device: ?*anyopaque,
        queue: ?*anyopaque,
        fence: ?*anyopaque,
        fence_value: *u64,
        cmd: model_render_types.RenderDrawCommand,
        is_indirect: bool,
        is_indexed_indirect: bool,
        queue_sync_mode: webgpu.QueueSyncMode,
        descriptor_state: *d3d12_descriptors.DescriptorHeapState,
    ) !RenderSubmission {
        const setup_start = common_timing.now_ns();

        const has_bind_groups = cmd.bind_texture_count > 0 or cmd.bind_sampler_count > 0;
        try self.ensure_pipeline_with_bindings(device, cmd, has_bind_groups);

        const setup_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);
        const encode_start = common_timing.now_ns();

        var cmd_allocator = self.cmd_allocator;
        var cmd_list = self.cmd_list;
        if (queue_sync_mode != .per_command) {
            cmd_allocator = bridge.c.d3d12_bridge_device_create_command_allocator(device) orelse return error.InvalidState;
            errdefer bridge.c.d3d12_bridge_release(cmd_allocator);
            cmd_list = bridge.c.d3d12_bridge_device_create_command_list(device, cmd_allocator) orelse return error.InvalidState;
            errdefer bridge.c.d3d12_bridge_release(cmd_list);
            bridge.c.d3d12_bridge_command_list_close(cmd_list);
        }

        if (bridge.c.d3d12_bridge_command_allocator_reset(cmd_allocator) != 0) return error.InvalidState;
        if (bridge.c.d3d12_bridge_command_list_reset(cmd_list, cmd_allocator) != 0) return error.InvalidState;

        bridge.c.d3d12_bridge_command_list_resource_barrier_transition(cmd_list, self.render_target, dc.RESOURCE_STATE_PRESENT, dc.RESOURCE_STATE_RENDER_TARGET);
        bridge.c.d3d12_bridge_command_list_set_graphics_root_signature(cmd_list, self.root_signature);
        bridge.c.d3d12_bridge_command_list_set_pipeline_state(cmd_list, self.graphics_pipeline);
        bridge.c.d3d12_bridge_command_list_set_render_targets(
            cmd_list,
            self.rtv_heap,
            0,
            if (has_depth_attachment(cmd)) self.depth_stencil.get_dsv_heap() else null,
            0,
        );

        // Bind texture/sampler descriptor tables if bind groups are active
        if (has_bind_groups) {
            try bind_model_descriptor_tables(cmd_list, device, descriptor_state, cmd);
        }

        const vp_w: f32 = cmd.viewport_width orelse @floatFromInt(cmd.target_width);
        const vp_h: f32 = cmd.viewport_height orelse @floatFromInt(cmd.target_height);
        bridge.c.d3d12_bridge_command_list_set_viewport(cmd_list, cmd.viewport_x, cmd.viewport_y, vp_w, vp_h, cmd.viewport_min_depth, cmd.viewport_max_depth);

        const sc_w: i32 = @intCast(cmd.scissor_width orelse cmd.target_width);
        const sc_h: i32 = @intCast(cmd.scissor_height orelse cmd.target_height);
        const sc_x: i32 = @intCast(cmd.scissor_x);
        const sc_y: i32 = @intCast(cmd.scissor_y);
        bridge.c.d3d12_bridge_command_list_set_scissor(cmd_list, sc_x, sc_y, sc_x + sc_w, sc_y + sc_h);

        bridge.c.d3d12_bridge_command_list_ia_set_primitive_topology(cmd_list, map_topology(cmd.topology));
        bridge.c.d3d12_bridge_command_list_set_blend_factor(cmd_list, &cmd.blend_constant);
        bridge.c.d3d12_bridge_command_list_set_stencil_ref(cmd_list, cmd.stencil_reference);
        try self.bind_vertex_and_index_buffers(cmd_list, cmd);

        var draw_count: u32 = 0;

        if (is_indexed_indirect) {
            try self.ensure_indexed_indirect(device);
            try self.write_indirect_args(cmd, true);
            var i: u32 = 0;
            while (i < cmd.draw_count) : (i += 1) {
                bridge.c.d3d12_bridge_command_list_execute_indirect(cmd_list, self.draw_indexed_cmd_sig, 1, self.indirect_arg_buffer, 0);
                draw_count += 1;
            }
        } else if (is_indirect) {
            try self.ensure_draw_indirect(device);
            try self.write_indirect_args(cmd, false);
            var i: u32 = 0;
            while (i < cmd.draw_count) : (i += 1) {
                bridge.c.d3d12_bridge_command_list_execute_indirect(cmd_list, self.draw_cmd_sig, 1, self.indirect_arg_buffer, 0);
                draw_count += 1;
            }
        } else {
            var i: u32 = 0;
            while (i < cmd.draw_count) : (i += 1) {
                if (cmd.index_count) |ic| {
                    bridge.c.d3d12_bridge_command_list_draw_indexed_instanced(cmd_list, ic, cmd.instance_count, cmd.first_index, cmd.base_vertex, cmd.first_instance);
                } else {
                    bridge.c.d3d12_bridge_command_list_draw_instanced(cmd_list, cmd.vertex_count, cmd.instance_count, cmd.first_vertex, cmd.first_instance);
                }
                draw_count += 1;
            }
        }

        bridge.c.d3d12_bridge_command_list_resource_barrier_transition(cmd_list, self.render_target, dc.RESOURCE_STATE_RENDER_TARGET, dc.RESOURCE_STATE_PRESENT);
        bridge.c.d3d12_bridge_command_list_close(cmd_list);

        const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);

        bridge.c.d3d12_bridge_queue_execute_command_list(queue, cmd_list);
        fence_value.* +|= 1;
        bridge.c.d3d12_bridge_queue_signal(queue, fence, fence_value.*);
        if (queue_sync_mode == .per_command) {
            const submit_start = common_timing.now_ns();
            bridge.c.d3d12_bridge_fence_wait(fence, fence_value.*);
            const submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_start);
            return .{ .metrics = .{ .setup_ns = setup_ns, .encode_ns = encode_ns, .submit_wait_ns = submit_wait_ns, .draw_count = draw_count } };
        }

        return .{
            .metrics = .{ .setup_ns = setup_ns, .encode_ns = encode_ns, .submit_wait_ns = 0, .draw_count = draw_count },
            .cmd_allocator = cmd_allocator,
            .cmd_list = cmd_list,
        };
    }

    fn ensure_pipeline_with_bindings(self: *RenderState, device: ?*anyopaque, cmd: model_render_types.RenderDrawCommand, has_bind_groups: bool) !void {
        return self.ensure_pipeline(device, cmd, has_bind_groups);
    }

    fn ensure_pipeline(self: *RenderState, device: ?*anyopaque, cmd: model_render_types.RenderDrawCommand, has_bind_groups: bool) !void {
        const width = cmd.target_width;
        const height = cmd.target_height;
        const format = cmd.target_format;
        if (self.root_signature == null) {
            if (has_bind_groups) {
                self.root_signature = try create_render_root_signature(device, cmd);
            } else {
                self.root_signature = bridge.c.d3d12_bridge_device_create_root_signature_empty(device) orelse return error.InvalidState;
            }
        }

        const key = build_pipeline_key(cmd);
        const needs_rebuild = self.graphics_pipeline == null or
            self.cached_format != format or
            self.cached_width != width or
            self.cached_height != height or
            !self.has_cached_pipeline_key or
            !std.meta.eql(self.cached_pipeline_key, key);
        if (!needs_rebuild) return;

        if (self.graphics_pipeline) |old| bridge.c.d3d12_bridge_release(old);
        if (self.render_target) |old| bridge.c.d3d12_bridge_release(old);

        var input_elements: [model_render_types.MAX_VERTEX_ATTRIBUTES]D3D12InputElementDesc = [_]D3D12InputElementDesc{std.mem.zeroes(D3D12InputElementDesc)} ** model_render_types.MAX_VERTEX_ATTRIBUTES;
        const input_count = try build_input_elements(cmd, &input_elements);
        const desc = D3D12GraphicsPipelineDesc{
            .target_format = key.target_format,
            .depth_stencil_format = key.depth_stencil_format,
            .sample_count = key.sample_count,
            .topology = key.topology,
            .topology_type = 0,
            .front_face = key.front_face,
            .cull_mode = key.cull_mode,
            .blend_enabled = if (key.blend_enabled) 1 else 0,
            .color_operation = key.color_operation,
            .color_src_factor = key.color_src_factor,
            .color_dst_factor = key.color_dst_factor,
            .alpha_operation = key.alpha_operation,
            .alpha_src_factor = key.alpha_src_factor,
            .alpha_dst_factor = key.alpha_dst_factor,
            .color_write_mask = key.color_write_mask,
            .depth_compare = key.depth_compare,
            .depth_write_enabled = if (key.depth_write_enabled) 1 else 0,
            .stencil_front_compare = key.stencil_front_compare,
            .stencil_front_fail_op = key.stencil_front_fail_op,
            .stencil_front_depth_fail_op = key.stencil_front_depth_fail_op,
            .stencil_front_pass_op = key.stencil_front_pass_op,
            .stencil_back_compare = key.stencil_back_compare,
            .stencil_back_fail_op = key.stencil_back_fail_op,
            .stencil_back_depth_fail_op = key.stencil_back_depth_fail_op,
            .stencil_back_pass_op = key.stencil_back_pass_op,
            .stencil_read_mask = key.stencil_read_mask,
            .stencil_write_mask = key.stencil_write_mask,
            .depth_bias = key.depth_bias,
            .depth_bias_slope_scale = key.depth_bias_slope_scale,
            .depth_bias_clamp = key.depth_bias_clamp,
            .unclipped_depth = if (key.unclipped_depth) 1 else 0,
        };
        self.graphics_pipeline = bridge.c.d3d12_bridge_device_create_graphics_pipeline_hlsl(
            device,
            self.root_signature,
            passthrough_vs_source,
            passthrough_vs_source.len,
            "main_vertex",
            passthrough_ps_source,
            passthrough_ps_source.len,
            "main_fragment",
            &desc,
            if (input_count > 0) &input_elements else null,
            input_count,
        ) orelse return error.ShaderCompileFailed;

        self.render_target = bridge.c.d3d12_bridge_device_create_texture_2d(device, width, height, 1, format, RENDER_ATTACHMENT_USAGE) orelse return error.InvalidState;
        if (has_depth_attachment(cmd)) {
            try self.depth_stencil.ensure_depth_texture(device, width, height, cmd.depth_stencil_format);
        } else {
            self.depth_stencil.deinit();
        }

        if (self.rtv_heap == null) {
            self.rtv_heap = bridge.c.d3d12_bridge_device_create_rtv_heap(device, 1) orelse return error.InvalidState;
        }
        bridge.c.d3d12_bridge_device_create_rtv(device, self.render_target, self.rtv_heap, 0, format);

        if (!self.has_cmd) {
            self.cmd_allocator = bridge.c.d3d12_bridge_device_create_command_allocator(device) orelse return error.InvalidState;
            self.cmd_list = bridge.c.d3d12_bridge_device_create_command_list(device, self.cmd_allocator) orelse return error.InvalidState;
            bridge.c.d3d12_bridge_command_list_close(self.cmd_list);
            self.has_cmd = true;
        }

        self.cached_format = format;
        self.cached_width = width;
        self.cached_height = height;
        self.cached_pipeline_key = key;
        self.has_cached_pipeline_key = true;
    }

    fn ensure_draw_indirect(self: *RenderState, device: ?*anyopaque) !void {
        if (self.draw_cmd_sig != null) return;
        self.draw_cmd_sig = bridge.c.d3d12_bridge_device_create_command_signature_draw(device, self.root_signature) orelse return error.InvalidState;
        if (self.indirect_arg_buffer == null) {
            self.indirect_arg_buffer = bridge.c.d3d12_bridge_device_create_buffer(device, DRAW_INDIRECT_ARG_BYTES, dc.HEAP_TYPE_UPLOAD) orelse return error.InvalidState;
        }
    }

    fn ensure_indexed_indirect(self: *RenderState, device: ?*anyopaque) !void {
        if (self.draw_indexed_cmd_sig != null) return;
        self.draw_indexed_cmd_sig = bridge.c.d3d12_bridge_device_create_command_signature_draw_indexed(device, self.root_signature) orelse return error.InvalidState;
        if (self.indirect_arg_buffer == null) {
            self.indirect_arg_buffer = bridge.c.d3d12_bridge_device_create_buffer(device, DRAW_INDEXED_INDIRECT_ARG_BYTES, dc.HEAP_TYPE_UPLOAD) orelse return error.InvalidState;
        }
    }

    fn write_indirect_args(self: *RenderState, cmd: model_render_types.RenderDrawCommand, indexed: bool) !void {
        const ptr = bridge.c.d3d12_bridge_resource_map(self.indirect_arg_buffer) orelse return error.InvalidState;
        defer bridge.c.d3d12_bridge_resource_unmap(self.indirect_arg_buffer);
        if (indexed) {
            const args = @as(*[5]u32, @ptrCast(@alignCast(ptr)));
            args[0] = cmd.index_count orelse 0;
            args[1] = cmd.instance_count;
            args[2] = cmd.first_index;
            args[3] = @bitCast(cmd.base_vertex);
            args[4] = cmd.first_instance;
        } else {
            const args = @as(*[4]u32, @ptrCast(@alignCast(ptr)));
            args[0] = cmd.vertex_count;
            args[1] = cmd.instance_count;
            args[2] = cmd.first_vertex;
            args[3] = cmd.first_instance;
        }
    }

    pub fn deinit(self: *RenderState) void {
        if (self.has_cmd) {
            bridge.c.d3d12_bridge_release(self.cmd_list);
            bridge.c.d3d12_bridge_release(self.cmd_allocator);
        }
        if (self.graphics_pipeline) |p| bridge.c.d3d12_bridge_release(p);
        if (self.root_signature) |r| bridge.c.d3d12_bridge_release(r);
        if (self.render_target) |t| bridge.c.d3d12_bridge_release(t);
        if (self.rtv_heap) |h| bridge.c.d3d12_bridge_release(h);
        if (self.draw_cmd_sig) |s| bridge.c.d3d12_bridge_release(s);
        if (self.draw_indexed_cmd_sig) |s| bridge.c.d3d12_bridge_release(s);
        if (self.indirect_arg_buffer) |b| bridge.c.d3d12_bridge_release(b);
        self.depth_stencil.deinit();
        self.* = .{};
    }

    fn bind_vertex_and_index_buffers(_: *RenderState, cmd_list: ?*anyopaque, cmd: model_render_types.RenderDrawCommand) !void {
        const vb_count = resolve_vertex_buffer_count(cmd);
        var slot: u32 = 0;
        while (slot < vb_count and slot < @as(u32, model_render_types.MAX_VERTEX_BUFFERS)) : (slot += 1) {
            const buffer = resolve_vertex_buffer_handle(cmd, slot) orelse continue;
            const offset = resolve_vertex_buffer_offset(cmd, slot);
            const total_size = bridge.c.d3d12_bridge_buffer_get_size(buffer);
            if (total_size <= offset) continue;
            const stride = try resolve_vertex_buffer_stride(cmd, slot);
            bridge.c.d3d12_bridge_command_list_ia_set_vertex_buffers(
                cmd_list,
                slot,
                1,
                buffer,
                @intCast(@min(total_size - offset, std.math.maxInt(u32))),
                stride,
                offset,
            );
        }

        const index_buffer = resolve_index_buffer_handle(cmd) orelse return;
        const index_offset = resolve_index_buffer_offset(cmd);
        const total_size = bridge.c.d3d12_bridge_buffer_get_size(index_buffer);
        if (total_size <= index_offset) return;
        const index_format = resolve_index_format(cmd) orelse return;
        bridge.c.d3d12_bridge_command_list_ia_set_index_buffer(
            cmd_list,
            index_buffer,
            index_format,
            @intCast(@min(total_size - index_offset, std.math.maxInt(u32))),
            index_offset,
        );
    }
};

fn build_input_elements(cmd: model_render_types.RenderDrawCommand, out: *[model_render_types.MAX_VERTEX_ATTRIBUTES]D3D12InputElementDesc) !u32 {
    const attribute_count = resolve_vertex_attribute_count(cmd);
    var i: u32 = 0;
    while (i < attribute_count and i < @as(u32, model_render_types.MAX_VERTEX_ATTRIBUTES)) : (i += 1) {
        const attr = resolve_vertex_attribute(cmd, i) orelse continue;
        const slot = attr.buffer_slot;
        out[i] = .{
            .format = try d3d12_formats.wgpu_vertex_format_to_dxgi(attr.format),
            .input_slot = slot,
            .aligned_byte_offset = @intCast(attr.offset),
            .semantic_index = attr.shader_location,
            .input_slot_class = if (resolve_vertex_step_mode(cmd, slot) == model_render_types.WGPUVertexStepMode_Instance)
                D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA
            else
                D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
            .instance_data_step_rate = if (resolve_vertex_step_mode(cmd, slot) == model_render_types.WGPUVertexStepMode_Instance) 1 else 0,
        };
    }
    return @min(attribute_count, @as(u32, model_render_types.MAX_VERTEX_ATTRIBUTES));
}

fn has_depth_attachment(cmd: model_render_types.RenderDrawCommand) bool {
    return cmd.depth_stencil_format != 0;
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

/// Root parameter indices for render pass descriptor tables.
const ROOT_PARAM_SRV_TABLE: u32 = 0;
const ROOT_PARAM_SAMPLER_TABLE: u32 = 1;

/// Create a root signature with SRV and sampler descriptor table slots matching
/// the bind group entries in the render draw command.
fn create_render_root_signature(device: ?*anyopaque, cmd: model_render_types.RenderDrawCommand) !?*anyopaque {
    var layout = d3d12_descriptors.RootSignatureLayout{
        .allow_input_assembler = true,
    };
    const max_entries = model_render_types.MAX_RENDER_BIND_ENTRIES * 2;
    var entries_buf: [max_entries]d3d12_descriptors.BindingEntry = undefined;
    var entry_count: usize = 0;

    var tex_i: u32 = 0;
    while (tex_i < cmd.bind_texture_count) : (tex_i += 1) {
        entries_buf[entry_count] = .{
            .binding = tex_i,
            .binding_type = .sampled_texture,
        };
        entry_count += 1;
    }

    var smp_i: u32 = 0;
    while (smp_i < cmd.bind_sampler_count) : (smp_i += 1) {
        entries_buf[entry_count] = .{
            .binding = smp_i,
            .binding_type = .sampler,
        };
        entry_count += 1;
    }

    if (entry_count == 0) {
        return bridge.c.d3d12_bridge_device_create_root_signature_empty(device);
    }

    layout.groups[0] = .{ .entries = entries_buf[0..entry_count] };
    return try d3d12_descriptors.create_root_signature_with_bindings(device, layout);
}

/// Allocate SRV and sampler descriptors for model-path bind groups and set
/// the descriptor tables on the command list.
fn bind_model_descriptor_tables(
    cmd_list: ?*anyopaque,
    device: ?*anyopaque,
    descriptor_state: *d3d12_descriptors.DescriptorHeapState,
    cmd: model_render_types.RenderDrawCommand,
) !void {
    try descriptor_state.ensure_heaps(device);
    const srv_base = descriptor_state.cbv_srv_uav_next;
    const sampler_base = descriptor_state.sampler_next;

    // Allocate SRV descriptors for each bound texture handle
    var tex_i: u32 = 0;
    while (tex_i < cmd.bind_texture_count) : (tex_i += 1) {
        const handle = cmd.bind_texture_handles[tex_i];
        if (handle == 0) continue;
        const RGBA8_UNORM_FORMAT: u32 = 0x00000012;
        _ = try descriptor_state.allocate_srv_texture(
            device,
            @ptrFromInt(handle),
            RGBA8_UNORM_FORMAT,
        );
    }

    // Allocate sampler descriptors for each bound sampler handle
    var smp_i: u32 = 0;
    while (smp_i < cmd.bind_sampler_count) : (smp_i += 1) {
        // Default linear wrap sampler for model-path bindings
        _ = try descriptor_state.allocate_sampler_descriptor(
            device,
            0x00000002, // linear min
            0x00000002, // linear mag
            0x00000002, // linear mip
            0x00000002, // wrap U
            0x00000002, // wrap V
            0x00000002, // wrap W
            0.0, // lod min
            32.0, // lod max
            0, // no compare
            1, // no anisotropy
        );
    }

    // Bind both heaps and set descriptor tables
    descriptor_state.bind_heaps(cmd_list);

    if (cmd.bind_texture_count > 0) {
        d3d12_descriptors.set_graphics_descriptor_table(
            cmd_list,
            ROOT_PARAM_SRV_TABLE,
            descriptor_state.cbv_srv_uav_heap,
            srv_base,
        );
    }
    if (cmd.bind_sampler_count > 0) {
        const sampler_root_param = if (cmd.bind_texture_count > 0)
            ROOT_PARAM_SAMPLER_TABLE
        else
            ROOT_PARAM_SRV_TABLE;
        d3d12_descriptors.set_graphics_sampler_table(
            cmd_list,
            sampler_root_param,
            descriptor_state.sampler_heap,
            sampler_base,
        );
    }
}

// Replay render bundles into a standalone render pass. Creates render target,
// sets up the command list, then replays each bundle's command list via
// replay_bundle_d3d12 from the shared render_bundle module.
pub fn execute_render_bundles(
    self: *RenderState,
    device: ?*anyopaque,
    queue: ?*anyopaque,
    fence: ?*anyopaque,
    fence_value: *u64,
    bundles: []const *const render_bundle.DoeRenderBundle,
    target_width: u32,
    target_height: u32,
    color_format: u32,
    sample_count: u32,
    queue_sync_mode: webgpu.QueueSyncMode,
) !RenderSubmission {
    if (bundles.len == 0) return .{};

    const width = if (target_width > 0) target_width else 256;
    const height = if (target_height > 0) target_height else 256;
    const pass_sample_count: u32 = if (sample_count == 0) 1 else sample_count;
    const pipeline_cmd = model_render_types.RenderDrawCommand{
        .draw_count = 1,
        .target_width = width,
        .target_height = height,
        .target_format = color_format,
        .sample_count = pass_sample_count,
    };

    const setup_start = common_timing.now_ns();
    try self.ensure_pipeline(device, pipeline_cmd, false);
    try self.ensure_draw_indirect(device);
    try self.ensure_indexed_indirect(device);
    const setup_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);

    const encode_start = common_timing.now_ns();
    var cmd_allocator = self.cmd_allocator;
    var cmd_list = self.cmd_list;
    if (queue_sync_mode != .per_command) {
        cmd_allocator = bridge.c.d3d12_bridge_device_create_command_allocator(device) orelse return error.InvalidState;
        errdefer bridge.c.d3d12_bridge_release(cmd_allocator);
        cmd_list = bridge.c.d3d12_bridge_device_create_command_list(device, cmd_allocator) orelse return error.InvalidState;
        errdefer bridge.c.d3d12_bridge_release(cmd_list);
        bridge.c.d3d12_bridge_command_list_close(cmd_list);
    }
    if (bridge.c.d3d12_bridge_command_allocator_reset(cmd_allocator) != 0) return error.InvalidState;
    if (bridge.c.d3d12_bridge_command_list_reset(cmd_list, cmd_allocator) != 0) return error.InvalidState;

    bridge.c.d3d12_bridge_command_list_resource_barrier_transition(cmd_list, self.render_target, dc.RESOURCE_STATE_PRESENT, dc.RESOURCE_STATE_RENDER_TARGET);
    bridge.c.d3d12_bridge_command_list_set_graphics_root_signature(cmd_list, self.root_signature);
    bridge.c.d3d12_bridge_command_list_set_pipeline_state(cmd_list, self.graphics_pipeline);
    bridge.c.d3d12_bridge_command_list_set_render_targets(cmd_list, self.rtv_heap, 0, null, 0);

    const vp_w: f32 = @floatFromInt(width);
    const vp_h: f32 = @floatFromInt(height);
    bridge.c.d3d12_bridge_command_list_set_viewport(cmd_list, 0, 0, vp_w, vp_h, 0, 1);
    bridge.c.d3d12_bridge_command_list_set_scissor(cmd_list, 0, 0, @intCast(width), @intCast(height));
    bridge.c.d3d12_bridge_command_list_ia_set_primitive_topology(cmd_list, dc.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

    var draw_count: u32 = 0;
    for (bundles) |b| {
        render_bundle.replay_bundle_d3d12(b, cmd_list, color_format, pass_sample_count, self.draw_cmd_sig, self.draw_indexed_cmd_sig) catch |err| {
            log.warn("bundle replay failed: {}", .{err});
            continue;
        };
        draw_count += 1;
    }

    bridge.c.d3d12_bridge_command_list_resource_barrier_transition(cmd_list, self.render_target, dc.RESOURCE_STATE_RENDER_TARGET, dc.RESOURCE_STATE_PRESENT);
    bridge.c.d3d12_bridge_command_list_close(cmd_list);
    const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);

    bridge.c.d3d12_bridge_queue_execute_command_list(queue, cmd_list);
    fence_value.* +|= 1;
    bridge.c.d3d12_bridge_queue_signal(queue, fence, fence_value.*);
    if (queue_sync_mode == .per_command) {
        const submit_start = common_timing.now_ns();
        bridge.c.d3d12_bridge_fence_wait(fence, fence_value.*);
        const submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_start);
        return .{ .metrics = .{ .setup_ns = setup_ns, .encode_ns = encode_ns, .submit_wait_ns = submit_wait_ns, .draw_count = draw_count } };
    }

    return .{
        .metrics = .{ .setup_ns = setup_ns, .encode_ns = encode_ns, .submit_wait_ns = 0, .draw_count = draw_count },
        .cmd_allocator = cmd_allocator,
        .cmd_list = cmd_list,
    };
}
