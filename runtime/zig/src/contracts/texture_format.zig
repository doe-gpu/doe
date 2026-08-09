// Canonical compressed texture format constants (BC + ETC2/EAC + ASTC).
// Sharded from wgpu_runtime_abi.zig to keep file size under limit.

pub const WGPUTextureFormat = u32;

// ETC2/EAC compressed texture formats (texture-compression-etc2 feature, webgpu.h values)
pub const WGPUTextureFormat_ETC2RGB8Unorm: WGPUTextureFormat = 0x00000040;
pub const WGPUTextureFormat_ETC2RGB8UnormSrgb: WGPUTextureFormat = 0x00000041;
pub const WGPUTextureFormat_ETC2RGB8A1Unorm: WGPUTextureFormat = 0x00000042;
pub const WGPUTextureFormat_ETC2RGB8A1UnormSrgb: WGPUTextureFormat = 0x00000043;
pub const WGPUTextureFormat_ETC2RGBA8Unorm: WGPUTextureFormat = 0x00000044;
pub const WGPUTextureFormat_ETC2RGBA8UnormSrgb: WGPUTextureFormat = 0x00000045;
pub const WGPUTextureFormat_EACR11Unorm: WGPUTextureFormat = 0x00000046;
pub const WGPUTextureFormat_EACR11Snorm: WGPUTextureFormat = 0x00000047;
pub const WGPUTextureFormat_EACRG11Unorm: WGPUTextureFormat = 0x00000048;
pub const WGPUTextureFormat_EACRG11Snorm: WGPUTextureFormat = 0x00000049;

pub const ETC2_FORMAT_FIRST: WGPUTextureFormat = WGPUTextureFormat_ETC2RGB8Unorm;
pub const ETC2_FORMAT_LAST: WGPUTextureFormat = WGPUTextureFormat_EACRG11Snorm;

pub fn isETC2Format(format: WGPUTextureFormat) bool {
    return format >= ETC2_FORMAT_FIRST and format <= ETC2_FORMAT_LAST;
}

// BC compressed texture formats (texture-compression-bc feature, webgpu.h values)
pub const WGPUTextureFormat_BC1RGBAUnorm: WGPUTextureFormat = 0x00000032;
pub const WGPUTextureFormat_BC1RGBAUnormSrgb: WGPUTextureFormat = 0x00000033;
pub const WGPUTextureFormat_BC2RGBAUnorm: WGPUTextureFormat = 0x00000034;
pub const WGPUTextureFormat_BC2RGBAUnormSrgb: WGPUTextureFormat = 0x00000035;
pub const WGPUTextureFormat_BC3RGBAUnorm: WGPUTextureFormat = 0x00000036;
pub const WGPUTextureFormat_BC3RGBAUnormSrgb: WGPUTextureFormat = 0x00000037;
pub const WGPUTextureFormat_BC4RUnorm: WGPUTextureFormat = 0x00000038;
pub const WGPUTextureFormat_BC4RSnorm: WGPUTextureFormat = 0x00000039;
pub const WGPUTextureFormat_BC5RGUnorm: WGPUTextureFormat = 0x0000003A;
pub const WGPUTextureFormat_BC5RGSnorm: WGPUTextureFormat = 0x0000003B;
pub const WGPUTextureFormat_BC6HRGBUfloat: WGPUTextureFormat = 0x0000003C;
pub const WGPUTextureFormat_BC6HRGBFloat: WGPUTextureFormat = 0x0000003D;
pub const WGPUTextureFormat_BC7RGBAUnorm: WGPUTextureFormat = 0x0000003E;
pub const WGPUTextureFormat_BC7RGBAUnormSrgb: WGPUTextureFormat = 0x0000003F;

pub const BC_FORMAT_FIRST: WGPUTextureFormat = WGPUTextureFormat_BC1RGBAUnorm;
pub const BC_FORMAT_LAST: WGPUTextureFormat = WGPUTextureFormat_BC7RGBAUnormSrgb;

pub fn isBCFormat(format: WGPUTextureFormat) bool {
    return format >= BC_FORMAT_FIRST and format <= BC_FORMAT_LAST;
}

// ASTC compressed texture formats (texture-compression-astc feature, webgpu.h values)
pub const WGPUTextureFormat_ASTC4x4Unorm: WGPUTextureFormat = 0x0000004A;
pub const WGPUTextureFormat_ASTC4x4UnormSrgb: WGPUTextureFormat = 0x0000004B;
pub const WGPUTextureFormat_ASTC5x4Unorm: WGPUTextureFormat = 0x0000004C;
pub const WGPUTextureFormat_ASTC5x4UnormSrgb: WGPUTextureFormat = 0x0000004D;
pub const WGPUTextureFormat_ASTC5x5Unorm: WGPUTextureFormat = 0x0000004E;
pub const WGPUTextureFormat_ASTC5x5UnormSrgb: WGPUTextureFormat = 0x0000004F;
pub const WGPUTextureFormat_ASTC6x5Unorm: WGPUTextureFormat = 0x00000050;
pub const WGPUTextureFormat_ASTC6x5UnormSrgb: WGPUTextureFormat = 0x00000051;
pub const WGPUTextureFormat_ASTC6x6Unorm: WGPUTextureFormat = 0x00000052;
pub const WGPUTextureFormat_ASTC6x6UnormSrgb: WGPUTextureFormat = 0x00000053;
pub const WGPUTextureFormat_ASTC8x5Unorm: WGPUTextureFormat = 0x00000054;
pub const WGPUTextureFormat_ASTC8x5UnormSrgb: WGPUTextureFormat = 0x00000055;
pub const WGPUTextureFormat_ASTC8x6Unorm: WGPUTextureFormat = 0x00000056;
pub const WGPUTextureFormat_ASTC8x6UnormSrgb: WGPUTextureFormat = 0x00000057;
pub const WGPUTextureFormat_ASTC8x8Unorm: WGPUTextureFormat = 0x00000058;
pub const WGPUTextureFormat_ASTC8x8UnormSrgb: WGPUTextureFormat = 0x00000059;
pub const WGPUTextureFormat_ASTC10x5Unorm: WGPUTextureFormat = 0x0000005A;
pub const WGPUTextureFormat_ASTC10x5UnormSrgb: WGPUTextureFormat = 0x0000005B;
pub const WGPUTextureFormat_ASTC10x6Unorm: WGPUTextureFormat = 0x0000005C;
pub const WGPUTextureFormat_ASTC10x6UnormSrgb: WGPUTextureFormat = 0x0000005D;
pub const WGPUTextureFormat_ASTC10x8Unorm: WGPUTextureFormat = 0x0000005E;
pub const WGPUTextureFormat_ASTC10x8UnormSrgb: WGPUTextureFormat = 0x0000005F;
pub const WGPUTextureFormat_ASTC10x10Unorm: WGPUTextureFormat = 0x00000060;
pub const WGPUTextureFormat_ASTC10x10UnormSrgb: WGPUTextureFormat = 0x00000061;
pub const WGPUTextureFormat_ASTC12x10Unorm: WGPUTextureFormat = 0x00000062;
pub const WGPUTextureFormat_ASTC12x10UnormSrgb: WGPUTextureFormat = 0x00000063;
pub const WGPUTextureFormat_ASTC12x12Unorm: WGPUTextureFormat = 0x00000064;
pub const WGPUTextureFormat_ASTC12x12UnormSrgb: WGPUTextureFormat = 0x00000065;

pub const ASTC_FORMAT_FIRST: WGPUTextureFormat = WGPUTextureFormat_ASTC4x4Unorm;
pub const ASTC_FORMAT_LAST: WGPUTextureFormat = WGPUTextureFormat_ASTC12x12UnormSrgb;

pub fn isASTCFormat(format: WGPUTextureFormat) bool {
    return format >= ASTC_FORMAT_FIRST and format <= ASTC_FORMAT_LAST;
}

// ============================================================
// Format capability classification
// ============================================================

// Depth/stencil format constants (base set, no feature gate required)
const DEPTH_STENCIL_STENCIL8: WGPUTextureFormat = 0x0000002C;
const DEPTH_STENCIL_DEPTH16UNORM: WGPUTextureFormat = 0x0000002D;
const DEPTH_STENCIL_DEPTH24PLUS: WGPUTextureFormat = 0x0000002E;
const DEPTH_STENCIL_DEPTH24PLUS_STENCIL8: WGPUTextureFormat = 0x0000002F;
const DEPTH_STENCIL_DEPTH32FLOAT: WGPUTextureFormat = 0x00000030;
const DEPTH_STENCIL_DEPTH32FLOAT_STENCIL8: WGPUTextureFormat = 0x00000031;

pub fn isDepthStencilFormat(format: WGPUTextureFormat) bool {
    return switch (format) {
        DEPTH_STENCIL_STENCIL8,
        DEPTH_STENCIL_DEPTH16UNORM,
        DEPTH_STENCIL_DEPTH24PLUS,
        DEPTH_STENCIL_DEPTH24PLUS_STENCIL8,
        DEPTH_STENCIL_DEPTH32FLOAT,
        DEPTH_STENCIL_DEPTH32FLOAT_STENCIL8,
        => true,
        else => false,
    };
}

pub fn hasStencilAspect(format: WGPUTextureFormat) bool {
    return switch (format) {
        DEPTH_STENCIL_STENCIL8,
        DEPTH_STENCIL_DEPTH24PLUS_STENCIL8,
        DEPTH_STENCIL_DEPTH32FLOAT_STENCIL8,
        => true,
        else => false,
    };
}

// Float32 formats: r32float, rg32float, rgba32float
const FORMAT_R32FLOAT: WGPUTextureFormat = 0x0000000E;
const FORMAT_RG32FLOAT: WGPUTextureFormat = 0x00000021;
const FORMAT_RGBA32FLOAT: WGPUTextureFormat = 0x00000027;

pub fn isFloat32Format(format: WGPUTextureFormat) bool {
    return switch (format) {
        FORMAT_R32FLOAT, FORMAT_RG32FLOAT, FORMAT_RGBA32FLOAT => true,
        else => false,
    };
}

// Formats valid for STORAGE_BINDING usage without any feature gate
const FORMAT_BGRA8UNORM: WGPUTextureFormat = 0x0000001B;

pub fn isBaseStorageTextureFormat(format: WGPUTextureFormat) bool {
    return switch (format) {
        0x00000016, // rgba8unorm
        0x00000018, // rgba8snorm
        0x00000019, // rgba8uint
        0x0000001A, // rgba8sint
        0x00000024, // rgba16uint
        0x00000025, // rgba16sint
        0x00000026, // rgba16float
        FORMAT_R32FLOAT,
        0x0000000F, // r32uint
        0x00000010, // r32sint
        FORMAT_RG32FLOAT,
        0x00000022, // rg32uint
        0x00000023, // rg32sint
        FORMAT_RGBA32FLOAT,
        0x00000028, // rgba32uint
        0x00000029, // rgba32sint
        => true,
        else => false,
    };
}

pub fn isStorageTextureFormat(format: WGPUTextureFormat, bgra8unorm_storage_enabled: bool) bool {
    if (isBaseStorageTextureFormat(format)) return true;
    if (format == FORMAT_BGRA8UNORM and bgra8unorm_storage_enabled) return true;
    return false;
}
