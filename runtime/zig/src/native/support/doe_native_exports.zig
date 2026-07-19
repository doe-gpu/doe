const abi_pipeline = @import("../../core/abi/wgpu_pipeline_descriptor_types.zig");

pub extern fn doeNativeBufferRelease(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeDeviceRelease(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeInstanceRelease(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeTextureRelease(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeTextureViewRelease(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeSamplerRelease(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeExternalTextureAddRef(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeExternalTextureRelease(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeExternalTextureDestroy(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeExternalTextureExpire(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeExternalTextureRefresh(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeExternalTextureSetLabel(raw: ?*anyopaque, label_ptr: [*]const u8, label_len: usize) callconv(.c) void;
pub extern fn doeNativeDeviceCreateCommandEncoder(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUCommandEncoderDescriptor) callconv(.c) ?*anyopaque;
pub extern fn doeNativeCommandEncoderRelease(raw: ?*anyopaque) callconv(.c) void;
pub extern fn doeNativeCommandEncoderFinish(enc_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUCommandBufferDescriptor) callconv(.c) ?*anyopaque;
pub extern fn doeNativeCommandBufferRelease(raw: ?*anyopaque) callconv(.c) void;
