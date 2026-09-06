const vertex_formats = @import("../../contracts/vertex_format.zig");
// WebGPU-to-DXGI format translation.
//
// Maps WGPUTextureFormat values to DXGI_FORMAT constants and provides
// per-format metadata (bytes per pixel, depth/stencil classification).
// Also maps WebGPU vertex format enum values to DXGI_FORMAT for vertex input.
// Mirrors the structure of vk_formats.zig for the D3D12 backend.

const std = @import("std");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const compressed_formats = @import("../../contracts/texture_format.zig");
const testing = std.testing;

// --- DXGI_FORMAT constants (Microsoft DXGI 1.0+ spec values) ---

// 4-channel 32-bit
pub const DXGI_FORMAT_R32G32B32A32_FLOAT: u32 = 2;
pub const DXGI_FORMAT_R32G32B32A32_UINT: u32 = 3;
pub const DXGI_FORMAT_R32G32B32A32_SINT: u32 = 4;

// 3-channel 32-bit (vertex-only; not valid for render targets or textures)
pub const DXGI_FORMAT_R32G32B32_FLOAT: u32 = 6;
pub const DXGI_FORMAT_R32G32B32_UINT: u32 = 7;
pub const DXGI_FORMAT_R32G32B32_SINT: u32 = 8;

// 4-channel 16-bit
pub const DXGI_FORMAT_R16G16B16A16_FLOAT: u32 = 10;
pub const DXGI_FORMAT_R16G16B16A16_UNORM: u32 = 11;
pub const DXGI_FORMAT_R16G16B16A16_UINT: u32 = 12;
pub const DXGI_FORMAT_R16G16B16A16_SNORM: u32 = 13;
pub const DXGI_FORMAT_R16G16B16A16_SINT: u32 = 14;

// 2-channel 32-bit
pub const DXGI_FORMAT_R32G32_FLOAT: u32 = 16;
pub const DXGI_FORMAT_R32G32_UINT: u32 = 17;
pub const DXGI_FORMAT_R32G32_SINT: u32 = 18;

// Depth 32 + stencil 8
pub const DXGI_FORMAT_D32_FLOAT_S8X24_UINT: u32 = 20;

// Packed 10/10/10/2
pub const DXGI_FORMAT_R10G10B10A2_UNORM: u32 = 24;
pub const DXGI_FORMAT_R10G10B10A2_UINT: u32 = 25;

// Packed float
pub const DXGI_FORMAT_R11G11B10_FLOAT: u32 = 26;

// 4-channel 8-bit
pub const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 28;
pub const DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: u32 = 29;
pub const DXGI_FORMAT_R8G8B8A8_UINT: u32 = 30;
pub const DXGI_FORMAT_R8G8B8A8_SNORM: u32 = 31;
pub const DXGI_FORMAT_R8G8B8A8_SINT: u32 = 32;

// 2-channel 16-bit
pub const DXGI_FORMAT_R16G16_FLOAT: u32 = 34;
pub const DXGI_FORMAT_R16G16_UNORM: u32 = 35;
pub const DXGI_FORMAT_R16G16_UINT: u32 = 36;
pub const DXGI_FORMAT_R16G16_SNORM: u32 = 37;
pub const DXGI_FORMAT_R16G16_SINT: u32 = 38;

// Depth 32
pub const DXGI_FORMAT_D32_FLOAT: u32 = 40;

// 1-channel 32-bit
pub const DXGI_FORMAT_R32_FLOAT: u32 = 41;
pub const DXGI_FORMAT_R32_UINT: u32 = 42;
pub const DXGI_FORMAT_R32_SINT: u32 = 43;

// Depth 24 + stencil 8
pub const DXGI_FORMAT_D24_UNORM_S8_UINT: u32 = 45;

// 2-channel 8-bit
pub const DXGI_FORMAT_R8G8_UNORM: u32 = 49;
pub const DXGI_FORMAT_R8G8_UINT: u32 = 50;
pub const DXGI_FORMAT_R8G8_SNORM: u32 = 51;
pub const DXGI_FORMAT_R8G8_SINT: u32 = 52;

// 1-channel 16-bit. Canonical dxgiformat.h order is FLOAT=54, D16=55, UNORM=56,
// UINT=57, SNORM=58, SINT=59 — previously transcribed with UINT and SNORM
// swapped. Latent for the compute-only cohort but any render/texture path
// that binds an R16Snorm surface would have produced the wrong DXGI format.
pub const DXGI_FORMAT_R16_FLOAT: u32 = 54;
pub const DXGI_FORMAT_D16_UNORM: u32 = 55;
pub const DXGI_FORMAT_R16_UNORM: u32 = 56;
pub const DXGI_FORMAT_R16_UINT: u32 = 57;
pub const DXGI_FORMAT_R16_SNORM: u32 = 58;
pub const DXGI_FORMAT_R16_SINT: u32 = 59;

// 1-channel 8-bit. Canonical dxgiformat.h order is UNORM=61, UINT=62,
// SNORM=63, SINT=64 — previously transcribed with UINT and SNORM swapped.
// Same latency class as the R16 swap above.
pub const DXGI_FORMAT_R8_UNORM: u32 = 61;
pub const DXGI_FORMAT_R8_UINT: u32 = 62;
pub const DXGI_FORMAT_R8_SNORM: u32 = 63;
pub const DXGI_FORMAT_R8_SINT: u32 = 64;

// Shared exponent
pub const DXGI_FORMAT_R9G9B9E5_SHAREDEXP: u32 = 67;

// BC compressed formats
pub const DXGI_FORMAT_BC1_UNORM: u32 = 71;
pub const DXGI_FORMAT_BC1_UNORM_SRGB: u32 = 72;
pub const DXGI_FORMAT_BC2_UNORM: u32 = 74;
pub const DXGI_FORMAT_BC2_UNORM_SRGB: u32 = 75;
pub const DXGI_FORMAT_BC3_UNORM: u32 = 77;
pub const DXGI_FORMAT_BC3_UNORM_SRGB: u32 = 78;
pub const DXGI_FORMAT_BC4_UNORM: u32 = 80;
pub const DXGI_FORMAT_BC4_SNORM: u32 = 81;
pub const DXGI_FORMAT_BC5_UNORM: u32 = 83;
pub const DXGI_FORMAT_BC5_SNORM: u32 = 84;

// BGRA 8-bit
pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
pub const DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: u32 = 91;

// BC6H / BC7 compressed formats
pub const DXGI_FORMAT_BC6H_UF16: u32 = 95;
pub const DXGI_FORMAT_BC6H_SF16: u32 = 96;
pub const DXGI_FORMAT_BC7_UNORM: u32 = 98;
pub const DXGI_FORMAT_BC7_UNORM_SRGB: u32 = 99;

// Stencil-only (DXGI uses the depth-stencil typeless family; D3D12 exposes
// stencil-only views via X24_TYPELESS_G8_UINT = 47, but the closest
// standalone format for an 8-bit stencil surface is the D24+S8 layout).
pub const DXGI_FORMAT_D24_X8_STENCIL8: u32 = 45; // same resource, stencil-only view

// --- Format translation ---

pub fn wgpu_format_to_dxgi(format: model_gpu_types.WGPUTextureFormat) !u32 {
    return switch (format) {
        // 1-channel 8-bit
        model_gpu_types.WGPUTextureFormat_R8Unorm => DXGI_FORMAT_R8_UNORM,
        model_gpu_types.WGPUTextureFormat_R8Snorm => DXGI_FORMAT_R8_SNORM,
        model_gpu_types.WGPUTextureFormat_R8Uint => DXGI_FORMAT_R8_UINT,
        model_gpu_types.WGPUTextureFormat_R8Sint => DXGI_FORMAT_R8_SINT,

        // 2-channel 8-bit
        model_gpu_types.WGPUTextureFormat_RG8Unorm => DXGI_FORMAT_R8G8_UNORM,
        model_gpu_types.WGPUTextureFormat_RG8Snorm => DXGI_FORMAT_R8G8_SNORM,
        model_gpu_types.WGPUTextureFormat_RG8Uint => DXGI_FORMAT_R8G8_UINT,
        model_gpu_types.WGPUTextureFormat_RG8Sint => DXGI_FORMAT_R8G8_SINT,

        // 4-channel 8-bit
        model_gpu_types.WGPUTextureFormat_RGBA8Unorm => DXGI_FORMAT_R8G8B8A8_UNORM,
        model_gpu_types.WGPUTextureFormat_RGBA8UnormSrgb => DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        model_gpu_types.WGPUTextureFormat_RGBA8Snorm => DXGI_FORMAT_R8G8B8A8_SNORM,
        model_gpu_types.WGPUTextureFormat_RGBA8Uint => DXGI_FORMAT_R8G8B8A8_UINT,
        model_gpu_types.WGPUTextureFormat_RGBA8Sint => DXGI_FORMAT_R8G8B8A8_SINT,
        model_gpu_types.WGPUTextureFormat_BGRA8Unorm => DXGI_FORMAT_B8G8R8A8_UNORM,
        model_gpu_types.WGPUTextureFormat_BGRA8UnormSrgb => DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,

        // 4-channel 16-bit
        model_gpu_types.WGPUTextureFormat_RGBA16Unorm => DXGI_FORMAT_R16G16B16A16_UNORM,
        model_gpu_types.WGPUTextureFormat_RGBA16Snorm => DXGI_FORMAT_R16G16B16A16_SNORM,

        // Packed 32-bit color
        model_gpu_types.WGPUTextureFormat_RGB10A2Uint => DXGI_FORMAT_R10G10B10A2_UINT,
        model_gpu_types.WGPUTextureFormat_RGB10A2Unorm => DXGI_FORMAT_R10G10B10A2_UNORM,
        model_gpu_types.WGPUTextureFormat_RG11B10Ufloat => DXGI_FORMAT_R11G11B10_FLOAT,
        model_gpu_types.WGPUTextureFormat_RGB9E5Ufloat => DXGI_FORMAT_R9G9B9E5_SHAREDEXP,

        // 1-channel 16-bit
        model_gpu_types.WGPUTextureFormat_R16Unorm => DXGI_FORMAT_R16_UNORM,
        model_gpu_types.WGPUTextureFormat_R16Snorm => DXGI_FORMAT_R16_SNORM,
        model_gpu_types.WGPUTextureFormat_R16Uint => DXGI_FORMAT_R16_UINT,
        model_gpu_types.WGPUTextureFormat_R16Sint => DXGI_FORMAT_R16_SINT,
        model_gpu_types.WGPUTextureFormat_R16Float => DXGI_FORMAT_R16_FLOAT,

        // 2-channel 16-bit
        model_gpu_types.WGPUTextureFormat_RG16Unorm => DXGI_FORMAT_R16G16_UNORM,
        model_gpu_types.WGPUTextureFormat_RG16Snorm => DXGI_FORMAT_R16G16_SNORM,
        model_gpu_types.WGPUTextureFormat_RG16Uint => DXGI_FORMAT_R16G16_UINT,
        model_gpu_types.WGPUTextureFormat_RG16Sint => DXGI_FORMAT_R16G16_SINT,
        model_gpu_types.WGPUTextureFormat_RG16Float => DXGI_FORMAT_R16G16_FLOAT,

        // 4-channel 16-bit
        model_gpu_types.WGPUTextureFormat_RGBA16Uint => DXGI_FORMAT_R16G16B16A16_UINT,
        model_gpu_types.WGPUTextureFormat_RGBA16Sint => DXGI_FORMAT_R16G16B16A16_SINT,
        model_gpu_types.WGPUTextureFormat_RGBA16Float => DXGI_FORMAT_R16G16B16A16_FLOAT,

        // 1-channel 32-bit
        model_gpu_types.WGPUTextureFormat_R32Uint => DXGI_FORMAT_R32_UINT,
        model_gpu_types.WGPUTextureFormat_R32Sint => DXGI_FORMAT_R32_SINT,
        model_gpu_types.WGPUTextureFormat_R32Float => DXGI_FORMAT_R32_FLOAT,

        // 2-channel 32-bit
        model_gpu_types.WGPUTextureFormat_RG32Uint => DXGI_FORMAT_R32G32_UINT,
        model_gpu_types.WGPUTextureFormat_RG32Sint => DXGI_FORMAT_R32G32_SINT,
        model_gpu_types.WGPUTextureFormat_RG32Float => DXGI_FORMAT_R32G32_FLOAT,

        // 4-channel 32-bit
        model_gpu_types.WGPUTextureFormat_RGBA32Uint => DXGI_FORMAT_R32G32B32A32_UINT,
        model_gpu_types.WGPUTextureFormat_RGBA32Sint => DXGI_FORMAT_R32G32B32A32_SINT,
        model_gpu_types.WGPUTextureFormat_RGBA32Float => DXGI_FORMAT_R32G32B32A32_FLOAT,

        // Depth/stencil
        model_gpu_types.WGPUTextureFormat_Depth16Unorm => DXGI_FORMAT_D16_UNORM,
        model_gpu_types.WGPUTextureFormat_Depth32Float => DXGI_FORMAT_D32_FLOAT,
        model_gpu_types.WGPUTextureFormat_Stencil8 => DXGI_FORMAT_D24_X8_STENCIL8,
        model_gpu_types.WGPUTextureFormat_Depth24Plus,
        model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8,
        => DXGI_FORMAT_D24_UNORM_S8_UINT,
        model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8 => DXGI_FORMAT_D32_FLOAT_S8X24_UINT,

        // BC compressed formats
        compressed_formats.WGPUTextureFormat_BC1RGBAUnorm => DXGI_FORMAT_BC1_UNORM,
        compressed_formats.WGPUTextureFormat_BC1RGBAUnormSrgb => DXGI_FORMAT_BC1_UNORM_SRGB,
        compressed_formats.WGPUTextureFormat_BC2RGBAUnorm => DXGI_FORMAT_BC2_UNORM,
        compressed_formats.WGPUTextureFormat_BC2RGBAUnormSrgb => DXGI_FORMAT_BC2_UNORM_SRGB,
        compressed_formats.WGPUTextureFormat_BC3RGBAUnorm => DXGI_FORMAT_BC3_UNORM,
        compressed_formats.WGPUTextureFormat_BC3RGBAUnormSrgb => DXGI_FORMAT_BC3_UNORM_SRGB,
        compressed_formats.WGPUTextureFormat_BC4RUnorm => DXGI_FORMAT_BC4_UNORM,
        compressed_formats.WGPUTextureFormat_BC4RSnorm => DXGI_FORMAT_BC4_SNORM,
        compressed_formats.WGPUTextureFormat_BC5RGUnorm => DXGI_FORMAT_BC5_UNORM,
        compressed_formats.WGPUTextureFormat_BC5RGSnorm => DXGI_FORMAT_BC5_SNORM,
        compressed_formats.WGPUTextureFormat_BC6HRGBUfloat => DXGI_FORMAT_BC6H_UF16,
        compressed_formats.WGPUTextureFormat_BC6HRGBFloat => DXGI_FORMAT_BC6H_SF16,
        compressed_formats.WGPUTextureFormat_BC7RGBAUnorm => DXGI_FORMAT_BC7_UNORM,
        compressed_formats.WGPUTextureFormat_BC7RGBAUnormSrgb => DXGI_FORMAT_BC7_UNORM_SRGB,

        // ETC2/EAC and ASTC formats have no DXGI equivalent; D3D12 does not
        // support these families. They fall through to UnsupportedFeature
        // intentionally rather than being hidden in the catch-all else.
        else => error.UnsupportedFeature,
    };
}

/// Returns the number of bytes per pixel for a given WebGPU texture format.
/// Depth/stencil formats return the total byte footprint per texel.
/// Compressed (BC) formats return the block byte size (per 4x4 block).
pub fn bytes_per_pixel(format: model_gpu_types.WGPUTextureFormat) !u32 {
    return switch (format) {
        // 1 byte per pixel
        model_gpu_types.WGPUTextureFormat_R8Unorm,
        model_gpu_types.WGPUTextureFormat_R8Snorm,
        model_gpu_types.WGPUTextureFormat_R8Uint,
        model_gpu_types.WGPUTextureFormat_R8Sint,
        model_gpu_types.WGPUTextureFormat_Stencil8,
        => 1,

        // 2 bytes per pixel
        model_gpu_types.WGPUTextureFormat_R16Unorm,
        model_gpu_types.WGPUTextureFormat_R16Snorm,
        model_gpu_types.WGPUTextureFormat_R16Uint,
        model_gpu_types.WGPUTextureFormat_R16Sint,
        model_gpu_types.WGPUTextureFormat_R16Float,
        model_gpu_types.WGPUTextureFormat_RG8Unorm,
        model_gpu_types.WGPUTextureFormat_RG8Snorm,
        model_gpu_types.WGPUTextureFormat_RG8Uint,
        model_gpu_types.WGPUTextureFormat_RG8Sint,
        model_gpu_types.WGPUTextureFormat_Depth16Unorm,
        => 2,

        // 4 bytes per pixel
        model_gpu_types.WGPUTextureFormat_RGBA8Unorm,
        model_gpu_types.WGPUTextureFormat_RGBA8UnormSrgb,
        model_gpu_types.WGPUTextureFormat_RGBA8Snorm,
        model_gpu_types.WGPUTextureFormat_RGBA8Uint,
        model_gpu_types.WGPUTextureFormat_RGBA8Sint,
        model_gpu_types.WGPUTextureFormat_BGRA8Unorm,
        model_gpu_types.WGPUTextureFormat_BGRA8UnormSrgb,
        model_gpu_types.WGPUTextureFormat_RGBA16Unorm,
        model_gpu_types.WGPUTextureFormat_RGBA16Snorm,
        model_gpu_types.WGPUTextureFormat_RGB10A2Uint,
        model_gpu_types.WGPUTextureFormat_RGB10A2Unorm,
        model_gpu_types.WGPUTextureFormat_RG11B10Ufloat,
        model_gpu_types.WGPUTextureFormat_RGB9E5Ufloat,
        model_gpu_types.WGPUTextureFormat_RG16Unorm,
        model_gpu_types.WGPUTextureFormat_RG16Snorm,
        model_gpu_types.WGPUTextureFormat_RG16Uint,
        model_gpu_types.WGPUTextureFormat_RG16Sint,
        model_gpu_types.WGPUTextureFormat_RG16Float,
        model_gpu_types.WGPUTextureFormat_R32Uint,
        model_gpu_types.WGPUTextureFormat_R32Sint,
        model_gpu_types.WGPUTextureFormat_R32Float,
        model_gpu_types.WGPUTextureFormat_Depth32Float,
        model_gpu_types.WGPUTextureFormat_Depth24Plus,
        model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8,
        => 4,

        // 8 bytes per pixel
        model_gpu_types.WGPUTextureFormat_RGBA16Uint,
        model_gpu_types.WGPUTextureFormat_RGBA16Sint,
        model_gpu_types.WGPUTextureFormat_RGBA16Float,
        model_gpu_types.WGPUTextureFormat_RG32Uint,
        model_gpu_types.WGPUTextureFormat_RG32Sint,
        model_gpu_types.WGPUTextureFormat_RG32Float,
        model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8,
        => 8,

        // 16 bytes per pixel
        model_gpu_types.WGPUTextureFormat_RGBA32Uint,
        model_gpu_types.WGPUTextureFormat_RGBA32Sint,
        model_gpu_types.WGPUTextureFormat_RGBA32Float,
        => 16,

        // BC compressed: bytes per 4x4 block
        // BC1/BC4: 8 bytes per block
        compressed_formats.WGPUTextureFormat_BC1RGBAUnorm,
        compressed_formats.WGPUTextureFormat_BC1RGBAUnormSrgb,
        compressed_formats.WGPUTextureFormat_BC4RUnorm,
        compressed_formats.WGPUTextureFormat_BC4RSnorm,
        => 8,

        // BC2/BC3/BC5/BC6H/BC7: 16 bytes per block
        compressed_formats.WGPUTextureFormat_BC2RGBAUnorm,
        compressed_formats.WGPUTextureFormat_BC2RGBAUnormSrgb,
        compressed_formats.WGPUTextureFormat_BC3RGBAUnorm,
        compressed_formats.WGPUTextureFormat_BC3RGBAUnormSrgb,
        compressed_formats.WGPUTextureFormat_BC5RGUnorm,
        compressed_formats.WGPUTextureFormat_BC5RGSnorm,
        compressed_formats.WGPUTextureFormat_BC6HRGBUfloat,
        compressed_formats.WGPUTextureFormat_BC6HRGBFloat,
        compressed_formats.WGPUTextureFormat_BC7RGBAUnorm,
        compressed_formats.WGPUTextureFormat_BC7RGBAUnormSrgb,
        => 16,

        else => error.UnsupportedFeature,
    };
}

/// Returns true if the format is a depth or depth-stencil format.
pub fn is_depth_stencil(format: model_gpu_types.WGPUTextureFormat) bool {
    return switch (format) {
        model_gpu_types.WGPUTextureFormat_Depth16Unorm,
        model_gpu_types.WGPUTextureFormat_Depth24Plus,
        model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8,
        model_gpu_types.WGPUTextureFormat_Depth32Float,
        model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8,
        model_gpu_types.WGPUTextureFormat_Stencil8,
        => true,
        else => false,
    };
}

/// Returns true when the format carries a stencil channel.
pub fn has_stencil(format: model_gpu_types.WGPUTextureFormat) bool {
    return switch (format) {
        model_gpu_types.WGPUTextureFormat_Stencil8,
        model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8,
        model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8,
        => true,
        else => false,
    };
}

/// Returns true when the format is a BC block-compressed format.
pub fn is_bc_compressed(format: model_gpu_types.WGPUTextureFormat) bool {
    return compressed_formats.isBCFormat(format);
}

/// Returns true when the format is an ETC2 or EAC compressed format.
/// DXGI has no native ETC2/EAC support; D3D12 reports supports_etc2 = false.
pub fn is_etc2_compressed(format: model_gpu_types.WGPUTextureFormat) bool {
    return compressed_formats.isETC2Format(format);
}

/// Returns true when the format is an ASTC compressed format.
/// DXGI has no native ASTC support; D3D12 reports supports_astc = false.
pub fn is_astc_compressed(format: model_gpu_types.WGPUTextureFormat) bool {
    return compressed_formats.isASTCFormat(format);
}

/// Returns true when the format is any block-compressed format (BC, ETC2/EAC, or ASTC).
pub fn is_any_compressed(format: model_gpu_types.WGPUTextureFormat) bool {
    return is_bc_compressed(format) or is_etc2_compressed(format) or is_astc_compressed(format);
}

// --- Vertex format translation ---
//
// Vertex identities come from the shared contract; Vulkan format conversion stays local.

pub fn wgpu_vertex_format_to_dxgi(format: u32) !u32 {
    return switch (try vertex_formats.fromCode(format)) {
        // 8-bit uint
        .uint8 => DXGI_FORMAT_R8_UINT,
        .uint8x2 => DXGI_FORMAT_R8G8_UINT,
        .uint8x4 => DXGI_FORMAT_R8G8B8A8_UINT,
        // 8-bit sint
        .sint8 => DXGI_FORMAT_R8_SINT,
        .sint8x2 => DXGI_FORMAT_R8G8_SINT,
        .sint8x4 => DXGI_FORMAT_R8G8B8A8_SINT,
        // 8-bit unorm
        .unorm8 => DXGI_FORMAT_R8_UNORM,
        .unorm8x2 => DXGI_FORMAT_R8G8_UNORM,
        .unorm8x4 => DXGI_FORMAT_R8G8B8A8_UNORM,
        // 8-bit snorm
        .snorm8 => DXGI_FORMAT_R8_SNORM,
        .snorm8x2 => DXGI_FORMAT_R8G8_SNORM,
        .snorm8x4 => DXGI_FORMAT_R8G8B8A8_SNORM,
        // 16-bit uint
        .uint16 => DXGI_FORMAT_R16_UINT,
        .uint16x2 => DXGI_FORMAT_R16G16_UINT,
        .uint16x4 => DXGI_FORMAT_R16G16B16A16_UINT,
        // 16-bit sint
        .sint16 => DXGI_FORMAT_R16_SINT,
        .sint16x2 => DXGI_FORMAT_R16G16_SINT,
        .sint16x4 => DXGI_FORMAT_R16G16B16A16_SINT,
        // 16-bit unorm
        .unorm16 => DXGI_FORMAT_R16_UNORM,
        .unorm16x2 => DXGI_FORMAT_R16G16_UNORM,
        .unorm16x4 => DXGI_FORMAT_R16G16B16A16_UNORM,
        // 16-bit snorm
        .snorm16 => DXGI_FORMAT_R16_SNORM,
        .snorm16x2 => DXGI_FORMAT_R16G16_SNORM,
        .snorm16x4 => DXGI_FORMAT_R16G16B16A16_SNORM,
        // 32-bit float
        .float32 => DXGI_FORMAT_R32_FLOAT,
        .float32x2 => DXGI_FORMAT_R32G32_FLOAT,
        .float32x3 => DXGI_FORMAT_R32G32B32_FLOAT,
        .float32x4 => DXGI_FORMAT_R32G32B32A32_FLOAT,
        // 16-bit float
        .float16 => DXGI_FORMAT_R16_FLOAT,
        .float16x2 => DXGI_FORMAT_R16G16_FLOAT,
        .float16x4 => DXGI_FORMAT_R16G16B16A16_FLOAT,
        // 32-bit uint
        .uint32 => DXGI_FORMAT_R32_UINT,
        .uint32x2 => DXGI_FORMAT_R32G32_UINT,
        .uint32x3 => DXGI_FORMAT_R32G32B32_UINT,
        .uint32x4 => DXGI_FORMAT_R32G32B32A32_UINT,
        // 32-bit sint
        .sint32 => DXGI_FORMAT_R32_SINT,
        .sint32x2 => DXGI_FORMAT_R32G32_SINT,
        .sint32x3 => DXGI_FORMAT_R32G32B32_SINT,
        .sint32x4 => DXGI_FORMAT_R32G32B32A32_SINT,
        // Packed
        .unorm10_10_10_2 => DXGI_FORMAT_R10G10B10A2_UNORM,
        .unorm8x4_bgra => DXGI_FORMAT_B8G8R8A8_UNORM,
    };
}

// --- Tests ---

test "wgpu_format_to_dxgi maps basic color formats" {
    try testing.expectEqual(DXGI_FORMAT_R8_UNORM, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_R8Unorm));
    try testing.expectEqual(DXGI_FORMAT_R8G8B8A8_UNORM, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_RGBA8Unorm));
    try testing.expectEqual(DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_RGBA8UnormSrgb));
    try testing.expectEqual(DXGI_FORMAT_B8G8R8A8_UNORM, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_BGRA8Unorm));
    try testing.expectEqual(DXGI_FORMAT_B8G8R8A8_UNORM_SRGB, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_BGRA8UnormSrgb));
    try testing.expectEqual(DXGI_FORMAT_R32_FLOAT, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_R32Float));
    try testing.expectEqual(DXGI_FORMAT_R16G16_UNORM, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_RG16Unorm));
    try testing.expectEqual(DXGI_FORMAT_R32G32B32A32_FLOAT, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_RGBA32Float));
}

test "wgpu_format_to_dxgi maps packed formats" {
    try testing.expectEqual(DXGI_FORMAT_R10G10B10A2_UNORM, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_RGB10A2Unorm));
    try testing.expectEqual(DXGI_FORMAT_R10G10B10A2_UINT, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_RGB10A2Uint));
    try testing.expectEqual(DXGI_FORMAT_R11G11B10_FLOAT, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_RG11B10Ufloat));
    try testing.expectEqual(DXGI_FORMAT_R9G9B9E5_SHAREDEXP, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_RGB9E5Ufloat));
}

test "wgpu_format_to_dxgi maps depth/stencil formats" {
    try testing.expectEqual(DXGI_FORMAT_D16_UNORM, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_Depth16Unorm));
    try testing.expectEqual(DXGI_FORMAT_D32_FLOAT, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_Depth32Float));
    try testing.expectEqual(DXGI_FORMAT_D24_UNORM_S8_UINT, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_Depth24Plus));
    try testing.expectEqual(DXGI_FORMAT_D24_UNORM_S8_UINT, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8));
    try testing.expectEqual(DXGI_FORMAT_D32_FLOAT_S8X24_UINT, try wgpu_format_to_dxgi(model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8));
}

test "wgpu_format_to_dxgi maps BC compressed formats" {
    try testing.expectEqual(DXGI_FORMAT_BC1_UNORM, try wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC1RGBAUnorm));
    try testing.expectEqual(DXGI_FORMAT_BC7_UNORM_SRGB, try wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC7RGBAUnormSrgb));
    try testing.expectEqual(DXGI_FORMAT_BC6H_UF16, try wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_BC6HRGBUfloat));
}

test "wgpu_format_to_dxgi returns error for unsupported format" {
    try testing.expectError(error.UnsupportedFeature, wgpu_format_to_dxgi(0xFFFF));
}

test "bytes_per_pixel returns correct sizes" {
    try testing.expectEqual(@as(u32, 1), try bytes_per_pixel(model_gpu_types.WGPUTextureFormat_R8Unorm));
    try testing.expectEqual(@as(u32, 2), try bytes_per_pixel(model_gpu_types.WGPUTextureFormat_R16Float));
    try testing.expectEqual(@as(u32, 4), try bytes_per_pixel(model_gpu_types.WGPUTextureFormat_RGBA8Unorm));
    try testing.expectEqual(@as(u32, 8), try bytes_per_pixel(model_gpu_types.WGPUTextureFormat_RGBA16Float));
    try testing.expectEqual(@as(u32, 16), try bytes_per_pixel(model_gpu_types.WGPUTextureFormat_RGBA32Float));
}

test "bytes_per_pixel returns block sizes for BC formats" {
    try testing.expectEqual(@as(u32, 8), try bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC1RGBAUnorm));
    try testing.expectEqual(@as(u32, 16), try bytes_per_pixel(compressed_formats.WGPUTextureFormat_BC7RGBAUnorm));
}

test "is_depth_stencil identifies depth formats" {
    try testing.expect(is_depth_stencil(model_gpu_types.WGPUTextureFormat_Depth16Unorm));
    try testing.expect(is_depth_stencil(model_gpu_types.WGPUTextureFormat_Depth24Plus));
    try testing.expect(is_depth_stencil(model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8));
    try testing.expect(!is_depth_stencil(model_gpu_types.WGPUTextureFormat_RGBA8Unorm));
}

test "has_stencil distinguishes stencil formats" {
    try testing.expect(!has_stencil(model_gpu_types.WGPUTextureFormat_Depth16Unorm));
    try testing.expect(has_stencil(model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8));
    try testing.expect(has_stencil(model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8));
    try testing.expect(has_stencil(model_gpu_types.WGPUTextureFormat_Stencil8));
}

test "is_etc2_compressed identifies ETC2/EAC formats" {
    try testing.expect(is_etc2_compressed(compressed_formats.WGPUTextureFormat_ETC2RGB8Unorm));
    try testing.expect(is_etc2_compressed(compressed_formats.WGPUTextureFormat_ETC2RGB8UnormSrgb));
    try testing.expect(is_etc2_compressed(compressed_formats.WGPUTextureFormat_ETC2RGB8A1Unorm));
    try testing.expect(is_etc2_compressed(compressed_formats.WGPUTextureFormat_ETC2RGBA8Unorm));
    try testing.expect(is_etc2_compressed(compressed_formats.WGPUTextureFormat_EACR11Unorm));
    try testing.expect(is_etc2_compressed(compressed_formats.WGPUTextureFormat_EACR11Snorm));
    try testing.expect(is_etc2_compressed(compressed_formats.WGPUTextureFormat_EACRG11Unorm));
    try testing.expect(is_etc2_compressed(compressed_formats.WGPUTextureFormat_EACRG11Snorm));
    try testing.expect(!is_etc2_compressed(model_gpu_types.WGPUTextureFormat_RGBA8Unorm));
    try testing.expect(!is_etc2_compressed(compressed_formats.WGPUTextureFormat_BC1RGBAUnorm));
    try testing.expect(!is_etc2_compressed(compressed_formats.WGPUTextureFormat_ASTC4x4Unorm));
}

test "is_astc_compressed identifies ASTC formats" {
    try testing.expect(is_astc_compressed(compressed_formats.WGPUTextureFormat_ASTC4x4Unorm));
    try testing.expect(is_astc_compressed(compressed_formats.WGPUTextureFormat_ASTC4x4UnormSrgb));
    try testing.expect(is_astc_compressed(compressed_formats.WGPUTextureFormat_ASTC8x8Unorm));
    try testing.expect(is_astc_compressed(compressed_formats.WGPUTextureFormat_ASTC10x10UnormSrgb));
    try testing.expect(is_astc_compressed(compressed_formats.WGPUTextureFormat_ASTC12x12Unorm));
    try testing.expect(is_astc_compressed(compressed_formats.WGPUTextureFormat_ASTC12x12UnormSrgb));
    try testing.expect(!is_astc_compressed(model_gpu_types.WGPUTextureFormat_RGBA8Unorm));
    try testing.expect(!is_astc_compressed(compressed_formats.WGPUTextureFormat_BC7RGBAUnorm));
    try testing.expect(!is_astc_compressed(compressed_formats.WGPUTextureFormat_ETC2RGB8Unorm));
}

test "is_any_compressed covers all compressed families" {
    // BC
    try testing.expect(is_any_compressed(compressed_formats.WGPUTextureFormat_BC1RGBAUnorm));
    try testing.expect(is_any_compressed(compressed_formats.WGPUTextureFormat_BC7RGBAUnormSrgb));
    // ETC2/EAC
    try testing.expect(is_any_compressed(compressed_formats.WGPUTextureFormat_ETC2RGB8Unorm));
    try testing.expect(is_any_compressed(compressed_formats.WGPUTextureFormat_EACRG11Snorm));
    // ASTC
    try testing.expect(is_any_compressed(compressed_formats.WGPUTextureFormat_ASTC4x4Unorm));
    try testing.expect(is_any_compressed(compressed_formats.WGPUTextureFormat_ASTC12x12UnormSrgb));
    // Non-compressed
    try testing.expect(!is_any_compressed(model_gpu_types.WGPUTextureFormat_RGBA8Unorm));
    try testing.expect(!is_any_compressed(model_gpu_types.WGPUTextureFormat_R32Float));
    try testing.expect(!is_any_compressed(model_gpu_types.WGPUTextureFormat_Depth32Float));
}

test "ETC2 and ASTC formats return UnsupportedFeature from wgpu_format_to_dxgi" {
    try testing.expectError(error.UnsupportedFeature, wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_ETC2RGB8Unorm));
    try testing.expectError(error.UnsupportedFeature, wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_EACRG11Snorm));
    try testing.expectError(error.UnsupportedFeature, wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_ASTC4x4Unorm));
    try testing.expectError(error.UnsupportedFeature, wgpu_format_to_dxgi(compressed_formats.WGPUTextureFormat_ASTC12x12UnormSrgb));
}

test "wgpu_vertex_format_to_dxgi maps 8-bit formats" {
    try testing.expectEqual(DXGI_FORMAT_R8_UINT, try wgpu_vertex_format_to_dxgi(0x01));
    try testing.expectEqual(DXGI_FORMAT_R8G8_UINT, try wgpu_vertex_format_to_dxgi(0x02));
    try testing.expectEqual(DXGI_FORMAT_R8G8B8A8_UINT, try wgpu_vertex_format_to_dxgi(0x03));
    try testing.expectEqual(DXGI_FORMAT_R8_SINT, try wgpu_vertex_format_to_dxgi(0x04));
    try testing.expectEqual(DXGI_FORMAT_R8_UNORM, try wgpu_vertex_format_to_dxgi(0x07));
    try testing.expectEqual(DXGI_FORMAT_R8G8B8A8_UNORM, try wgpu_vertex_format_to_dxgi(0x09));
    try testing.expectEqual(DXGI_FORMAT_R8_SNORM, try wgpu_vertex_format_to_dxgi(0x0A));
    try testing.expectEqual(DXGI_FORMAT_R8G8B8A8_SNORM, try wgpu_vertex_format_to_dxgi(0x0C));
}

test "wgpu_vertex_format_to_dxgi maps 16-bit formats" {
    try testing.expectEqual(DXGI_FORMAT_R16_UINT, try wgpu_vertex_format_to_dxgi(0x0D));
    try testing.expectEqual(DXGI_FORMAT_R16G16B16A16_SINT, try wgpu_vertex_format_to_dxgi(0x12));
    try testing.expectEqual(DXGI_FORMAT_R16_UNORM, try wgpu_vertex_format_to_dxgi(0x13));
    try testing.expectEqual(DXGI_FORMAT_R16G16B16A16_SNORM, try wgpu_vertex_format_to_dxgi(0x18));
}

test "wgpu_vertex_format_to_dxgi maps 32-bit float formats" {
    try testing.expectEqual(DXGI_FORMAT_R32_FLOAT, try wgpu_vertex_format_to_dxgi(0x1C));
    try testing.expectEqual(DXGI_FORMAT_R32G32_FLOAT, try wgpu_vertex_format_to_dxgi(0x1D));
    try testing.expectEqual(DXGI_FORMAT_R32G32B32_FLOAT, try wgpu_vertex_format_to_dxgi(0x1E));
    try testing.expectEqual(DXGI_FORMAT_R32G32B32A32_FLOAT, try wgpu_vertex_format_to_dxgi(0x1F));
}

test "wgpu_vertex_format_to_dxgi maps 16-bit float formats" {
    try testing.expectEqual(DXGI_FORMAT_R16_FLOAT, try wgpu_vertex_format_to_dxgi(0x19));
    try testing.expectEqual(DXGI_FORMAT_R16G16_FLOAT, try wgpu_vertex_format_to_dxgi(0x1A));
    try testing.expectEqual(DXGI_FORMAT_R16G16B16A16_FLOAT, try wgpu_vertex_format_to_dxgi(0x1B));
}

test "wgpu_vertex_format_to_dxgi maps 32-bit int formats" {
    try testing.expectEqual(DXGI_FORMAT_R32_UINT, try wgpu_vertex_format_to_dxgi(0x20));
    try testing.expectEqual(DXGI_FORMAT_R32G32B32_UINT, try wgpu_vertex_format_to_dxgi(0x22));
    try testing.expectEqual(DXGI_FORMAT_R32G32B32A32_UINT, try wgpu_vertex_format_to_dxgi(0x23));
    try testing.expectEqual(DXGI_FORMAT_R32_SINT, try wgpu_vertex_format_to_dxgi(0x24));
    try testing.expectEqual(DXGI_FORMAT_R32G32B32A32_SINT, try wgpu_vertex_format_to_dxgi(0x27));
}

test "wgpu_vertex_format_to_dxgi maps packed formats" {
    try testing.expectEqual(DXGI_FORMAT_R10G10B10A2_UNORM, try wgpu_vertex_format_to_dxgi(0x28));
    try testing.expectEqual(DXGI_FORMAT_B8G8R8A8_UNORM, try wgpu_vertex_format_to_dxgi(0x29));
}

test "wgpu_vertex_format_to_dxgi rejects invalid format" {
    try testing.expectError(error.UnsupportedFeature, wgpu_vertex_format_to_dxgi(0x00));
    try testing.expectError(error.UnsupportedFeature, wgpu_vertex_format_to_dxgi(0x2A));
    try testing.expectError(error.UnsupportedFeature, wgpu_vertex_format_to_dxgi(0xFF));
}
