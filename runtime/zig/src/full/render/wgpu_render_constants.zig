const std = @import("std");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const render_resource_mod = @import("wgpu_render_resources.zig");
const render_types_mod = @import("wgpu_render_types.zig");

pub const RENDER_LOAD_OP_CLEAR: u32 = 0x00000002;
pub const RENDER_STORE_OP_STORE: u32 = 0x00000001;
pub const RENDER_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST: u32 = 0x00000004;
pub const RENDER_FRONT_FACE_CCW: u32 = 0x00000001;
pub const RENDER_CULL_MODE_NONE: u32 = 0x00000001;
pub const RENDER_COLOR_WRITE_MASK_ALL: u64 = 0x000000000000000F;
pub const RENDER_TARGET_DEPTH_SLICE_UNDEFINED: u32 = std.math.maxInt(u32);
pub const RENDER_MULTISAMPLE_MASK_ALL: u32 = 0xFFFF_FFFF;
pub const RENDER_DEPTH_STENCIL_FORMAT: model_gpu_types.WGPUTextureFormat = model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8;
pub const RENDER_DEPTH_STENCIL_CLEAR_VALUE: f32 = 1.0;
pub const RENDER_STENCIL_CLEAR_VALUE: u32 = 0;
pub const RENDER_COMPARE_FUNCTION_ALWAYS: u32 = 0x00000008;
pub const RENDER_STENCIL_OPERATION_KEEP: u32 = 0x00000001;
pub const RENDER_OPTIONAL_BOOL_FALSE: u32 = 0x00000000;
pub const RENDER_STENCIL_MASK_DEFAULT: u32 = 0x000000FF;
pub const RENDER_DEPTH_ATTACHMENT_HANDLE_MASK: u64 = 0x8C9F_2400_0000_0000;
pub const RENDER_VERTEX_BUFFER_HANDLE: u64 = 0x8C9F_2500_0000_0000;
pub const RENDER_MULTI_DRAW_INDIRECT_BUFFER_HANDLE: u64 = 0x8C9F_2A00_0000_0000;
pub const TEMP_RENDER_TEXTURE_OFFSET: u64 = 0xBEEF_0000_0000_0001;
pub const RENDER_VERTEX_FORMAT_FLOAT32X4: u32 = 0x0000001F;
pub const RENDER_VERTEX_STEP_MODE_VERTEX: u32 = 0x00000001;
pub const RENDER_VERTEX_STRIDE_BYTES: u64 = 4 * @sizeOf(f32);
pub const RENDER_UNIFORM_BINDING_INDEX: u32 = render_resource_mod.RENDER_UNIFORM_BINDING_INDEX;
pub const RENDER_UNIFORM_DYNAMIC_STRIDE_BYTES: u64 = render_resource_mod.RENDER_UNIFORM_DYNAMIC_STRIDE_BYTES;
pub const RENDER_UNIFORM_MIN_BINDING_SIZE_BYTES: u64 = render_resource_mod.RENDER_UNIFORM_MIN_BINDING_SIZE_BYTES;
pub const RENDER_UNIFORM_TOTAL_BYTES: u64 = render_resource_mod.RENDER_UNIFORM_TOTAL_BYTES;

pub const RenderColor = render_types_mod.RenderColor;
pub const RenderBundleDescriptor = render_types_mod.RenderBundleDescriptor;
pub const RenderBundleEncoderDescriptor = render_types_mod.RenderBundleEncoderDescriptor;
pub const RenderPassColorAttachment = render_types_mod.RenderPassColorAttachment;
pub const RenderPassDescriptor = render_types_mod.RenderPassDescriptor;
pub const RenderPassDepthStencilAttachment = render_types_mod.RenderPassDepthStencilAttachment;
pub const RenderVertexAttribute = render_types_mod.RenderVertexAttribute;
pub const RenderVertexBufferLayout = render_types_mod.RenderVertexBufferLayout;
pub const RenderColorTargetState = render_types_mod.RenderColorTargetState;
pub const RenderFragmentState = render_types_mod.RenderFragmentState;
pub const RenderStencilFaceState = render_types_mod.RenderStencilFaceState;
pub const RenderDepthStencilState = render_types_mod.RenderDepthStencilState;
pub const RenderPipelineDescriptor = render_types_mod.RenderPipelineDescriptor;
pub const RenderUniformBindingResources = render_resource_mod.RenderUniformBindingResources;

pub fn is_affected_render_format(format: model_gpu_types.WGPUTextureFormat) bool {
    return format == model_gpu_types.WGPUTextureFormat_R8Unorm or
        format == model_gpu_types.WGPUTextureFormat_RG8Unorm;
}

const testing = std.testing;

test "is_affected_render_format returns true for R8Unorm" {
    try testing.expect(is_affected_render_format(model_gpu_types.WGPUTextureFormat_R8Unorm));
}

test "is_affected_render_format returns true for RG8Unorm" {
    try testing.expect(is_affected_render_format(model_gpu_types.WGPUTextureFormat_RG8Unorm));
}

test "is_affected_render_format returns false for RGBA8Unorm" {
    try testing.expect(!is_affected_render_format(model_gpu_types.WGPUTextureFormat_RGBA8Unorm));
}

test "is_affected_render_format returns false for BGRA8Unorm" {
    try testing.expect(!is_affected_render_format(model_gpu_types.WGPUTextureFormat_BGRA8Unorm));
}

test "is_affected_render_format returns false for Undefined" {
    try testing.expect(!is_affected_render_format(model_gpu_types.WGPUTextureFormat_Undefined));
}

test "RENDER_LOAD_OP_CLEAR is nonzero" {
    try testing.expect(RENDER_LOAD_OP_CLEAR != 0);
}

test "RENDER_STORE_OP_STORE is nonzero" {
    try testing.expect(RENDER_STORE_OP_STORE != 0);
}

test "RENDER_MULTISAMPLE_MASK_ALL is 0xFFFFFFFF" {
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), RENDER_MULTISAMPLE_MASK_ALL);
}
