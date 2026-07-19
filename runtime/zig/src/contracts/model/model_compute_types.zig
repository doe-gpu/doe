const gpu_texture = @import("model_texture_value_types.zig");
const gpu_binding = @import("model_binding_value_types.zig");

pub const DispatchCommand = struct {
    x: u32,
    y: u32,
    z: u32,
};

pub const DispatchIndirectCommand = DispatchCommand;

pub const KernelBindingResourceKind = enum(u8) {
    buffer,
    texture,
    storage_texture,
    sampler,
};

pub const KernelBinding = struct {
    binding: u32,
    group: u32 = 0,
    resource_kind: KernelBindingResourceKind,
    resource_handle: u64,
    visibility: gpu_texture.WGPUFlags = gpu_binding.WGPUShaderStage_Compute,
    buffer_offset: u64 = 0,
    buffer_size: u64 = gpu_texture.WGPUWholeSize,
    buffer_type: u32 = gpu_binding.WGPUBufferBindingType_Undefined,
    texture_sample_type: u32 = gpu_binding.WGPUTextureSampleType_Undefined,
    texture_view_dimension: u32 = gpu_texture.WGPUTextureViewDimension_Undefined,
    storage_texture_access: u32 = gpu_binding.WGPUStorageTextureAccess_Undefined,
    texture_aspect: u32 = gpu_texture.WGPUTextureAspect_Undefined,
    texture_format: gpu_texture.WGPUTextureFormat = gpu_texture.WGPUTextureFormat_Undefined,
    texture_multisampled: bool = false,
};

pub const KernelDispatchRepeatSynchronization = enum(u8) {
    dependent,
    independent,
};

pub const KernelDispatchCommand = struct {
    kernel: []const u8,
    entry_point: ?[]const u8 = null,
    x: u32,
    y: u32,
    z: u32,
    repeat: u32 = 1,
    repeat_synchronization: KernelDispatchRepeatSynchronization = .dependent,
    warmup_dispatch_count: u32 = 0,
    initialize_buffers_on_create: bool = false,
    bindings: ?[]const KernelBinding = null,
};
