//! Backend-neutral WebGPU texture format and view classifications.

const binding = @import("model/model_binding_value_types.zig");
const texture = @import("model/model_texture_value_types.zig");

pub fn inferSampleType(format: texture.WGPUTextureFormat) u32 {
    return switch (format) {
        texture.WGPUTextureFormat_Depth16Unorm,
        texture.WGPUTextureFormat_Depth24Plus,
        texture.WGPUTextureFormat_Depth24PlusStencil8,
        texture.WGPUTextureFormat_Depth32Float,
        texture.WGPUTextureFormat_Depth32FloatStencil8,
        => binding.WGPUTextureSampleType_Depth,
        texture.WGPUTextureFormat_R8Uint,
        texture.WGPUTextureFormat_R16Uint,
        texture.WGPUTextureFormat_RG8Uint,
        texture.WGPUTextureFormat_R32Uint,
        texture.WGPUTextureFormat_RG16Uint,
        texture.WGPUTextureFormat_RGBA8Uint,
        texture.WGPUTextureFormat_RGB10A2Uint,
        texture.WGPUTextureFormat_RG32Uint,
        texture.WGPUTextureFormat_RGBA16Uint,
        texture.WGPUTextureFormat_RGBA32Uint,
        => binding.WGPUTextureSampleType_Uint,
        texture.WGPUTextureFormat_R8Sint,
        texture.WGPUTextureFormat_R16Sint,
        texture.WGPUTextureFormat_RG8Sint,
        texture.WGPUTextureFormat_R32Sint,
        texture.WGPUTextureFormat_RG16Sint,
        texture.WGPUTextureFormat_RGBA8Sint,
        texture.WGPUTextureFormat_RG32Sint,
        texture.WGPUTextureFormat_RGBA16Sint,
        texture.WGPUTextureFormat_RGBA32Sint,
        => binding.WGPUTextureSampleType_Sint,
        else => binding.WGPUTextureSampleType_Float,
    };
}

pub fn defaultViewDimension(dimension: u32) u32 {
    return switch (dimension) {
        texture.WGPUTextureDimension_1D => texture.WGPUTextureViewDimension_1D,
        texture.WGPUTextureDimension_3D => texture.WGPUTextureViewDimension_3D,
        else => texture.WGPUTextureViewDimension_2D,
    };
}

pub fn aspectMatches(format: texture.WGPUTextureFormat, aspect: u32) bool {
    return switch (aspect) {
        texture.WGPUTextureAspect_All => true,
        texture.WGPUTextureAspect_DepthOnly => switch (format) {
            texture.WGPUTextureFormat_Depth16Unorm,
            texture.WGPUTextureFormat_Depth24Plus,
            texture.WGPUTextureFormat_Depth24PlusStencil8,
            texture.WGPUTextureFormat_Depth32Float,
            texture.WGPUTextureFormat_Depth32FloatStencil8,
            => true,
            else => false,
        },
        texture.WGPUTextureAspect_StencilOnly => switch (format) {
            texture.WGPUTextureFormat_Stencil8,
            texture.WGPUTextureFormat_Depth24PlusStencil8,
            texture.WGPUTextureFormat_Depth32FloatStencil8,
            => true,
            else => false,
        },
        else => false,
    };
}

test "texture format classifications are stable" {
    const std = @import("std");
    try std.testing.expectEqual(binding.WGPUTextureSampleType_Uint, inferSampleType(texture.WGPUTextureFormat_RGBA8Uint));
    try std.testing.expectEqual(binding.WGPUTextureSampleType_Depth, inferSampleType(texture.WGPUTextureFormat_Depth32Float));
    try std.testing.expect(aspectMatches(texture.WGPUTextureFormat_Depth24PlusStencil8, texture.WGPUTextureAspect_StencilOnly));
}
