// doe_render_pipeline_native.zig — Render Pipeline creation and release C ABI exports.
// Sharded from doe_render_native.zig for file-size compliance.

const std = @import("std");
const resource_ops = @import("../../backend/dropin_resource_ops.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const error_scope = @import("../../runtime/diagnostics/error_scope.zig");
const d3d12_formats = resource_ops.d3d12_formats;

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const ERR_CAP = native_shared.ERR_CAP;

const DoeDevice = native_types.DoeDevice;
const DoeShaderModule = native_types.DoeShaderModule;
const DoePipelineLayout = native_types.DoePipelineLayout;
const DoeRenderPipeline = native_types.DoeRenderPipeline;

extern fn metal_bridge_release(obj: ?*anyopaque) callconv(.c) void;
extern fn d3d12_bridge_release(obj: ?*anyopaque) callconv(.c) void;
extern fn d3d12_bridge_device_create_root_signature_empty(device: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn metal_bridge_library_new_function(library: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn metal_bridge_device_new_render_pipeline_full(device: ?*anyopaque, vertex_function: ?*anyopaque, fragment_function: ?*anyopaque, pixel_format: u32, depth_format: u32, sample_count: u32, blend_enabled: c_int, color_operation: u32, color_src_factor: u32, color_dst_factor: u32, alpha_operation: u32, alpha_src_factor: u32, alpha_dst_factor: u32, color_write_mask: u32, vertex_layouts: ?[*]const MtlVertexBufferLayout, vertex_layout_count: u32, vertex_attributes: ?[*]const MtlVertexAttributeDesc, vertex_attribute_count: u32, error_buf: ?[*]u8, error_cap: usize) callconv(.c) ?*anyopaque;

const D3D12InputElementDesc = extern struct {
    format: u32,
    input_slot: u32,
    aligned_byte_offset: u32,
    semantic_index: u32,
    input_slot_class: u32,
    instance_data_step_rate: u32,
};
const D3D12GraphicsPipelineDesc = extern struct {
    target_format: u32,
    depth_stencil_format: u32,
    sample_count: u32,
    topology: u32,
    topology_type: u32,
    front_face: u32,
    cull_mode: u32,
    blend_enabled: u32,
    color_operation: u32,
    color_src_factor: u32,
    color_dst_factor: u32,
    alpha_operation: u32,
    alpha_src_factor: u32,
    alpha_dst_factor: u32,
    color_write_mask: u32,
    depth_compare: u32,
    depth_write_enabled: u32,
    stencil_front_compare: u32,
    stencil_front_fail_op: u32,
    stencil_front_depth_fail_op: u32,
    stencil_front_pass_op: u32,
    stencil_back_compare: u32,
    stencil_back_fail_op: u32,
    stencil_back_depth_fail_op: u32,
    stencil_back_pass_op: u32,
    stencil_read_mask: u32,
    stencil_write_mask: u32,
    depth_bias: i32,
    depth_bias_slope_scale: f32,
    depth_bias_clamp: f32,
    unclipped_depth: u32,
};
extern fn d3d12_bridge_device_create_graphics_pipeline_hlsl(
    device: ?*anyopaque,
    root_sig: ?*anyopaque,
    vs_source: [*:0]const u8,
    vs_source_len: usize,
    vs_entry: [*:0]const u8,
    ps_source: [*:0]const u8,
    ps_source_len: usize,
    ps_entry: [*:0]const u8,
    desc: *const D3D12GraphicsPipelineDesc,
    input_elements: ?[*]const D3D12InputElementDesc,
    input_element_count: u32,
) callconv(.c) ?*anyopaque;

const MtlVertexBufferLayout = extern struct {
    array_stride: u64,
    step_mode: u32,
    buffer_index: u32,
};
const MtlVertexAttributeDesc = extern struct {
    format: u32,
    offset: u64,
    shader_location: u32,
    buffer_index: u32,
};

// Mirror of the C structs passed by doe_napi.c for WGPURenderPipelineDescriptor.
const RenderStringView = extern struct { data: ?[*]const u8, length: usize };
const RenderBlendComponent = extern struct {
    operation: u32,
    srcFactor: u32,
    dstFactor: u32,
};
const RenderBlendState = extern struct {
    color: RenderBlendComponent,
    alpha: RenderBlendComponent,
};
const RenderColorTargetState = extern struct {
    nextInChain: ?*anyopaque,
    format: u32,
    blend: ?*const RenderBlendState,
    writeMask: u64,
};
const RenderVertexState = extern struct {
    nextInChain: ?*anyopaque,
    module: ?*anyopaque,
    entryPoint: RenderStringView,
    constantCount: usize,
    constants: ?*anyopaque,
    bufferCount: usize,
    buffers: ?*anyopaque,
};
const RenderFragmentState = extern struct {
    nextInChain: ?*anyopaque,
    module: ?*anyopaque,
    entryPoint: RenderStringView,
    constantCount: usize,
    constants: ?*anyopaque,
    targetCount: usize,
    targets: ?[*]const RenderColorTargetState,
};
const RenderPrimitiveState = extern struct {
    nextInChain: ?*anyopaque,
    topology: u32,
    stripIndexFormat: u32,
    frontFace: u32,
    cullMode: u32,
    unclippedDepth: u32,
};
const RenderMultisampleState = extern struct {
    nextInChain: ?*anyopaque,
    count: u32,
    mask: u32,
    alphaToCoverageEnabled: u32,
};
const RenderVertexAttribute = extern struct {
    nextInChain: ?*anyopaque,
    format: u32,
    offset: u64,
    shaderLocation: u32,
};
const RenderVertexBufferLayout = extern struct {
    nextInChain: ?*anyopaque,
    stepMode: u32,
    arrayStride: u64,
    attributeCount: usize,
    attributes: ?[*]const RenderVertexAttribute,
};
const RenderDepthStencilDesc = extern struct {
    nextInChain: ?*anyopaque,
    format: u32,
    depthWriteEnabled: u32,
    depthCompare: u32,
    stencilFront: extern struct {
        compare: u32,
        failOp: u32,
        depthFailOp: u32,
        passOp: u32,
    },
    stencilBack: extern struct {
        compare: u32,
        failOp: u32,
        depthFailOp: u32,
        passOp: u32,
    },
    stencilReadMask: u32,
    stencilWriteMask: u32,
    depthBias: i32,
    depthBiasSlopeScale: f32,
    depthBiasClamp: f32,
};
const RenderPipelineDesc = extern struct {
    nextInChain: ?*anyopaque,
    label: RenderStringView,
    layout: ?*anyopaque,
    vertex: RenderVertexState,
    primitive: RenderPrimitiveState,
    depthStencil: ?*anyopaque,
    multisample: RenderMultisampleState,
    fragment: ?*const RenderFragmentState,
};

const D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA: u32 = 0;
const D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA: u32 = 1;

const StageKind = enum { vertex, fragment };

fn mslStageName(sv: RenderStringView, stage: StageKind, buf: []u8) [*:0]const u8 {
    const data = sv.data orelse return switch (stage) {
        .vertex => "main_vertex",
        .fragment => "main_fragment",
    };
    const len = if (sv.length > 0) sv.length else std.mem.indexOfScalar(u8, data[0..256], 0) orelse 0;
    const name = data[0..len];
    if (std.mem.eql(u8, name, "main")) {
        return switch (stage) {
            .vertex => "main_vertex",
            .fragment => "main_fragment",
        };
    }
    if (len >= buf.len) return switch (stage) {
        .vertex => "main_vertex",
        .fragment => "main_fragment",
    };
    @memcpy(buf[0..len], name);
    buf[len] = 0;
    return buf[0..len :0];
}

fn stageEntryName(sv: RenderStringView, fallback: [*:0]const u8) [*:0]const u8 {
    const data = sv.data orelse return fallback;
    return @ptrCast(data);
}

// ============================================================
// Render Pipeline
// ============================================================

fn createRenderPipeline(dev_raw: ?*anyopaque, desc_raw: ?*anyopaque) ?*anyopaque {
    const dev = cast(DoeDevice, dev_raw) orelse return null;
    const d = @as(*const RenderPipelineDesc, @ptrCast(@alignCast(desc_raw orelse return null)));
    const shader_handles = [_]?*anyopaque{ d.vertex.module, if (d.fragment) |fragment| fragment.module else null };
    for (shader_handles) |handle| {
        if (cast(DoeShaderModule, handle)) |module| {
            if (module.device != null and module.device != dev) {
                dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, "render pipeline shader belongs to a different device");
                return null;
            }
        }
    }
    const pip = make(DoeRenderPipeline) orelse return null;
    pip.* = .{};
    pip.layout = cast(DoePipelineLayout, d.layout);

    const buf_count = @min(d.vertex.bufferCount, @as(usize, model_render_types.MAX_VERTEX_BUFFERS));
    if (buf_count > 0) {
        const bufs = @as(?[*]const RenderVertexBufferLayout, @ptrCast(@alignCast(d.vertex.buffers)));
        if (bufs) |layouts| {
            pip.vertex_layout_count = @intCast(buf_count);
            var i: usize = 0;
            while (i < buf_count) : (i += 1) {
                const layout = layouts[i];
                const dst = &pip.vertex_layouts[i];
                dst.* = .{
                    .array_stride = layout.arrayStride,
                    .step_mode = layout.stepMode,
                    .attribute_count = @intCast(@min(layout.attributeCount, @as(usize, model_render_types.MAX_VERTEX_ATTRIBUTES))),
                };
                if (layout.attributes) |attrs| {
                    const attr_count = @min(layout.attributeCount, @as(usize, model_render_types.MAX_VERTEX_ATTRIBUTES));
                    var j: usize = 0;
                    while (j < attr_count) : (j += 1) {
                        const attr = attrs[j];
                        dst.attributes[j] = .{
                            .format = attr.format,
                            .offset = attr.offset,
                            .shader_location = attr.shaderLocation,
                        };
                    }
                }
            }
        }
    }

    if (dev.backend == .vulkan) {
        const vk_render = @import("../vulkan/vulkan_render_native.zig");
        if (!vk_render.vulkan_create_render_pipeline(dev, pip, @ptrCast(d))) {
            alloc.destroy(pip);
            return null;
        }
        return toOpaque(pip);
    }
    var err_buf: [ERR_CAP]u8 = undefined;
    const frag = d.fragment orelse {
        alloc.destroy(pip);
        return null;
    };
    const vert_mod = cast(DoeShaderModule, d.vertex.module) orelse {
        alloc.destroy(pip);
        return null;
    };
    const frag_mod = cast(DoeShaderModule, frag.module) orelse {
        alloc.destroy(pip);
        return null;
    };

    const pixel_format: u32 = if (frag.targetCount > 0)
        if (frag.targets) |ts| ts[0].format else 0x00000016
    else
        0x00000016;

    const depth_format: u32 = if (d.depthStencil) |ds_raw|
        (@as(*const RenderDepthStencilDesc, @ptrCast(@alignCast(ds_raw)))).format
    else
        0;

    const target0 = if (frag.targetCount > 0 and frag.targets != null) frag.targets.?[0] else RenderColorTargetState{
        .nextInChain = null,
        .format = pixel_format,
        .blend = null,
        .writeMask = 0xF,
    };
    const blend_enabled: c_int = if (target0.blend != null) 1 else 0;
    const color_operation: u32 = if (target0.blend) |blend| blend.color.operation else 1;
    const color_src_factor: u32 = if (target0.blend) |blend| blend.color.srcFactor else 2;
    const color_dst_factor: u32 = if (target0.blend) |blend| blend.color.dstFactor else 1;
    const alpha_operation: u32 = if (target0.blend) |blend| blend.alpha.operation else 1;
    const alpha_src_factor: u32 = if (target0.blend) |blend| blend.alpha.srcFactor else 2;
    const alpha_dst_factor: u32 = if (target0.blend) |blend| blend.alpha.dstFactor else 1;
    const sample_count: u32 = if (d.multisample.count > 0) d.multisample.count else 1;
    const depth_desc = if (d.depthStencil) |ds_raw|
        @as(*const RenderDepthStencilDesc, @ptrCast(@alignCast(ds_raw)))
    else
        null;

    if (dev.backend == .d3d12) {
        const vertex_hlsl = vert_mod.hlsl_source orelse {
            alloc.destroy(pip);
            return null;
        };
        const fragment_hlsl = frag_mod.hlsl_source orelse {
            alloc.destroy(pip);
            return null;
        };
        const root_sig = d3d12_bridge_device_create_root_signature_empty(dev.mtl_device) orelse {
            alloc.destroy(pip);
            return null;
        };
        errdefer d3d12_bridge_release(root_sig);

        var input_elements: [model_render_types.MAX_VERTEX_ATTRIBUTES]D3D12InputElementDesc =
            [_]D3D12InputElementDesc{std.mem.zeroes(D3D12InputElementDesc)} ** model_render_types.MAX_VERTEX_ATTRIBUTES;
        var input_count: u32 = 0;
        var vb_count: u32 = 0;
        var attr_count: u32 = 0;
        var i: usize = 0;
        while (i < @as(usize, pip.vertex_layout_count) and i < model_render_types.MAX_VERTEX_BUFFERS) : (i += 1) {
            const layout = pip.vertex_layouts[i];
            vb_count += 1;
            pip.vertex_buffer_strides[i] = layout.array_stride;
            pip.vertex_step_modes[i] = layout.step_mode;
            var j: usize = 0;
            while (j < @as(usize, layout.attribute_count) and attr_count < @as(u32, model_render_types.MAX_VERTEX_ATTRIBUTES)) : (j += 1) {
                const attr = layout.attributes[j];
                const input_slot_class = if (layout.step_mode == model_render_types.WGPUVertexStepMode_Instance)
                    D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA
                else
                    D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA;
                input_elements[input_count] = .{
                    .format = d3d12_formats.wgpu_vertex_format_to_dxgi(attr.format) catch {
                        alloc.destroy(pip);
                        return null;
                    },
                    .input_slot = @intCast(i),
                    .aligned_byte_offset = @intCast(attr.offset),
                    .semantic_index = attr.shader_location,
                    .input_slot_class = input_slot_class,
                    .instance_data_step_rate = if (input_slot_class == D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA) 1 else 0,
                };
                pip.vertex_attribute_formats[attr_count] = attr.format;
                pip.vertex_attribute_offsets[attr_count] = attr.offset;
                pip.vertex_attribute_locations[attr_count] = attr.shader_location;
                pip.vertex_attribute_buffer_slots[attr_count] = @intCast(i);
                input_count += 1;
                attr_count += 1;
            }
        }

        const d3d_desc = D3D12GraphicsPipelineDesc{
            .target_format = pixel_format,
            .depth_stencil_format = depth_format,
            .sample_count = sample_count,
            .topology = d.primitive.topology,
            .topology_type = 0,
            .front_face = d.primitive.frontFace,
            .cull_mode = d.primitive.cullMode,
            .blend_enabled = if (blend_enabled != 0) 1 else 0,
            .color_operation = color_operation,
            .color_src_factor = color_src_factor,
            .color_dst_factor = color_dst_factor,
            .alpha_operation = alpha_operation,
            .alpha_src_factor = alpha_src_factor,
            .alpha_dst_factor = alpha_dst_factor,
            .color_write_mask = @intCast(target0.writeMask),
            .depth_compare = if (depth_desc) |ds| ds.depthCompare else 0x00000008,
            .depth_write_enabled = if (depth_desc) |ds| ds.depthWriteEnabled else 0,
            .stencil_front_compare = if (depth_desc) |ds| ds.stencilFront.compare else 0x00000008,
            .stencil_front_fail_op = if (depth_desc) |ds| ds.stencilFront.failOp else 0,
            .stencil_front_depth_fail_op = if (depth_desc) |ds| ds.stencilFront.depthFailOp else 0,
            .stencil_front_pass_op = if (depth_desc) |ds| ds.stencilFront.passOp else 0,
            .stencil_back_compare = if (depth_desc) |ds| ds.stencilBack.compare else 0x00000008,
            .stencil_back_fail_op = if (depth_desc) |ds| ds.stencilBack.failOp else 0,
            .stencil_back_depth_fail_op = if (depth_desc) |ds| ds.stencilBack.depthFailOp else 0,
            .stencil_back_pass_op = if (depth_desc) |ds| ds.stencilBack.passOp else 0,
            .stencil_read_mask = if (depth_desc) |ds| ds.stencilReadMask else 0xFFFF_FFFF,
            .stencil_write_mask = if (depth_desc) |ds| ds.stencilWriteMask else 0xFFFF_FFFF,
            .depth_bias = if (depth_desc) |ds| ds.depthBias else 0,
            .depth_bias_slope_scale = if (depth_desc) |ds| ds.depthBiasSlopeScale else 0,
            .depth_bias_clamp = if (depth_desc) |ds| ds.depthBiasClamp else 0,
            .unclipped_depth = d.primitive.unclippedDepth,
        };
        const d3d_pso = d3d12_bridge_device_create_graphics_pipeline_hlsl(
            dev.mtl_device,
            root_sig,
            @ptrCast(vertex_hlsl.ptr),
            vertex_hlsl.len,
            stageEntryName(d.vertex.entryPoint, "main"),
            @ptrCast(fragment_hlsl.ptr),
            fragment_hlsl.len,
            stageEntryName(frag.entryPoint, "main"),
            &d3d_desc,
            if (input_count > 0) &input_elements else null,
            input_count,
        ) orelse {
            alloc.destroy(pip);
            return null;
        };
        pip.* = .{
            .mtl_pso = d3d_pso,
            .backend_root_signature = root_sig,
            .topology = d.primitive.topology,
            .front_face = d.primitive.frontFace,
            .cull_mode = d.primitive.cullMode,
            .depth_stencil_format = depth_format,
            .depth_compare = if (depth_desc) |ds| ds.depthCompare else 0x00000008,
            .depth_write_enabled = if (depth_desc) |ds| ds.depthWriteEnabled != 0 else false,
            .unclipped_depth = d.primitive.unclippedDepth != 0,
            .stencil_front_compare = if (depth_desc) |ds| ds.stencilFront.compare else 0x00000008,
            .stencil_front_fail_op = if (depth_desc) |ds| ds.stencilFront.failOp else 0,
            .stencil_front_depth_fail_op = if (depth_desc) |ds| ds.stencilFront.depthFailOp else 0,
            .stencil_front_pass_op = if (depth_desc) |ds| ds.stencilFront.passOp else 0,
            .stencil_back_compare = if (depth_desc) |ds| ds.stencilBack.compare else 0x00000008,
            .stencil_back_fail_op = if (depth_desc) |ds| ds.stencilBack.failOp else 0,
            .stencil_back_depth_fail_op = if (depth_desc) |ds| ds.stencilBack.depthFailOp else 0,
            .stencil_back_pass_op = if (depth_desc) |ds| ds.stencilBack.passOp else 0,
            .stencil_read_mask = if (depth_desc) |ds| ds.stencilReadMask else 0xFFFF_FFFF,
            .stencil_write_mask = if (depth_desc) |ds| ds.stencilWriteMask else 0xFFFF_FFFF,
            .blend_enabled = blend_enabled != 0,
            .color_operation = color_operation,
            .color_src_factor = color_src_factor,
            .color_dst_factor = color_dst_factor,
            .alpha_operation = alpha_operation,
            .alpha_src_factor = alpha_src_factor,
            .alpha_dst_factor = alpha_dst_factor,
            .color_write_mask = @intCast(target0.writeMask),
            .sample_count = sample_count,
            .vertex_layout_count = pip.vertex_layout_count,
            .vertex_layouts = pip.vertex_layouts,
            .vertex_buffer_count = vb_count,
            .vertex_buffer_strides = pip.vertex_buffer_strides,
            .vertex_step_modes = pip.vertex_step_modes,
            .vertex_attribute_count = attr_count,
            .vertex_attribute_formats = pip.vertex_attribute_formats,
            .vertex_attribute_offsets = pip.vertex_attribute_offsets,
            .vertex_attribute_locations = pip.vertex_attribute_locations,
            .vertex_attribute_buffer_slots = pip.vertex_attribute_buffer_slots,
        };
        return toOpaque(pip);
    }

    // MSL function lookup, applying the "main" -> "main_vertex"/"main_fragment" rename.
    var vert_entry_buf: [256]u8 = undefined;
    var frag_entry_buf: [256]u8 = undefined;
    const vert_entry = mslStageName(d.vertex.entryPoint, .vertex, &vert_entry_buf);
    const frag_entry = mslStageName(frag.entryPoint, .fragment, &frag_entry_buf);
    const vfn = metal_bridge_library_new_function(vert_mod.mtl_library, vert_entry);
    const ffn = metal_bridge_library_new_function(frag_mod.mtl_library, frag_entry);

    if (vfn == null or ffn == null) {
        if (vfn) |f| metal_bridge_release(f);
        if (ffn) |f| metal_bridge_release(f);
        alloc.destroy(pip);
        return null;
    }

    var mtl_layouts: [8]MtlVertexBufferLayout = undefined;
    var mtl_attrs: [16]MtlVertexAttributeDesc = undefined;
    var layout_count: u32 = 0;
    var attr_count: u32 = 0;

    const metal_buf_count = @min(d.vertex.bufferCount, 8);
    if (metal_buf_count > 0) {
        const bufs = @as(?[*]const RenderVertexBufferLayout, @ptrCast(@alignCast(d.vertex.buffers)));
        if (bufs) |layouts| {
            var i: usize = 0;
            while (i < metal_buf_count) : (i += 1) {
                const layout = layouts[i];
                mtl_layouts[layout_count] = .{
                    .array_stride = layout.arrayStride,
                    .step_mode = layout.stepMode,
                    .buffer_index = @intCast(i),
                };
                layout_count += 1;
                const ac = @min(layout.attributeCount, 16 - @as(usize, attr_count));
                if (layout.attributes) |attrs| {
                    var j: usize = 0;
                    while (j < ac) : (j += 1) {
                        const attr = attrs[j];
                        mtl_attrs[attr_count] = .{
                            .format = attr.format,
                            .offset = attr.offset,
                            .shader_location = attr.shaderLocation,
                            .buffer_index = @intCast(i),
                        };
                        attr_count += 1;
                    }
                }
            }
        }
    }

    const pso = metal_bridge_device_new_render_pipeline_full(
        dev.mtl_device,
        vfn,
        ffn,
        pixel_format,
        depth_format,
        sample_count,
        blend_enabled,
        color_operation,
        color_src_factor,
        color_dst_factor,
        alpha_operation,
        alpha_src_factor,
        alpha_dst_factor,
        @intCast(target0.writeMask),
        if (layout_count > 0) &mtl_layouts else null,
        layout_count,
        if (attr_count > 0) &mtl_attrs else null,
        attr_count,
        &err_buf,
        ERR_CAP,
    ) orelse {
        if (vfn) |f| metal_bridge_release(f);
        if (ffn) |f| metal_bridge_release(f);
        alloc.destroy(pip);
        return null;
    };
    if (vfn) |f| metal_bridge_release(f);
    if (ffn) |f| metal_bridge_release(f);
    pip.mtl_pso = pso;
    pip.topology = d.primitive.topology;
    pip.front_face = d.primitive.frontFace;
    pip.cull_mode = d.primitive.cullMode;
    pip.blend_enabled = blend_enabled != 0;
    pip.color_operation = color_operation;
    pip.color_src_factor = color_src_factor;
    pip.color_dst_factor = color_dst_factor;
    pip.alpha_operation = alpha_operation;
    pip.alpha_src_factor = alpha_src_factor;
    pip.alpha_dst_factor = alpha_dst_factor;
    pip.color_write_mask = @intCast(target0.writeMask);
    pip.sample_count = sample_count;
    return toOpaque(pip);
}

pub export fn doeNativeRenderPipelineRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeRenderPipeline, raw)) |p| {
        if (!native_helpers.object_should_destroy(p)) return;
        native_helpers.label_store.remove(raw);
        if (p.backend_root_signature != null) {
            if (p.mtl_pso) |pso| d3d12_bridge_release(pso);
            if (p.backend_root_signature) |root_sig| d3d12_bridge_release(root_sig);
        } else if (p.mtl_pso) |pso| {
            metal_bridge_release(pso);
        }
        if (p.vertex_spirv_data) |s| alloc.free(s);
        if (p.fragment_spirv_data) |s| alloc.free(s);
        if (p.vertex_entry_point) |ep| alloc.free(ep);
        if (p.fragment_entry_point) |ep| alloc.free(ep);
        if (p.layout) |layout| @import("../support/doe_native_exports.zig").doeNativePipelineLayoutRelease(toOpaque(layout));
        const device = p.device_ref;
        alloc.destroy(p);
        if (device) |owner| @import("../support/doe_native_exports.zig").doeNativeDeviceRelease(toOpaque(owner));
    }
}

pub export fn doeNativeDeviceCreateRenderPipeline(dev_raw: ?*anyopaque, desc_raw: ?*anyopaque) callconv(.c) ?*anyopaque {
    const raw = createRenderPipeline(dev_raw, desc_raw) orelse return null;
    const pipeline = cast(DoeRenderPipeline, raw).?;
    const device = cast(native_types.DoeDevice, dev_raw).?;
    native_helpers.object_add_ref(native_types.DoeDevice, dev_raw);
    pipeline.device_ref = device;
    if (pipeline.layout) |layout| native_helpers.object_add_ref(DoePipelineLayout, toOpaque(layout));
    return raw;
}
