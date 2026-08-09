const core = @import("wgpu_core_base_types.zig");
const binding = @import("../../contracts/model/model_binding_value_types.zig");

pub const WGPUShaderStageFlags = core.WGPUFlags;

pub const WGPUTextureSampleType_BindingNotUsed: u32 = 0x00000000;
pub const WGPUTextureSampleType_Undefined: u32 = binding.WGPUTextureSampleType_Undefined;
pub const WGPUTextureSampleType_Float: u32 = binding.WGPUTextureSampleType_Float;
pub const WGPUTextureSampleType_UnfilterableFloat: u32 = binding.WGPUTextureSampleType_UnfilterableFloat;
pub const WGPUTextureSampleType_Depth: u32 = binding.WGPUTextureSampleType_Depth;
pub const WGPUTextureSampleType_Sint: u32 = binding.WGPUTextureSampleType_Sint;
pub const WGPUTextureSampleType_Uint: u32 = binding.WGPUTextureSampleType_Uint;
pub const WGPUTextureSampleType_UndefinedDefault: u32 = WGPUTextureSampleType_Undefined;

pub const WGPUStorageTextureAccess_BindingNotUsed: u32 = 0x00000000;
pub const WGPUStorageTextureAccess_Undefined: u32 = binding.WGPUStorageTextureAccess_Undefined;
pub const WGPUStorageTextureAccess_WriteOnly: u32 = binding.WGPUStorageTextureAccess_WriteOnly;
pub const WGPUStorageTextureAccess_ReadOnly: u32 = binding.WGPUStorageTextureAccess_ReadOnly;
pub const WGPUStorageTextureAccess_ReadWrite: u32 = binding.WGPUStorageTextureAccess_ReadWrite;

pub const WGPUBufferBindingType_BindingNotUsed: u32 = 0x00000000;
pub const WGPUBufferBindingType_Undefined: u32 = binding.WGPUBufferBindingType_Undefined;
pub const WGPUBufferBindingType_Uniform: u32 = binding.WGPUBufferBindingType_Uniform;
pub const WGPUBufferBindingType_Storage: u32 = binding.WGPUBufferBindingType_Storage;
pub const WGPUBufferBindingType_ReadOnlyStorage: u32 = binding.WGPUBufferBindingType_ReadOnlyStorage;

pub const WGPUShaderStage_None: core.WGPUFlags = binding.WGPUShaderStage_None;
pub const WGPUShaderStage_Vertex: core.WGPUFlags = binding.WGPUShaderStage_Vertex;
pub const WGPUShaderStage_Fragment: core.WGPUFlags = binding.WGPUShaderStage_Fragment;
pub const WGPUShaderStage_Compute: core.WGPUFlags = binding.WGPUShaderStage_Compute;

pub const WGPUSamplerBindingType_BindingNotUsed: u32 = 0x00000000;
pub const WGPUSamplerBindingType_Undefined: u32 = 0x00000001;
pub const WGPUSamplerBindingType_Filtering: u32 = 0x00000002;
pub const WGPUSamplerBindingType_NonFiltering: u32 = 0x00000003;
pub const WGPUSamplerBindingType_Comparison: u32 = 0x00000004;
