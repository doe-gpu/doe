const std = @import("std");
const vk_render_pipeline = @import("../../src/backend/vulkan/vk_render_pipeline.zig");
const vk_feature_caps = @import("../../src/backend/vulkan/vk_feature_caps.zig");
const vk_constants = @import("../../src/backend/vulkan/vk_constants.zig");
const model_binding_types = @import("../../src/contracts/model/model_binding_value_types.zig");
const model_render_types = @import("../../src/contracts/model/model_render_types.zig");
const model_texture_formats = @import("../../src/contracts/model/model_texture_format_value_types.zig");

// blend_factor_to_vk

test "vulkan: blend_factor_to_vk maps Zero correctly" {
    try std.testing.expectEqual(vk_constants.VK_BLEND_FACTOR_ZERO, vk_render_pipeline.blend_factor_to_vk(1));
}

test "vulkan: blend_factor_to_vk maps One correctly" {
    try std.testing.expectEqual(vk_constants.VK_BLEND_FACTOR_ONE, vk_render_pipeline.blend_factor_to_vk(2));
}

test "vulkan: blend_factor_to_vk maps SrcAlpha correctly" {
    try std.testing.expectEqual(vk_constants.VK_BLEND_FACTOR_SRC_ALPHA, vk_render_pipeline.blend_factor_to_vk(5));
}

test "vulkan: blend_factor_to_vk maps OneMinusSrcAlpha correctly" {
    try std.testing.expectEqual(vk_constants.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA, vk_render_pipeline.blend_factor_to_vk(6));
}

test "vulkan: blend_factor_to_vk returns One for unknown value" {
    try std.testing.expectEqual(vk_constants.VK_BLEND_FACTOR_ONE, vk_render_pipeline.blend_factor_to_vk(0));
    try std.testing.expectEqual(vk_constants.VK_BLEND_FACTOR_ONE, vk_render_pipeline.blend_factor_to_vk(255));
}

test "vulkan: render buffer descriptor types preserve uniform versus storage" {
    try std.testing.expectEqual(
        vk_constants.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        vk_render_pipeline.render_buffer_descriptor_type(model_binding_types.WGPUBufferBindingType_Uniform),
    );
    try std.testing.expectEqual(
        vk_constants.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        vk_render_pipeline.render_buffer_descriptor_type(model_binding_types.WGPUBufferBindingType_ReadOnlyStorage),
    );
}

// blend_operation_to_vk

test "vulkan: blend_operation_to_vk maps Add correctly" {
    try std.testing.expectEqual(vk_constants.VK_BLEND_OP_ADD, vk_render_pipeline.blend_operation_to_vk(1));
}

test "vulkan: blend_operation_to_vk maps Subtract correctly" {
    try std.testing.expectEqual(vk_constants.VK_BLEND_OP_SUBTRACT, vk_render_pipeline.blend_operation_to_vk(2));
}

test "vulkan: blend_operation_to_vk maps Min and Max correctly" {
    try std.testing.expectEqual(vk_constants.VK_BLEND_OP_MIN, vk_render_pipeline.blend_operation_to_vk(4));
    try std.testing.expectEqual(vk_constants.VK_BLEND_OP_MAX, vk_render_pipeline.blend_operation_to_vk(5));
}

test "vulkan: blend_operation_to_vk returns Add for unknown value" {
    try std.testing.expectEqual(vk_constants.VK_BLEND_OP_ADD, vk_render_pipeline.blend_operation_to_vk(0));
    try std.testing.expectEqual(vk_constants.VK_BLEND_OP_ADD, vk_render_pipeline.blend_operation_to_vk(99));
}

// topology_to_vk

test "vulkan: topology_to_vk maps TriangleList as default" {
    try std.testing.expectEqual(vk_constants.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, vk_render_pipeline.topology_to_vk(0x00000004));
}

test "vulkan: topology_to_vk maps PointList correctly" {
    try std.testing.expectEqual(@as(u32, 0), vk_render_pipeline.topology_to_vk(0x00000001));
}

test "vulkan: topology_to_vk maps LineList correctly" {
    try std.testing.expectEqual(@as(u32, 1), vk_render_pipeline.topology_to_vk(0x00000002));
}

test "vulkan: topology_to_vk maps LineStrip correctly" {
    try std.testing.expectEqual(@as(u32, 2), vk_render_pipeline.topology_to_vk(0x00000003));
}

test "vulkan: topology_to_vk maps TriangleStrip correctly" {
    try std.testing.expectEqual(@as(u32, 4), vk_render_pipeline.topology_to_vk(0x00000005));
}

test "vulkan: topology_to_vk returns TriangleList for unknown" {
    try std.testing.expectEqual(vk_constants.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, vk_render_pipeline.topology_to_vk(0));
    try std.testing.expectEqual(vk_constants.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, vk_render_pipeline.topology_to_vk(0xFF));
}

// cull_mode_to_vk

test "vulkan: cull_mode_to_vk maps None as default" {
    try std.testing.expectEqual(vk_constants.VK_CULL_MODE_NONE, vk_render_pipeline.cull_mode_to_vk(0));
    try std.testing.expectEqual(vk_constants.VK_CULL_MODE_NONE, vk_render_pipeline.cull_mode_to_vk(1));
}

test "vulkan: cull_mode_to_vk maps Front correctly" {
    try std.testing.expectEqual(@as(u32, 0x00000001), vk_render_pipeline.cull_mode_to_vk(0x00000002));
}

test "vulkan: cull_mode_to_vk maps Back correctly" {
    try std.testing.expectEqual(@as(u32, 0x00000002), vk_render_pipeline.cull_mode_to_vk(0x00000003));
}

// front_face_to_vk

test "vulkan: front_face_to_vk maps CCW as default" {
    try std.testing.expectEqual(vk_constants.VK_FRONT_FACE_COUNTER_CLOCKWISE, vk_render_pipeline.front_face_to_vk(0));
    try std.testing.expectEqual(vk_constants.VK_FRONT_FACE_COUNTER_CLOCKWISE, vk_render_pipeline.front_face_to_vk(1));
}

test "vulkan: front_face_to_vk maps CW correctly" {
    try std.testing.expectEqual(@as(u32, 1), vk_render_pipeline.front_face_to_vk(0x00000002));
}

// sample_count_to_vk

test "vulkan: sample_count_to_vk maps 1 as default" {
    try std.testing.expectEqual(vk_constants.VK_SAMPLE_COUNT_1_BIT, vk_render_pipeline.sample_count_to_vk(1));
    try std.testing.expectEqual(vk_constants.VK_SAMPLE_COUNT_1_BIT, vk_render_pipeline.sample_count_to_vk(0));
    try std.testing.expectEqual(vk_constants.VK_SAMPLE_COUNT_1_BIT, vk_render_pipeline.sample_count_to_vk(3));
}

test "vulkan: sample_count_to_vk maps 2 correctly" {
    try std.testing.expectEqual(vk_constants.VK_SAMPLE_COUNT_2_BIT, vk_render_pipeline.sample_count_to_vk(2));
}

test "vulkan: sample_count_to_vk maps 4 correctly" {
    try std.testing.expectEqual(vk_constants.VK_SAMPLE_COUNT_4_BIT, vk_render_pipeline.sample_count_to_vk(4));
}

// color_write_mask_to_vk

test "vulkan: color_write_mask_to_vk maps All correctly" {
    const ALL = vk_constants.VK_COLOR_COMPONENT_R_BIT |
        vk_constants.VK_COLOR_COMPONENT_G_BIT |
        vk_constants.VK_COLOR_COMPONENT_B_BIT |
        vk_constants.VK_COLOR_COMPONENT_A_BIT;
    try std.testing.expectEqual(ALL, vk_render_pipeline.color_write_mask_to_vk(0xF, 0));
}

test "vulkan: color_write_mask_to_vk maps R-only correctly" {
    try std.testing.expectEqual(vk_constants.VK_COLOR_COMPONENT_R_BIT, vk_render_pipeline.color_write_mask_to_vk(0x1, 0));
}

test "vulkan: color_write_mask_to_vk returns fallback for zero mask" {
    try std.testing.expectEqual(@as(u32, 42), vk_render_pipeline.color_write_mask_to_vk(0, 42));
}

// wgpu_compare_to_vk

test "vulkan: wgpu_compare_to_vk maps Never as default" {
    try std.testing.expectEqual(vk_constants.VK_COMPARE_OP_NEVER, vk_render_pipeline.wgpu_compare_to_vk(0));
    try std.testing.expectEqual(vk_constants.VK_COMPARE_OP_NEVER, vk_render_pipeline.wgpu_compare_to_vk(1));
}

test "vulkan: wgpu_compare_to_vk maps Less correctly" {
    try std.testing.expectEqual(@as(u32, 1), vk_render_pipeline.wgpu_compare_to_vk(0x00000002));
}

test "vulkan: wgpu_compare_to_vk maps Always correctly" {
    try std.testing.expectEqual(@as(u32, 7), vk_render_pipeline.wgpu_compare_to_vk(0x00000008));
}

// wgpu_stencil_op_to_vk

test "vulkan: wgpu_stencil_op_to_vk maps Keep as default" {
    try std.testing.expectEqual(@as(u32, 0), vk_render_pipeline.wgpu_stencil_op_to_vk(0));
    try std.testing.expectEqual(@as(u32, 0), vk_render_pipeline.wgpu_stencil_op_to_vk(255));
}

test "vulkan: wgpu_stencil_op_to_vk maps Zero correctly" {
    try std.testing.expectEqual(@as(u32, 1), vk_render_pipeline.wgpu_stencil_op_to_vk(0x00000001));
}

test "vulkan: wgpu_stencil_op_to_vk maps Replace correctly" {
    try std.testing.expectEqual(@as(u32, 2), vk_render_pipeline.wgpu_stencil_op_to_vk(0x00000002));
}

test "vulkan: wgpu_stencil_op_to_vk maps Invert correctly" {
    try std.testing.expectEqual(@as(u32, 5), vk_render_pipeline.wgpu_stencil_op_to_vk(0x00000003));
}

// format_has_stencil

test "vulkan: format_has_stencil returns true for Stencil8" {
    try std.testing.expect(vk_render_pipeline.format_has_stencil(model_texture_formats.WGPUTextureFormat_Stencil8));
}

test "vulkan: format_has_stencil returns true for Depth24PlusStencil8" {
    try std.testing.expect(vk_render_pipeline.format_has_stencil(model_texture_formats.WGPUTextureFormat_Depth24PlusStencil8));
}

test "vulkan: format_has_stencil returns true for Depth32FloatStencil8" {
    try std.testing.expect(vk_render_pipeline.format_has_stencil(model_texture_formats.WGPUTextureFormat_Depth32FloatStencil8));
}

test "vulkan: format_has_stencil returns false for Depth24Plus" {
    try std.testing.expect(!vk_render_pipeline.format_has_stencil(model_texture_formats.WGPUTextureFormat_Depth24Plus));
}

test "vulkan: format_has_stencil returns false for Depth32Float" {
    try std.testing.expect(!vk_render_pipeline.format_has_stencil(model_texture_formats.WGPUTextureFormat_Depth32Float));
}

test "vulkan: format_has_stencil returns false for Undefined" {
    try std.testing.expect(!vk_render_pipeline.format_has_stencil(model_texture_formats.WGPUTextureFormat_Undefined));
}

// resolve_entry_point_name

test "vulkan: resolve_entry_point_name uses provided name" {
    var buf: [64]u8 = undefined;
    const name = vk_render_pipeline.resolve_entry_point_name("vertex_main", "main", &buf);
    try std.testing.expectEqualStrings("vertex_main", std.mem.span(name));
}

test "vulkan: resolve_entry_point_name uses fallback when null" {
    var buf: [64]u8 = undefined;
    const name = vk_render_pipeline.resolve_entry_point_name(null, "main", &buf);
    try std.testing.expectEqualStrings("main", std.mem.span(name));
}

test "vulkan: resolve_entry_point_name truncates to buffer size" {
    var buf: [4]u8 = undefined;
    const name = vk_render_pipeline.resolve_entry_point_name("long_entry_name", "main", &buf);
    try std.testing.expectEqualStrings("lon", std.mem.span(name));
}

// vertex_step_mode_to_vk

test "vulkan: vertex_step_mode_to_vk maps Vertex as default" {
    try std.testing.expectEqual(@as(u32, 0), vk_render_pipeline.vertex_step_mode_to_vk(model_render_types.WGPUVertexStepMode_Vertex));
}

test "vulkan: vertex_step_mode_to_vk maps Instance correctly" {
    try std.testing.expectEqual(@as(u32, 1), vk_render_pipeline.vertex_step_mode_to_vk(model_render_types.WGPUVertexStepMode_Instance));
}

test "vulkan: vertex_step_mode_to_vk returns Vertex for unknown" {
    try std.testing.expectEqual(@as(u32, 0), vk_render_pipeline.vertex_step_mode_to_vk(0));
    try std.testing.expectEqual(@as(u32, 0), vk_render_pipeline.vertex_step_mode_to_vk(99));
}

test "vulkan: render texture descriptor type preserves storage ownership" {
    try std.testing.expectEqual(
        vk_constants.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE,
        vk_render_pipeline.render_texture_descriptor_type(false),
    );
    try std.testing.expectEqual(
        vk_constants.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
        vk_render_pipeline.render_texture_descriptor_type(true),
    );
}

test "vulkan: render texture layout preserves storage ownership" {
    try std.testing.expectEqual(
        vk_constants.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        vk_render_pipeline.render_texture_image_layout(false),
    );
    try std.testing.expectEqual(
        vk_constants.VK_IMAGE_LAYOUT_GENERAL,
        vk_render_pipeline.render_texture_image_layout(true),
    );
}

test "vulkan: required graphics storage-write features survive device enablement" {
    var raw = std.mem.zeroes(vk_constants.VkPhysicalDeviceFeatures);
    raw.robustBufferAccess = vk_constants.VK_TRUE;
    raw.vertexPipelineStoresAndAtomics = vk_constants.VK_TRUE;
    raw.fragmentStoresAndAtomics = vk_constants.VK_TRUE;

    const enabled = vk_feature_caps.enabled_core_features(raw);
    try std.testing.expectEqual(vk_constants.VK_TRUE, enabled.robustBufferAccess);
    try std.testing.expectEqual(vk_constants.VK_TRUE, enabled.vertexPipelineStoresAndAtomics);
    try std.testing.expectEqual(vk_constants.VK_TRUE, enabled.fragmentStoresAndAtomics);
}
