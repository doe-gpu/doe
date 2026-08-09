const abi_core = @import("../core/abi/wgpu_core_base_types.zig");
const abi_callback = @import("../core/abi/wgpu_callback_descriptor_types.zig");
const abi_copy = @import("../core/abi/wgpu_copy_descriptor_types.zig");
const p2life = @import("../core/abi/procs/wgpu_p2_lifecycle_procs.zig");
const surface = @import("../full/surface/wgpu_surface_procs.zig");
const native = @import("../native/mod.zig");
const future_ids = @import("../native/support/doe_future_ids.zig");

extern fn doeNativeBufferGetMapState(raw: ?*anyopaque) callconv(.c) u32;

fn set_local_label(handle: ?*anyopaque, label: abi_core.WGPUStringView) void {
    native.doeNativeObjectSetLabel(handle, label.data, label.length);
}

pub export fn wgpuBindGroupLayoutSetLabel(a0: abi_core.WGPUBindGroupLayout, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuBindGroupSetLabel(a0: abi_core.WGPUBindGroup, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuBufferGetMapState(a0: abi_core.WGPUBuffer) callconv(.c) u32 {
    if (native.cast(native.DoeBuffer, a0) != null) return doeNativeBufferGetMapState(a0);
    return 0;
}

pub export fn wgpuBufferGetMappedRange(a0: abi_core.WGPUBuffer, a1: usize, a2: usize) callconv(.c) ?*anyopaque {
    return native.doeNativeBufferGetMappedRange(a0, a1, a2);
}

pub export fn wgpuBufferGetSize(a0: abi_core.WGPUBuffer) callconv(.c) u64 {
    if (native.cast(native.DoeBuffer, a0)) |buf| return buf.size;
    return 0;
}

pub export fn wgpuBufferGetUsage(a0: abi_core.WGPUBuffer) callconv(.c) abi_core.WGPUBufferUsage {
    if (native.cast(native.DoeBuffer, a0)) |buf| return buf.usage;
    return 0;
}

pub export fn wgpuBufferReadMappedRange(a0: abi_core.WGPUBuffer, a1: usize, a2: ?*anyopaque, a3: usize) callconv(.c) abi_core.WGPUStatus {
    const src_ptr = native.doeNativeBufferGetMappedRange(a0, a1, a3) orelse return 0;
    const dst: [*]u8 = @ptrCast(@alignCast(a2 orelse return 0));
    const src: [*]const u8 = @ptrCast(src_ptr);
    @memcpy(dst[0..a3], src[0..a3]);
    return abi_core.WGPUStatus_Success;
}

pub export fn wgpuBufferSetLabel(a0: abi_core.WGPUBuffer, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuBufferWriteMappedRange(a0: abi_core.WGPUBuffer, a1: usize, a2: ?*const anyopaque, a3: usize) callconv(.c) abi_core.WGPUStatus {
    const dst_ptr = native.doeNativeBufferGetMappedRange(a0, a1, a3) orelse return 0;
    const src: [*]const u8 = @ptrCast(@alignCast(a2 orelse return 0));
    const dst: [*]u8 = @ptrCast(dst_ptr);
    @memcpy(dst[0..a3], src[0..a3]);
    return abi_core.WGPUStatus_Success;
}

pub export fn wgpuCommandBufferSetLabel(a0: abi_core.WGPUCommandBuffer, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuCommandEncoderInsertDebugMarker(a0: abi_core.WGPUCommandEncoder, a1: abi_core.WGPUStringView) callconv(.c) void {
    _ = a0;
    _ = a1;
}

pub export fn wgpuCommandEncoderPopDebugGroup(a0: abi_core.WGPUCommandEncoder) callconv(.c) void {
    _ = a0;
}

pub export fn wgpuCommandEncoderPushDebugGroup(a0: abi_core.WGPUCommandEncoder, a1: abi_core.WGPUStringView) callconv(.c) void {
    _ = a0;
    _ = a1;
}

pub export fn wgpuCommandEncoderSetLabel(a0: abi_core.WGPUCommandEncoder, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuComputePassEncoderInsertDebugMarker(a0: abi_core.WGPUComputePassEncoder, a1: abi_core.WGPUStringView) callconv(.c) void {
    native.doeNativeComputePassInsertDebugMarker(a0, if (a1.data) |d| d else null, a1.length);
}

pub export fn wgpuComputePassEncoderPopDebugGroup(a0: abi_core.WGPUComputePassEncoder) callconv(.c) void {
    native.doeNativeComputePassPopDebugGroup(a0);
}

pub export fn wgpuComputePassEncoderPushDebugGroup(a0: abi_core.WGPUComputePassEncoder, a1: abi_core.WGPUStringView) callconv(.c) void {
    native.doeNativeComputePassPushDebugGroup(a0, if (a1.data) |d| d else null, a1.length);
}

pub export fn wgpuComputePassEncoderSetLabel(a0: abi_core.WGPUComputePassEncoder, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuComputePipelineGetBindGroupLayout(a0: abi_core.WGPUComputePipeline, a1: u32) callconv(.c) abi_core.WGPUBindGroupLayout {
    return @ptrCast(native.doeNativeComputePipelineGetBindGroupLayout(a0, a1));
}

pub export fn wgpuComputePipelineSetLabel(a0: abi_core.WGPUComputePipeline, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuDeviceGetLostFuture(a0: abi_core.WGPUDevice) callconv(.c) abi_core.WGPUFuture {
    return .{ .id = future_ids.device_lost_future_id(a0) };
}

pub export fn wgpuDeviceSetDeviceLostCallback(
    dev_raw: abi_core.WGPUDevice,
    callback: ?abi_callback.WGPUDeviceLostCallback,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    const dev = native.cast(native.DoeDevice, dev_raw) orelse return;
    dev.device_lost_callback = callback;
    dev.device_lost_userdata1 = userdata1;
    dev.device_lost_userdata2 = userdata2;
}

pub export fn wgpuDeviceSetLabel(a0: abi_core.WGPUDevice, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuExternalTextureDestroy(a0: p2life.WGPUExternalTexture) callconv(.c) void {
    native.doeNativeExternalTextureDestroy(a0);
}

pub export fn wgpuExternalTextureExpire(a0: p2life.WGPUExternalTexture) callconv(.c) void {
    native.doeNativeExternalTextureExpire(a0);
}

pub export fn wgpuExternalTextureRefresh(a0: p2life.WGPUExternalTexture) callconv(.c) void {
    native.doeNativeExternalTextureRefresh(a0);
}

pub export fn wgpuExternalTextureRelease(a0: p2life.WGPUExternalTexture) callconv(.c) void {
    native.doeNativeExternalTextureRelease(a0);
}

pub export fn wgpuExternalTextureSetLabel(a0: p2life.WGPUExternalTexture, a1: abi_core.WGPUStringView) callconv(.c) void {
    const data = a1.data orelse return;
    native.doeNativeExternalTextureSetLabel(a0, data, a1.length);
}

pub export fn wgpuPipelineLayoutSetLabel(a0: abi_core.WGPUPipelineLayout, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuQuerySetSetLabel(a0: abi_core.WGPUQuerySet, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuQueueSetLabel(a0: abi_core.WGPUQueue, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuQueueWriteTexture(a0: abi_core.WGPUQueue, a1: *const abi_copy.WGPUTexelCopyTextureInfo, a2: ?*const anyopaque, a3: usize, a4: *const abi_copy.WGPUTexelCopyBufferLayout, a5: *const abi_copy.WGPUExtent3D) callconv(.c) void {
    doeAbiBridgeQueueWriteTexture(a0, a1, a2, a3, a4, a5);
}

pub export fn wgpuQueueCopyExternalTextureForBrowser(
    a0: abi_core.WGPUQueue,
    a1: ?*const abi_copy.WGPUImageCopyExternalTexture,
    a2: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    a3: ?*const abi_copy.WGPUExtent3D,
    a4: ?*const abi_copy.WGPUCopyTextureForBrowserOptions,
) callconv(.c) void {
    native.doeNativeQueueCopyExternalTextureForBrowser(a0, a1, a2, a3, a4);
}

pub export fn wgpuQueueCopyTextureForBrowser(
    a0: abi_core.WGPUQueue,
    a1: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    a2: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    a3: ?*const abi_copy.WGPUExtent3D,
    a4: ?*const abi_copy.WGPUCopyTextureForBrowserOptions,
) callconv(.c) void {
    native.doeNativeQueueCopyTextureForBrowser(a0, a1, a2, a3, a4);
}

/// ABI bridge for wgpuQueueWriteTexture: unpacks struct pointers into the
/// flattened parameter list expected by doeNativeQueueWriteTexture.
pub fn doeAbiBridgeQueueWriteTexture(
    queue: abi_core.WGPUQueue,
    destination: *const abi_copy.WGPUTexelCopyTextureInfo,
    data: ?*const anyopaque,
    data_size: usize,
    data_layout: *const abi_copy.WGPUTexelCopyBufferLayout,
    write_size: *const abi_copy.WGPUExtent3D,
) callconv(.c) void {
    const cmd_texture = @import("../native/resource/doe_command_texture_native.zig");
    const data_ptr: [*]const u8 = if (data) |d| @ptrCast(d) else return;
    cmd_texture.doeNativeQueueWriteTexture(
        queue,
        destination.texture,
        data_ptr,
        data_size,
        data_layout.bytesPerRow,
        data_layout.rowsPerImage,
        destination.origin.x,
        destination.origin.y,
        destination.origin.z,
        destination.mipLevel,
        0, // slice (derived from origin.z for 2D arrays; 0 for simple cases)
        write_size.width,
        write_size.height,
        write_size.depthOrArrayLayers,
    );
}

pub export fn wgpuRenderPassEncoderInsertDebugMarker(a0: abi_core.WGPURenderPassEncoder, a1: abi_core.WGPUStringView) callconv(.c) void {
    _ = a0;
    _ = a1;
}

pub export fn wgpuRenderPassEncoderPopDebugGroup(a0: abi_core.WGPURenderPassEncoder) callconv(.c) void {
    _ = a0;
}

pub export fn wgpuRenderPassEncoderPushDebugGroup(a0: abi_core.WGPURenderPassEncoder, a1: abi_core.WGPUStringView) callconv(.c) void {
    _ = a0;
    _ = a1;
}

pub export fn wgpuRenderPassEncoderSetLabel(a0: abi_core.WGPURenderPassEncoder, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuRenderPipelineSetLabel(a0: abi_core.WGPURenderPipeline, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuSamplerSetLabel(a0: abi_core.WGPUSampler, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuShaderModuleSetLabel(a0: abi_core.WGPUShaderModule, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuSurfaceSetLabel(a0: surface.Surface, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuTextureSetLabel(a0: abi_core.WGPUTexture, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}

pub export fn wgpuTextureViewSetLabel(a0: abi_core.WGPUTextureView, a1: abi_core.WGPUStringView) callconv(.c) void {
    set_local_label(a0, a1);
}
