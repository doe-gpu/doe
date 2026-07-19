const model_texture_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_binding_types = @import("../../contracts/model/model_binding_value_types.zig");
const proc_types = @import("../abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;

pub fn normalizeBufferBindingType(value: u32) u32 {
    return switch (value) {
        model_binding_types.WGPUBufferBindingType_Uniform => abi_base.WGPUBufferBindingType_Uniform,
        model_binding_types.WGPUBufferBindingType_Storage => abi_base.WGPUBufferBindingType_Storage,
        model_binding_types.WGPUBufferBindingType_ReadOnlyStorage => abi_base.WGPUBufferBindingType_ReadOnlyStorage,
        else => abi_base.WGPUBufferBindingType_Undefined,
    };
}

pub fn normalizeTextureSampleType(value: u32) u32 {
    return switch (value) {
        model_binding_types.WGPUTextureSampleType_Float => abi_base.WGPUTextureSampleType_Float,
        model_binding_types.WGPUTextureSampleType_UnfilterableFloat => abi_base.WGPUTextureSampleType_UnfilterableFloat,
        model_binding_types.WGPUTextureSampleType_Depth => abi_base.WGPUTextureSampleType_Depth,
        model_binding_types.WGPUTextureSampleType_Sint => abi_base.WGPUTextureSampleType_Sint,
        model_binding_types.WGPUTextureSampleType_Uint => abi_base.WGPUTextureSampleType_Uint,
        else => abi_base.WGPUTextureSampleType_Float,
    };
}

pub fn normalizeTextureViewDimension(value: u32) abi_base.WGPUTextureViewDimension {
    return switch (value) {
        model_texture_types.WGPUTextureViewDimension_1D => abi_base.WGPUTextureViewDimension_1D,
        model_texture_types.WGPUTextureViewDimension_2D => abi_base.WGPUTextureViewDimension_2D,
        model_texture_types.WGPUTextureViewDimension_2DArray => abi_base.WGPUTextureViewDimension_2DArray,
        model_texture_types.WGPUTextureViewDimension_Cube => abi_base.WGPUTextureViewDimension_Cube,
        model_texture_types.WGPUTextureViewDimension_CubeArray => abi_base.WGPUTextureViewDimension_CubeArray,
        model_texture_types.WGPUTextureViewDimension_3D => abi_base.WGPUTextureViewDimension_3D,
        else => abi_base.WGPUTextureViewDimension_2D,
    };
}

pub fn normalizeStorageTextureAccess(value: u32) u32 {
    return switch (value) {
        model_binding_types.WGPUStorageTextureAccess_WriteOnly => abi_base.WGPUStorageTextureAccess_WriteOnly,
        model_binding_types.WGPUStorageTextureAccess_ReadOnly => abi_base.WGPUStorageTextureAccess_ReadOnly,
        model_binding_types.WGPUStorageTextureAccess_ReadWrite => abi_base.WGPUStorageTextureAccess_ReadWrite,
        else => abi_base.WGPUStorageTextureAccess_WriteOnly,
    };
}

pub fn normalizeTextureFormat(value: u32) abi_base.WGPUTextureFormat {
    return switch (value) {
        model_texture_types.WGPUTextureFormat_Undefined => abi_base.WGPUTextureFormat_Undefined,
        model_texture_types.WGPUTextureFormat_R8Unorm => abi_base.WGPUTextureFormat_R8Unorm,
        model_texture_types.WGPUTextureFormat_R8Snorm => model_texture_types.WGPUTextureFormat_R8Snorm,
        model_texture_types.WGPUTextureFormat_R8Uint => model_texture_types.WGPUTextureFormat_R8Uint,
        model_texture_types.WGPUTextureFormat_R8Sint => model_texture_types.WGPUTextureFormat_R8Sint,
        model_texture_types.WGPUTextureFormat_R16Unorm => model_texture_types.WGPUTextureFormat_R16Unorm,
        model_texture_types.WGPUTextureFormat_R16Snorm => model_texture_types.WGPUTextureFormat_R16Snorm,
        model_texture_types.WGPUTextureFormat_R16Uint => model_texture_types.WGPUTextureFormat_R16Uint,
        model_texture_types.WGPUTextureFormat_R16Sint => model_texture_types.WGPUTextureFormat_R16Sint,
        model_texture_types.WGPUTextureFormat_R16Float => model_texture_types.WGPUTextureFormat_R16Float,
        model_texture_types.WGPUTextureFormat_RG8Unorm => model_texture_types.WGPUTextureFormat_RG8Unorm,
        model_texture_types.WGPUTextureFormat_RG8Snorm => model_texture_types.WGPUTextureFormat_RG8Snorm,
        model_texture_types.WGPUTextureFormat_RG8Uint => model_texture_types.WGPUTextureFormat_RG8Uint,
        model_texture_types.WGPUTextureFormat_RG8Sint => model_texture_types.WGPUTextureFormat_RG8Sint,
        model_texture_types.WGPUTextureFormat_R32Float => model_texture_types.WGPUTextureFormat_R32Float,
        model_texture_types.WGPUTextureFormat_R32Uint => model_texture_types.WGPUTextureFormat_R32Uint,
        model_texture_types.WGPUTextureFormat_R32Sint => model_texture_types.WGPUTextureFormat_R32Sint,
        model_texture_types.WGPUTextureFormat_RG16Unorm => model_texture_types.WGPUTextureFormat_RG16Unorm,
        model_texture_types.WGPUTextureFormat_RG16Snorm => model_texture_types.WGPUTextureFormat_RG16Snorm,
        model_texture_types.WGPUTextureFormat_RG16Uint => model_texture_types.WGPUTextureFormat_RG16Uint,
        model_texture_types.WGPUTextureFormat_RG16Sint => model_texture_types.WGPUTextureFormat_RG16Sint,
        model_texture_types.WGPUTextureFormat_RG16Float => model_texture_types.WGPUTextureFormat_RG16Float,
        model_texture_types.WGPUTextureFormat_RGBA8Unorm => model_texture_types.WGPUTextureFormat_RGBA8Unorm,
        model_texture_types.WGPUTextureFormat_RGBA8UnormSrgb => model_texture_types.WGPUTextureFormat_RGBA8UnormSrgb,
        model_texture_types.WGPUTextureFormat_RGBA8Snorm => model_texture_types.WGPUTextureFormat_RGBA8Snorm,
        model_texture_types.WGPUTextureFormat_RGBA8Uint => model_texture_types.WGPUTextureFormat_RGBA8Uint,
        model_texture_types.WGPUTextureFormat_RGBA8Sint => model_texture_types.WGPUTextureFormat_RGBA8Sint,
        model_texture_types.WGPUTextureFormat_BGRA8Unorm => model_texture_types.WGPUTextureFormat_BGRA8Unorm,
        model_texture_types.WGPUTextureFormat_BGRA8UnormSrgb => model_texture_types.WGPUTextureFormat_BGRA8UnormSrgb,
        model_texture_types.WGPUTextureFormat_Depth16Unorm => model_texture_types.WGPUTextureFormat_Depth16Unorm,
        model_texture_types.WGPUTextureFormat_Depth24Plus => model_texture_types.WGPUTextureFormat_Depth24Plus,
        model_texture_types.WGPUTextureFormat_Depth24PlusStencil8 => model_texture_types.WGPUTextureFormat_Depth24PlusStencil8,
        model_texture_types.WGPUTextureFormat_Depth32Float => model_texture_types.WGPUTextureFormat_Depth32Float,
        model_texture_types.WGPUTextureFormat_Depth32FloatStencil8 => model_texture_types.WGPUTextureFormat_Depth32FloatStencil8,
        else => abi_base.WGPUTextureFormat_Undefined,
    };
}

pub fn textureFormatBytesPerPixel(format: abi_base.WGPUTextureFormat) ?u32 {
    return switch (format) {
        abi_base.WGPUTextureFormat_R8Unorm,
        model_texture_types.WGPUTextureFormat_R8Snorm,
        model_texture_types.WGPUTextureFormat_R8Uint,
        model_texture_types.WGPUTextureFormat_R8Sint,
        => 1,
        model_texture_types.WGPUTextureFormat_R16Unorm,
        model_texture_types.WGPUTextureFormat_R16Snorm,
        model_texture_types.WGPUTextureFormat_R16Uint,
        model_texture_types.WGPUTextureFormat_R16Sint,
        model_texture_types.WGPUTextureFormat_R16Float,
        model_texture_types.WGPUTextureFormat_RG8Unorm,
        model_texture_types.WGPUTextureFormat_RG8Snorm,
        model_texture_types.WGPUTextureFormat_RG8Uint,
        model_texture_types.WGPUTextureFormat_RG8Sint,
        => 2,
        model_texture_types.WGPUTextureFormat_R32Float,
        model_texture_types.WGPUTextureFormat_R32Uint,
        model_texture_types.WGPUTextureFormat_R32Sint,
        model_texture_types.WGPUTextureFormat_RG16Unorm,
        model_texture_types.WGPUTextureFormat_RG16Snorm,
        model_texture_types.WGPUTextureFormat_RG16Uint,
        model_texture_types.WGPUTextureFormat_RG16Sint,
        model_texture_types.WGPUTextureFormat_RG16Float,
        model_texture_types.WGPUTextureFormat_RGBA8Unorm,
        model_texture_types.WGPUTextureFormat_RGBA8UnormSrgb,
        model_texture_types.WGPUTextureFormat_RGBA8Snorm,
        model_texture_types.WGPUTextureFormat_RGBA8Uint,
        model_texture_types.WGPUTextureFormat_RGBA8Sint,
        model_texture_types.WGPUTextureFormat_BGRA8Unorm,
        model_texture_types.WGPUTextureFormat_BGRA8UnormSrgb,
        model_texture_types.WGPUTextureFormat_Depth32Float,
        => 4,
        else => null,
    };
}

pub fn inferTextureDimensionFromViewDimension(value: u32) abi_base.WGPUTextureDimension {
    const view_dim = normalizeTextureViewDimension(value);
    return switch (view_dim) {
        abi_base.WGPUTextureViewDimension_Undefined => abi_base.WGPUTextureDimension_Undefined,
        abi_base.WGPUTextureViewDimension_1D => abi_base.WGPUTextureDimension_1D,
        abi_base.WGPUTextureViewDimension_3D => abi_base.WGPUTextureDimension_3D,
        else => abi_base.WGPUTextureDimension_2D,
    };
}

pub fn normalizeTextureViewAspect(value: u32) abi_base.WGPUTextureAspect {
    return switch (value) {
        model_texture_types.WGPUTextureAspect_DepthOnly => abi_base.WGPUTextureAspect_DepthOnly,
        model_texture_types.WGPUTextureAspect_StencilOnly => abi_base.WGPUTextureAspect_StencilOnly,
        else => abi_base.WGPUTextureAspect_All,
    };
}

pub fn normalizeTextureBytesPerRow(format: abi_base.WGPUTextureFormat, width: u32, explicit_bytes_per_row: u32) u32 {
    if (explicit_bytes_per_row != 0) return explicit_bytes_per_row;
    const bytes_per_pixel = textureFormatBytesPerPixel(format) orelse return 0;
    return width * bytes_per_pixel;
}

pub fn normalizeTextureRowsPerImage(height: u32, explicit_rows_per_image: u32) u32 {
    if (explicit_rows_per_image != 0) return explicit_rows_per_image;
    return height;
}

const std = @import("std");

test "normalizeBufferBindingType maps Uniform correctly" {
    try std.testing.expectEqual(abi_base.WGPUBufferBindingType_Uniform, normalizeBufferBindingType(model_binding_types.WGPUBufferBindingType_Uniform));
}

test "normalizeBufferBindingType maps Storage correctly" {
    try std.testing.expectEqual(abi_base.WGPUBufferBindingType_Storage, normalizeBufferBindingType(model_binding_types.WGPUBufferBindingType_Storage));
}

test "normalizeBufferBindingType maps ReadOnlyStorage correctly" {
    try std.testing.expectEqual(abi_base.WGPUBufferBindingType_ReadOnlyStorage, normalizeBufferBindingType(model_binding_types.WGPUBufferBindingType_ReadOnlyStorage));
}

test "normalizeBufferBindingType returns Undefined for unknown value" {
    try std.testing.expectEqual(abi_base.WGPUBufferBindingType_Undefined, normalizeBufferBindingType(0xDEAD));
}

test "normalizeTextureSampleType maps Float correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureSampleType_Float, normalizeTextureSampleType(model_binding_types.WGPUTextureSampleType_Float));
}

test "normalizeTextureSampleType maps UnfilterableFloat correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureSampleType_UnfilterableFloat, normalizeTextureSampleType(model_binding_types.WGPUTextureSampleType_UnfilterableFloat));
}

test "normalizeTextureSampleType maps Depth correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureSampleType_Depth, normalizeTextureSampleType(model_binding_types.WGPUTextureSampleType_Depth));
}

test "normalizeTextureSampleType maps Sint correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureSampleType_Sint, normalizeTextureSampleType(model_binding_types.WGPUTextureSampleType_Sint));
}

test "normalizeTextureSampleType maps Uint correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureSampleType_Uint, normalizeTextureSampleType(model_binding_types.WGPUTextureSampleType_Uint));
}

test "normalizeTextureSampleType defaults to Float for unknown value" {
    try std.testing.expectEqual(abi_base.WGPUTextureSampleType_Float, normalizeTextureSampleType(0xDEAD));
}

test "normalizeTextureViewDimension maps 1D correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureViewDimension_1D, normalizeTextureViewDimension(model_texture_types.WGPUTextureViewDimension_1D));
}

test "normalizeTextureViewDimension maps 2D correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureViewDimension_2D, normalizeTextureViewDimension(model_texture_types.WGPUTextureViewDimension_2D));
}

test "normalizeTextureViewDimension maps 2DArray correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureViewDimension_2DArray, normalizeTextureViewDimension(model_texture_types.WGPUTextureViewDimension_2DArray));
}

test "normalizeTextureViewDimension maps Cube correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureViewDimension_Cube, normalizeTextureViewDimension(model_texture_types.WGPUTextureViewDimension_Cube));
}

test "normalizeTextureViewDimension maps CubeArray correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureViewDimension_CubeArray, normalizeTextureViewDimension(model_texture_types.WGPUTextureViewDimension_CubeArray));
}

test "normalizeTextureViewDimension maps 3D correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureViewDimension_3D, normalizeTextureViewDimension(model_texture_types.WGPUTextureViewDimension_3D));
}

test "normalizeTextureViewDimension defaults to 2D for unknown value" {
    try std.testing.expectEqual(abi_base.WGPUTextureViewDimension_2D, normalizeTextureViewDimension(0xDEAD));
}

test "normalizeStorageTextureAccess maps WriteOnly correctly" {
    try std.testing.expectEqual(abi_base.WGPUStorageTextureAccess_WriteOnly, normalizeStorageTextureAccess(model_binding_types.WGPUStorageTextureAccess_WriteOnly));
}

test "normalizeStorageTextureAccess maps ReadOnly correctly" {
    try std.testing.expectEqual(abi_base.WGPUStorageTextureAccess_ReadOnly, normalizeStorageTextureAccess(model_binding_types.WGPUStorageTextureAccess_ReadOnly));
}

test "normalizeStorageTextureAccess maps ReadWrite correctly" {
    try std.testing.expectEqual(abi_base.WGPUStorageTextureAccess_ReadWrite, normalizeStorageTextureAccess(model_binding_types.WGPUStorageTextureAccess_ReadWrite));
}

test "normalizeStorageTextureAccess defaults to WriteOnly for unknown value" {
    try std.testing.expectEqual(abi_base.WGPUStorageTextureAccess_WriteOnly, normalizeStorageTextureAccess(0xDEAD));
}

test "normalizeTextureFormat maps R8Unorm correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureFormat_R8Unorm, normalizeTextureFormat(model_texture_types.WGPUTextureFormat_R8Unorm));
}

test "normalizeTextureFormat maps RGBA8Unorm correctly" {
    try std.testing.expectEqual(model_texture_types.WGPUTextureFormat_RGBA8Unorm, normalizeTextureFormat(model_texture_types.WGPUTextureFormat_RGBA8Unorm));
}

test "normalizeTextureFormat maps Depth32Float correctly" {
    try std.testing.expectEqual(model_texture_types.WGPUTextureFormat_Depth32Float, normalizeTextureFormat(model_texture_types.WGPUTextureFormat_Depth32Float));
}

test "normalizeTextureFormat returns Undefined for unknown value" {
    try std.testing.expectEqual(abi_base.WGPUTextureFormat_Undefined, normalizeTextureFormat(0xDEAD));
}

test "textureFormatBytesPerPixel returns 1 for R8Unorm" {
    try std.testing.expectEqual(@as(?u32, 1), textureFormatBytesPerPixel(abi_base.WGPUTextureFormat_R8Unorm));
}

test "textureFormatBytesPerPixel returns 2 for RG8Unorm" {
    try std.testing.expectEqual(@as(?u32, 2), textureFormatBytesPerPixel(model_texture_types.WGPUTextureFormat_RG8Unorm));
}

test "textureFormatBytesPerPixel returns 4 for RGBA8Unorm" {
    try std.testing.expectEqual(@as(?u32, 4), textureFormatBytesPerPixel(model_texture_types.WGPUTextureFormat_RGBA8Unorm));
}

test "textureFormatBytesPerPixel returns null for unknown format" {
    try std.testing.expectEqual(@as(?u32, null), textureFormatBytesPerPixel(0xDEAD));
}

test "inferTextureDimensionFromViewDimension maps 1D to 1D" {
    try std.testing.expectEqual(abi_base.WGPUTextureDimension_1D, inferTextureDimensionFromViewDimension(model_texture_types.WGPUTextureViewDimension_1D));
}

test "inferTextureDimensionFromViewDimension maps 2D to 2D" {
    try std.testing.expectEqual(abi_base.WGPUTextureDimension_2D, inferTextureDimensionFromViewDimension(model_texture_types.WGPUTextureViewDimension_2D));
}

test "inferTextureDimensionFromViewDimension maps 3D to 3D" {
    try std.testing.expectEqual(abi_base.WGPUTextureDimension_3D, inferTextureDimensionFromViewDimension(model_texture_types.WGPUTextureViewDimension_3D));
}

test "inferTextureDimensionFromViewDimension maps Cube to 2D" {
    try std.testing.expectEqual(abi_base.WGPUTextureDimension_2D, inferTextureDimensionFromViewDimension(model_texture_types.WGPUTextureViewDimension_Cube));
}

test "normalizeTextureViewAspect maps DepthOnly correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureAspect_DepthOnly, normalizeTextureViewAspect(model_texture_types.WGPUTextureAspect_DepthOnly));
}

test "normalizeTextureViewAspect maps StencilOnly correctly" {
    try std.testing.expectEqual(abi_base.WGPUTextureAspect_StencilOnly, normalizeTextureViewAspect(model_texture_types.WGPUTextureAspect_StencilOnly));
}

test "normalizeTextureViewAspect defaults to All for unknown value" {
    try std.testing.expectEqual(abi_base.WGPUTextureAspect_All, normalizeTextureViewAspect(0xDEAD));
}

test "normalizeTextureBytesPerRow uses explicit value when nonzero" {
    try std.testing.expectEqual(@as(u32, 256), normalizeTextureBytesPerRow(abi_base.WGPUTextureFormat_R8Unorm, 64, 256));
}

test "normalizeTextureBytesPerRow infers from format and width when zero" {
    // R8Unorm = 1 byte per pixel, width = 64, so expected = 64
    try std.testing.expectEqual(@as(u32, 64), normalizeTextureBytesPerRow(abi_base.WGPUTextureFormat_R8Unorm, 64, 0));
}

test "normalizeTextureBytesPerRow returns zero for unknown format when explicit is zero" {
    try std.testing.expectEqual(@as(u32, 0), normalizeTextureBytesPerRow(0xDEAD, 64, 0));
}

test "normalizeTextureRowsPerImage uses explicit value when nonzero" {
    try std.testing.expectEqual(@as(u32, 128), normalizeTextureRowsPerImage(64, 128));
}

test "normalizeTextureRowsPerImage returns height when explicit is zero" {
    try std.testing.expectEqual(@as(u32, 64), normalizeTextureRowsPerImage(64, 0));
}
