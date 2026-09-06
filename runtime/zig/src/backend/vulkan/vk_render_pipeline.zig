// vk_render_pipeline.zig — Graphics pipeline creation and state conversion helpers
// for the Vulkan backend. Sharded from vk_render.zig.

const std = @import("std");
const log = std.log.scoped(.vk_render_pipeline);
const c = @import("vk_constants.zig");
const vk_formats = @import("vk_formats.zig");
const vk_pipeline = @import("vk_pipeline.zig");
const vk_shader_source = @import("vk_shader_source.zig");
const vk_resources = @import("vk_resources.zig");

// Canonical default render shaders loaded from `bench/kernels/` when a
// render-draw command does not reference an explicit vertex/fragment shader.
// Unblocks the render_draw_* and render_pass_* workload family without
// requiring each benchmark command file to author its own minimal shader
// pair. See bench/kernels/draw_call_proxy_vertex.wgsl and
// draw_call_proxy_fragment.wgsl for the source.
const DEFAULT_VERTEX_SHADER_NAME = "draw_call_proxy_vertex";
const DEFAULT_FRAGMENT_SHADER_NAME = "draw_call_proxy_fragment";
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_binding_types = @import("../../contracts/model/model_binding_value_types.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");

const VK_NULL_U64 = c.VK_NULL_U64;

const VK_PRIMITIVE_TOPOLOGY_POINT_LIST: u32 = 0;
const VK_PRIMITIVE_TOPOLOGY_LINE_LIST: u32 = 1;
const VK_PRIMITIVE_TOPOLOGY_LINE_STRIP: u32 = 2;
const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP: u32 = 4;
const VK_CULL_MODE_FRONT_BIT: u32 = 0x00000001;
const VK_CULL_MODE_BACK_BIT: u32 = 0x00000002;
const VK_FRONT_FACE_CLOCKWISE: u32 = 1;
const VK_COMPARE_OP_LESS: u32 = 1;
const VK_COMPARE_OP_EQUAL: u32 = 2;
const VK_COMPARE_OP_LESS_OR_EQUAL: u32 = 3;
const VK_COMPARE_OP_GREATER: u32 = 4;
const VK_COMPARE_OP_NOT_EQUAL: u32 = 5;
const VK_COMPARE_OP_GREATER_OR_EQUAL: u32 = 6;
const VK_COMPARE_OP_ALWAYS: u32 = 7;
const VK_STENCIL_OP_KEEP: u32 = 0;
const VK_STENCIL_OP_ZERO: u32 = 1;
const VK_STENCIL_OP_REPLACE: u32 = 2;
const VK_STENCIL_OP_INCREMENT_AND_CLAMP: u32 = 3;
const VK_STENCIL_OP_DECREMENT_AND_CLAMP: u32 = 4;
const VK_STENCIL_OP_INVERT: u32 = 5;
const VK_STENCIL_OP_INCREMENT_AND_WRAP: u32 = 6;
const VK_STENCIL_OP_DECREMENT_AND_WRAP: u32 = 7;
const VK_VERTEX_INPUT_RATE_VERTEX: u32 = 0;
const VK_VERTEX_INPUT_RATE_INSTANCE: u32 = 1;

pub fn render_texture_descriptor_type(is_storage: bool) u32 {
    return if (is_storage) c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE else c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
}

pub fn render_texture_image_layout(is_storage: bool) u32 {
    return if (is_storage) c.VK_IMAGE_LAYOUT_GENERAL else c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
}

pub fn render_buffer_descriptor_type(binding_type: u32) u32 {
    return if (binding_type == model_binding_types.WGPUBufferBindingType_Uniform)
        c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
    else
        c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
}

const VkStencilOpState = extern struct {
    failOp: u32,
    passOp: u32,
    depthFailOp: u32,
    compareOp: u32,
    compareMask: u32,
    writeMask: u32,
    reference: u32,
};

pub const VkPipelineDepthStencilStateCreateInfo = extern struct {
    sType: i32,
    pNext: ?*const anyopaque,
    flags: u32,
    depthTestEnable: u32,
    depthWriteEnable: u32,
    depthCompareOp: u32,
    depthBoundsTestEnable: u32,
    stencilTestEnable: u32,
    front: VkStencilOpState,
    back: VkStencilOpState,
    minDepthBounds: f32,
    maxDepthBounds: f32,
};

pub fn wgpu_compare_to_vk(compare: u32) u32 {
    return switch (compare) {
        0x00000002 => VK_COMPARE_OP_LESS,
        0x00000003 => VK_COMPARE_OP_EQUAL,
        0x00000004 => VK_COMPARE_OP_LESS_OR_EQUAL,
        0x00000005 => VK_COMPARE_OP_GREATER,
        0x00000006 => VK_COMPARE_OP_NOT_EQUAL,
        0x00000007 => VK_COMPARE_OP_GREATER_OR_EQUAL,
        0x00000008 => VK_COMPARE_OP_ALWAYS,
        else => c.VK_COMPARE_OP_NEVER,
    };
}

pub fn wgpu_stencil_op_to_vk(op: u32) u32 {
    return switch (op) {
        0x00000001 => VK_STENCIL_OP_ZERO,
        0x00000002 => VK_STENCIL_OP_REPLACE,
        0x00000003 => VK_STENCIL_OP_INVERT,
        0x00000004 => VK_STENCIL_OP_INCREMENT_AND_CLAMP,
        0x00000005 => VK_STENCIL_OP_DECREMENT_AND_CLAMP,
        0x00000006 => VK_STENCIL_OP_INCREMENT_AND_WRAP,
        0x00000007 => VK_STENCIL_OP_DECREMENT_AND_WRAP,
        else => VK_STENCIL_OP_KEEP,
    };
}

pub fn format_has_stencil(format: model_gpu_types.WGPUTextureFormat) bool {
    return switch (format) {
        model_gpu_types.WGPUTextureFormat_Stencil8,
        model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8,
        model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8,
        => true,
        else => false,
    };
}

pub fn resolve_entry_point_name(entry_point: ?[]const u8, fallback: []const u8, buf: []u8) [*:0]const u8 {
    const name = entry_point orelse fallback;
    const len = @min(name.len, buf.len - 1);
    @memcpy(buf[0..len], name[0..len]);
    buf[len] = 0;
    return buf[0..len :0];
}

pub fn topology_to_vk(topology: u32) u32 {
    return switch (topology) {
        0x00000001 => c.VK_PRIMITIVE_TOPOLOGY_POINT_LIST,
        0x00000002 => c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST,
        0x00000003 => c.VK_PRIMITIVE_TOPOLOGY_LINE_STRIP,
        0x00000005 => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
        else => c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };
}

pub fn vertex_step_mode_to_vk(step_mode: u32) u32 {
    return if (step_mode == model_render_types.WGPUVertexStepMode_Instance) VK_VERTEX_INPUT_RATE_INSTANCE else VK_VERTEX_INPUT_RATE_VERTEX;
}

pub fn front_face_to_vk(front_face: u32) u32 {
    return switch (front_face) {
        0x00000002 => c.VK_FRONT_FACE_CLOCKWISE,
        else => c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
    };
}

pub fn cull_mode_to_vk(cull_mode: u32) u32 {
    return switch (cull_mode) {
        0x00000002 => c.VK_CULL_MODE_FRONT_BIT,
        0x00000003 => c.VK_CULL_MODE_BACK_BIT,
        else => c.VK_CULL_MODE_NONE,
    };
}

pub fn sample_count_to_vk(sample_count: u32) u32 {
    return switch (sample_count) {
        2 => c.VK_SAMPLE_COUNT_2_BIT,
        4 => c.VK_SAMPLE_COUNT_4_BIT,
        8 => c.VK_SAMPLE_COUNT_8_BIT,
        16 => c.VK_SAMPLE_COUNT_16_BIT,
        else => c.VK_SAMPLE_COUNT_1_BIT,
    };
}

pub fn blend_factor_to_vk(factor: u32) u32 {
    return switch (factor) {
        1 => c.VK_BLEND_FACTOR_ZERO,
        2 => c.VK_BLEND_FACTOR_ONE,
        3 => c.VK_BLEND_FACTOR_SRC_COLOR,
        4 => c.VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,
        5 => c.VK_BLEND_FACTOR_SRC_ALPHA,
        6 => c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        7 => c.VK_BLEND_FACTOR_DST_COLOR,
        8 => c.VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR,
        9 => c.VK_BLEND_FACTOR_DST_ALPHA,
        10 => c.VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,
        11 => c.VK_BLEND_FACTOR_SRC_ALPHA_SATURATE,
        12 => c.VK_BLEND_FACTOR_CONSTANT_COLOR,
        13 => c.VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR,
        14 => c.VK_BLEND_FACTOR_SRC1_COLOR,
        15 => c.VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR,
        16 => c.VK_BLEND_FACTOR_SRC1_ALPHA,
        17 => c.VK_BLEND_FACTOR_ONE_MINUS_SRC1_ALPHA,
        else => c.VK_BLEND_FACTOR_ONE,
    };
}

pub fn blend_operation_to_vk(operation: u32) u32 {
    return switch (operation) {
        2 => c.VK_BLEND_OP_SUBTRACT,
        3 => c.VK_BLEND_OP_REVERSE_SUBTRACT,
        4 => c.VK_BLEND_OP_MIN,
        5 => c.VK_BLEND_OP_MAX,
        else => c.VK_BLEND_OP_ADD,
    };
}

pub fn color_write_mask_to_vk(write_mask: u32, fallback: u32) u32 {
    var mask: u32 = 0;
    if ((write_mask & 0x1) != 0) mask |= c.VK_COLOR_COMPONENT_R_BIT;
    if ((write_mask & 0x2) != 0) mask |= c.VK_COLOR_COMPONENT_G_BIT;
    if ((write_mask & 0x4) != 0) mask |= c.VK_COLOR_COMPONENT_B_BIT;
    if ((write_mask & 0x8) != 0) mask |= c.VK_COLOR_COMPONENT_A_BIT;
    return if (mask == 0) fallback else mask;
}

pub fn create_graphics_pipeline(
    self: anytype,
    state: anytype,
    vk_format: u32,
    cmd: model_render_types.RenderDrawCommand,
) !void {
    _ = vk_format;
    // When the render-draw command carries explicit shader SPIR-V, use it.
    // Otherwise fall back to Doe's canonical draw_call_proxy_vertex /
    // draw_call_proxy_fragment pair shipped under bench/kernels/ so draws
    // without bound shaders (bench harness draw_call_indexed_proxy and its
    // family) have a functional render pipeline. The load goes through the
    // backend's kernel SPV cache so the first-use compile is shared across
    // subsequent draws in the same process.
    const vertex_spirv_words = cmd.vertex_spirv orelse
        vk_shader_source.load_kernel_spirv_cached(self, DEFAULT_VERTEX_SHADER_NAME) catch
        return error.ShaderCompileFailed;
    const fragment_spirv_words = cmd.fragment_spirv orelse
        vk_shader_source.load_kernel_spirv_cached(self, DEFAULT_FRAGMENT_SHADER_NAME) catch
        return error.ShaderCompileFailed;
    var vertex_entry_buf: [64]u8 = undefined;
    var fragment_entry_buf: [64]u8 = undefined;
    const vertex_entry = resolve_entry_point_name(cmd.vertex_entry_point, "main", &vertex_entry_buf);
    const fragment_entry = resolve_entry_point_name(cmd.fragment_entry_point, "main", &fragment_entry_buf);

    var vertex_shader_info = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = vertex_spirv_words.len * @sizeOf(u32),
        .pCode = vertex_spirv_words.ptr,
    };
    try c.check_vk(c.vkCreateShaderModule(self.device, &vertex_shader_info, null, &state.vertex_shader));

    var fragment_shader_info = c.VkShaderModuleCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = fragment_spirv_words.len * @sizeOf(u32),
        .pCode = fragment_spirv_words.ptr,
    };
    try c.check_vk(c.vkCreateShaderModule(self.device, &fragment_shader_info, null, &state.fragment_shader));

    const has_bind_groups = cmd.bind_buffer_count > 0 or cmd.bind_texture_count > 0 or cmd.bind_sampler_count > 0;
    if (has_bind_groups) {
        try createRenderDescriptorState(self, state, cmd);
    }

    var set_layouts = [1]u64{state.descriptor_set_layout};
    var layout_info = c.VkPipelineLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = if (has_bind_groups) 1 else 0,
        .pSetLayouts = if (has_bind_groups) &set_layouts else null,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };
    try c.check_vk(c.vkCreatePipelineLayout(self.device, &layout_info, null, &state.graphics_pipeline_layout));

    const stages = [2]c.VkPipelineShaderStageCreateInfo{
        .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            .module = state.vertex_shader,
            .pName = vertex_entry,
            .pSpecializationInfo = null,
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = state.fragment_shader,
            .pName = fragment_entry,
            .pSpecializationInfo = null,
        },
    };

    var vertex_binding_descriptions: [model_render_types.MAX_VERTEX_BUFFERS]c.VkVertexInputBindingDescription = undefined;
    var vertex_attribute_descriptions: [model_render_types.MAX_VERTEX_BUFFERS * model_render_types.MAX_VERTEX_ATTRIBUTES]c.VkVertexInputAttributeDescription = undefined;
    var vertex_binding_count: usize = 0;
    var vertex_attribute_count: usize = 0;
    if (cmd.vertex_layouts) |layouts| {
        const layout_count = @min(layouts.len, model_render_types.MAX_VERTEX_BUFFERS);
        var layout_index: usize = 0;
        while (layout_index < layout_count) : (layout_index += 1) {
            const layout = layouts[layout_index];
            vertex_binding_descriptions[vertex_binding_count] = .{
                .binding = @intCast(layout_index),
                .stride = @intCast(@min(layout.array_stride, @as(u64, std.math.maxInt(u32)))),
                .inputRate = vertex_step_mode_to_vk(layout.step_mode),
            };
            vertex_binding_count += 1;

            const attr_count = @min(@as(usize, layout.attribute_count), model_render_types.MAX_VERTEX_ATTRIBUTES);
            var attr_index: usize = 0;
            while (attr_index < attr_count and vertex_attribute_count < vertex_attribute_descriptions.len) : (attr_index += 1) {
                const attr = layout.attributes[attr_index];
                vertex_attribute_descriptions[vertex_attribute_count] = .{
                    .location = attr.shader_location,
                    .binding = @intCast(layout_index),
                    .format = try vk_formats.wgpu_vertex_format_to_vk(attr.format),
                    .offset = @intCast(@min(attr.offset, @as(u64, std.math.maxInt(u32)))),
                };
                vertex_attribute_count += 1;
            }
        }
    }

    var vertex_input = c.VkPipelineVertexInputStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = @intCast(vertex_binding_count),
        .pVertexBindingDescriptions = if (vertex_binding_count > 0) vertex_binding_descriptions[0..vertex_binding_count].ptr else null,
        .vertexAttributeDescriptionCount = @intCast(vertex_attribute_count),
        .pVertexAttributeDescriptions = if (vertex_attribute_count > 0) vertex_attribute_descriptions[0..vertex_attribute_count].ptr else null,
    };

    var input_assembly = c.VkPipelineInputAssemblyStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = topology_to_vk(cmd.topology),
        .primitiveRestartEnable = c.VK_FALSE,
    };

    var viewport_state = c.VkPipelineViewportStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = null,
        .scissorCount = 1,
        .pScissors = null,
    };

    const use_unclipped = cmd.unclipped_depth and self.has_depth_clip_enable_ext;
    if (cmd.unclipped_depth and !self.has_depth_clip_enable_ext) {
        log.warn("unclippedDepth requested but VK_EXT_depth_clip_enable unavailable; falling back to standard clipping", .{});
    }

    var depth_clip_state = c.VkPipelineRasterizationDepthClipStateCreateInfoEXT{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_DEPTH_CLIP_STATE_CREATE_INFO_EXT,
        .pNext = null,
        .flags = 0,
        .depthClipEnable = c.VK_FALSE,
    };
    var rasterization = c.VkPipelineRasterizationStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext = if (use_unclipped) @ptrCast(&depth_clip_state) else null,
        .flags = 0,
        .depthClampEnable = if (use_unclipped) c.VK_TRUE else c.VK_FALSE,
        .rasterizerDiscardEnable = c.VK_FALSE,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .cullMode = cull_mode_to_vk(cmd.cull_mode),
        .frontFace = front_face_to_vk(cmd.front_face),
        .depthBiasEnable = if (cmd.depth_bias != 0 or cmd.depth_bias_slope_scale != 0 or cmd.depth_bias_clamp != 0) c.VK_TRUE else c.VK_FALSE,
        .depthBiasConstantFactor = @floatFromInt(cmd.depth_bias),
        .depthBiasClamp = cmd.depth_bias_clamp,
        .depthBiasSlopeFactor = cmd.depth_bias_slope_scale,
        .lineWidth = 1.0,
    };

    var multisample = c.VkPipelineMultisampleStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = sample_count_to_vk(cmd.sample_count),
        .sampleShadingEnable = c.VK_FALSE,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = c.VK_FALSE,
        .alphaToOneEnable = c.VK_FALSE,
    };

    const COLOR_WRITE_ALL = c.VK_COLOR_COMPONENT_R_BIT |
        c.VK_COLOR_COMPONENT_G_BIT |
        c.VK_COLOR_COMPONENT_B_BIT |
        c.VK_COLOR_COMPONENT_A_BIT;

    var blend_attachment = c.VkPipelineColorBlendAttachmentState{
        .blendEnable = if (cmd.blend_enabled) c.VK_TRUE else c.VK_FALSE,
        .srcColorBlendFactor = blend_factor_to_vk(cmd.color_src_factor),
        .dstColorBlendFactor = blend_factor_to_vk(cmd.color_dst_factor),
        .colorBlendOp = blend_operation_to_vk(cmd.color_operation),
        .srcAlphaBlendFactor = blend_factor_to_vk(cmd.alpha_src_factor),
        .dstAlphaBlendFactor = blend_factor_to_vk(cmd.alpha_dst_factor),
        .alphaBlendOp = blend_operation_to_vk(cmd.alpha_operation),
        .colorWriteMask = color_write_mask_to_vk(cmd.color_write_mask, COLOR_WRITE_ALL),
    };

    var color_blend = c.VkPipelineColorBlendStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = c.VK_FALSE,
        .logicOp = c.VK_LOGIC_OP_CLEAR,
        .attachmentCount = 1,
        .pAttachments = @ptrCast(&blend_attachment),
        .blendConstants = cmd.blend_constant,
    };

    const has_depth_stencil = cmd.depth_stencil_format != model_gpu_types.WGPUTextureFormat_Undefined;
    const depth_bias_enabled = cmd.depth_bias != 0 or cmd.depth_bias_slope_scale != 0 or cmd.depth_bias_clamp != 0;
    const dynamic_states_full = [_]u32{
        c.VK_DYNAMIC_STATE_VIEWPORT,
        c.VK_DYNAMIC_STATE_SCISSOR,
        c.VK_DYNAMIC_STATE_DEPTH_BIAS,
        c.VK_DYNAMIC_STATE_STENCIL_REFERENCE,
    };
    const dynamic_states_base = [_]u32{
        c.VK_DYNAMIC_STATE_VIEWPORT,
        c.VK_DYNAMIC_STATE_SCISSOR,
    };
    const dynamic_count: u32 = if (depth_bias_enabled or has_depth_stencil) dynamic_states_full.len else dynamic_states_base.len;
    var dynamic_state = c.VkPipelineDynamicStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = dynamic_count,
        .pDynamicStates = if (depth_bias_enabled or has_depth_stencil) &dynamic_states_full else &dynamic_states_base,
    };
    const has_stencil = has_depth_stencil and format_has_stencil(cmd.depth_stencil_format);
    var depth_stencil_state = VkPipelineDepthStencilStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthTestEnable = if (cmd.depth_compare != 0) c.VK_TRUE else c.VK_FALSE,
        .depthWriteEnable = if (cmd.depth_write_enabled) c.VK_TRUE else c.VK_FALSE,
        .depthCompareOp = wgpu_compare_to_vk(cmd.depth_compare),
        .depthBoundsTestEnable = c.VK_FALSE,
        .stencilTestEnable = if (has_stencil) c.VK_TRUE else c.VK_FALSE,
        .front = .{
            .failOp = wgpu_stencil_op_to_vk(cmd.stencil_front_fail_op),
            .passOp = wgpu_stencil_op_to_vk(cmd.stencil_front_pass_op),
            .depthFailOp = wgpu_stencil_op_to_vk(cmd.stencil_front_depth_fail_op),
            .compareOp = wgpu_compare_to_vk(cmd.stencil_front_compare),
            .compareMask = cmd.stencil_read_mask,
            .writeMask = cmd.stencil_write_mask,
            .reference = cmd.stencil_reference,
        },
        .back = .{
            .failOp = wgpu_stencil_op_to_vk(cmd.stencil_back_fail_op),
            .passOp = wgpu_stencil_op_to_vk(cmd.stencil_back_pass_op),
            .depthFailOp = wgpu_stencil_op_to_vk(cmd.stencil_back_depth_fail_op),
            .compareOp = wgpu_compare_to_vk(cmd.stencil_back_compare),
            .compareMask = cmd.stencil_read_mask,
            .writeMask = cmd.stencil_write_mask,
            .reference = cmd.stencil_reference,
        },
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
    };

    var pipeline_info = c.VkGraphicsPipelineCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stageCount = 2,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pTessellationState = null,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pDepthStencilState = if (has_depth_stencil) @ptrCast(&depth_stencil_state) else null,
        .pColorBlendState = &color_blend,
        .pDynamicState = &dynamic_state,
        .layout = state.graphics_pipeline_layout,
        .renderPass = state.render_pass,
        .subpass = 0,
        .basePipelineHandle = VK_NULL_U64,
        .basePipelineIndex = -1,
    };
    const graphics_cache_handle = self.pipeline_cache.handleForPipelineCreation();
    try c.check_vk(c.vkCreateGraphicsPipelines(
        self.device,
        graphics_cache_handle,
        1,
        @ptrCast(&pipeline_info),
        null,
        @ptrCast(&state.graphics_pipeline),
    ));
}

const MAX_RENDER_DESCRIPTOR_BINDINGS: usize = model_render_types.MAX_RENDER_BIND_ENTRIES * 3;
const VK_SHADER_STAGE_ALL_GRAPHICS: u32 = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;

/// Build descriptor set layout, pool, and set for render pipeline bindings.
/// WGSL lowers buffers, sampled images, and samplers as SPIR-V descriptors, so
/// descriptor bindings must preserve the original WebGPU binding numbers.
/// Descriptor writes resolve texture views and samplers from the runtime resource maps.
fn createRenderDescriptorState(
    self: anytype,
    state: anytype,
    cmd: model_render_types.RenderDrawCommand,
) !void {
    const buffer_count: u32 = cmd.bind_buffer_count;
    const tex_count: u32 = cmd.bind_texture_count;
    const samp_count: u32 = cmd.bind_sampler_count;
    const total_bindings = buffer_count + tex_count + samp_count;
    if (total_bindings == 0) return;

    // Build layout bindings at the WGSL-decorated binding numbers.
    var bindings: [MAX_RENDER_DESCRIPTOR_BINDINGS]c.VkDescriptorSetLayoutBinding = undefined;
    var binding_count: u32 = 0;
    var buffer_binding_index: u32 = 0;
    while (buffer_binding_index < buffer_count) : (buffer_binding_index += 1) {
        const binding = if (cmd.bind_buffer_bindings[buffer_binding_index] != model_render_types.RENDER_BINDING_UNSET)
            cmd.bind_buffer_bindings[buffer_binding_index]
        else
            buffer_binding_index;
        bindings[binding_count] = .{
            .binding = binding,
            .descriptorType = render_buffer_descriptor_type(cmd.bind_buffer_types[buffer_binding_index]),
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_ALL_GRAPHICS,
            .pImmutableSamplers = null,
        };
        binding_count += 1;
    }
    var tex_binding_index: u32 = 0;
    while (tex_binding_index < tex_count) : (tex_binding_index += 1) {
        const fallback_binding = tex_binding_index;
        const binding = if (cmd.bind_texture_bindings[tex_binding_index] != model_render_types.RENDER_BINDING_UNSET)
            cmd.bind_texture_bindings[tex_binding_index]
        else
            fallback_binding;
        bindings[binding_count] = .{
            .binding = binding,
            .descriptorType = render_texture_descriptor_type(cmd.bind_texture_storage[tex_binding_index]),
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_ALL_GRAPHICS,
            .pImmutableSamplers = null,
        };
        binding_count += 1;
    }
    var samp_binding_index: u32 = 0;
    while (samp_binding_index < samp_count) : (samp_binding_index += 1) {
        const fallback_binding = buffer_count + tex_count + samp_binding_index;
        const binding = if (cmd.bind_sampler_bindings[samp_binding_index] != model_render_types.RENDER_BINDING_UNSET)
            cmd.bind_sampler_bindings[samp_binding_index]
        else
            fallback_binding;
        bindings[binding_count] = .{
            .binding = binding,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = VK_SHADER_STAGE_ALL_GRAPHICS,
            .pImmutableSamplers = null,
        };
        binding_count += 1;
    }

    // Create descriptor set layout
    var layout_ci = c.VkDescriptorSetLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = binding_count,
        .pBindings = bindings[0..binding_count].ptr,
    };
    try c.check_vk(c.vkCreateDescriptorSetLayout(self.device, &layout_ci, null, &state.descriptor_set_layout));
    errdefer {
        c.vkDestroyDescriptorSetLayout(self.device, state.descriptor_set_layout, null);
        state.descriptor_set_layout = VK_NULL_U64;
    }

    // Create descriptor pool
    var sampled_texture_count: u32 = 0;
    var storage_texture_count: u32 = 0;
    var texture_index: u32 = 0;
    while (texture_index < tex_count) : (texture_index += 1) {
        if (cmd.bind_texture_storage[texture_index]) {
            storage_texture_count += 1;
        } else {
            sampled_texture_count += 1;
        }
    }
    var uniform_buffer_count: u32 = 0;
    var storage_buffer_count: u32 = 0;
    var buffer_index: u32 = 0;
    while (buffer_index < buffer_count) : (buffer_index += 1) {
        if (render_buffer_descriptor_type(cmd.bind_buffer_types[buffer_index]) == c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER) {
            uniform_buffer_count += 1;
        } else {
            storage_buffer_count += 1;
        }
    }
    var pool_sizes: [5]c.VkDescriptorPoolSize = undefined;
    var pool_size_count: u32 = 0;
    if (uniform_buffer_count > 0) {
        pool_sizes[pool_size_count] = .{
            .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = uniform_buffer_count,
        };
        pool_size_count += 1;
    }
    if (storage_buffer_count > 0) {
        pool_sizes[pool_size_count] = .{
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = storage_buffer_count,
        };
        pool_size_count += 1;
    }
    if (sampled_texture_count > 0) {
        pool_sizes[pool_size_count] = .{
            .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = sampled_texture_count,
        };
        pool_size_count += 1;
    }
    if (storage_texture_count > 0) {
        pool_sizes[pool_size_count] = .{
            .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .descriptorCount = storage_texture_count,
        };
        pool_size_count += 1;
    }
    if (samp_count > 0) {
        pool_sizes[pool_size_count] = .{
            .type = c.VK_DESCRIPTOR_TYPE_SAMPLER,
            .descriptorCount = samp_count,
        };
        pool_size_count += 1;
    }
    var pool_ci = c.VkDescriptorPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = 1,
        .poolSizeCount = pool_size_count,
        .pPoolSizes = pool_sizes[0..pool_size_count].ptr,
    };
    try c.check_vk(c.vkCreateDescriptorPool(self.device, &pool_ci, null, &state.descriptor_pool));
    errdefer {
        c.vkDestroyDescriptorPool(self.device, state.descriptor_pool, null);
        state.descriptor_pool = VK_NULL_U64;
    }

    // Allocate descriptor set
    const set_layout = [1]u64{state.descriptor_set_layout};
    var alloc_info = c.VkDescriptorSetAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = state.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &set_layout,
    };
    try c.check_vk(c.vkAllocateDescriptorSets(self.device, &alloc_info, @ptrCast(&state.descriptor_set)));

    // Write descriptor updates for buffer, texture, and sampler bindings.
    var buffer_infos: [MAX_RENDER_DESCRIPTOR_BINDINGS]c.VkDescriptorBufferInfo = undefined;
    var image_infos: [MAX_RENDER_DESCRIPTOR_BINDINGS]c.VkDescriptorImageInfo = undefined;
    var writes: [MAX_RENDER_DESCRIPTOR_BINDINGS]c.VkWriteDescriptorSet = undefined;
    var write_count: u32 = 0;

    var bi: u32 = 0;
    while (bi < buffer_count) : (bi += 1) {
        const compute_buffer = self.compute_buffers.get(cmd.bind_buffer_handles[bi]) orelse return error.InvalidArgument;
        const binding = if (cmd.bind_buffer_bindings[bi] != model_render_types.RENDER_BINDING_UNSET)
            cmd.bind_buffer_bindings[bi]
        else
            bi;
        const offset = cmd.bind_buffer_offsets[bi];
        const range = if (cmd.bind_buffer_sizes[bi] > 0) cmd.bind_buffer_sizes[bi] else compute_buffer.size -| offset;
        buffer_infos[write_count] = .{
            .buffer = compute_buffer.buffer,
            .offset = offset,
            .range = range,
        };
        writes[write_count] = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = state.descriptor_set,
            .dstBinding = binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = render_buffer_descriptor_type(cmd.bind_buffer_types[bi]),
            .pImageInfo = null,
            .pBufferInfo = @ptrCast(&buffer_infos[write_count]),
            .pTexelBufferView = null,
        };
        write_count += 1;
    }

    var ti: u32 = 0;
    while (ti < tex_count) : (ti += 1) {
        const tex_handle = cmd.bind_texture_handles[ti];
        const texture = self.textures.get(tex_handle);
        const fallback_binding = ti;
        const binding = if (cmd.bind_texture_bindings[ti] != model_render_types.RENDER_BINDING_UNSET)
            cmd.bind_texture_bindings[ti]
        else
            fallback_binding;
        image_infos[write_count] = .{
            .sampler = VK_NULL_U64,
            .imageView = if (texture) |t| t.view else VK_NULL_U64,
            .imageLayout = render_texture_image_layout(cmd.bind_texture_storage[ti]),
        };
        writes[write_count] = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = state.descriptor_set,
            .dstBinding = binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = render_texture_descriptor_type(cmd.bind_texture_storage[ti]),
            .pImageInfo = @ptrCast(&image_infos[write_count]),
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        write_count += 1;
    }

    var si: u32 = 0;
    while (si < samp_count) : (si += 1) {
        const sampler_handle = cmd.bind_sampler_handles[si];
        const sampler_vk: u64 = if (sampler_handle != 0)
            if (self.samplers.get(sampler_handle)) |sampler| sampler.handle else VK_NULL_U64
        else
            VK_NULL_U64;
        const fallback_binding = buffer_count + tex_count + si;
        const binding = if (cmd.bind_sampler_bindings[si] != model_render_types.RENDER_BINDING_UNSET)
            cmd.bind_sampler_bindings[si]
        else
            fallback_binding;
        image_infos[write_count] = .{
            .sampler = sampler_vk,
            .imageView = VK_NULL_U64,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        writes[write_count] = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = state.descriptor_set,
            .dstBinding = binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER,
            .pImageInfo = @ptrCast(&image_infos[write_count]),
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        write_count += 1;
    }

    if (write_count > 0) {
        c.vkUpdateDescriptorSets(self.device, write_count, writes[0..write_count].ptr, 0, null);
    }
}
