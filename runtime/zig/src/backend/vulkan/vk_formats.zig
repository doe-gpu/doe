const vertex_formats = @import("../../contracts/vertex_format.zig");
// WebGPU-to-Vulkan format translation.
//
// Maps WGPUTextureFormat values to VkFormat constants and provides
// per-format metadata (bytes per pixel, aspect mask).
// Also maps WebGPU vertex format enum values to VkFormat for vertex input.

const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");

// --- VkFormat constants (Vulkan 1.0 spec values) ---

// 1-channel 8-bit
pub const VK_FORMAT_R8_UNORM: u32 = 9;
pub const VK_FORMAT_R8_SNORM: u32 = 10;
pub const VK_FORMAT_R8_UINT: u32 = 13;
pub const VK_FORMAT_R8_SINT: u32 = 14;

// 2-channel 8-bit
pub const VK_FORMAT_R8G8_UNORM: u32 = 16;
pub const VK_FORMAT_R8G8_SNORM: u32 = 17;
pub const VK_FORMAT_R8G8_UINT: u32 = 20;
pub const VK_FORMAT_R8G8_SINT: u32 = 21;

// 4-channel 8-bit
pub const VK_FORMAT_R8G8B8A8_UNORM: u32 = 37;
pub const VK_FORMAT_R8G8B8A8_SRGB: u32 = 43;
pub const VK_FORMAT_R8G8B8A8_SNORM: u32 = 38;
pub const VK_FORMAT_R8G8B8A8_UINT: u32 = 41;
pub const VK_FORMAT_R8G8B8A8_SINT: u32 = 42;
pub const VK_FORMAT_B8G8R8A8_UNORM: u32 = 44;
pub const VK_FORMAT_B8G8R8A8_SRGB: u32 = 50;

// Packed 32-bit color
pub const VK_FORMAT_A2B10G10R10_UINT_PACK32: u32 = 68;
pub const VK_FORMAT_A2B10G10R10_UNORM_PACK32: u32 = 64;

// 1-channel 16-bit
pub const VK_FORMAT_R16_UNORM: u32 = 70;
pub const VK_FORMAT_R16_SNORM: u32 = 71;
pub const VK_FORMAT_R16_UINT: u32 = 74;
pub const VK_FORMAT_R16_SINT: u32 = 75;
pub const VK_FORMAT_R16_SFLOAT: u32 = 76;

// 2-channel 16-bit
pub const VK_FORMAT_R16G16_UNORM: u32 = 77;
pub const VK_FORMAT_R16G16_SNORM: u32 = 78;
pub const VK_FORMAT_R16G16_UINT: u32 = 81;
pub const VK_FORMAT_R16G16_SINT: u32 = 82;
pub const VK_FORMAT_R16G16_SFLOAT: u32 = 83;

// 4-channel 16-bit
pub const VK_FORMAT_R16G16B16A16_UNORM: u32 = 91;
pub const VK_FORMAT_R16G16B16A16_SNORM: u32 = 92;
pub const VK_FORMAT_R16G16B16A16_UINT: u32 = 95;
pub const VK_FORMAT_R16G16B16A16_SINT: u32 = 96;
pub const VK_FORMAT_R16G16B16A16_SFLOAT: u32 = 97;

// 1-channel 32-bit
pub const VK_FORMAT_R32_UINT: u32 = 98;
pub const VK_FORMAT_R32_SINT: u32 = 99;
pub const VK_FORMAT_R32_SFLOAT: u32 = 100;

// 2-channel 32-bit
pub const VK_FORMAT_R32G32_UINT: u32 = 101;
pub const VK_FORMAT_R32G32_SINT: u32 = 102;
pub const VK_FORMAT_R32G32_SFLOAT: u32 = 103;

// 3-channel 32-bit (vertex-only; not used for texture formats)
pub const VK_FORMAT_R32G32B32_UINT: u32 = 104;
pub const VK_FORMAT_R32G32B32_SINT: u32 = 105;
pub const VK_FORMAT_R32G32B32_SFLOAT: u32 = 106;

// 4-channel 32-bit
pub const VK_FORMAT_R32G32B32A32_UINT: u32 = 107;
pub const VK_FORMAT_R32G32B32A32_SINT: u32 = 108;
pub const VK_FORMAT_R32G32B32A32_SFLOAT: u32 = 109;

// Packed float formats
pub const VK_FORMAT_B10G11R11_UFLOAT_PACK32: u32 = 122;
pub const VK_FORMAT_E5B9G9R9_UFLOAT_PACK32: u32 = 123;

// Depth/stencil
pub const VK_FORMAT_D16_UNORM: u32 = 124;
pub const VK_FORMAT_D32_SFLOAT: u32 = 126;
pub const VK_FORMAT_S8_UINT: u32 = 127;
pub const VK_FORMAT_D24_UNORM_S8_UINT: u32 = 129;
pub const VK_FORMAT_D32_SFLOAT_S8_UINT: u32 = 130;
pub const VK_FORMAT_BC1_RGBA_UNORM_BLOCK: u32 = 133;
pub const VK_FORMAT_BC1_RGBA_SRGB_BLOCK: u32 = 134;
pub const VK_FORMAT_BC2_UNORM_BLOCK: u32 = 135;
pub const VK_FORMAT_BC2_SRGB_BLOCK: u32 = 136;
pub const VK_FORMAT_BC3_UNORM_BLOCK: u32 = 137;
pub const VK_FORMAT_BC3_SRGB_BLOCK: u32 = 138;
pub const VK_FORMAT_BC4_UNORM_BLOCK: u32 = 139;
pub const VK_FORMAT_BC4_SNORM_BLOCK: u32 = 140;
pub const VK_FORMAT_BC5_UNORM_BLOCK: u32 = 141;
pub const VK_FORMAT_BC5_SNORM_BLOCK: u32 = 142;
pub const VK_FORMAT_BC6H_UFLOAT_BLOCK: u32 = 143;
pub const VK_FORMAT_BC6H_SFLOAT_BLOCK: u32 = 144;
pub const VK_FORMAT_BC7_UNORM_BLOCK: u32 = 145;
pub const VK_FORMAT_BC7_SRGB_BLOCK: u32 = 146;
pub const VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK: u32 = 147;
pub const VK_FORMAT_ETC2_R8G8B8_SRGB_BLOCK: u32 = 148;
pub const VK_FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK: u32 = 149;
pub const VK_FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK: u32 = 150;
pub const VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK: u32 = 151;
pub const VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK: u32 = 152;
pub const VK_FORMAT_EAC_R11_UNORM_BLOCK: u32 = 153;
pub const VK_FORMAT_EAC_R11_SNORM_BLOCK: u32 = 154;
pub const VK_FORMAT_EAC_R11G11_UNORM_BLOCK: u32 = 155;
pub const VK_FORMAT_EAC_R11G11_SNORM_BLOCK: u32 = 156;
pub const VK_FORMAT_ASTC_4X4_UNORM_BLOCK: u32 = 157;
pub const VK_FORMAT_ASTC_4X4_SRGB_BLOCK: u32 = 158;
pub const VK_FORMAT_ASTC_5X4_UNORM_BLOCK: u32 = 159;
pub const VK_FORMAT_ASTC_5X4_SRGB_BLOCK: u32 = 160;
pub const VK_FORMAT_ASTC_5X5_UNORM_BLOCK: u32 = 161;
pub const VK_FORMAT_ASTC_5X5_SRGB_BLOCK: u32 = 162;
pub const VK_FORMAT_ASTC_6X5_UNORM_BLOCK: u32 = 163;
pub const VK_FORMAT_ASTC_6X5_SRGB_BLOCK: u32 = 164;
pub const VK_FORMAT_ASTC_6X6_UNORM_BLOCK: u32 = 165;
pub const VK_FORMAT_ASTC_6X6_SRGB_BLOCK: u32 = 166;
pub const VK_FORMAT_ASTC_8X5_UNORM_BLOCK: u32 = 167;
pub const VK_FORMAT_ASTC_8X5_SRGB_BLOCK: u32 = 168;
pub const VK_FORMAT_ASTC_8X6_UNORM_BLOCK: u32 = 169;
pub const VK_FORMAT_ASTC_8X6_SRGB_BLOCK: u32 = 170;
pub const VK_FORMAT_ASTC_8X8_UNORM_BLOCK: u32 = 171;
pub const VK_FORMAT_ASTC_8X8_SRGB_BLOCK: u32 = 172;
pub const VK_FORMAT_ASTC_10X5_UNORM_BLOCK: u32 = 173;
pub const VK_FORMAT_ASTC_10X5_SRGB_BLOCK: u32 = 174;
pub const VK_FORMAT_ASTC_10X6_UNORM_BLOCK: u32 = 175;
pub const VK_FORMAT_ASTC_10X6_SRGB_BLOCK: u32 = 176;
pub const VK_FORMAT_ASTC_10X8_UNORM_BLOCK: u32 = 177;
pub const VK_FORMAT_ASTC_10X8_SRGB_BLOCK: u32 = 178;
pub const VK_FORMAT_ASTC_10X10_UNORM_BLOCK: u32 = 179;
pub const VK_FORMAT_ASTC_10X10_SRGB_BLOCK: u32 = 180;
pub const VK_FORMAT_ASTC_12X10_UNORM_BLOCK: u32 = 181;
pub const VK_FORMAT_ASTC_12X10_SRGB_BLOCK: u32 = 182;
pub const VK_FORMAT_ASTC_12X12_UNORM_BLOCK: u32 = 183;
pub const VK_FORMAT_ASTC_12X12_SRGB_BLOCK: u32 = 184;

// --- Aspect mask constants ---

pub const VK_IMAGE_ASPECT_COLOR_BIT: u32 = 0x00000001;
pub const VK_IMAGE_ASPECT_DEPTH_BIT: u32 = 0x00000002;
pub const VK_IMAGE_ASPECT_STENCIL_BIT: u32 = 0x00000004;

// --- Format translation ---

pub fn wgpu_format_to_vk_format(format: model_gpu_types.WGPUTextureFormat) !u32 {
    return switch (format) {
        // 1-channel 8-bit
        model_gpu_types.WGPUTextureFormat_R8Unorm => VK_FORMAT_R8_UNORM,
        model_gpu_types.WGPUTextureFormat_R8Snorm => VK_FORMAT_R8_SNORM,
        model_gpu_types.WGPUTextureFormat_R8Uint => VK_FORMAT_R8_UINT,
        model_gpu_types.WGPUTextureFormat_R8Sint => VK_FORMAT_R8_SINT,

        // 2-channel 8-bit
        model_gpu_types.WGPUTextureFormat_RG8Unorm => VK_FORMAT_R8G8_UNORM,
        model_gpu_types.WGPUTextureFormat_RG8Snorm => VK_FORMAT_R8G8_SNORM,
        model_gpu_types.WGPUTextureFormat_RG8Uint => VK_FORMAT_R8G8_UINT,
        model_gpu_types.WGPUTextureFormat_RG8Sint => VK_FORMAT_R8G8_SINT,

        // 4-channel 8-bit
        model_gpu_types.WGPUTextureFormat_RGBA8Unorm => VK_FORMAT_R8G8B8A8_UNORM,
        model_gpu_types.WGPUTextureFormat_RGBA8UnormSrgb => VK_FORMAT_R8G8B8A8_SRGB,
        model_gpu_types.WGPUTextureFormat_RGBA8Snorm => VK_FORMAT_R8G8B8A8_SNORM,
        model_gpu_types.WGPUTextureFormat_RGBA8Uint => VK_FORMAT_R8G8B8A8_UINT,
        model_gpu_types.WGPUTextureFormat_RGBA8Sint => VK_FORMAT_R8G8B8A8_SINT,
        model_gpu_types.WGPUTextureFormat_BGRA8Unorm => VK_FORMAT_B8G8R8A8_UNORM,
        model_gpu_types.WGPUTextureFormat_BGRA8UnormSrgb => VK_FORMAT_B8G8R8A8_SRGB,

        // Packed 32-bit color
        model_gpu_types.WGPUTextureFormat_RGB10A2Uint => VK_FORMAT_A2B10G10R10_UINT_PACK32,
        model_gpu_types.WGPUTextureFormat_RGB10A2Unorm => VK_FORMAT_A2B10G10R10_UNORM_PACK32,
        model_gpu_types.WGPUTextureFormat_RG11B10Ufloat => VK_FORMAT_B10G11R11_UFLOAT_PACK32,
        model_gpu_types.WGPUTextureFormat_RGB9E5Ufloat => VK_FORMAT_E5B9G9R9_UFLOAT_PACK32,

        // 1-channel 16-bit
        model_gpu_types.WGPUTextureFormat_R16Unorm => VK_FORMAT_R16_UNORM,
        model_gpu_types.WGPUTextureFormat_R16Snorm => VK_FORMAT_R16_SNORM,
        model_gpu_types.WGPUTextureFormat_R16Uint => VK_FORMAT_R16_UINT,
        model_gpu_types.WGPUTextureFormat_R16Sint => VK_FORMAT_R16_SINT,
        model_gpu_types.WGPUTextureFormat_R16Float => VK_FORMAT_R16_SFLOAT,

        // 2-channel 16-bit
        model_gpu_types.WGPUTextureFormat_RG16Unorm => VK_FORMAT_R16G16_UNORM,
        model_gpu_types.WGPUTextureFormat_RG16Snorm => VK_FORMAT_R16G16_SNORM,
        model_gpu_types.WGPUTextureFormat_RG16Uint => VK_FORMAT_R16G16_UINT,
        model_gpu_types.WGPUTextureFormat_RG16Sint => VK_FORMAT_R16G16_SINT,
        model_gpu_types.WGPUTextureFormat_RG16Float => VK_FORMAT_R16G16_SFLOAT,

        // 4-channel 16-bit
        model_gpu_types.WGPUTextureFormat_RGBA16Unorm => VK_FORMAT_R16G16B16A16_UNORM,
        model_gpu_types.WGPUTextureFormat_RGBA16Snorm => VK_FORMAT_R16G16B16A16_SNORM,
        model_gpu_types.WGPUTextureFormat_RGBA16Uint => VK_FORMAT_R16G16B16A16_UINT,
        model_gpu_types.WGPUTextureFormat_RGBA16Sint => VK_FORMAT_R16G16B16A16_SINT,
        model_gpu_types.WGPUTextureFormat_RGBA16Float => VK_FORMAT_R16G16B16A16_SFLOAT,

        // 1-channel 32-bit
        model_gpu_types.WGPUTextureFormat_R32Uint => VK_FORMAT_R32_UINT,
        model_gpu_types.WGPUTextureFormat_R32Sint => VK_FORMAT_R32_SINT,
        model_gpu_types.WGPUTextureFormat_R32Float => VK_FORMAT_R32_SFLOAT,

        // 2-channel 32-bit
        model_gpu_types.WGPUTextureFormat_RG32Uint => VK_FORMAT_R32G32_UINT,
        model_gpu_types.WGPUTextureFormat_RG32Sint => VK_FORMAT_R32G32_SINT,
        model_gpu_types.WGPUTextureFormat_RG32Float => VK_FORMAT_R32G32_SFLOAT,

        // 4-channel 32-bit
        model_gpu_types.WGPUTextureFormat_RGBA32Uint => VK_FORMAT_R32G32B32A32_UINT,
        model_gpu_types.WGPUTextureFormat_RGBA32Sint => VK_FORMAT_R32G32B32A32_SINT,
        model_gpu_types.WGPUTextureFormat_RGBA32Float => VK_FORMAT_R32G32B32A32_SFLOAT,

        // Depth/stencil
        model_gpu_types.WGPUTextureFormat_Depth16Unorm => VK_FORMAT_D16_UNORM,
        model_gpu_types.WGPUTextureFormat_Depth32Float => VK_FORMAT_D32_SFLOAT,
        model_gpu_types.WGPUTextureFormat_Stencil8 => VK_FORMAT_S8_UINT,
        model_gpu_types.WGPUTextureFormat_Depth24Plus,
        model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8,
        => VK_FORMAT_D24_UNORM_S8_UINT,
        model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8 => VK_FORMAT_D32_SFLOAT_S8_UINT,
        model_gpu_types.WGPUTextureFormat_BC1RGBAUnorm => VK_FORMAT_BC1_RGBA_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC1RGBAUnormSrgb => VK_FORMAT_BC1_RGBA_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC2RGBAUnorm => VK_FORMAT_BC2_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC2RGBAUnormSrgb => VK_FORMAT_BC2_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC3RGBAUnorm => VK_FORMAT_BC3_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC3RGBAUnormSrgb => VK_FORMAT_BC3_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC4RUnorm => VK_FORMAT_BC4_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC4RSnorm => VK_FORMAT_BC4_SNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC5RGUnorm => VK_FORMAT_BC5_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC5RGSnorm => VK_FORMAT_BC5_SNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC6HRGBUfloat => VK_FORMAT_BC6H_UFLOAT_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC6HRGBFloat => VK_FORMAT_BC6H_SFLOAT_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC7RGBAUnorm => VK_FORMAT_BC7_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_BC7RGBAUnormSrgb => VK_FORMAT_BC7_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ETC2RGB8Unorm => VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ETC2RGB8UnormSrgb => VK_FORMAT_ETC2_R8G8B8_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ETC2RGB8A1Unorm => VK_FORMAT_ETC2_R8G8B8A1_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ETC2RGB8A1UnormSrgb => VK_FORMAT_ETC2_R8G8B8A1_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ETC2RGBA8Unorm => VK_FORMAT_ETC2_R8G8B8A8_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ETC2RGBA8UnormSrgb => VK_FORMAT_ETC2_R8G8B8A8_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_EACR11Unorm => VK_FORMAT_EAC_R11_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_EACR11Snorm => VK_FORMAT_EAC_R11_SNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_EACRG11Unorm => VK_FORMAT_EAC_R11G11_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_EACRG11Snorm => VK_FORMAT_EAC_R11G11_SNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC4x4Unorm => VK_FORMAT_ASTC_4X4_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC4x4UnormSrgb => VK_FORMAT_ASTC_4X4_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC5x4Unorm => VK_FORMAT_ASTC_5X4_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC5x4UnormSrgb => VK_FORMAT_ASTC_5X4_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC5x5Unorm => VK_FORMAT_ASTC_5X5_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC5x5UnormSrgb => VK_FORMAT_ASTC_5X5_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC6x5Unorm => VK_FORMAT_ASTC_6X5_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC6x5UnormSrgb => VK_FORMAT_ASTC_6X5_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC6x6Unorm => VK_FORMAT_ASTC_6X6_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC6x6UnormSrgb => VK_FORMAT_ASTC_6X6_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC8x5Unorm => VK_FORMAT_ASTC_8X5_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC8x5UnormSrgb => VK_FORMAT_ASTC_8X5_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC8x6Unorm => VK_FORMAT_ASTC_8X6_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC8x6UnormSrgb => VK_FORMAT_ASTC_8X6_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC8x8Unorm => VK_FORMAT_ASTC_8X8_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC8x8UnormSrgb => VK_FORMAT_ASTC_8X8_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC10x5Unorm => VK_FORMAT_ASTC_10X5_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC10x5UnormSrgb => VK_FORMAT_ASTC_10X5_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC10x6Unorm => VK_FORMAT_ASTC_10X6_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC10x6UnormSrgb => VK_FORMAT_ASTC_10X6_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC10x8Unorm => VK_FORMAT_ASTC_10X8_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC10x8UnormSrgb => VK_FORMAT_ASTC_10X8_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC10x10Unorm => VK_FORMAT_ASTC_10X10_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC10x10UnormSrgb => VK_FORMAT_ASTC_10X10_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC12x10Unorm => VK_FORMAT_ASTC_12X10_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC12x10UnormSrgb => VK_FORMAT_ASTC_12X10_SRGB_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC12x12Unorm => VK_FORMAT_ASTC_12X12_UNORM_BLOCK,
        model_gpu_types.WGPUTextureFormat_ASTC12x12UnormSrgb => VK_FORMAT_ASTC_12X12_SRGB_BLOCK,

        else => error.UnsupportedFeature,
    };
}

/// Returns the number of bytes per pixel for a given WebGPU texture format.
/// Depth/stencil formats return the total byte footprint per texel.
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
        model_gpu_types.WGPUTextureFormat_RGBA16Unorm,
        model_gpu_types.WGPUTextureFormat_RGBA16Snorm,
        model_gpu_types.WGPUTextureFormat_RGBA16Uint,
        model_gpu_types.WGPUTextureFormat_RGBA16Sint,
        model_gpu_types.WGPUTextureFormat_RGBA16Float,
        model_gpu_types.WGPUTextureFormat_RG32Uint,
        model_gpu_types.WGPUTextureFormat_RG32Sint,
        model_gpu_types.WGPUTextureFormat_RG32Float,
        model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8,
        => 8,

        // 8 bytes per block
        model_gpu_types.WGPUTextureFormat_BC1RGBAUnorm,
        model_gpu_types.WGPUTextureFormat_BC1RGBAUnormSrgb,
        model_gpu_types.WGPUTextureFormat_BC4RUnorm,
        model_gpu_types.WGPUTextureFormat_BC4RSnorm,
        model_gpu_types.WGPUTextureFormat_ETC2RGB8Unorm,
        model_gpu_types.WGPUTextureFormat_ETC2RGB8UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ETC2RGB8A1Unorm,
        model_gpu_types.WGPUTextureFormat_ETC2RGB8A1UnormSrgb,
        model_gpu_types.WGPUTextureFormat_EACR11Unorm,
        model_gpu_types.WGPUTextureFormat_EACR11Snorm,
        => 8,

        // 16 bytes per block
        model_gpu_types.WGPUTextureFormat_BC2RGBAUnorm,
        model_gpu_types.WGPUTextureFormat_BC2RGBAUnormSrgb,
        model_gpu_types.WGPUTextureFormat_BC3RGBAUnorm,
        model_gpu_types.WGPUTextureFormat_BC3RGBAUnormSrgb,
        model_gpu_types.WGPUTextureFormat_BC5RGUnorm,
        model_gpu_types.WGPUTextureFormat_BC5RGSnorm,
        model_gpu_types.WGPUTextureFormat_BC6HRGBUfloat,
        model_gpu_types.WGPUTextureFormat_BC6HRGBFloat,
        model_gpu_types.WGPUTextureFormat_BC7RGBAUnorm,
        model_gpu_types.WGPUTextureFormat_BC7RGBAUnormSrgb,
        model_gpu_types.WGPUTextureFormat_ETC2RGBA8Unorm,
        model_gpu_types.WGPUTextureFormat_ETC2RGBA8UnormSrgb,
        model_gpu_types.WGPUTextureFormat_EACRG11Unorm,
        model_gpu_types.WGPUTextureFormat_EACRG11Snorm,
        model_gpu_types.WGPUTextureFormat_ASTC4x4Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC4x4UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC5x4Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC5x4UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC5x5Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC5x5UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC6x5Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC6x5UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC6x6Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC6x6UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC8x5Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC8x5UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC8x6Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC8x6UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC8x8Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC8x8UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC10x5Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC10x5UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC10x6Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC10x6UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC10x8Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC10x8UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC10x10Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC10x10UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC12x10Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC12x10UnormSrgb,
        model_gpu_types.WGPUTextureFormat_ASTC12x12Unorm,
        model_gpu_types.WGPUTextureFormat_ASTC12x12UnormSrgb,
        => 16,

        // 16 bytes per pixel
        model_gpu_types.WGPUTextureFormat_RGBA32Uint,
        model_gpu_types.WGPUTextureFormat_RGBA32Sint,
        model_gpu_types.WGPUTextureFormat_RGBA32Float,
        => 16,

        else => error.UnsupportedFeature,
    };
}

/// Returns the Vulkan image aspect mask for a WebGPU texture format.
/// Color formats use COLOR_BIT; depth and depth-stencil formats use the
/// appropriate depth/stencil combination.
pub fn aspect_mask_for_format(format: model_gpu_types.WGPUTextureFormat) u32 {
    return switch (format) {
        model_gpu_types.WGPUTextureFormat_Depth16Unorm,
        model_gpu_types.WGPUTextureFormat_Depth32Float,
        model_gpu_types.WGPUTextureFormat_Depth24Plus,
        => VK_IMAGE_ASPECT_DEPTH_BIT,

        model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8,
        model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8,
        => VK_IMAGE_ASPECT_DEPTH_BIT | VK_IMAGE_ASPECT_STENCIL_BIT,

        model_gpu_types.WGPUTextureFormat_Stencil8 => VK_IMAGE_ASPECT_STENCIL_BIT,

        else => VK_IMAGE_ASPECT_COLOR_BIT,
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

// --- Vertex format translation ---
//
// Vertex identities come from the shared contract; Vulkan format conversion stays local.

pub fn wgpu_vertex_format_to_vk(format: u32) !u32 {
    return switch (try vertex_formats.fromCode(format)) {
        // 8-bit uint
        .uint8 => VK_FORMAT_R8_UINT,
        .uint8x2 => VK_FORMAT_R8G8_UINT,
        .uint8x4 => VK_FORMAT_R8G8B8A8_UINT,
        // 8-bit sint
        .sint8 => VK_FORMAT_R8_SINT,
        .sint8x2 => VK_FORMAT_R8G8_SINT,
        .sint8x4 => VK_FORMAT_R8G8B8A8_SINT,
        // 8-bit unorm
        .unorm8 => VK_FORMAT_R8_UNORM,
        .unorm8x2 => VK_FORMAT_R8G8_UNORM,
        .unorm8x4 => VK_FORMAT_R8G8B8A8_UNORM,
        // 8-bit snorm
        .snorm8 => VK_FORMAT_R8_SNORM,
        .snorm8x2 => VK_FORMAT_R8G8_SNORM,
        .snorm8x4 => VK_FORMAT_R8G8B8A8_SNORM,
        // 16-bit uint
        .uint16 => VK_FORMAT_R16_UINT,
        .uint16x2 => VK_FORMAT_R16G16_UINT,
        .uint16x4 => VK_FORMAT_R16G16B16A16_UINT,
        // 16-bit sint
        .sint16 => VK_FORMAT_R16_SINT,
        .sint16x2 => VK_FORMAT_R16G16_SINT,
        .sint16x4 => VK_FORMAT_R16G16B16A16_SINT,
        // 16-bit unorm
        .unorm16 => VK_FORMAT_R16_UNORM,
        .unorm16x2 => VK_FORMAT_R16G16_UNORM,
        .unorm16x4 => VK_FORMAT_R16G16B16A16_UNORM,
        // 16-bit snorm
        .snorm16 => VK_FORMAT_R16_SNORM,
        .snorm16x2 => VK_FORMAT_R16G16_SNORM,
        .snorm16x4 => VK_FORMAT_R16G16B16A16_SNORM,
        // 32-bit float
        .float32 => VK_FORMAT_R32_SFLOAT,
        .float32x2 => VK_FORMAT_R32G32_SFLOAT,
        .float32x3 => VK_FORMAT_R32G32B32_SFLOAT,
        .float32x4 => VK_FORMAT_R32G32B32A32_SFLOAT,
        // 16-bit float
        .float16 => VK_FORMAT_R16_SFLOAT,
        .float16x2 => VK_FORMAT_R16G16_SFLOAT,
        .float16x4 => VK_FORMAT_R16G16B16A16_SFLOAT,
        // 32-bit uint
        .uint32 => VK_FORMAT_R32_UINT,
        .uint32x2 => VK_FORMAT_R32G32_UINT,
        .uint32x3 => VK_FORMAT_R32G32B32_UINT,
        .uint32x4 => VK_FORMAT_R32G32B32A32_UINT,
        // 32-bit sint
        .sint32 => VK_FORMAT_R32_SINT,
        .sint32x2 => VK_FORMAT_R32G32_SINT,
        .sint32x3 => VK_FORMAT_R32G32B32_SINT,
        .sint32x4 => VK_FORMAT_R32G32B32A32_SINT,
        // Packed
        .unorm10_10_10_2 => VK_FORMAT_A2B10G10R10_UNORM_PACK32,
        .unorm8x4_bgra => VK_FORMAT_B8G8R8A8_UNORM,
    };
}
