const std = @import("std");
const abi_core = @import("../../core/abi/wgpu_core_base_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const wgsl_analysis = @import("../../compiler/wgsl/pipeline/analysis.zig");
const runtime_compile = @import("../../compiler/wgsl/runtime/runtime_compile.zig");
const shared = @import("vulkan_render_shared.zig");

pub fn vulkan_create_render_pipeline(
    dev: *shared.DoeDevice,
    pip: *shared.DoeRenderPipeline,
    desc: *const anyopaque,
) bool {
    _ = dev;
    const RenderStringView = extern struct {
        data: ?[*]const u8,
        length: usize,
    };
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
    const RenderStencilFaceState = extern struct {
        compare: u32,
        failOp: u32,
        depthFailOp: u32,
        passOp: u32,
    };
    const RenderDepthStencilDesc = extern struct {
        nextInChain: ?*anyopaque,
        format: u32,
        depthWriteEnabled: u32,
        depthCompare: u32,
        stencilFront: RenderStencilFaceState,
        stencilBack: RenderStencilFaceState,
        stencilReadMask: u32,
        stencilWriteMask: u32,
        depthBias: i32,
        depthBiasSlopeScale: f32,
        depthBiasClamp: f32,
    };
    const LocalDesc = extern struct {
        nextInChain: ?*anyopaque,
        label_data: ?[*]const u8,
        label_length: usize,
        layout: ?*anyopaque,
        vertex_nextInChain: ?*anyopaque,
        vertex_module: ?*anyopaque,
        vertex_ep_data: ?[*]const u8,
        vertex_ep_length: usize,
        vertex_constantCount: usize,
        vertex_constants: ?*anyopaque,
        vertex_bufferCount: usize,
        vertex_buffers: ?*anyopaque,
        primitive: RenderPrimitiveState,
        depthStencil: ?*anyopaque,
        multisample_nextInChain: ?*anyopaque,
        multisample_count: u32,
        multisample_mask: u32,
        multisample_alphaToCoverageEnabled: u32,
        fragment: ?*const RenderFragmentState,
    };
    const d = @as(*const LocalDesc, @ptrCast(@alignCast(desc)));
    pip.topology = d.primitive.topology;
    pip.front_face = d.primitive.frontFace;
    pip.cull_mode = d.primitive.cullMode;
    pip.unclipped_depth = d.primitive.unclippedDepth != 0;
    pip.sample_count = if (d.multisample_count == 0) 1 else d.multisample_count;
    pip.vertex_buffer_count = 0;
    pip.vertex_attribute_count = 0;
    if (d.vertex_bufferCount > 0 and d.vertex_buffers != null) {
        const buffer_count = @min(d.vertex_bufferCount, native_shared.MAX_VERTEX_BUFFERS);
        const buffers = @as([*]const RenderVertexBufferLayout, @ptrCast(@alignCast(d.vertex_buffers)));
        var buffer_index: usize = 0;
        while (buffer_index < buffer_count) : (buffer_index += 1) {
            const layout = buffers[buffer_index];
            pip.vertex_buffer_strides[buffer_index] = layout.arrayStride;
            pip.vertex_step_modes[buffer_index] = layout.stepMode;
            pip.vertex_buffer_count += 1;
            if (layout.attributes) |attrs| {
                const available = native_shared.MAX_VERTEX_ATTRIBUTES - pip.vertex_attribute_count;
                const attr_count = @min(layout.attributeCount, available);
                var attr_index: usize = 0;
                while (attr_index < attr_count) : (attr_index += 1) {
                    const dst = pip.vertex_attribute_count;
                    const attr = attrs[attr_index];
                    pip.vertex_attribute_formats[dst] = attr.format;
                    pip.vertex_attribute_offsets[dst] = attr.offset;
                    pip.vertex_attribute_locations[dst] = attr.shaderLocation;
                    pip.vertex_attribute_buffer_slots[dst] = @intCast(buffer_index);
                    pip.vertex_attribute_count += 1;
                }
            }
        }
    }

    if (d.depthStencil) |ds_raw| {
        const ds = @as(*const RenderDepthStencilDesc, @ptrCast(@alignCast(ds_raw)));
        pip.depth_stencil_format = ds.format;
        pip.depth_compare = ds.depthCompare;
        pip.depth_write_enabled = ds.depthWriteEnabled != 0;
        pip.stencil_front_compare = ds.stencilFront.compare;
        pip.stencil_front_fail_op = ds.stencilFront.failOp;
        pip.stencil_front_depth_fail_op = ds.stencilFront.depthFailOp;
        pip.stencil_front_pass_op = ds.stencilFront.passOp;
        pip.stencil_back_compare = ds.stencilBack.compare;
        pip.stencil_back_fail_op = ds.stencilBack.failOp;
        pip.stencil_back_depth_fail_op = ds.stencilBack.depthFailOp;
        pip.stencil_back_pass_op = ds.stencilBack.passOp;
        pip.stencil_read_mask = ds.stencilReadMask;
        pip.stencil_write_mask = ds.stencilWriteMask;
    }

    if (d.fragment) |frag| {
        if (frag.targetCount > 0 and frag.targets != null) {
            const target0 = frag.targets.?[0];
            pip.color_write_mask = @intCast(target0.writeMask);
            if (target0.blend) |blend| {
                pip.blend_enabled = true;
                pip.color_operation = blend.color.operation;
                pip.color_src_factor = blend.color.srcFactor;
                pip.color_dst_factor = blend.color.dstFactor;
                pip.alpha_operation = blend.alpha.operation;
                pip.alpha_src_factor = blend.alpha.srcFactor;
                pip.alpha_dst_factor = blend.alpha.dstFactor;
            }
        }
    }

    if (native_helpers.cast(shared.DoeShaderModule, d.vertex_module)) |vert_sm| {
        if (vert_sm.vertex_spirv_data) |vs| {
            pip.vertex_spirv_data = native_helpers.alloc.dupe(u32, vs) catch null;
        }
    }
    if (d.fragment) |frag| {
        if (native_helpers.cast(shared.DoeShaderModule, frag.module)) |frag_sm| {
            if (frag_sm.fragment_spirv_data) |fs| {
                pip.fragment_spirv_data = native_helpers.alloc.dupe(u32, fs) catch null;
            }
        }
    }

    if (d.vertex_ep_data) |ep_data| {
        const ep_len = if (d.vertex_ep_length == abi_core.WGPU_STRLEN)
            std.mem.len(@as([*:0]const u8, @ptrCast(ep_data)))
        else
            d.vertex_ep_length;
        if (ep_len > 0) {
            pip.vertex_entry_point = native_helpers.alloc.dupe(u8, ep_data[0..ep_len]) catch null;
        }
    }
    if (d.fragment) |frag| {
        if (frag.entryPoint.data) |ep_data| {
            const ep_len = if (frag.entryPoint.length == abi_core.WGPU_STRLEN)
                std.mem.len(@as([*:0]const u8, @ptrCast(ep_data)))
            else
                frag.entryPoint.length;
            if (ep_len > 0) {
                pip.fragment_entry_point = native_helpers.alloc.dupe(u8, ep_data[0..ep_len]) catch null;
            }
        }
    }

    pip.mtl_pso = null;
    return true;
}

pub fn probe_has_graphics_entry_points(wgsl: []const u8) bool {
    return std.mem.indexOf(u8, wgsl, "@vertex") != null or
        std.mem.indexOf(u8, wgsl, "@fragment") != null;
}

pub fn vulkan_create_graphics_shader_module(
    sm: *shared.DoeShaderModule,
    wgsl: []const u8,
) error{ OutOfMemory, ShaderCompileFailed }!void {
    const alloc = native_helpers.alloc;
    var result = runtime_compile.translateToSpirvForGraphicsRuntime(alloc, wgsl) catch {
        std.log.err("doe_vulkan_render: WGSL→SPIR-V graphics translation failed: {s}", .{wgsl_analysis.lastErrorMessage()});
        return error.ShaderCompileFailed;
    };
    errdefer result.deinit(alloc);

    if (result.vertex_spirv) |v| {
        sm.vertex_spirv_data = alloc.dupe(u32, v) catch return error.OutOfMemory;
    }
    if (result.fragment_spirv) |f| {
        sm.fragment_spirv_data = alloc.dupe(u32, f) catch return error.OutOfMemory;
    }

    sm.wg_x = 0;
    sm.wg_y = 0;
    sm.wg_z = 0;
    sm.needs_sizes_buf = false;

    result.vertex_spirv = null;
    result.fragment_spirv = null;
}
