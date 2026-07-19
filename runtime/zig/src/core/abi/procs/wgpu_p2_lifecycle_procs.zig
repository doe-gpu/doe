const std = @import("std");
const abi_base = @import("../wgpu_handle_types.zig");

pub const WGPUExternalTexture = ?*anyopaque;
pub const WGPUResourceTable = ?*anyopaque;
pub const WGPUSharedBufferMemory = ?*anyopaque;
pub const WGPUSharedFence = ?*anyopaque;
pub const WGPUSharedTextureMemory = ?*anyopaque;
pub const WGPUSurface = ?*anyopaque;
pub const WGPUTexelBufferView = ?*anyopaque;

pub const FnAdapterAddRef = *const fn (abi_base.WGPUAdapter) callconv(.c) void;
pub const FnBindGroupAddRef = *const fn (abi_base.WGPUBindGroup) callconv(.c) void;
pub const FnBindGroupLayoutAddRef = *const fn (abi_base.WGPUBindGroupLayout) callconv(.c) void;
pub const FnBufferAddRef = *const fn (abi_base.WGPUBuffer) callconv(.c) void;
pub const FnCommandBufferAddRef = *const fn (abi_base.WGPUCommandBuffer) callconv(.c) void;
pub const FnCommandEncoderAddRef = *const fn (abi_base.WGPUCommandEncoder) callconv(.c) void;
pub const FnComputePassEncoderAddRef = *const fn (abi_base.WGPUComputePassEncoder) callconv(.c) void;
pub const FnComputePipelineAddRef = *const fn (abi_base.WGPUComputePipeline) callconv(.c) void;
pub const FnDeviceAddRef = *const fn (abi_base.WGPUDevice) callconv(.c) void;
pub const FnExternalTextureAddRef = *const fn (WGPUExternalTexture) callconv(.c) void;
pub const FnInstanceAddRef = *const fn (abi_base.WGPUInstance) callconv(.c) void;
pub const FnPipelineLayoutAddRef = *const fn (abi_base.WGPUPipelineLayout) callconv(.c) void;
pub const FnQuerySetAddRef = *const fn (abi_base.WGPUQuerySet) callconv(.c) void;
pub const FnQueueAddRef = *const fn (abi_base.WGPUQueue) callconv(.c) void;
pub const FnRenderPassEncoderAddRef = *const fn (abi_base.WGPURenderPassEncoder) callconv(.c) void;
pub const FnRenderPipelineAddRef = *const fn (abi_base.WGPURenderPipeline) callconv(.c) void;
pub const FnResourceTableAddRef = *const fn (WGPUResourceTable) callconv(.c) void;
pub const FnSamplerAddRef = *const fn (abi_base.WGPUSampler) callconv(.c) void;
pub const FnShaderModuleAddRef = *const fn (abi_base.WGPUShaderModule) callconv(.c) void;
pub const FnSharedBufferMemoryAddRef = *const fn (WGPUSharedBufferMemory) callconv(.c) void;
pub const FnSharedFenceAddRef = *const fn (WGPUSharedFence) callconv(.c) void;
pub const FnSharedTextureMemoryAddRef = *const fn (WGPUSharedTextureMemory) callconv(.c) void;
pub const FnSurfaceAddRef = *const fn (WGPUSurface) callconv(.c) void;
pub const FnTexelBufferViewAddRef = *const fn (WGPUTexelBufferView) callconv(.c) void;
pub const FnTextureAddRef = *const fn (abi_base.WGPUTexture) callconv(.c) void;
pub const FnTextureViewAddRef = *const fn (abi_base.WGPUTextureView) callconv(.c) void;

pub const LifecycleProcs = struct {
    adapter_add_ref: ?FnAdapterAddRef = null,
    bind_group_add_ref: ?FnBindGroupAddRef = null,
    bind_group_layout_add_ref: ?FnBindGroupLayoutAddRef = null,
    buffer_add_ref: ?FnBufferAddRef = null,
    command_buffer_add_ref: ?FnCommandBufferAddRef = null,
    command_encoder_add_ref: ?FnCommandEncoderAddRef = null,
    compute_pass_encoder_add_ref: ?FnComputePassEncoderAddRef = null,
    compute_pipeline_add_ref: ?FnComputePipelineAddRef = null,
    device_add_ref: ?FnDeviceAddRef = null,
    external_texture_add_ref: ?FnExternalTextureAddRef = null,
    instance_add_ref: ?FnInstanceAddRef = null,
    pipeline_layout_add_ref: ?FnPipelineLayoutAddRef = null,
    query_set_add_ref: ?FnQuerySetAddRef = null,
    queue_add_ref: ?FnQueueAddRef = null,
    render_pass_encoder_add_ref: ?FnRenderPassEncoderAddRef = null,
    render_pipeline_add_ref: ?FnRenderPipelineAddRef = null,
    resource_table_add_ref: ?FnResourceTableAddRef = null,
    sampler_add_ref: ?FnSamplerAddRef = null,
    shader_module_add_ref: ?FnShaderModuleAddRef = null,
    shared_buffer_memory_add_ref: ?FnSharedBufferMemoryAddRef = null,
    shared_fence_add_ref: ?FnSharedFenceAddRef = null,
    shared_texture_memory_add_ref: ?FnSharedTextureMemoryAddRef = null,
    surface_add_ref: ?FnSurfaceAddRef = null,
    texel_buffer_view_add_ref: ?FnTexelBufferViewAddRef = null,
    texture_add_ref: ?FnTextureAddRef = null,
    texture_view_add_ref: ?FnTextureViewAddRef = null,
};

fn loadProc(comptime T: type, lib: std.DynLib, comptime name: [:0]const u8) ?T {
    var mutable = lib;
    return mutable.lookup(T, name);
}

pub fn loadLifecycleProcs(dyn_lib: ?std.DynLib) ?LifecycleProcs {
    const lib = dyn_lib orelse return null;
    return .{
        .adapter_add_ref = loadProc(FnAdapterAddRef, lib, "wgpuAdapterAddRef"),
        .bind_group_add_ref = loadProc(FnBindGroupAddRef, lib, "wgpuBindGroupAddRef"),
        .bind_group_layout_add_ref = loadProc(FnBindGroupLayoutAddRef, lib, "wgpuBindGroupLayoutAddRef"),
        .buffer_add_ref = loadProc(FnBufferAddRef, lib, "wgpuBufferAddRef"),
        .command_buffer_add_ref = loadProc(FnCommandBufferAddRef, lib, "wgpuCommandBufferAddRef"),
        .command_encoder_add_ref = loadProc(FnCommandEncoderAddRef, lib, "wgpuCommandEncoderAddRef"),
        .compute_pass_encoder_add_ref = loadProc(FnComputePassEncoderAddRef, lib, "wgpuComputePassEncoderAddRef"),
        .compute_pipeline_add_ref = loadProc(FnComputePipelineAddRef, lib, "wgpuComputePipelineAddRef"),
        .device_add_ref = loadProc(FnDeviceAddRef, lib, "wgpuDeviceAddRef"),
        .external_texture_add_ref = loadProc(FnExternalTextureAddRef, lib, "wgpuExternalTextureAddRef"),
        .instance_add_ref = loadProc(FnInstanceAddRef, lib, "wgpuInstanceAddRef"),
        .pipeline_layout_add_ref = loadProc(FnPipelineLayoutAddRef, lib, "wgpuPipelineLayoutAddRef"),
        .query_set_add_ref = loadProc(FnQuerySetAddRef, lib, "wgpuQuerySetAddRef"),
        .queue_add_ref = loadProc(FnQueueAddRef, lib, "wgpuQueueAddRef"),
        .render_pass_encoder_add_ref = loadProc(FnRenderPassEncoderAddRef, lib, "wgpuRenderPassEncoderAddRef"),
        .render_pipeline_add_ref = loadProc(FnRenderPipelineAddRef, lib, "wgpuRenderPipelineAddRef"),
        .resource_table_add_ref = loadProc(FnResourceTableAddRef, lib, "wgpuResourceTableAddRef"),
        .sampler_add_ref = loadProc(FnSamplerAddRef, lib, "wgpuSamplerAddRef"),
        .shader_module_add_ref = loadProc(FnShaderModuleAddRef, lib, "wgpuShaderModuleAddRef"),
        .shared_buffer_memory_add_ref = loadProc(FnSharedBufferMemoryAddRef, lib, "wgpuSharedBufferMemoryAddRef"),
        .shared_fence_add_ref = loadProc(FnSharedFenceAddRef, lib, "wgpuSharedFenceAddRef"),
        .shared_texture_memory_add_ref = loadProc(FnSharedTextureMemoryAddRef, lib, "wgpuSharedTextureMemoryAddRef"),
        .surface_add_ref = loadProc(FnSurfaceAddRef, lib, "wgpuSurfaceAddRef"),
        .texel_buffer_view_add_ref = loadProc(FnTexelBufferViewAddRef, lib, "wgpuTexelBufferViewAddRef"),
        .texture_add_ref = loadProc(FnTextureAddRef, lib, "wgpuTextureAddRef"),
        .texture_view_add_ref = loadProc(FnTextureViewAddRef, lib, "wgpuTextureViewAddRef"),
    };
}

pub fn addRefIfPresent(comptime T: type, proc: ?*const fn (T) callconv(.c) void, object: T) void {
    if (object == null) return;
    if (proc) |add_ref| add_ref(object);
}
