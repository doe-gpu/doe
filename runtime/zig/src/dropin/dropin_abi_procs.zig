const std = @import("std");
const proc_types = @import("../core/abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const ptypes = @import("../wgpu_types_procs.zig");
const native = @import("../doe_wgpu_native.zig");
const native_helpers = @import("../doe_native_object_helpers.zig");
const native_types = @import("../doe_native_object_types.zig");
const queue_flush_breakdown = @import("../doe_queue_flush_breakdown.zig");

const BUFFER_MAP_SYNC_TIMEOUT_NS = 5 * std.time.ns_per_s;
const MAP_READ_COPY_UNMAP_BREAKDOWN_FIELD_COUNT: usize = 6;
const BREAKDOWN_WAIT_COMPLETED_INDEX: usize = 0;
const BREAKDOWN_DEFERRED_COPY_INDEX: usize = 1;
const BREAKDOWN_DEFERRED_RESOLVE_INDEX: usize = 2;
const BREAKDOWN_MAP_INDEX: usize = 3;
const BREAKDOWN_COPY_INDEX: usize = 4;
const BREAKDOWN_UNMAP_INDEX: usize = 5;

extern fn wgpuGetProcAddress(name: abi_base.WGPUStringView) callconv(.c) ?*const fn () callconv(.c) void;

fn loadRequiredProc(comptime FnType: type, comptime symbol_name: [:0]const u8) FnType {
    const proc = wgpuGetProcAddress(.{
        .data = symbol_name.ptr,
        .length = abi_base.WGPU_STRLEN,
    }) orelse std.debug.panic("missing required WebGPU symbol: {s}", .{symbol_name});
    return @ptrCast(proc);
}

const BufferMapSyncResult = struct {
    done: bool = false,
    status: abi_base.WGPUMapAsyncStatus = 0,
};

fn buffer_map_sync_callback(
    status: abi_base.WGPUMapAsyncStatus,
    message: abi_base.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    const raw = userdata1 orelse return;
    const result: *BufferMapSyncResult = @ptrCast(@alignCast(raw));
    result.status = status;
    result.done = true;
}

pub export fn wgpuCreateInstance(a0: ?*anyopaque) callconv(.c) abi_base.WGPUInstance {
    return native.doeNativeCreateInstance(a0);
}

pub export fn wgpuInstanceRequestAdapter(a0: abi_base.WGPUInstance, a1: ?*const abi_descriptor.WGPURequestAdapterOptions, a2: abi_descriptor.WGPURequestAdapterCallbackInfo) callconv(.c) abi_base.WGPUFuture {
    return native.doeNativeInstanceRequestAdapter(a0, a1, a2);
}

pub export fn wgpuInstanceWaitAny(a0: abi_base.WGPUInstance, a1: usize, a2: [*]abi_descriptor.WGPUFutureWaitInfo, a3: u64) callconv(.c) abi_descriptor.WGPUWaitStatus {
    return @enumFromInt(native.doeNativeInstanceWaitAny(a0, a1, a2, a3));
}

pub export fn wgpuInstanceProcessEvents(a0: abi_base.WGPUInstance) callconv(.c) void {
    native.doeNativeInstanceProcessEvents(a0);
}

pub export fn wgpuAdapterRequestDevice(a0: abi_base.WGPUAdapter, a1: ?*const abi_descriptor.WGPUDeviceDescriptor, a2: abi_descriptor.WGPURequestDeviceCallbackInfo) callconv(.c) abi_base.WGPUFuture {
    return native.doeNativeAdapterRequestDevice(a0, a1, a2);
}

pub export fn wgpuAdapterCreateDevice(a0: abi_base.WGPUAdapter, a1: ?*const abi_descriptor.WGPUDeviceDescriptor) callconv(.c) abi_base.WGPUDevice {
    return native.doeNativeAdapterCreateDevice(a0, a1);
}

pub export fn doeNativeQueueFamilyPolicyCode(q_raw: ?*anyopaque) callconv(.c) u32 {
    return native.doeNativeQueueFamilyPolicyCode(q_raw);
}

pub export fn doeNativeQueueDeferredSubmissionSyncPolicyCode(q_raw: ?*anyopaque) callconv(.c) u32 {
    return native.doeNativeQueueDeferredSubmissionSyncPolicyCode(q_raw);
}

pub export fn doeNativeQueueFamilyKindCode(q_raw: ?*anyopaque) callconv(.c) u32 {
    return native.doeNativeQueueFamilyKindCode(q_raw);
}

pub export fn doeNativeQueueFamilyIndex(q_raw: ?*anyopaque) callconv(.c) u32 {
    return native.doeNativeQueueFamilyIndex(q_raw);
}

pub export fn doeNativeQueueFamilyQueueCount(q_raw: ?*anyopaque) callconv(.c) u32 {
    return native.doeNativeQueueFamilyQueueCount(q_raw);
}

pub export fn doeNativeQueueFamilyTimestampValidBits(q_raw: ?*anyopaque) callconv(.c) u32 {
    return native.doeNativeQueueFamilyTimestampValidBits(q_raw);
}

pub export fn doeNativeQueueFamilySupportsGraphics(q_raw: ?*anyopaque) callconv(.c) u32 {
    return native.doeNativeQueueFamilySupportsGraphics(q_raw);
}

pub export fn doeNativeQueuePipelineCacheInfo(q_raw: ?*anyopaque) callconv(.c) u32 {
    return native.doeNativeQueuePipelineCacheInfo(q_raw);
}

pub export fn doeNativeQueuePipelineCacheWarmupCount(q_raw: ?*anyopaque) callconv(.c) u64 {
    return native.doeNativeQueuePipelineCacheWarmupCount(q_raw);
}

pub export fn doeNativeQueuePipelineCacheWarmupNs(q_raw: ?*anyopaque) callconv(.c) u64 {
    return native.doeNativeQueuePipelineCacheWarmupNs(q_raw);
}

pub export fn doeNativeQueuePipelineCacheFlush(q_raw: ?*anyopaque) callconv(.c) void {
    native.doeNativeQueuePipelineCacheFlush(q_raw);
}

// FFI-friendly wrappers: flattened args for runtimes that cannot pass structs by value (Bun FFI, Node ffi-napi).
// These assemble the CallbackInfo struct from scalar args and delegate to the standard C ABI functions.

pub export fn doeRequestAdapterFlat(
    instance: abi_base.WGPUInstance,
    options: ?*const abi_descriptor.WGPURequestAdapterOptions,
    mode: abi_descriptor.WGPUCallbackMode,
    callback: abi_descriptor.WGPURequestAdapterCallback,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) abi_base.WGPUFuture {
    const info = abi_descriptor.WGPURequestAdapterCallbackInfo{
        .nextInChain = null,
        .mode = mode,
        .callback = callback,
        .userdata1 = userdata1,
        .userdata2 = userdata2,
    };
    return native.doeNativeInstanceRequestAdapter(instance, options, info);
}

pub export fn doeRequestDeviceFlat(
    adapter: abi_base.WGPUAdapter,
    descriptor: ?*const abi_descriptor.WGPUDeviceDescriptor,
    mode: abi_descriptor.WGPUCallbackMode,
    callback: abi_descriptor.WGPURequestDeviceCallback,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) abi_base.WGPUFuture {
    const info = abi_descriptor.WGPURequestDeviceCallbackInfo{
        .nextInChain = null,
        .mode = mode,
        .callback = callback,
        .userdata1 = userdata1,
        .userdata2 = userdata2,
    };
    return native.doeNativeAdapterRequestDevice(adapter, descriptor, info);
}

pub export fn wgpuDeviceCreateBuffer(a0: abi_base.WGPUDevice, a1: ?*const abi_descriptor.WGPUBufferDescriptor) callconv(.c) abi_base.WGPUBuffer {
    const proc = loadRequiredProc(ptypes.FnWgpuDeviceCreateBuffer, "wgpuDeviceCreateBuffer");
    return proc(a0, a1);
}

pub export fn wgpuDeviceCreateShaderModule(a0: abi_base.WGPUDevice, a1: ?*const abi_descriptor.WGPUShaderModuleDescriptor) callconv(.c) abi_base.WGPUShaderModule {
    const proc = loadRequiredProc(ptypes.FnWgpuDeviceCreateShaderModule, "wgpuDeviceCreateShaderModule");
    return proc(a0, a1);
}

pub export fn wgpuShaderModuleRelease(a0: abi_base.WGPUShaderModule) callconv(.c) void {
    native.doeNativeShaderModuleRelease(a0);
}

pub export fn wgpuDeviceCreateComputePipeline(a0: abi_base.WGPUDevice, a1: ?*const abi_descriptor.WGPUComputePipelineDescriptor) callconv(.c) abi_base.WGPUComputePipeline {
    const proc = loadRequiredProc(ptypes.FnWgpuDeviceCreateComputePipeline, "wgpuDeviceCreateComputePipeline");
    return proc(a0, a1);
}

pub export fn wgpuComputePipelineRelease(a0: abi_base.WGPUComputePipeline) callconv(.c) void {
    native.doeNativeComputePipelineRelease(a0);
}

pub export fn wgpuRenderPipelineRelease(a0: abi_base.WGPURenderPipeline) callconv(.c) void {
    native.doeNativeRenderPipelineRelease(a0);
}

pub export fn wgpuDeviceCreateCommandEncoder(a0: abi_base.WGPUDevice, a1: ?*const abi_descriptor.WGPUCommandEncoderDescriptor) callconv(.c) abi_base.WGPUCommandEncoder {
    const proc = loadRequiredProc(ptypes.FnWgpuDeviceCreateCommandEncoder, "wgpuDeviceCreateCommandEncoder");
    return proc(a0, a1);
}

pub export fn wgpuCommandEncoderBeginComputePass(a0: abi_base.WGPUCommandEncoder, a1: ?*const abi_descriptor.WGPUComputePassDescriptor) callconv(.c) abi_base.WGPUComputePassEncoder {
    const proc = loadRequiredProc(ptypes.FnWgpuCommandEncoderBeginComputePass, "wgpuCommandEncoderBeginComputePass");
    return proc(a0, a1);
}

pub export fn wgpuDeviceCreateRenderPipeline(a0: abi_base.WGPUDevice, a1: *const anyopaque) callconv(.c) abi_base.WGPURenderPipeline {
    const proc = loadRequiredProc(ptypes.FnWgpuDeviceCreateRenderPipeline, "wgpuDeviceCreateRenderPipeline");
    return proc(a0, a1);
}

pub export fn wgpuCommandEncoderBeginRenderPass(a0: abi_base.WGPUCommandEncoder, a1: *const anyopaque) callconv(.c) abi_base.WGPURenderPassEncoder {
    const proc = loadRequiredProc(ptypes.FnWgpuCommandEncoderBeginRenderPass, "wgpuCommandEncoderBeginRenderPass");
    return proc(a0, a1);
}

pub export fn wgpuCommandEncoderWriteTimestamp(a0: abi_base.WGPUCommandEncoder, a1: abi_base.WGPUQuerySet, a2: u32) callconv(.c) void {
    native.doeNativeCommandEncoderWriteTimestamp(a0, a1, a2);
}

pub export fn wgpuCommandEncoderCopyBufferToBuffer(a0: abi_base.WGPUCommandEncoder, a1: abi_base.WGPUBuffer, a2: u64, a3: abi_base.WGPUBuffer, a4: u64, a5: u64) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuCommandEncoderCopyBufferToBuffer, "wgpuCommandEncoderCopyBufferToBuffer");
    proc(a0, a1, a2, a3, a4, a5);
}

pub export fn wgpuCommandEncoderCopyBufferToTexture(a0: abi_base.WGPUCommandEncoder, a1: *const abi_descriptor.WGPUTexelCopyBufferInfo, a2: *const abi_descriptor.WGPUTexelCopyTextureInfo, a3: *const abi_descriptor.WGPUExtent3D) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuCommandEncoderCopyBufferToTexture, "wgpuCommandEncoderCopyBufferToTexture");
    proc(a0, a1, a2, a3);
}

pub export fn wgpuCommandEncoderCopyTextureToBuffer(a0: abi_base.WGPUCommandEncoder, a1: *const abi_descriptor.WGPUTexelCopyTextureInfo, a2: *const abi_descriptor.WGPUTexelCopyBufferInfo, a3: *const abi_descriptor.WGPUExtent3D) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuCommandEncoderCopyTextureToBuffer, "wgpuCommandEncoderCopyTextureToBuffer");
    proc(a0, a1, a2, a3);
}

pub export fn wgpuCommandEncoderCopyTextureToTexture(a0: abi_base.WGPUCommandEncoder, a1: *const abi_descriptor.WGPUTexelCopyTextureInfo, a2: *const abi_descriptor.WGPUTexelCopyTextureInfo, a3: *const abi_descriptor.WGPUExtent3D) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuCommandEncoderCopyTextureToTexture, "wgpuCommandEncoderCopyTextureToTexture");
    proc(a0, a1, a2, a3);
}

pub export fn wgpuComputePassEncoderSetPipeline(a0: abi_base.WGPUComputePassEncoder, a1: abi_base.WGPUComputePipeline) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuComputePassEncoderSetPipeline, "wgpuComputePassEncoderSetPipeline");
    proc(a0, a1);
}

pub export fn wgpuComputePassEncoderSetBindGroup(a0: abi_base.WGPUComputePassEncoder, a1: u32, a2: abi_base.WGPUBindGroup, a3: usize, a4: ?[*]const u32) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuComputePassEncoderSetBindGroup, "wgpuComputePassEncoderSetBindGroup");
    proc(a0, a1, a2, a3, a4);
}

pub export fn wgpuComputePassEncoderDispatchWorkgroups(a0: abi_base.WGPUComputePassEncoder, a1: u32, a2: u32, a3: u32) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuComputePassEncoderDispatchWorkgroups, "wgpuComputePassEncoderDispatchWorkgroups");
    proc(a0, a1, a2, a3);
}

pub export fn wgpuComputePassEncoderEnd(a0: abi_base.WGPUComputePassEncoder) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuComputePassEncoderEnd, "wgpuComputePassEncoderEnd");
    proc(a0);
}

pub export fn wgpuComputePassEncoderRelease(a0: abi_base.WGPUComputePassEncoder) callconv(.c) void {
    native.doeNativeComputePassRelease(a0);
}

pub export fn wgpuRenderPassEncoderSetPipeline(a0: abi_base.WGPURenderPassEncoder, a1: abi_base.WGPURenderPipeline) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuRenderPassEncoderSetPipeline, "wgpuRenderPassEncoderSetPipeline");
    proc(a0, a1);
}

pub export fn wgpuRenderPassEncoderSetVertexBuffer(a0: abi_base.WGPURenderPassEncoder, a1: u32, a2: abi_base.WGPUBuffer, a3: u64, a4: u64) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuRenderPassEncoderSetVertexBuffer, "wgpuRenderPassEncoderSetVertexBuffer");
    proc(a0, a1, a2, a3, a4);
}

pub export fn wgpuRenderPassEncoderSetIndexBuffer(a0: abi_base.WGPURenderPassEncoder, a1: abi_base.WGPUBuffer, a2: u32, a3: u64, a4: u64) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuRenderPassEncoderSetIndexBuffer, "wgpuRenderPassEncoderSetIndexBuffer");
    proc(a0, a1, a2, a3, a4);
}

pub export fn wgpuRenderPassEncoderSetBindGroup(a0: abi_base.WGPURenderPassEncoder, a1: u32, a2: abi_base.WGPUBindGroup, a3: usize, a4: ?[*]const u32) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuRenderPassEncoderSetBindGroup, "wgpuRenderPassEncoderSetBindGroup");
    proc(a0, a1, a2, a3, a4);
}

pub export fn wgpuRenderPassEncoderDraw(a0: abi_base.WGPURenderPassEncoder, a1: u32, a2: u32, a3: u32, a4: u32) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuRenderPassEncoderDraw, "wgpuRenderPassEncoderDraw");
    proc(a0, a1, a2, a3, a4);
}

pub export fn wgpuRenderPassEncoderDrawIndexed(a0: abi_base.WGPURenderPassEncoder, a1: u32, a2: u32, a3: u32, a4: i32, a5: u32) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuRenderPassEncoderDrawIndexed, "wgpuRenderPassEncoderDrawIndexed");
    proc(a0, a1, a2, a3, a4, a5);
}

pub export fn wgpuRenderPassEncoderDrawIndirect(a0: abi_base.WGPURenderPassEncoder, a1: abi_base.WGPUBuffer, a2: u64) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuRenderPassEncoderDrawIndirect, "wgpuRenderPassEncoderDrawIndirect");
    proc(a0, a1, a2);
}

pub export fn wgpuRenderPassEncoderDrawIndexedIndirect(a0: abi_base.WGPURenderPassEncoder, a1: abi_base.WGPUBuffer, a2: u64) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuRenderPassEncoderDrawIndexedIndirect, "wgpuRenderPassEncoderDrawIndexedIndirect");
    proc(a0, a1, a2);
}

pub export fn wgpuRenderPassEncoderEnd(a0: abi_base.WGPURenderPassEncoder) callconv(.c) void {
    const proc = loadRequiredProc(ptypes.FnWgpuRenderPassEncoderEnd, "wgpuRenderPassEncoderEnd");
    proc(a0);
}

pub export fn wgpuRenderPassEncoderRelease(a0: abi_base.WGPURenderPassEncoder) callconv(.c) void {
    native.doeNativeRenderPassRelease(a0);
}

pub export fn wgpuCommandEncoderFinish(a0: abi_base.WGPUCommandEncoder, a1: ?*const abi_descriptor.WGPUCommandBufferDescriptor) callconv(.c) abi_base.WGPUCommandBuffer {
    const proc = loadRequiredProc(ptypes.FnWgpuCommandEncoderFinish, "wgpuCommandEncoderFinish");
    return proc(a0, a1);
}

pub export fn wgpuDeviceGetQueue(a0: abi_base.WGPUDevice) callconv(.c) abi_base.WGPUQueue {
    return native.doeNativeDeviceGetQueue(a0);
}

pub export fn wgpuQueueSubmit(a0: abi_base.WGPUQueue, a1: usize, a2: [*c]abi_base.WGPUCommandBuffer) callconv(.c) void {
    native.doeNativeQueueSubmit(a0, a1, a2);
}

pub export fn doeQueueSubmitOneAndRelease(
    queue: abi_base.WGPUQueue,
    command_buffer: abi_base.WGPUCommandBuffer,
) callconv(.c) void {
    var command_buffers = [_]abi_base.WGPUCommandBuffer{command_buffer};
    native.doeNativeQueueSubmit(queue, command_buffers.len, &command_buffers);
    native.doeNativeCommandBufferRelease(command_buffer);
}

pub export fn wgpuQueueOnSubmittedWorkDone(a0: abi_base.WGPUQueue, a1: abi_descriptor.WGPUQueueWorkDoneCallbackInfo) callconv(.c) abi_base.WGPUFuture {
    return native.doeNativeQueueOnSubmittedWorkDone(a0, a1);
}

pub export fn wgpuQueueWriteBuffer(a0: abi_base.WGPUQueue, a1: abi_base.WGPUBuffer, a2: u64, a3: ?*const anyopaque, a4: usize) callconv(.c) void {
    const data = a3 orelse return;
    native.doeNativeQueueWriteBuffer(a0, a1, a2, @ptrCast(data), a4);
}

pub export fn wgpuDeviceCreateTexture(a0: abi_base.WGPUDevice, a1: ?*const abi_descriptor.WGPUTextureDescriptor) callconv(.c) abi_base.WGPUTexture {
    const proc = loadRequiredProc(ptypes.FnWgpuDeviceCreateTexture, "wgpuDeviceCreateTexture");
    return proc(a0, a1);
}

pub export fn wgpuDeviceValidateTextureDescriptor(a0: abi_base.WGPUDevice, a1: ?*const abi_descriptor.WGPUTextureDescriptor) callconv(.c) void {
    const Fn = *const fn (abi_base.WGPUDevice, ?*const abi_descriptor.WGPUTextureDescriptor) callconv(.c) void;
    const proc = loadRequiredProc(Fn, "wgpuDeviceValidateTextureDescriptor");
    proc(a0, a1);
}

pub export fn wgpuTextureCreateView(a0: abi_base.WGPUTexture, a1: ?*const abi_descriptor.WGPUTextureViewDescriptor) callconv(.c) abi_base.WGPUTextureView {
    const proc = loadRequiredProc(ptypes.FnWgpuTextureCreateView, "wgpuTextureCreateView");
    return proc(a0, a1);
}

pub export fn wgpuDeviceCreateBindGroupLayout(a0: abi_base.WGPUDevice, a1: ?*const abi_descriptor.WGPUBindGroupLayoutDescriptor) callconv(.c) abi_base.WGPUBindGroupLayout {
    const proc = loadRequiredProc(ptypes.FnWgpuDeviceCreateBindGroupLayout, "wgpuDeviceCreateBindGroupLayout");
    return proc(a0, a1);
}

pub export fn wgpuBindGroupLayoutRelease(a0: abi_base.WGPUBindGroupLayout) callconv(.c) void {
    native.doeNativeBindGroupLayoutRelease(a0);
}

pub export fn wgpuDeviceCreateBindGroup(a0: abi_base.WGPUDevice, a1: ?*const abi_descriptor.WGPUBindGroupDescriptor) callconv(.c) abi_base.WGPUBindGroup {
    const proc = loadRequiredProc(ptypes.FnWgpuDeviceCreateBindGroup, "wgpuDeviceCreateBindGroup");
    return proc(a0, a1);
}

pub export fn wgpuBindGroupRelease(a0: abi_base.WGPUBindGroup) callconv(.c) void {
    native.doeNativeBindGroupRelease(a0);
}

pub export fn wgpuDeviceCreatePipelineLayout(a0: abi_base.WGPUDevice, a1: *const abi_descriptor.WGPUPipelineLayoutDescriptor) callconv(.c) abi_base.WGPUPipelineLayout {
    const proc = loadRequiredProc(ptypes.FnWgpuDeviceCreatePipelineLayout, "wgpuDeviceCreatePipelineLayout");
    return proc(a0, a1);
}

pub export fn wgpuPipelineLayoutRelease(a0: abi_base.WGPUPipelineLayout) callconv(.c) void {
    native.doeNativePipelineLayoutRelease(a0);
}

pub export fn wgpuTextureRelease(a0: abi_base.WGPUTexture) callconv(.c) void {
    native.doeNativeTextureRelease(a0);
}

pub export fn wgpuTextureViewRelease(a0: abi_base.WGPUTextureView) callconv(.c) void {
    native.doeNativeTextureViewRelease(a0);
}

pub export fn wgpuInstanceRelease(a0: abi_base.WGPUInstance) callconv(.c) void {
    native.doeNativeInstanceRelease(a0);
}

pub export fn wgpuAdapterRelease(a0: abi_base.WGPUAdapter) callconv(.c) void {
    native.doeNativeAdapterRelease(a0);
}

pub export fn wgpuDeviceRelease(a0: abi_base.WGPUDevice) callconv(.c) void {
    native.doeNativeDeviceRelease(a0);
}

pub export fn wgpuQueueRelease(a0: abi_base.WGPUQueue) callconv(.c) void {
    native.doeNativeQueueRelease(a0);
}

pub export fn wgpuCommandEncoderRelease(a0: abi_base.WGPUCommandEncoder) callconv(.c) void {
    native.doeNativeCommandEncoderRelease(a0);
}

pub export fn wgpuCommandBufferRelease(a0: abi_base.WGPUCommandBuffer) callconv(.c) void {
    native.doeNativeCommandBufferRelease(a0);
}

pub export fn wgpuBufferRelease(a0: abi_base.WGPUBuffer) callconv(.c) void {
    native.doeNativeBufferRelease(a0);
}

pub export fn wgpuAdapterHasFeature(a0: abi_base.WGPUAdapter, a1: abi_base.WGPUFeatureName) callconv(.c) abi_base.WGPUBool {
    return native.doeNativeAdapterHasFeature(a0, a1);
}

pub export fn wgpuDeviceHasFeature(a0: abi_base.WGPUDevice, a1: abi_base.WGPUFeatureName) callconv(.c) abi_base.WGPUBool {
    return native.doeNativeDeviceHasFeature(a0, a1);
}

pub export fn wgpuDeviceCreateQuerySet(a0: abi_base.WGPUDevice, a1: *const abi_descriptor.WGPUQuerySetDescriptor) callconv(.c) abi_base.WGPUQuerySet {
    return native.doeNativeDeviceCreateQuerySet(a0, a1.type, a1.count);
}

pub export fn wgpuCommandEncoderResolveQuerySet(a0: abi_base.WGPUCommandEncoder, a1: abi_base.WGPUQuerySet, a2: u32, a3: u32, a4: abi_base.WGPUBuffer, a5: u64) callconv(.c) void {
    native.doeNativeCommandEncoderResolveQuerySet(a0, a1, a2, a3, a4, a5);
}

pub export fn wgpuQuerySetRelease(a0: abi_base.WGPUQuerySet) callconv(.c) void {
    native.doeNativeQuerySetRelease(a0);
}

pub export fn wgpuBufferMapAsync(a0: abi_base.WGPUBuffer, a1: abi_base.WGPUMapMode, a2: usize, a3: usize, a4: abi_descriptor.WGPUBufferMapCallbackInfo) callconv(.c) abi_base.WGPUFuture {
    return native.doeNativeBufferMapAsync(a0, a1, a2, a3, a4);
}

// FFI-friendly buffer map: flattened args for runtimes that cannot pass WGPUBufferMapCallbackInfo by value.
pub export fn doeBufferMapAsyncFlat(
    buffer: abi_base.WGPUBuffer,
    mode: abi_base.WGPUMapMode,
    offset: usize,
    size: usize,
    cb_mode: abi_descriptor.WGPUCallbackMode,
    callback: abi_descriptor.WGPUBufferMapCallback,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) abi_base.WGPUFuture {
    const info = abi_descriptor.WGPUBufferMapCallbackInfo{
        .nextInChain = null,
        .mode = cb_mode,
        .callback = callback,
        .userdata1 = userdata1,
        .userdata2 = userdata2,
    };
    return native.doeNativeBufferMapAsync(buffer, mode, offset, size, info);
}

pub export fn doeBufferMapSyncFlat(
    instance: abi_base.WGPUInstance,
    buffer: abi_base.WGPUBuffer,
    mode: abi_base.WGPUMapMode,
    offset: usize,
    size: usize,
) callconv(.c) abi_base.WGPUMapAsyncStatus {
    var result = BufferMapSyncResult{};
    const info = abi_descriptor.WGPUBufferMapCallbackInfo{
        .nextInChain = null,
        .mode = abi_descriptor.WGPUCallbackMode_AllowProcessEvents,
        .callback = buffer_map_sync_callback,
        .userdata1 = @ptrCast(&result),
        .userdata2 = null,
    };
    const future = native.doeNativeBufferMapAsync(buffer, mode, offset, size, info);
    if (future.id == 0) return 0;
    const process_events = loadRequiredProc(ptypes.FnWgpuInstanceProcessEvents, "wgpuInstanceProcessEvents");
    const start_ns = std.time.nanoTimestamp();
    while (!result.done) {
        process_events(instance);
        if (std.time.nanoTimestamp() - start_ns >= BUFFER_MAP_SYNC_TIMEOUT_NS) return 0;
    }
    return result.status;
}

pub export fn doeBufferMapReadCopyUnmapFlat(
    queue: abi_base.WGPUQueue,
    buffer: abi_base.WGPUBuffer,
    mode: abi_base.WGPUMapMode,
    offset: usize,
    size: usize,
    should_flush: u32,
    dst_ptr: ?*anyopaque,
    breakdown_ptr: ?[*]u64,
) callconv(.c) abi_base.WGPUStatus {
    const dst_raw = dst_ptr orelse return 0;
    if (mode != abi_base.WGPUMapMode_Read) return 0;
    const wants_breakdown = breakdown_ptr != null;
    if (breakdown_ptr) |breakdown| {
        for (0..MAP_READ_COPY_UNMAP_BREAKDOWN_FIELD_COUNT) |index| {
            breakdown[index] = 0;
        }
    }

    if (should_flush != 0) {
        if (native_helpers.cast(native_types.DoeQueue, queue)) |q| {
            if (q.dev.backend == .metal) {
                const dst: [*]u8 = @ptrCast(dst_raw);
                const flush = queue_flush_breakdown.flushPendingWorkTimedDirectReadback(q, buffer, offset, size, dst);
                if (breakdown_ptr) |breakdown| {
                    breakdown[BREAKDOWN_WAIT_COMPLETED_INDEX] = flush.breakdown.waitCompletedNs;
                    breakdown[BREAKDOWN_DEFERRED_COPY_INDEX] = flush.breakdown.deferredCopyNs;
                    breakdown[BREAKDOWN_DEFERRED_RESOLVE_INDEX] = flush.breakdown.deferredResolveNs;
                }
                if (flush.copied_direct) return abi_base.WGPUStatus_Success;
            } else if (wants_breakdown) {
                var wait_completed_ns: u64 = 0;
                var deferred_copy_ns: u64 = 0;
                var deferred_resolve_ns: u64 = 0;
                native.doeNativeQueueFlushBreakdown(
                    queue,
                    &wait_completed_ns,
                    &deferred_copy_ns,
                    &deferred_resolve_ns,
                );
                if (breakdown_ptr) |breakdown| {
                    breakdown[BREAKDOWN_WAIT_COMPLETED_INDEX] = wait_completed_ns;
                    breakdown[BREAKDOWN_DEFERRED_COPY_INDEX] = deferred_copy_ns;
                    breakdown[BREAKDOWN_DEFERRED_RESOLVE_INDEX] = deferred_resolve_ns;
                }
            } else {
                native.doeNativeQueueFlush(queue);
            }
        } else if (wants_breakdown) {
            var wait_completed_ns: u64 = 0;
            var deferred_copy_ns: u64 = 0;
            var deferred_resolve_ns: u64 = 0;
            native.doeNativeQueueFlushBreakdown(
                queue,
                &wait_completed_ns,
                &deferred_copy_ns,
                &deferred_resolve_ns,
            );
            if (breakdown_ptr) |breakdown| {
                breakdown[BREAKDOWN_WAIT_COMPLETED_INDEX] = wait_completed_ns;
                breakdown[BREAKDOWN_DEFERRED_COPY_INDEX] = deferred_copy_ns;
                breakdown[BREAKDOWN_DEFERRED_RESOLVE_INDEX] = deferred_resolve_ns;
            }
        } else {
            native.doeNativeQueueFlush(queue);
        }
    }

    var result = BufferMapSyncResult{};
    const info = abi_descriptor.WGPUBufferMapCallbackInfo{
        .nextInChain = null,
        .mode = abi_descriptor.WGPUCallbackMode_AllowProcessEvents,
        .callback = buffer_map_sync_callback,
        .userdata1 = @ptrCast(&result),
        .userdata2 = null,
    };
    const map_started_ns = if (wants_breakdown) std.time.nanoTimestamp() else 0;
    const future = native.doeNativeBufferMapAsync(buffer, mode, offset, size, info);
    if (future.id == 0 or !result.done or result.status != abi_base.WGPUMapAsyncStatus_Success) {
        return 0;
    }
    if (breakdown_ptr) |breakdown| {
        breakdown[BREAKDOWN_MAP_INDEX] = @intCast(std.time.nanoTimestamp() - map_started_ns);
    }

    const copy_started_ns = if (wants_breakdown) std.time.nanoTimestamp() else 0;
    const src_ptr = native.doeNativeBufferGetConstMappedRange(buffer, offset, size) orelse {
        native.doeNativeBufferUnmap(buffer);
        return 0;
    };
    const src: [*]const u8 = @ptrCast(src_ptr);
    const dst: [*]u8 = @ptrCast(dst_raw);
    @memcpy(dst[0..size], src[0..size]);
    if (breakdown_ptr) |breakdown| {
        breakdown[BREAKDOWN_COPY_INDEX] = @intCast(std.time.nanoTimestamp() - copy_started_ns);
    }

    const unmap_started_ns = if (wants_breakdown) std.time.nanoTimestamp() else 0;
    native.doeNativeBufferUnmap(buffer);
    if (breakdown_ptr) |breakdown| {
        breakdown[BREAKDOWN_UNMAP_INDEX] = @intCast(std.time.nanoTimestamp() - unmap_started_ns);
    }
    return abi_base.WGPUStatus_Success;
}

// FFI-friendly queue work-done: flattened args for runtimes that cannot pass WGPUQueueWorkDoneCallbackInfo by value.
pub export fn doeQueueOnSubmittedWorkDoneFlat(
    queue: abi_base.WGPUQueue,
    cb_mode: abi_descriptor.WGPUCallbackMode,
    callback: abi_descriptor.WGPUQueueWorkDoneCallback,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) abi_base.WGPUFuture {
    const info = abi_descriptor.WGPUQueueWorkDoneCallbackInfo{
        .nextInChain = null,
        .mode = cb_mode,
        .callback = callback,
        .userdata1 = userdata1,
        .userdata2 = userdata2,
    };
    return native.doeNativeQueueOnSubmittedWorkDone(queue, info);
}

pub export fn wgpuBufferGetConstMappedRange(a0: abi_base.WGPUBuffer, a1: usize, a2: usize) callconv(.c) ?*const anyopaque {
    return native.doeNativeBufferGetConstMappedRange(a0, a1, a2);
}

pub export fn wgpuBufferUnmap(a0: abi_base.WGPUBuffer) callconv(.c) void {
    native.doeNativeBufferUnmap(a0);
}

pub export fn wgpuDeviceCreateSampler(a0: abi_base.WGPUDevice, a1: ?*const abi_descriptor.WGPUSamplerDescriptor) callconv(.c) abi_base.WGPUSampler {
    const proc = loadRequiredProc(ptypes.FnWgpuDeviceCreateSampler, "wgpuDeviceCreateSampler");
    return proc(a0, a1);
}

pub export fn wgpuSamplerRelease(a0: abi_base.WGPUSampler) callconv(.c) void {
    native.doeNativeSamplerRelease(a0);
}
