const core = @import("wgpu_core_base_types.zig");
const texture = @import("wgpu_texture_base_types.zig");
const callbacks = @import("wgpu_callback_descriptor_types.zig");
const upstream = @import("generated/webgpu_upstream.zig");

pub const WGPUExtent3D = upstream.WGPUExtent3D;

pub const WGPUExtent2D = extern struct {
    width: u32,
    height: u32,
};

pub const WGPUOrigin3D = upstream.WGPUOrigin3D;
pub const WGPUTexelCopyBufferLayout = upstream.WGPUTexelCopyBufferLayout;
pub const WGPUTexelCopyBufferInfo = upstream.WGPUTexelCopyBufferInfo;
pub const WGPUTexelCopyTextureInfo = upstream.WGPUTexelCopyTextureInfo;

pub const WGPUCopyTextureForBrowserOptions = extern struct {
    nextInChain: ?*callbacks.WGPUChainedStruct,
    flipY: core.WGPUBool,
    needsColorSpaceConversion: core.WGPUBool,
    srcAlphaMode: core.WGPUAlphaMode,
    srcTransferFunctionParameters: ?[*]const f32,
    conversionMatrix: ?[*]const f32,
    dstTransferFunctionParameters: ?[*]const f32,
    dstAlphaMode: core.WGPUAlphaMode,
    internalUsage: core.WGPUBool,
};

pub const WGPUImageCopyExternalTexture = extern struct {
    nextInChain: ?*callbacks.WGPUChainedStruct,
    externalTexture: core.WGPUExternalTexture,
    origin: WGPUOrigin3D,
    naturalSize: WGPUExtent2D,
};
