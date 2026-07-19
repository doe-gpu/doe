const gpu = @import("model_texture_value_types.zig");

pub const CopyResourceKind = enum(u8) {
    buffer,
    texture,
};

pub const CopyDirection = enum(u8) {
    buffer_to_buffer,
    buffer_to_texture,
    texture_to_buffer,
    texture_to_texture,
};

pub const CopyTextureResource = struct {
    handle: u64,
    kind: CopyResourceKind = .buffer,
    width: u32 = 1,
    height: u32 = 1,
    depth_or_array_layers: u32 = 1,
    format: gpu.WGPUTextureFormat = gpu.WGPUTextureFormat_Undefined,
    usage: gpu.WGPUFlags = 0,
    dimension: u32 = gpu.WGPUTextureDimension_Undefined,
    view_dimension: u32 = gpu.WGPUTextureViewDimension_Undefined,
    mip_level: u32 = 0,
    sample_count: u32 = 1,
    aspect: u32 = gpu.WGPUTextureAspect_Undefined,
    bytes_per_row: u32 = 0,
    rows_per_image: u32 = 0,
    offset: u64 = 0,
};

pub const UploadCommand = struct {
    bytes: usize,
    align_bytes: u32,
};

pub const BufferWriteCommand = struct {
    handle: u64,
    offset: u64 = 0,
    buffer_size: u64 = 0,
    data: []u32,
};

pub const CopyCommand = struct {
    direction: CopyDirection,
    src: CopyTextureResource,
    dst: CopyTextureResource,
    bytes: usize,
    uses_temporary_buffer: bool = false,
    temporary_buffer_alignment: u32 = 0,
};

pub const BarrierCommand = struct {
    dependency_count: u32,
};
