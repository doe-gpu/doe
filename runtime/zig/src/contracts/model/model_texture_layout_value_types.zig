pub const WGPUFlags = u64;
pub const WGPUSType = u32;
pub const WGPUTextureFormat = u32;

pub const WGPUTextureUsage_None: WGPUFlags = 0;
pub const WGPUTextureUsage_CopySrc: WGPUFlags = 0x0000000000000001;
pub const WGPUTextureUsage_CopyDst: WGPUFlags = 0x0000000000000002;
pub const WGPUTextureUsage_TextureBinding: WGPUFlags = 0x0000000000000004;
pub const WGPUTextureUsage_StorageBinding: WGPUFlags = 0x0000000000000008;
pub const WGPUTextureUsage_RenderAttachment: WGPUFlags = 0x0000000000000010;

pub const WGPUCopyStrideUndefined: u32 = 0xFFFFFFFF;
pub const WGPUWholeSize: u64 = 0xFFFFFFFFFFFFFFFF;

pub const WGPUTextureDimension_Undefined: u32 = 0;
pub const WGPUTextureDimension_1D: u32 = 1;
pub const WGPUTextureDimension_2D: u32 = 2;
pub const WGPUTextureDimension_3D: u32 = 3;

pub const WGPUTextureViewDimension_Undefined: u32 = 0;
pub const WGPUTextureViewDimension_1D: u32 = 1;
pub const WGPUTextureViewDimension_2D: u32 = 2;
pub const WGPUTextureViewDimension_2DArray: u32 = 3;
pub const WGPUTextureViewDimension_Cube: u32 = 4;
pub const WGPUTextureViewDimension_CubeArray: u32 = 5;
pub const WGPUTextureViewDimension_3D: u32 = 6;

pub const WGPUTextureAspect_Undefined: u32 = 0;
pub const WGPUTextureAspect_All: u32 = 1;
pub const WGPUTextureAspect_StencilOnly: u32 = 2;
pub const WGPUTextureAspect_DepthOnly: u32 = 3;
