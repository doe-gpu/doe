const std = @import("std");
const abi_core = @import("../wgpu_core_base_types.zig");
const abi_texture = @import("../wgpu_texture_base_types.zig");
const abi_copy = @import("../wgpu_copy_descriptor_types.zig");

const FnDeviceCreateSampler = *const fn (abi_core.WGPUDevice, ?*const anyopaque) callconv(.c) abi_core.WGPUSampler;
const FnSamplerRelease = *const fn (abi_core.WGPUSampler) callconv(.c) void;
const FnQueueWriteTexture = *const fn (
    abi_core.WGPUQueue,
    *const abi_copy.WGPUTexelCopyTextureInfo,
    ?*const anyopaque,
    usize,
    *const abi_copy.WGPUTexelCopyBufferLayout,
    *const abi_copy.WGPUExtent3D,
) callconv(.c) void;
const FnTextureDestroy = *const fn (abi_core.WGPUTexture) callconv(.c) void;
const FnTextureGetWidth = *const fn (abi_core.WGPUTexture) callconv(.c) u32;
const FnTextureGetHeight = *const fn (abi_core.WGPUTexture) callconv(.c) u32;
const FnTextureGetDepthOrArrayLayers = *const fn (abi_core.WGPUTexture) callconv(.c) u32;
const FnTextureGetDimension = *const fn (abi_core.WGPUTexture) callconv(.c) abi_texture.WGPUTextureDimension;
const FnTextureGetFormat = *const fn (abi_core.WGPUTexture) callconv(.c) abi_texture.WGPUTextureFormat;
const FnTextureGetMipLevelCount = *const fn (abi_core.WGPUTexture) callconv(.c) u32;
const FnTextureGetSampleCount = *const fn (abi_core.WGPUTexture) callconv(.c) u32;
const FnTextureGetTextureBindingViewDimension = *const fn (abi_core.WGPUTexture) callconv(.c) abi_texture.WGPUTextureViewDimension;
const FnTextureGetUsage = *const fn (abi_core.WGPUTexture) callconv(.c) abi_texture.WGPUTextureUsage;

pub const TextureInfo = struct {
    width: u32,
    height: u32,
    depth_or_array_layers: u32,
    dimension: abi_texture.WGPUTextureDimension,
    format: abi_texture.WGPUTextureFormat,
    mip_level_count: u32,
    sample_count: u32,
    view_dimension: abi_texture.WGPUTextureViewDimension,
    usage: abi_texture.WGPUTextureUsage,
};

pub const TextureProcs = struct {
    device_create_sampler: FnDeviceCreateSampler,
    sampler_release: FnSamplerRelease,
    queue_write_texture: FnQueueWriteTexture,
    texture_destroy: FnTextureDestroy,
    texture_get_width: FnTextureGetWidth,
    texture_get_height: FnTextureGetHeight,
    texture_get_depth_or_array_layers: FnTextureGetDepthOrArrayLayers,
    texture_get_dimension: FnTextureGetDimension,
    texture_get_format: FnTextureGetFormat,
    texture_get_mip_level_count: FnTextureGetMipLevelCount,
    texture_get_sample_count: FnTextureGetSampleCount,
    texture_get_texture_binding_view_dimension: FnTextureGetTextureBindingViewDimension,
    texture_get_usage: FnTextureGetUsage,
};

const LoadState = enum {
    uninitialized,
    unavailable,
    ready,
};

var load_state: LoadState = .uninitialized;
var cached_procs: TextureProcs = undefined;

fn loadProc(comptime T: type, lib: std.DynLib, comptime name: [:0]const u8) ?T {
    var mutable = lib;
    return mutable.lookup(T, name);
}

pub fn loadTextureProcs(dyn_lib: ?std.DynLib) ?TextureProcs {
    switch (load_state) {
        .ready => return cached_procs,
        .unavailable => return null,
        .uninitialized => {},
    }
    const lib = dyn_lib orelse return null;
    const loaded = TextureProcs{
        .device_create_sampler = loadProc(FnDeviceCreateSampler, lib, "wgpuDeviceCreateSampler") orelse return null,
        .sampler_release = loadProc(FnSamplerRelease, lib, "wgpuSamplerRelease") orelse return null,
        .queue_write_texture = loadProc(FnQueueWriteTexture, lib, "wgpuQueueWriteTexture") orelse return null,
        .texture_destroy = loadProc(FnTextureDestroy, lib, "wgpuTextureDestroy") orelse return null,
        .texture_get_width = loadProc(FnTextureGetWidth, lib, "wgpuTextureGetWidth") orelse return null,
        .texture_get_height = loadProc(FnTextureGetHeight, lib, "wgpuTextureGetHeight") orelse return null,
        .texture_get_depth_or_array_layers = loadProc(FnTextureGetDepthOrArrayLayers, lib, "wgpuTextureGetDepthOrArrayLayers") orelse return null,
        .texture_get_dimension = loadProc(FnTextureGetDimension, lib, "wgpuTextureGetDimension") orelse return null,
        .texture_get_format = loadProc(FnTextureGetFormat, lib, "wgpuTextureGetFormat") orelse return null,
        .texture_get_mip_level_count = loadProc(FnTextureGetMipLevelCount, lib, "wgpuTextureGetMipLevelCount") orelse return null,
        .texture_get_sample_count = loadProc(FnTextureGetSampleCount, lib, "wgpuTextureGetSampleCount") orelse return null,
        .texture_get_texture_binding_view_dimension = loadProc(FnTextureGetTextureBindingViewDimension, lib, "wgpuTextureGetTextureBindingViewDimension") orelse return null,
        .texture_get_usage = loadProc(FnTextureGetUsage, lib, "wgpuTextureGetUsage") orelse return null,
    };
    cached_procs = loaded;
    load_state = .ready;
    return loaded;
}

pub fn queryTextureInfo(procs: TextureProcs, texture: abi_core.WGPUTexture) TextureInfo {
    return .{
        .width = procs.texture_get_width(texture),
        .height = procs.texture_get_height(texture),
        .depth_or_array_layers = procs.texture_get_depth_or_array_layers(texture),
        .dimension = procs.texture_get_dimension(texture),
        .format = procs.texture_get_format(texture),
        .mip_level_count = procs.texture_get_mip_level_count(texture),
        .sample_count = procs.texture_get_sample_count(texture),
        .view_dimension = procs.texture_get_texture_binding_view_dimension(texture),
        .usage = procs.texture_get_usage(texture),
    };
}
