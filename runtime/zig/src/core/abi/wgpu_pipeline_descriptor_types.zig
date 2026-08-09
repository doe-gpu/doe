const callbacks = @import("wgpu_callback_descriptor_types.zig");
const core = @import("wgpu_core_base_types.zig");
const texture = @import("wgpu_texture_base_types.zig");
const upstream = @import("generated/webgpu_upstream.zig");

pub const WGPUChainedStruct = upstream.WGPUChainedStruct;

pub const WGPUSType_DawnTextureInternalUsageDescriptor: core.WGPUSType = 0x00050004;

pub const WGPUDawnTextureInternalUsageDescriptor = extern struct {
    chain: WGPUChainedStruct,
    internalUsage: texture.WGPUTextureUsage,
};

pub const WGPUTextureViewDescriptor = upstream.WGPUTextureViewDescriptor;
pub const WGPUTextureComponentSwizzleDescriptor = upstream.WGPUTextureComponentSwizzleDescriptor;
pub const WGPUTextureDescriptor = upstream.WGPUTextureDescriptor;
pub const WGPUBufferBindingLayout = upstream.WGPUBufferBindingLayout;
pub const WGPUSamplerBindingLayout = upstream.WGPUSamplerBindingLayout;
pub const WGPUTextureBindingLayout = upstream.WGPUTextureBindingLayout;
pub const WGPUStorageTextureBindingLayout = upstream.WGPUStorageTextureBindingLayout;
pub const WGPUBindGroupLayoutEntry = upstream.WGPUBindGroupLayoutEntry;
pub const WGPUBindGroupEntry = upstream.WGPUBindGroupEntry;
pub const WGPUExternalTextureBindingLayout = upstream.WGPUExternalTextureBindingLayout;
pub const WGPUExternalTextureBindingEntry = upstream.WGPUExternalTextureBindingEntry;
pub const WGPUBindGroupLayoutDescriptor = upstream.WGPUBindGroupLayoutDescriptor;
pub const WGPUBindGroupDescriptor = upstream.WGPUBindGroupDescriptor;
pub const WGPUPipelineLayoutDescriptor = upstream.WGPUPipelineLayoutDescriptor;
pub const WGPUBufferDescriptor = upstream.WGPUBufferDescriptor;
pub const WGPUShaderModuleDescriptor = upstream.WGPUShaderModuleDescriptor;
pub const WGPUShaderSourceWGSL = upstream.WGPUShaderSourceWGSL;

pub const WGPUShaderSourceMSL = extern struct {
    chain: callbacks.WGPUChainedStruct,
    code: core.WGPUStringView,
    workgroup_size_x: u32,
    workgroup_size_y: u32,
    workgroup_size_z: u32,
};

pub const WGPUShaderSourceSPIRV = upstream.WGPUShaderSourceSPIRV;

pub const WGPUShaderSourceHLSL = extern struct {
    chain: callbacks.WGPUChainedStruct,
    code: core.WGPUStringView,
    workgroup_size_x: u32,
    workgroup_size_y: u32,
    workgroup_size_z: u32,
};

pub const WGPUConstantEntry = upstream.WGPUConstantEntry;
pub const WGPUComputeState = upstream.WGPUComputeState;
pub const WGPUComputePipelineDescriptor = upstream.WGPUComputePipelineDescriptor;
pub const WGPUComputePassDescriptor = upstream.WGPUComputePassDescriptor;
pub const WGPUPassTimestampWrites = upstream.WGPUPassTimestampWrites;
pub const WGPUCommandEncoderDescriptor = upstream.WGPUCommandEncoderDescriptor;
pub const WGPUCommandBufferDescriptor = upstream.WGPUCommandBufferDescriptor;
pub const WGPUQuerySetDescriptor = upstream.WGPUQuerySetDescriptor;
pub const WGPUSamplerDescriptor = upstream.WGPUSamplerDescriptor;
pub const WGPUColor = upstream.WGPUColor;
pub const WGPURenderPassColorAttachment = upstream.WGPURenderPassColorAttachment;
pub const WGPURenderPassDepthStencilAttachment = upstream.WGPURenderPassDepthStencilAttachment;
pub const WGPURenderPassDescriptor = upstream.WGPURenderPassDescriptor;
pub const WGPURenderPassMaxDrawCount = upstream.WGPURenderPassMaxDrawCount;
