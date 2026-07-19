const std = @import("std");
const proc_types = @import("../wgpu_proc_types.zig");
const types = struct {
    pub const WGPUAdapter = proc_types.base.WGPUAdapter;
    pub const WGPUBindGroup = proc_types.base.WGPUBindGroup;
    pub const WGPUBindGroupDescriptor = proc_types.descriptor.WGPUBindGroupDescriptor;
    pub const WGPUBindGroupLayout = proc_types.base.WGPUBindGroupLayout;
    pub const WGPUBindGroupLayoutDescriptor = proc_types.descriptor.WGPUBindGroupLayoutDescriptor;
    pub const WGPUBool = proc_types.base.WGPUBool;
    pub const WGPUBuffer = proc_types.base.WGPUBuffer;
    pub const WGPUBufferDescriptor = proc_types.descriptor.WGPUBufferDescriptor;
    pub const WGPUBufferMapCallbackInfo = proc_types.descriptor.WGPUBufferMapCallbackInfo;
    pub const WGPUCommandBuffer = proc_types.base.WGPUCommandBuffer;
    pub const WGPUCommandBufferDescriptor = proc_types.descriptor.WGPUCommandBufferDescriptor;
    pub const WGPUCommandEncoder = proc_types.base.WGPUCommandEncoder;
    pub const WGPUCommandEncoderDescriptor = proc_types.descriptor.WGPUCommandEncoderDescriptor;
    pub const WGPUComputePassDescriptor = proc_types.descriptor.WGPUComputePassDescriptor;
    pub const WGPUComputePassEncoder = proc_types.base.WGPUComputePassEncoder;
    pub const WGPUComputePipeline = proc_types.base.WGPUComputePipeline;
    pub const WGPUComputePipelineDescriptor = proc_types.descriptor.WGPUComputePipelineDescriptor;
    pub const WGPUDevice = proc_types.base.WGPUDevice;
    pub const WGPUDeviceDescriptor = proc_types.descriptor.WGPUDeviceDescriptor;
    pub const WGPUExtent3D = proc_types.descriptor.WGPUExtent3D;
    pub const WGPUFeatureName = proc_types.base.WGPUFeatureName;
    pub const WGPUFuture = proc_types.base.WGPUFuture;
    pub const WGPUFutureWaitInfo = proc_types.descriptor.WGPUFutureWaitInfo;
    pub const WGPUInstance = proc_types.base.WGPUInstance;
    pub const WGPUMapMode = proc_types.base.WGPUMapMode;
    pub const WGPUPipelineLayout = proc_types.base.WGPUPipelineLayout;
    pub const WGPUPipelineLayoutDescriptor = proc_types.descriptor.WGPUPipelineLayoutDescriptor;
    pub const WGPUQuerySet = proc_types.base.WGPUQuerySet;
    pub const WGPUQuerySetDescriptor = proc_types.descriptor.WGPUQuerySetDescriptor;
    pub const WGPUQueue = proc_types.base.WGPUQueue;
    pub const WGPUQueueWorkDoneCallbackInfo = proc_types.descriptor.WGPUQueueWorkDoneCallbackInfo;
    pub const WGPURenderPassEncoder = proc_types.base.WGPURenderPassEncoder;
    pub const WGPURenderPipeline = proc_types.base.WGPURenderPipeline;
    pub const WGPURequestAdapterCallbackInfo = proc_types.descriptor.WGPURequestAdapterCallbackInfo;
    pub const WGPURequestAdapterOptions = proc_types.descriptor.WGPURequestAdapterOptions;
    pub const WGPURequestDeviceCallbackInfo = proc_types.descriptor.WGPURequestDeviceCallbackInfo;
    pub const WGPUSampler = proc_types.base.WGPUSampler;
    pub const WGPUSamplerDescriptor = proc_types.descriptor.WGPUSamplerDescriptor;
    pub const WGPUShaderModule = proc_types.base.WGPUShaderModule;
    pub const WGPUShaderModuleDescriptor = proc_types.descriptor.WGPUShaderModuleDescriptor;
    pub const WGPUTexelCopyBufferInfo = proc_types.descriptor.WGPUTexelCopyBufferInfo;
    pub const WGPUTexelCopyTextureInfo = proc_types.descriptor.WGPUTexelCopyTextureInfo;
    pub const WGPUTexture = proc_types.base.WGPUTexture;
    pub const WGPUTextureDescriptor = proc_types.descriptor.WGPUTextureDescriptor;
    pub const WGPUTextureView = proc_types.base.WGPUTextureView;
    pub const WGPUTextureViewDescriptor = proc_types.descriptor.WGPUTextureViewDescriptor;
    pub const WGPUWaitStatus = proc_types.descriptor.WGPUWaitStatus;
};

pub const FnWgpuCreateInstance = *const fn (?*anyopaque) callconv(.c) types.WGPUInstance;
pub const FnWgpuInstanceRequestAdapter = *const fn (types.WGPUInstance, ?*const types.WGPURequestAdapterOptions, types.WGPURequestAdapterCallbackInfo) callconv(.c) types.WGPUFuture;
pub const FnWgpuInstanceWaitAny = *const fn (types.WGPUInstance, usize, [*]types.WGPUFutureWaitInfo, u64) callconv(.c) types.WGPUWaitStatus;
pub const FnWgpuInstanceProcessEvents = *const fn (types.WGPUInstance) callconv(.c) void;
pub const FnWgpuAdapterRequestDevice = *const fn (types.WGPUAdapter, ?*const types.WGPUDeviceDescriptor, types.WGPURequestDeviceCallbackInfo) callconv(.c) types.WGPUFuture;
pub const FnWgpuDeviceCreateBuffer = *const fn (types.WGPUDevice, ?*const types.WGPUBufferDescriptor) callconv(.c) types.WGPUBuffer;
pub const FnWgpuDeviceCreateShaderModule = *const fn (types.WGPUDevice, ?*const types.WGPUShaderModuleDescriptor) callconv(.c) types.WGPUShaderModule;
pub const FnWgpuShaderModuleRelease = *const fn (types.WGPUShaderModule) callconv(.c) void;
pub const FnWgpuDeviceCreateComputePipeline = *const fn (types.WGPUDevice, ?*const types.WGPUComputePipelineDescriptor) callconv(.c) types.WGPUComputePipeline;
pub const FnWgpuComputePipelineRelease = *const fn (types.WGPUComputePipeline) callconv(.c) void;
pub const FnWgpuRenderPipelineRelease = *const fn (types.WGPURenderPipeline) callconv(.c) void;
pub const FnWgpuDeviceCreateCommandEncoder = *const fn (types.WGPUDevice, ?*const types.WGPUCommandEncoderDescriptor) callconv(.c) types.WGPUCommandEncoder;
pub const FnWgpuCommandEncoderBeginComputePass = *const fn (types.WGPUCommandEncoder, ?*const types.WGPUComputePassDescriptor) callconv(.c) types.WGPUComputePassEncoder;
pub const FnWgpuDeviceCreateRenderPipeline = *const fn (types.WGPUDevice, *const anyopaque) callconv(.c) types.WGPURenderPipeline;
pub const FnWgpuCommandEncoderBeginRenderPass = *const fn (types.WGPUCommandEncoder, *const anyopaque) callconv(.c) types.WGPURenderPassEncoder;
pub const FnWgpuCommandEncoderWriteTimestamp = *const fn (types.WGPUCommandEncoder, types.WGPUQuerySet, u32) callconv(.c) void;
pub const FnWgpuCommandEncoderCopyBufferToBuffer = *const fn (types.WGPUCommandEncoder, types.WGPUBuffer, u64, types.WGPUBuffer, u64, u64) callconv(.c) void;
pub const FnWgpuCommandEncoderCopyBufferToTexture = *const fn (types.WGPUCommandEncoder, *const types.WGPUTexelCopyBufferInfo, *const types.WGPUTexelCopyTextureInfo, *const types.WGPUExtent3D) callconv(.c) void;
pub const FnWgpuCommandEncoderCopyTextureToBuffer = *const fn (types.WGPUCommandEncoder, *const types.WGPUTexelCopyTextureInfo, *const types.WGPUTexelCopyBufferInfo, *const types.WGPUExtent3D) callconv(.c) void;
pub const FnWgpuCommandEncoderCopyTextureToTexture = *const fn (types.WGPUCommandEncoder, *const types.WGPUTexelCopyTextureInfo, *const types.WGPUTexelCopyTextureInfo, *const types.WGPUExtent3D) callconv(.c) void;
pub const FnWgpuComputePassEncoderSetPipeline = *const fn (types.WGPUComputePassEncoder, types.WGPUComputePipeline) callconv(.c) void;
pub const FnWgpuComputePassEncoderSetBindGroup = *const fn (types.WGPUComputePassEncoder, u32, types.WGPUBindGroup, usize, ?[*]const u32) callconv(.c) void;
pub const FnWgpuComputePassEncoderDispatchWorkgroups = *const fn (types.WGPUComputePassEncoder, u32, u32, u32) callconv(.c) void;
pub const FnWgpuComputePassEncoderEnd = *const fn (types.WGPUComputePassEncoder) callconv(.c) void;
pub const FnWgpuComputePassEncoderRelease = *const fn (types.WGPUComputePassEncoder) callconv(.c) void;
pub const FnWgpuRenderPassEncoderSetPipeline = *const fn (types.WGPURenderPassEncoder, types.WGPURenderPipeline) callconv(.c) void;
pub const FnWgpuRenderPassEncoderSetVertexBuffer = *const fn (types.WGPURenderPassEncoder, u32, types.WGPUBuffer, u64, u64) callconv(.c) void;
pub const FnWgpuRenderPassEncoderSetIndexBuffer = *const fn (types.WGPURenderPassEncoder, types.WGPUBuffer, u32, u64, u64) callconv(.c) void;
pub const FnWgpuRenderPassEncoderSetBindGroup = *const fn (types.WGPURenderPassEncoder, u32, types.WGPUBindGroup, usize, ?[*]const u32) callconv(.c) void;
pub const FnWgpuRenderPassEncoderDraw = *const fn (types.WGPURenderPassEncoder, u32, u32, u32, u32) callconv(.c) void;
pub const FnWgpuRenderPassEncoderDrawIndexed = *const fn (types.WGPURenderPassEncoder, u32, u32, u32, i32, u32) callconv(.c) void;
pub const FnWgpuRenderPassEncoderDrawIndirect = *const fn (types.WGPURenderPassEncoder, types.WGPUBuffer, u64) callconv(.c) void;
pub const FnWgpuRenderPassEncoderDrawIndexedIndirect = *const fn (types.WGPURenderPassEncoder, types.WGPUBuffer, u64) callconv(.c) void;
pub const FnWgpuRenderPassEncoderEnd = *const fn (types.WGPURenderPassEncoder) callconv(.c) void;
pub const FnWgpuRenderPassEncoderRelease = *const fn (types.WGPURenderPassEncoder) callconv(.c) void;
pub const FnWgpuCommandEncoderFinish = *const fn (types.WGPUCommandEncoder, ?*const types.WGPUCommandBufferDescriptor) callconv(.c) types.WGPUCommandBuffer;
pub const FnWgpuDeviceGetQueue = *const fn (types.WGPUDevice) callconv(.c) types.WGPUQueue;
pub const FnWgpuQueueSubmit = *const fn (types.WGPUQueue, usize, [*c]types.WGPUCommandBuffer) callconv(.c) void;
pub const FnWgpuQueueOnSubmittedWorkDone = *const fn (types.WGPUQueue, types.WGPUQueueWorkDoneCallbackInfo) callconv(.c) types.WGPUFuture;
pub const FnWgpuQueueWriteBuffer = *const fn (types.WGPUQueue, types.WGPUBuffer, u64, ?*const anyopaque, usize) callconv(.c) void;
pub const FnWgpuDeviceCreateTexture = *const fn (types.WGPUDevice, ?*const types.WGPUTextureDescriptor) callconv(.c) types.WGPUTexture;
pub const FnWgpuTextureCreateView = *const fn (types.WGPUTexture, ?*const types.WGPUTextureViewDescriptor) callconv(.c) types.WGPUTextureView;
pub const FnWgpuDeviceCreateBindGroupLayout = *const fn (types.WGPUDevice, ?*const types.WGPUBindGroupLayoutDescriptor) callconv(.c) types.WGPUBindGroupLayout;
pub const FnWgpuBindGroupLayoutRelease = *const fn (types.WGPUBindGroupLayout) callconv(.c) void;
pub const FnWgpuDeviceCreateBindGroup = *const fn (types.WGPUDevice, ?*const types.WGPUBindGroupDescriptor) callconv(.c) types.WGPUBindGroup;
pub const FnWgpuBindGroupRelease = *const fn (types.WGPUBindGroup) callconv(.c) void;
pub const FnWgpuDeviceCreatePipelineLayout = *const fn (types.WGPUDevice, *const types.WGPUPipelineLayoutDescriptor) callconv(.c) types.WGPUPipelineLayout;
pub const FnWgpuPipelineLayoutRelease = *const fn (types.WGPUPipelineLayout) callconv(.c) void;
pub const FnWgpuTextureRelease = *const fn (types.WGPUTexture) callconv(.c) void;
pub const FnWgpuTextureViewRelease = *const fn (types.WGPUTextureView) callconv(.c) void;
pub const FnWgpuInstanceRelease = *const fn (types.WGPUInstance) callconv(.c) void;
pub const FnWgpuAdapterRelease = *const fn (types.WGPUAdapter) callconv(.c) void;
pub const FnWgpuDeviceRelease = *const fn (types.WGPUDevice) callconv(.c) void;
pub const FnWgpuQueueRelease = *const fn (types.WGPUQueue) callconv(.c) void;
pub const FnWgpuCommandEncoderRelease = *const fn (types.WGPUCommandEncoder) callconv(.c) void;
pub const FnWgpuCommandBufferRelease = *const fn (types.WGPUCommandBuffer) callconv(.c) void;
pub const FnWgpuBufferRelease = *const fn (types.WGPUBuffer) callconv(.c) void;
pub const FnWgpuAdapterHasFeature = *const fn (types.WGPUAdapter, types.WGPUFeatureName) callconv(.c) types.WGPUBool;
pub const FnWgpuDeviceHasFeature = *const fn (types.WGPUDevice, types.WGPUFeatureName) callconv(.c) types.WGPUBool;
pub const FnWgpuDeviceCreateQuerySet = *const fn (types.WGPUDevice, *const types.WGPUQuerySetDescriptor) callconv(.c) types.WGPUQuerySet;
pub const FnWgpuCommandEncoderResolveQuerySet = *const fn (types.WGPUCommandEncoder, types.WGPUQuerySet, u32, u32, types.WGPUBuffer, u64) callconv(.c) void;
pub const FnWgpuQuerySetRelease = *const fn (types.WGPUQuerySet) callconv(.c) void;
pub const FnWgpuBufferMapAsync = *const fn (types.WGPUBuffer, types.WGPUMapMode, usize, usize, types.WGPUBufferMapCallbackInfo) callconv(.c) types.WGPUFuture;
pub const FnWgpuBufferGetConstMappedRange = *const fn (types.WGPUBuffer, usize, usize) callconv(.c) ?*const anyopaque;
pub const FnWgpuBufferGetMappedRange = *const fn (types.WGPUBuffer, usize, usize) callconv(.c) ?*anyopaque;
pub const FnWgpuBufferUnmap = *const fn (types.WGPUBuffer) callconv(.c) void;
pub const FnWgpuDeviceCreateSampler = *const fn (types.WGPUDevice, ?*const types.WGPUSamplerDescriptor) callconv(.c) types.WGPUSampler;
pub const FnWgpuSamplerRelease = *const fn (types.WGPUSampler) callconv(.c) void;

pub const Procs = struct {
    wgpuCreateInstance: FnWgpuCreateInstance,
    wgpuInstanceRequestAdapter: FnWgpuInstanceRequestAdapter,
    wgpuInstanceWaitAny: FnWgpuInstanceWaitAny,
    wgpuInstanceProcessEvents: FnWgpuInstanceProcessEvents,
    wgpuAdapterRequestDevice: FnWgpuAdapterRequestDevice,
    wgpuDeviceCreateBuffer: FnWgpuDeviceCreateBuffer,
    wgpuDeviceCreateShaderModule: FnWgpuDeviceCreateShaderModule,
    wgpuShaderModuleRelease: FnWgpuShaderModuleRelease,
    wgpuDeviceCreateComputePipeline: FnWgpuDeviceCreateComputePipeline,
    wgpuComputePipelineRelease: FnWgpuComputePipelineRelease,
    wgpuRenderPipelineRelease: ?FnWgpuRenderPipelineRelease,
    wgpuDeviceCreateCommandEncoder: FnWgpuDeviceCreateCommandEncoder,
    wgpuCommandEncoderBeginComputePass: FnWgpuCommandEncoderBeginComputePass,
    wgpuDeviceCreateRenderPipeline: ?FnWgpuDeviceCreateRenderPipeline,
    wgpuCommandEncoderBeginRenderPass: ?FnWgpuCommandEncoderBeginRenderPass,
    wgpuCommandEncoderWriteTimestamp: ?FnWgpuCommandEncoderWriteTimestamp,
    wgpuCommandEncoderCopyBufferToBuffer: FnWgpuCommandEncoderCopyBufferToBuffer,
    wgpuCommandEncoderCopyBufferToTexture: FnWgpuCommandEncoderCopyBufferToTexture,
    wgpuCommandEncoderCopyTextureToBuffer: FnWgpuCommandEncoderCopyTextureToBuffer,
    wgpuCommandEncoderCopyTextureToTexture: FnWgpuCommandEncoderCopyTextureToTexture,
    wgpuComputePassEncoderSetBindGroup: FnWgpuComputePassEncoderSetBindGroup,
    wgpuComputePassEncoderSetPipeline: FnWgpuComputePassEncoderSetPipeline,
    wgpuComputePassEncoderDispatchWorkgroups: FnWgpuComputePassEncoderDispatchWorkgroups,
    wgpuComputePassEncoderEnd: FnWgpuComputePassEncoderEnd,
    wgpuComputePassEncoderRelease: FnWgpuComputePassEncoderRelease,
    wgpuRenderPassEncoderSetPipeline: ?FnWgpuRenderPassEncoderSetPipeline,
    wgpuRenderPassEncoderSetVertexBuffer: ?FnWgpuRenderPassEncoderSetVertexBuffer,
    wgpuRenderPassEncoderSetIndexBuffer: ?FnWgpuRenderPassEncoderSetIndexBuffer,
    wgpuRenderPassEncoderSetBindGroup: ?FnWgpuRenderPassEncoderSetBindGroup,
    wgpuRenderPassEncoderDraw: ?FnWgpuRenderPassEncoderDraw,
    wgpuRenderPassEncoderDrawIndexed: ?FnWgpuRenderPassEncoderDrawIndexed,
    wgpuRenderPassEncoderDrawIndirect: ?FnWgpuRenderPassEncoderDrawIndirect,
    wgpuRenderPassEncoderDrawIndexedIndirect: ?FnWgpuRenderPassEncoderDrawIndexedIndirect,
    wgpuRenderPassEncoderEnd: ?FnWgpuRenderPassEncoderEnd,
    wgpuRenderPassEncoderRelease: ?FnWgpuRenderPassEncoderRelease,
    wgpuDeviceCreateTexture: FnWgpuDeviceCreateTexture,
    wgpuTextureCreateView: FnWgpuTextureCreateView,
    wgpuDeviceCreateBindGroupLayout: FnWgpuDeviceCreateBindGroupLayout,
    wgpuBindGroupLayoutRelease: FnWgpuBindGroupLayoutRelease,
    wgpuDeviceCreateBindGroup: FnWgpuDeviceCreateBindGroup,
    wgpuBindGroupRelease: FnWgpuBindGroupRelease,
    wgpuDeviceCreatePipelineLayout: FnWgpuDeviceCreatePipelineLayout,
    wgpuPipelineLayoutRelease: FnWgpuPipelineLayoutRelease,
    wgpuTextureRelease: FnWgpuTextureRelease,
    wgpuTextureViewRelease: FnWgpuTextureViewRelease,
    wgpuCommandEncoderFinish: FnWgpuCommandEncoderFinish,
    wgpuDeviceGetQueue: FnWgpuDeviceGetQueue,
    wgpuQueueSubmit: FnWgpuQueueSubmit,
    wgpuQueueOnSubmittedWorkDone: FnWgpuQueueOnSubmittedWorkDone,
    wgpuQueueWriteBuffer: FnWgpuQueueWriteBuffer,
    wgpuInstanceRelease: FnWgpuInstanceRelease,
    wgpuAdapterRelease: FnWgpuAdapterRelease,
    wgpuDeviceRelease: FnWgpuDeviceRelease,
    wgpuQueueRelease: FnWgpuQueueRelease,
    wgpuCommandEncoderRelease: FnWgpuCommandEncoderRelease,
    wgpuCommandBufferRelease: FnWgpuCommandBufferRelease,
    wgpuBufferRelease: FnWgpuBufferRelease,
    wgpuAdapterHasFeature: FnWgpuAdapterHasFeature,
    wgpuDeviceHasFeature: ?FnWgpuDeviceHasFeature,
    wgpuDeviceCreateQuerySet: FnWgpuDeviceCreateQuerySet,
    wgpuCommandEncoderResolveQuerySet: FnWgpuCommandEncoderResolveQuerySet,
    wgpuQuerySetRelease: FnWgpuQuerySetRelease,
    wgpuBufferMapAsync: FnWgpuBufferMapAsync,
    wgpuBufferGetConstMappedRange: FnWgpuBufferGetConstMappedRange,
    wgpuBufferGetMappedRange: FnWgpuBufferGetMappedRange,
    wgpuBufferUnmap: FnWgpuBufferUnmap,
};
