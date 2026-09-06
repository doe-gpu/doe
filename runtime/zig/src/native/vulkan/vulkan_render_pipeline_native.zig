const std = @import("std");
const abi_core = @import("../../core/abi/wgpu_core_base_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const wgsl_analysis = @import("../../compiler/wgsl/pipeline/analysis.zig");
const runtime_compile = @import("../../compiler/wgsl/runtime/runtime_graphics_translation.zig");
const shared = @import("vulkan_render_shared.zig");
const error_scope = @import("../../runtime/diagnostics/error_scope.zig");

pub fn vulkan_create_render_pipeline(
    dev: *shared.DoeDevice,
    pip: *shared.DoeRenderPipeline,
    desc: *const anyopaque,
) bool {
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

    const vertex = native_helpers.cast(shared.DoeShaderModule, d.vertex_module);
    const fragment = if (d.fragment) |frag| native_helpers.cast(shared.DoeShaderModule, frag.module) else null;
    if (d.fragment != null and fragment == null) {
        dev.error_scopes.deliver(error_scope.ERROR_TYPE_VALIDATION, "render pipeline requires a valid fragment shader");
        return false;
    }
    retainShaderCode(native_helpers.alloc, pip, vertex, fragment, entryPoint(d.vertex_ep_data, d.vertex_ep_length), if (d.fragment) |frag| entryPoint(frag.entryPoint.data, frag.entryPoint.length) else null) catch |err| {
        dev.error_scopes.deliver(error_scope.zig_error_to_type(err), if (err == error.OutOfMemory) "render pipeline could not retain shader code" else "render pipeline requires compiled graphics shader code");
        return false;
    };

    pip.mtl_pso = null;
    return true;
}

fn entryPoint(data: ?[*]const u8, length: usize) ?[]const u8 {
    const bytes = data orelse return null;
    const len = if (length == abi_core.WGPU_STRLEN) std.mem.len(@as([*:0]const u8, @ptrCast(bytes))) else length;
    return if (len == 0) null else bytes[0..len];
}

fn retainShaderCode(
    allocator: std.mem.Allocator,
    pipeline: *shared.DoeRenderPipeline,
    vertex: ?*const shared.DoeShaderModule,
    fragment: ?*const shared.DoeShaderModule,
    vertex_entry: ?[]const u8,
    fragment_entry: ?[]const u8,
) !void {
    const vertex_module = vertex orelse return error.ShaderCompileFailed;
    const vertex_source = vertex_module.vertex_spirv_data orelse return error.ShaderCompileFailed;
    const fragment_source = if (fragment) |module| module.fragment_spirv_data orelse return error.ShaderCompileFailed else null;
    const vs = try allocator.dupe(u32, vertex_source);
    errdefer allocator.free(vs);
    const fs = if (fragment_source) |source| try allocator.dupe(u32, source) else null;
    errdefer if (fs) |source| allocator.free(source);
    const ve = if (vertex_entry) |name| try allocator.dupe(u8, name) else null;
    errdefer if (ve) |name| allocator.free(name);
    const fe = if (fragment_entry) |name| try allocator.dupe(u8, name) else null;
    pipeline.vertex_spirv_data = vs;
    pipeline.fragment_spirv_data = fs;
    pipeline.vertex_entry_point = ve;
    pipeline.fragment_entry_point = fe;
    if (vertex_module.wgsl_source) |source| {
        std.crypto.hash.sha2.Sha256.hash(source, &pipeline.vertex_wgsl_sha256, .{});
        pipeline.vertex_wgsl_sha256_ready = true;
    }
    if (fragment) |module| if (module.wgsl_source) |source| {
        std.crypto.hash.sha2.Sha256.hash(source, &pipeline.fragment_wgsl_sha256, .{});
        pipeline.fragment_wgsl_sha256_ready = true;
    };
}

fn shaderCodeAllocationFailures(allocator: std.mem.Allocator) !void {
    var pipeline = shared.DoeRenderPipeline{};
    const vertex = shared.DoeShaderModule{ .vertex_spirv_data = &.{ 1, 2 }, .wgsl_source = "vertex" };
    const fragment = shared.DoeShaderModule{ .fragment_spirv_data = &.{ 3, 4 }, .wgsl_source = "fragment" };
    retainShaderCode(allocator, &pipeline, &vertex, &fragment, "vertex", "fragment") catch |err| {
        try std.testing.expectEqual(@as(?[]const u32, null), pipeline.vertex_spirv_data);
        try std.testing.expectEqual(@as(?[]const u32, null), pipeline.fragment_spirv_data);
        try std.testing.expectEqual(@as(?[]const u8, null), pipeline.vertex_entry_point);
        try std.testing.expectEqual(@as(?[]const u8, null), pipeline.fragment_entry_point);
        try std.testing.expect(!pipeline.vertex_wgsl_sha256_ready);
        return err;
    };
    defer allocator.free(pipeline.vertex_spirv_data.?);
    defer allocator.free(pipeline.fragment_spirv_data.?);
    defer allocator.free(pipeline.vertex_entry_point.?);
    defer allocator.free(pipeline.fragment_entry_point.?);
    try std.testing.expectEqualSlices(u32, vertex.vertex_spirv_data.?, pipeline.vertex_spirv_data.?);
    try std.testing.expect(pipeline.vertex_spirv_data.?.ptr != vertex.vertex_spirv_data.?.ptr);
    try std.testing.expectEqualStrings("fragment", pipeline.fragment_entry_point.?);
}

test "render shader retention publishes only after every allocation succeeds" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, shaderCodeAllocationFailures, .{});
}

test "missing graphics code is a shader failure rather than an empty pipeline" {
    var pipeline = shared.DoeRenderPipeline{};
    const missing = shared.DoeShaderModule{};
    try std.testing.expectError(error.ShaderCompileFailed, retainShaderCode(std.testing.allocator, &pipeline, &missing, null, null, null));
    const vertex = shared.DoeShaderModule{ .vertex_spirv_data = &.{1} };
    try std.testing.expectError(error.ShaderCompileFailed, retainShaderCode(std.testing.allocator, &pipeline, &vertex, &missing, null, null));
    try std.testing.expectEqual(@as(?[]const u32, null), pipeline.vertex_spirv_data);
}

pub fn probe_has_graphics_entry_points(wgsl: []const u8) bool {
    return std.mem.indexOf(u8, wgsl, "@vertex") != null or
        std.mem.indexOf(u8, wgsl, "@fragment") != null;
}

pub fn vulkan_create_graphics_shader_moduleWithDiagnostic(sm: *shared.DoeShaderModule, wgsl: []const u8, diagnostic: *wgsl_analysis.Diagnostic) wgsl_analysis.TranslateError!void {
    const alloc = native_helpers.alloc;
    var result = try runtime_compile.translateToSpirvForGraphicsRuntimeWithDiagnostic(alloc, wgsl, diagnostic);
    defer result.deinit(alloc);
    sm.vertex_spirv_data = result.vertex_spirv;
    sm.fragment_spirv_data = result.fragment_spirv;

    sm.wg_x = 0;
    sm.wg_y = 0;
    sm.wg_z = 0;
    sm.needs_sizes_buf = false;

    result.vertex_spirv = null;
    result.fragment_spirv = null;
}

pub fn vulkan_create_graphics_shader_module(sm: *shared.DoeShaderModule, wgsl: []const u8) wgsl_analysis.TranslateError!void {
    return vulkan_create_graphics_shader_moduleWithDiagnostic(sm, wgsl, wgsl_analysis.compatibilityDiagnostic());
}
