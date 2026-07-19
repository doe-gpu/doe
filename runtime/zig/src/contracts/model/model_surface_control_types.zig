const gpu = @import("model_texture_value_types.zig");

pub const SurfaceCreateCommand = struct {
    handle: u64,
};

pub const SurfaceCapabilitiesCommand = struct {
    handle: u64,
};

pub const WGPUCanvasToneMappingMode_Standard: u32 = 0x00000001;
pub const WGPUCanvasToneMappingMode_Extended: u32 = 0x00000002;

pub const SurfaceConfigureCommand = struct {
    handle: u64,
    width: u32,
    height: u32,
    format: gpu.WGPUTextureFormat = gpu.WGPUTextureFormat_RGBA8Unorm,
    usage: gpu.WGPUFlags = gpu.WGPUTextureUsage_RenderAttachment,
    alpha_mode: u32 = 0x00000001,
    present_mode: u32 = 0x00000002,
    tone_mapping_mode: u32 = WGPUCanvasToneMappingMode_Standard,
    desired_maximum_frame_latency: u32 = 2,
};

pub const SurfaceAcquireCommand = struct {
    handle: u64,
};

pub const SurfacePresentCommand = struct {
    handle: u64,
};

pub const SurfaceUnconfigureCommand = struct {
    handle: u64,
};

pub const SurfaceReleaseCommand = struct {
    handle: u64,
};
