/*
 * doe_napi_internal.h — Shared header for split doe_napi modules.
 *
 * All types, macros, extern declarations, and function prototypes needed
 * by the individual .c files that together implement the Doe N-API addon.
 */
#pragma once

#ifndef _WIN32
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#endif

#include <node_api.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <stdbool.h>
#include <math.h>

#ifdef _WIN32
#include <windows.h>
#define LIB_OPEN(p)      LoadLibraryA(p)
#define LIB_SYM(h, n)    ((void*)GetProcAddress((HMODULE)(h), n))
#define LIB_CLOSE(h)     FreeLibrary((HMODULE)(h))
#else
#include <dlfcn.h>
#include <time.h>
#define LIB_OPEN(p)      dlopen(p, RTLD_NOW | RTLD_LOCAL)
#define LIB_SYM(h, n)    dlsym(h, n)
#define LIB_CLOSE(h)     dlclose(h)
#endif

/* ================================================================
 * WebGPU C ABI type definitions (matching wgpu_types.zig)
 * ================================================================ */

typedef void* WGPUInstance;
typedef void* WGPUAdapter;
typedef void* WGPUDevice;
typedef void* WGPUQueue;
typedef void* WGPUBuffer;
typedef void* WGPUShaderModule;
typedef void* WGPUComputePipeline;
typedef void* WGPURenderPipeline;
typedef void* WGPUBindGroupLayout;
typedef void* WGPUBindGroup;
typedef void* WGPUPipelineLayout;
typedef void* WGPUCommandEncoder;
typedef void* WGPUCommandBuffer;
typedef void* WGPUComputePassEncoder;
typedef void* WGPUQuerySet;
typedef void* WGPUTexture;
typedef void* WGPUTextureView;
typedef void* WGPUSampler;
typedef void* WGPURenderPassEncoder;
typedef void* WGPUSurface;
typedef uint64_t WGPUFlags;
typedef uint32_t WGPUBool;

#define WGPU_STRLEN SIZE_MAX
#define WGPU_WHOLE_SIZE UINT64_MAX
#define WGPU_STYPE_SHADER_SOURCE_WGSL 0x00000002
#define WGPU_STYPE_RENDER_PASS_MAX_DRAW_COUNT 0x00000003
#define DOE_DEFAULT_MAX_DRAW_COUNT 50000000ULL
#define WGPU_WAIT_STATUS_SUCCESS 1
#define WGPU_WAIT_STATUS_TIMED_OUT 2
#define WGPU_WAIT_STATUS_ERROR 3
#define WGPU_STATUS_SUCCESS 1
#define WGPU_MAP_ASYNC_STATUS_SUCCESS 1
#define WGPU_REQUEST_STATUS_SUCCESS 1
#define WGPU_CALLBACK_MODE_ALLOW_PROCESS_EVENTS 2
#define DOE_DEFAULT_TIMEOUT_NS 2000000000ULL
#define DOE_WAIT_SLICE_NS 1000ULL
#define DOE_ERROR_BUF_CAP 512
#define WGPU_FEATURE_SHADER_F16 0x0000000B
#define WGPU_CALLBACK_MODE_WAIT_ANY_ONLY 1
#define WGPU_QUEUE_WORK_DONE_STATUS_SUCCESS 1
#define BATCH_MAX_BIND_GROUPS 4
#define DOE_SHADER_BINDING_CAPACITY 32
#define DOE_GPU_MAP_READ 0x0001u
#define DOE_READBACK_BREAKDOWN_FIELD_COUNT 6u
#define DOE_READBACK_BREAKDOWN_WAIT_COMPLETED 0u
#define DOE_READBACK_BREAKDOWN_DEFERRED_COPY 1u
#define DOE_READBACK_BREAKDOWN_DEFERRED_RESOLVE 2u
#define DOE_READBACK_BREAKDOWN_MAP 3u
#define DOE_READBACK_BREAKDOWN_COPY 4u
#define DOE_READBACK_BREAKDOWN_UNMAP 5u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_FIELD_COUNT 12u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY 0u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_QUEUE_SUBMIT 1u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_FLUSH 2u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_WAIT_COMPLETED 3u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_DEFERRED_COPY 4u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_DEFERRED_RESOLVE 5u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_BUFFER_END 6u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_SYNC_PREPARE 7u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_DRIVER_SUBMIT 8u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_PREPARE 9u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_RECORD 10u
#define DOE_DISPATCH_FLUSH_BREAKDOWN_COMMAND_REPLAY_COPY 11u

static inline void doe_append_truncated(char* dst, size_t* offset, size_t cap, const char* src) {
    if (!dst || !offset || cap == 0 || *offset >= cap - 1) return;
    if (!src) src = "";
    while (*src != '\0' && *offset < cap - 1) {
        dst[*offset] = *src;
        *offset += 1;
        src += 1;
    }
    dst[*offset] = '\0';
}

static inline void doe_format_library_error_message(
    char* dst,
    size_t cap,
    const char* stage,
    const char* kind,
    const char* msg
) {
    if (!dst || cap == 0) return;
    size_t offset = 0;
    dst[0] = '\0';
    const bool has_stage = stage && stage[0] != '\0';
    const bool has_kind = kind && kind[0] != '\0';

    if (has_stage && has_kind) {
        doe_append_truncated(dst, &offset, cap, "[");
        doe_append_truncated(dst, &offset, cap, stage);
        doe_append_truncated(dst, &offset, cap, "/");
        doe_append_truncated(dst, &offset, cap, kind);
        doe_append_truncated(dst, &offset, cap, "] ");
    } else if (has_stage) {
        doe_append_truncated(dst, &offset, cap, "[");
        doe_append_truncated(dst, &offset, cap, stage);
        doe_append_truncated(dst, &offset, cap, "] ");
    }
    doe_append_truncated(dst, &offset, cap, msg);
}

typedef struct { uint64_t id; } WGPUFuture;
typedef struct { const char* data; size_t length; } WGPUStringView;
typedef struct { WGPUFuture future; WGPUBool completed; } WGPUFutureWaitInfo;
typedef struct { void* next; uint32_t sType; } WGPUChainedStruct;
typedef uint32_t WGPUFeatureName;
typedef uint32_t WGPUDeviceLostReason;
typedef uint32_t WGPUErrorType;

typedef struct {
    void* nextInChain;
    WGPUStringView label;
    uint64_t usage;
    uint64_t size;
    WGPUBool mappedAtCreation;
} WGPUBufferDescriptor;

typedef struct { void* nextInChain; WGPUStringView label; } WGPUCommandEncoderDescriptor;
typedef struct { void* nextInChain; WGPUStringView label; } WGPUCommandBufferDescriptor;
typedef struct { WGPUChainedStruct chain; WGPUStringView code; } WGPUShaderSourceWGSL;

typedef struct {
    WGPUStringView entryPoint;
    void* layout; /* WGPUPipelineLayout or NULL for "auto" */
} WGPUShaderModuleCompilationHint;

typedef struct {
    void* nextInChain;
    WGPUStringView label;
    size_t compilationHintCount;
    const WGPUShaderModuleCompilationHint* compilationHints;
} WGPUShaderModuleDescriptor;

typedef struct {
    void* nextInChain;
    WGPUShaderModule module;
    WGPUStringView entryPoint;
    size_t constantCount;
    void* constants;
} WGPUComputeState;

typedef struct {
    void* nextInChain;
    WGPUStringView label;
    void* layout;
    WGPUComputeState compute;
} WGPUComputePipelineDescriptor;

typedef struct { void* nextInChain; uint32_t type; WGPUBool hasDynamicOffset; uint64_t minBindingSize; } WGPUBufferBindingLayout;
typedef struct { void* nextInChain; uint32_t type; } WGPUSamplerBindingLayout;
typedef struct { void* nextInChain; uint32_t sampleType; uint32_t viewDimension; WGPUBool multisampled; } WGPUTextureBindingLayout;
typedef struct { void* nextInChain; uint32_t access; uint32_t format; uint32_t viewDimension; } WGPUStorageTextureBindingLayout;

typedef struct {
    void* nextInChain;
    uint32_t binding;
    uint64_t visibility;
    uint32_t bindingArraySize;
    WGPUBufferBindingLayout buffer;
    WGPUSamplerBindingLayout sampler;
    WGPUTextureBindingLayout texture;
    WGPUStorageTextureBindingLayout storageTexture;
} WGPUBindGroupLayoutEntry;

typedef struct { void* nextInChain; WGPUStringView label; size_t entryCount; const WGPUBindGroupLayoutEntry* entries; } WGPUBindGroupLayoutDescriptor;

typedef struct {
    void* nextInChain;
    uint32_t binding;
    WGPUBuffer buffer;
    uint64_t offset;
    uint64_t size;
    WGPUSampler sampler;
    WGPUTextureView textureView;
} WGPUBindGroupEntry;

typedef struct { void* nextInChain; WGPUStringView label; WGPUBindGroupLayout layout; size_t entryCount; const WGPUBindGroupEntry* entries; } WGPUBindGroupDescriptor;
typedef struct { void* nextInChain; WGPUStringView label; size_t bindGroupLayoutCount; const WGPUBindGroupLayout* bindGroupLayouts; uint32_t immediateSize; } WGPUPipelineLayoutDescriptor;

typedef struct { uint32_t group; uint32_t binding; uint32_t kind; uint32_t addr_space; uint32_t access; } DoeShaderBindingInfo;

/* Compilation message types (WebGPU spec) */
typedef enum {
    WGPU_COMPILATION_MESSAGE_TYPE_ERROR   = 1,
    WGPU_COMPILATION_MESSAGE_TYPE_WARNING = 2,
    WGPU_COMPILATION_MESSAGE_TYPE_INFO    = 3,
} WGPUCompilationMessageType;

typedef struct {
    const char* message;
    WGPUCompilationMessageType type;
    uint64_t lineNum;
    uint64_t linePos;
    uint64_t offset;
    uint64_t length;
} WGPUCompilationMessage;

typedef struct {
    size_t messageCount;
    const WGPUCompilationMessage* messages;
} WGPUCompilationInfo;
typedef struct {
    const WGPUChainedStruct* nextInChain;
    WGPUQuerySet querySet;
    uint32_t beginningOfPassWriteIndex;
    uint32_t endOfPassWriteIndex;
} WGPUPassTimestampWrites;

typedef WGPUPassTimestampWrites WGPUComputePassTimestampWrites;
typedef WGPUPassTimestampWrites WGPURenderPassTimestampWrites;

typedef struct { void* nextInChain; WGPUStringView label; const WGPUComputePassTimestampWrites* timestampWrites; } WGPUComputePassDescriptor;
typedef struct { uint32_t width; uint32_t height; uint32_t depthOrArrayLayers; } WGPUExtent3D;
typedef struct { uint32_t x; uint32_t y; uint32_t z; } WGPUOrigin3D;
typedef struct { uint64_t offset; uint32_t bytesPerRow; uint32_t rowsPerImage; } WGPUTexelCopyBufferLayout;
typedef struct { WGPUTexelCopyBufferLayout layout; WGPUBuffer buffer; } WGPUTexelCopyBufferInfo;
typedef struct { WGPUTexture texture; uint32_t mipLevel; WGPUOrigin3D origin; uint32_t aspect; } WGPUTexelCopyTextureInfo;

typedef struct {
    void* nextInChain; WGPUStringView label; uint64_t usage; uint32_t dimension;
    WGPUExtent3D size; uint32_t format; uint32_t mipLevelCount; uint32_t sampleCount;
    size_t viewFormatCount; const uint32_t* viewFormats;
    uint32_t textureBindingViewDimension;
} WGPUTextureDescriptor;

typedef struct {
    void* nextInChain; WGPUStringView label; uint32_t format; uint32_t dimension;
    uint32_t baseMipLevel; uint32_t mipLevelCount; uint32_t baseArrayLayer; uint32_t arrayLayerCount;
    uint32_t aspect; uint64_t usage;
    uint32_t swizzleR; uint32_t swizzleG; uint32_t swizzleB; uint32_t swizzleA;
} WGPUTextureViewDescriptor;

typedef struct {
    void* nextInChain; WGPUStringView label;
    uint32_t addressModeU; uint32_t addressModeV; uint32_t addressModeW;
    uint32_t magFilter; uint32_t minFilter; uint32_t mipmapFilter;
    float lodMinClamp; float lodMaxClamp; uint32_t compare; uint16_t maxAnisotropy;
} WGPUSamplerDescriptor;

typedef struct { double r; double g; double b; double a; } WGPUColor;

typedef struct {
    void* nextInChain; WGPUTextureView view; uint32_t depthSlice; WGPUTextureView resolveTarget;
    uint32_t loadOp; uint32_t storeOp; WGPUColor clearValue;
} WGPURenderPassColorAttachment;

typedef struct {
    void* nextInChain; WGPUTextureView view;
    uint32_t depthLoadOp; uint32_t depthStoreOp; float depthClearValue; WGPUBool depthReadOnly;
    uint32_t stencilLoadOp; uint32_t stencilStoreOp; uint32_t stencilClearValue; WGPUBool stencilReadOnly;
} WGPURenderPassDepthStencilAttachment;

typedef struct {
    void* nextInChain; WGPUStringView label;
    size_t colorAttachmentCount; const WGPURenderPassColorAttachment* colorAttachments;
    void* depthStencilAttachment; WGPUQuerySet occlusionQuerySet; const WGPURenderPassTimestampWrites* timestampWrites;
} WGPURenderPassDescriptor;

typedef struct {
    WGPUChainedStruct chain;
    uint64_t maxDrawCount;
} WGPURenderPassMaxDrawCount;

typedef struct { void* nextInChain; WGPUStringView key; double value; } WGPUConstantEntry;

typedef struct {
    void* nextInChain; WGPUShaderModule module; WGPUStringView entryPoint;
    size_t constantCount; const WGPUConstantEntry* constants; size_t bufferCount; const void* buffers;
} WGPURenderVertexState;

typedef struct { void* nextInChain; uint32_t format; uint64_t offset; uint32_t shaderLocation; } WGPURenderVertexAttribute;
typedef struct { void* nextInChain; uint32_t stepMode; uint64_t arrayStride; size_t attributeCount; const WGPURenderVertexAttribute* attributes; } WGPURenderVertexBufferLayout;
typedef struct { uint32_t operation; uint32_t srcFactor; uint32_t dstFactor; } WGPUBlendComponent;
typedef struct { WGPUBlendComponent color; WGPUBlendComponent alpha; } WGPUBlendState;
typedef struct { void* nextInChain; uint32_t format; const WGPUBlendState* blend; uint64_t writeMask; } WGPURenderColorTargetState;

typedef struct {
    void* nextInChain; WGPUShaderModule module; WGPUStringView entryPoint;
    size_t constantCount; const WGPUConstantEntry* constants; size_t targetCount; const WGPURenderColorTargetState* targets;
} WGPURenderFragmentState;

typedef struct { void* nextInChain; uint32_t topology; uint32_t stripIndexFormat; uint32_t frontFace; uint32_t cullMode; WGPUBool unclippedDepth; } WGPURenderPrimitiveState;
typedef struct { void* nextInChain; uint32_t count; uint32_t mask; WGPUBool alphaToCoverageEnabled; } WGPURenderMultisampleState;
typedef struct { uint32_t compare; uint32_t failOp; uint32_t depthFailOp; uint32_t passOp; } WGPURenderStencilFaceState;

typedef struct {
    void* nextInChain; uint32_t format; uint32_t depthWriteEnabled; uint32_t depthCompare;
    WGPURenderStencilFaceState stencilFront; WGPURenderStencilFaceState stencilBack;
    uint32_t stencilReadMask; uint32_t stencilWriteMask;
    int32_t depthBias; float depthBiasSlopeScale; float depthBiasClamp;
} WGPURenderDepthStencilState;

typedef struct {
    void* nextInChain; WGPUStringView label; WGPUPipelineLayout layout;
    WGPURenderVertexState vertex; WGPURenderPrimitiveState primitive;
    const WGPURenderDepthStencilState* depthStencil; WGPURenderMultisampleState multisample;
    const WGPURenderFragmentState* fragment;
} WGPURenderPipelineDescriptor;

typedef struct {
    void* nextInChain;
    uint32_t maxTextureDimension1D; uint32_t maxTextureDimension2D; uint32_t maxTextureDimension3D;
    uint32_t maxTextureArrayLayers; uint32_t maxBindGroups; uint32_t maxBindGroupsPlusVertexBuffers;
    uint32_t maxBindingsPerBindGroup; uint32_t maxDynamicUniformBuffersPerPipelineLayout;
    uint32_t maxDynamicStorageBuffersPerPipelineLayout; uint32_t maxSampledTexturesPerShaderStage;
    uint32_t maxSamplersPerShaderStage; uint32_t maxStorageBuffersPerShaderStage;
    uint32_t maxStorageTexturesPerShaderStage; uint32_t maxUniformBuffersPerShaderStage;
    uint64_t maxUniformBufferBindingSize; uint64_t maxStorageBufferBindingSize;
    uint32_t minUniformBufferOffsetAlignment; uint32_t minStorageBufferOffsetAlignment;
    uint32_t maxVertexBuffers; uint64_t maxBufferSize; uint32_t maxVertexAttributes;
    uint32_t maxVertexBufferArrayStride; uint32_t maxInterStageShaderVariables;
    uint32_t maxColorAttachments; uint32_t maxColorAttachmentBytesPerSample;
    uint32_t maxComputeWorkgroupStorageSize; uint32_t maxComputeInvocationsPerWorkgroup;
    uint32_t maxComputeWorkgroupSizeX; uint32_t maxComputeWorkgroupSizeY;
    uint32_t maxComputeWorkgroupSizeZ; uint32_t maxComputeWorkgroupsPerDimension;
    uint32_t maxImmediateSize;
} WGPULimits;

typedef struct { void* nextInChain; WGPUStringView label; } WGPUQueueDescriptor;

/* Callback types */
typedef void (*WGPURequestAdapterCallback)(uint32_t status, WGPUAdapter adapter, WGPUStringView message, void* userdata1, void* userdata2);
typedef void (*WGPURequestDeviceCallback)(uint32_t status, WGPUDevice device, WGPUStringView message, void* userdata1, void* userdata2);
typedef struct { void* nextInChain; uint32_t mode; WGPURequestAdapterCallback callback; void* userdata1; void* userdata2; } WGPURequestAdapterCallbackInfo;
typedef struct { void* nextInChain; uint32_t mode; WGPURequestDeviceCallback callback; void* userdata1; void* userdata2; } WGPURequestDeviceCallbackInfo;
typedef void (*WGPUBufferMapCallback)(uint32_t status, WGPUStringView message, void* userdata1, void* userdata2);
typedef void (*WGPUQueueWorkDoneCallback)(uint32_t status, WGPUStringView message, void* userdata1, void* userdata2);
typedef struct { void* nextInChain; uint32_t mode; WGPUQueueWorkDoneCallback callback; void* userdata1; void* userdata2; } WGPUQueueWorkDoneCallbackInfo;
typedef struct { void* nextInChain; uint32_t mode; WGPUBufferMapCallback callback; void* userdata1; void* userdata2; } WGPUBufferMapCallbackInfo;
typedef void (*WGPUDeviceLostCallback)(const void* device, WGPUDeviceLostReason reason, WGPUStringView message, void* userdata1, void* userdata2);
typedef void (*WGPUUncapturedErrorCallback)(const void* device, WGPUErrorType type, WGPUStringView message, void* userdata1, void* userdata2);
typedef struct { void* nextInChain; uint32_t mode; WGPUDeviceLostCallback callback; void* userdata1; void* userdata2; } WGPUDeviceLostCallbackInfo;
typedef struct { void* nextInChain; WGPUUncapturedErrorCallback callback; void* userdata1; void* userdata2; } WGPUUncapturedErrorCallbackInfo;

typedef struct {
    void* nextInChain;
    WGPUStringView label;
    size_t requiredFeatureCount;
    const WGPUFeatureName* requiredFeatures;
    const WGPULimits* requiredLimits;
    WGPUQueueDescriptor defaultQueue;
    WGPUDeviceLostCallbackInfo deviceLostCallbackInfo;
    WGPUUncapturedErrorCallbackInfo uncapturedErrorCallbackInfo;
} WGPUDeviceDescriptor;

typedef struct {
    void* next_in_chain; uint32_t mode;
    void (*callback)(uint32_t error_type, WGPUStringView message, void* userdata1, void* userdata2);
    void* userdata1; void* userdata2;
} WGPUPopErrorScopeCallbackInfo2;

/* WGPUFeatureLevel values (matching wgpu_types.zig WGPUFeatureLevel enum). */
#define WGPU_FEATURE_LEVEL_UNDEFINED     0
#define WGPU_FEATURE_LEVEL_COMPATIBILITY 1
#define WGPU_FEATURE_LEVEL_CORE          2

typedef struct {
    void* nextInChain;
    uint32_t featureLevel;       /* WGPU_FEATURE_LEVEL_* */
    uint32_t powerPreference;
    WGPUBool forceFallbackAdapter;
    uint32_t backendType;        /* ignored by Doe; 0 = undefined */
    void* compatibleSurface;     /* NULL for headless */
} WGPURequestAdapterOptions;

typedef struct {
    void* nextInChain;
    WGPUStringView vendor;
    WGPUStringView architecture;
    WGPUStringView device;
    WGPUStringView description;
    uint32_t backendType;
    uint32_t adapterType;
    uint32_t vendorID;
    uint32_t deviceID;
    uint32_t subgroupMinSize;
    uint32_t subgroupMaxSize;
} WGPUAdapterInfo;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    WGPUStringView label;
} WGPUSurfaceDescriptor;

typedef struct {
    WGPUChainedStruct chain;
    void* layer;
} WGPUSurfaceSourceMetalLayer;

typedef struct {
    void* nextInChain;
    uint64_t usages;
    size_t formatCount;
    const uint32_t* formats;
    size_t presentModeCount;
    const uint32_t* presentModes;
    size_t alphaModeCount;
    const uint32_t* alphaModes;
} WGPUSurfaceCapabilities;

typedef struct {
    void* nextInChain;
    WGPUDevice device;
    uint32_t format;
    uint64_t usage;
    uint32_t width;
    uint32_t height;
    size_t viewFormatCount;
    const uint32_t* viewFormats;
    uint32_t alphaMode;
    uint32_t presentMode;
} WGPUSurfaceConfiguration;

typedef struct {
    void* nextInChain;
    WGPUTexture texture;
    uint32_t status;
} WGPUSurfaceTexture;

#define WGPU_SURFACE_SOURCE_METAL_LAYER_STYPE 0x00000004
#define WGPU_SURFACE_TEXTURE_STATUS_SUCCESS_OPTIMAL 0x00000001
#define WGPU_SURFACE_TEXTURE_STATUS_SUCCESS_SUBOPTIMAL 0x00000002
#define WGPU_PRESENT_MODE_FIFO 0x00000001
#define WGPU_PRESENT_MODE_FIFO_RELAXED 0x00000002
#define WGPU_PRESENT_MODE_IMMEDIATE 0x00000003
#define WGPU_PRESENT_MODE_MAILBOX 0x00000004
#define WGPU_CANVAS_ALPHA_MODE_AUTO 0x00000000
#define WGPU_CANVAS_ALPHA_MODE_OPAQUE 0x00000001
#define WGPU_CANVAS_ALPHA_MODE_PREMULTIPLIED 0x00000002
#define WGPU_CANVAS_TONE_MAPPING_MODE_STANDARD 0x00000001

/* ================================================================
 * Function pointer types — DECL_PFN creates typedef + extern decl
 * ================================================================ */

#define DECL_PFN(ret, name, params) typedef ret (*PFN_##name) params; extern PFN_##name pfn_##name

DECL_PFN(WGPUInstance, wgpuCreateInstance, (const void*));
DECL_PFN(void, wgpuInstanceRelease, (WGPUInstance));
DECL_PFN(WGPUFuture, wgpuInstanceRequestAdapter, (WGPUInstance, const void*, WGPURequestAdapterCallbackInfo));
DECL_PFN(uint32_t, wgpuInstanceWaitAny, (WGPUInstance, size_t, WGPUFutureWaitInfo*, uint64_t));
DECL_PFN(void, wgpuInstanceProcessEvents, (WGPUInstance));
DECL_PFN(void, wgpuAdapterRelease, (WGPUAdapter));
DECL_PFN(WGPUBool, wgpuAdapterHasFeature, (WGPUAdapter, uint32_t));
DECL_PFN(uint32_t, wgpuAdapterGetInfo, (WGPUAdapter, WGPUAdapterInfo*));
DECL_PFN(uint32_t, wgpuAdapterGetLimits, (WGPUAdapter, void*));
DECL_PFN(void, wgpuAdapterInfoFreeMembers, (WGPUAdapterInfo));
DECL_PFN(WGPUFuture, wgpuAdapterRequestDevice, (WGPUAdapter, const void*, WGPURequestDeviceCallbackInfo));
DECL_PFN(void, wgpuDeviceRelease, (WGPUDevice));
DECL_PFN(WGPUBool, wgpuDeviceHasFeature, (WGPUDevice, uint32_t));
DECL_PFN(uint32_t, wgpuDeviceGetLimits, (WGPUDevice, void*));
DECL_PFN(WGPUQueue, wgpuDeviceGetQueue, (WGPUDevice));
DECL_PFN(WGPUSurface, wgpuInstanceCreateSurface, (WGPUInstance, const WGPUSurfaceDescriptor*));
DECL_PFN(uint32_t, wgpuSurfaceGetCapabilities, (WGPUSurface, WGPUAdapter, WGPUSurfaceCapabilities*));
DECL_PFN(void, wgpuSurfaceConfigure, (WGPUSurface, const WGPUSurfaceConfiguration*));
DECL_PFN(void, wgpuSurfaceGetCurrentTexture, (WGPUSurface, WGPUSurfaceTexture*));
DECL_PFN(uint32_t, wgpuSurfacePresent, (WGPUSurface));
DECL_PFN(void, wgpuSurfaceUnconfigure, (WGPUSurface));
DECL_PFN(void, wgpuSurfaceRelease, (WGPUSurface));
DECL_PFN(void, wgpuSurfaceCapabilitiesFreeMembers, (WGPUSurfaceCapabilities));
DECL_PFN(WGPUBuffer, wgpuDeviceCreateBuffer, (WGPUDevice, const WGPUBufferDescriptor*));
DECL_PFN(WGPUShaderModule, wgpuDeviceCreateShaderModule, (WGPUDevice, const WGPUShaderModuleDescriptor*));
DECL_PFN(void, wgpuShaderModuleRelease, (WGPUShaderModule));
DECL_PFN(WGPUComputePipeline, wgpuDeviceCreateComputePipeline, (WGPUDevice, const WGPUComputePipelineDescriptor*));
DECL_PFN(void, wgpuComputePipelineRelease, (WGPUComputePipeline));
DECL_PFN(WGPUBindGroupLayout, wgpuComputePipelineGetBindGroupLayout, (WGPUComputePipeline, uint32_t));
DECL_PFN(WGPUBindGroupLayout, wgpuDeviceCreateBindGroupLayout, (WGPUDevice, const WGPUBindGroupLayoutDescriptor*));
DECL_PFN(void, wgpuBindGroupLayoutRelease, (WGPUBindGroupLayout));
DECL_PFN(WGPUBindGroup, wgpuDeviceCreateBindGroup, (WGPUDevice, const WGPUBindGroupDescriptor*));
DECL_PFN(void, wgpuBindGroupRelease, (WGPUBindGroup));
DECL_PFN(WGPUPipelineLayout, wgpuDeviceCreatePipelineLayout, (WGPUDevice, const WGPUPipelineLayoutDescriptor*));
DECL_PFN(void, wgpuPipelineLayoutRelease, (WGPUPipelineLayout));
DECL_PFN(WGPUCommandEncoder, wgpuDeviceCreateCommandEncoder, (WGPUDevice, const WGPUCommandEncoderDescriptor*));
DECL_PFN(void, wgpuCommandEncoderRelease, (WGPUCommandEncoder));
DECL_PFN(WGPUComputePassEncoder, wgpuCommandEncoderBeginComputePass, (WGPUCommandEncoder, const WGPUComputePassDescriptor*));
DECL_PFN(void, wgpuCommandEncoderCopyBufferToBuffer, (WGPUCommandEncoder, WGPUBuffer, uint64_t, WGPUBuffer, uint64_t, uint64_t));
DECL_PFN(void, wgpuCommandEncoderCopyBufferToTexture, (WGPUCommandEncoder, const WGPUTexelCopyBufferInfo*, const WGPUTexelCopyTextureInfo*, const WGPUExtent3D*));
DECL_PFN(void, wgpuCommandEncoderCopyTextureToBuffer, (WGPUCommandEncoder, const WGPUTexelCopyTextureInfo*, const WGPUTexelCopyBufferInfo*, const WGPUExtent3D*));
DECL_PFN(void, doeNativeCommandEncoderCopyBufferToTexture, (WGPUCommandEncoder, WGPUBuffer, uint64_t, uint32_t, uint32_t, WGPUTexture, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t));
DECL_PFN(void, doeNativeCommandEncoderCopyTextureToBuffer, (WGPUCommandEncoder, WGPUTexture, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, WGPUBuffer, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t));
DECL_PFN(WGPUCommandBuffer, wgpuCommandEncoderFinish, (WGPUCommandEncoder, const WGPUCommandBufferDescriptor*));
DECL_PFN(void, wgpuComputePassEncoderSetPipeline, (WGPUComputePassEncoder, WGPUComputePipeline));
DECL_PFN(void, wgpuComputePassEncoderSetBindGroup, (WGPUComputePassEncoder, uint32_t, WGPUBindGroup, size_t, const uint32_t*));
DECL_PFN(void, wgpuComputePassEncoderDispatchWorkgroups, (WGPUComputePassEncoder, uint32_t, uint32_t, uint32_t));
DECL_PFN(void, doeNativeComputePassDispatchBound, (WGPUComputePassEncoder, WGPUComputePipeline, WGPUBindGroup, uint32_t, uint32_t, uint32_t));
DECL_PFN(void, wgpuComputePassEncoderDispatchWorkgroupsIndirect, (WGPUComputePassEncoder, WGPUBuffer, uint64_t));
DECL_PFN(void, doeNativeComputePassDispatchIndirect, (WGPUComputePassEncoder, WGPUBuffer, uint64_t));
DECL_PFN(void, wgpuComputePassEncoderEnd, (WGPUComputePassEncoder));
DECL_PFN(void, wgpuComputePassEncoderRelease, (WGPUComputePassEncoder));
DECL_PFN(void, wgpuQueueSubmit, (WGPUQueue, size_t, const WGPUCommandBuffer*));
DECL_PFN(void, wgpuQueueWriteBuffer, (WGPUQueue, WGPUBuffer, uint64_t, const void*, size_t));
DECL_PFN(void, doeNativeQueueWriteBuffer, (WGPUQueue, WGPUBuffer, uint64_t, const void*, size_t));
DECL_PFN(void, doeNativeQueueWriteBufferBatch, (WGPUQueue, size_t, const WGPUBuffer*, const uint64_t*, const uint32_t*, const void*));
DECL_PFN(void, doeNativeQueueWriteBufferBatchDataPtrs, (WGPUQueue, size_t, const WGPUBuffer*, const uint64_t*, const uint32_t*, const void* const*));
DECL_PFN(WGPUFuture, wgpuQueueOnSubmittedWorkDone, (WGPUQueue, WGPUQueueWorkDoneCallbackInfo));
DECL_PFN(void, wgpuQueueRelease, (WGPUQueue));
DECL_PFN(void, wgpuBufferRelease, (WGPUBuffer));
DECL_PFN(void, wgpuBufferUnmap, (WGPUBuffer));
DECL_PFN(const void*, wgpuBufferGetConstMappedRange, (WGPUBuffer, size_t, size_t));
DECL_PFN(void*, wgpuBufferGetMappedRange, (WGPUBuffer, size_t, size_t));
DECL_PFN(uint32_t, doeNativeBufferGetMapState, (WGPUBuffer));
DECL_PFN(void, wgpuCommandBufferRelease, (WGPUCommandBuffer));
DECL_PFN(WGPUTexture, wgpuDeviceCreateTexture, (WGPUDevice, const WGPUTextureDescriptor*));
DECL_PFN(WGPUTextureView, wgpuTextureCreateView, (WGPUTexture, const WGPUTextureViewDescriptor*));
DECL_PFN(void, wgpuTextureRelease, (WGPUTexture));
DECL_PFN(void, wgpuTextureViewRelease, (WGPUTextureView));
DECL_PFN(WGPUSampler, wgpuDeviceCreateSampler, (WGPUDevice, const WGPUSamplerDescriptor*));
DECL_PFN(void, wgpuSamplerRelease, (WGPUSampler));
DECL_PFN(WGPURenderPipeline, wgpuDeviceCreateRenderPipeline, (WGPUDevice, const void*));
DECL_PFN(void, wgpuRenderPipelineRelease, (WGPURenderPipeline));
DECL_PFN(WGPURenderPassEncoder, wgpuCommandEncoderBeginRenderPass, (WGPUCommandEncoder, const WGPURenderPassDescriptor*));
DECL_PFN(void, wgpuRenderPassEncoderSetPipeline, (WGPURenderPassEncoder, WGPURenderPipeline));
DECL_PFN(void, wgpuRenderPassEncoderSetBindGroup, (WGPURenderPassEncoder, uint32_t, WGPUBindGroup, size_t, const uint32_t*));
DECL_PFN(void, wgpuRenderPassEncoderSetVertexBuffer, (WGPURenderPassEncoder, uint32_t, WGPUBuffer, uint64_t, uint64_t));
DECL_PFN(void, wgpuRenderPassEncoderSetIndexBuffer, (WGPURenderPassEncoder, WGPUBuffer, uint32_t, uint64_t, uint64_t));
DECL_PFN(void, wgpuRenderPassEncoderDraw, (WGPURenderPassEncoder, uint32_t, uint32_t, uint32_t, uint32_t));
DECL_PFN(void, wgpuRenderPassEncoderDrawIndexed, (WGPURenderPassEncoder, uint32_t, uint32_t, uint32_t, int32_t, uint32_t));
DECL_PFN(void, wgpuRenderPassEncoderEnd, (WGPURenderPassEncoder));
DECL_PFN(void, wgpuRenderPassEncoderRelease, (WGPURenderPassEncoder));
DECL_PFN(uint32_t, doeNativeAdapterGetLimits, (WGPUAdapter, void*));
DECL_PFN(uint32_t, doeNativeDeviceGetLimits, (WGPUDevice, void*));
DECL_PFN(uint32_t, doeNativeAdapterHasFeature, (WGPUAdapter, uint32_t));
DECL_PFN(uint32_t, doeNativeDeviceHasFeature, (WGPUDevice, uint32_t));
DECL_PFN(size_t, doeNativeCopyLastErrorMessage, (char*, size_t));
DECL_PFN(size_t, doeNativeCopyLastErrorStage, (char*, size_t));
DECL_PFN(size_t, doeNativeCopyLastErrorKind, (char*, size_t));
DECL_PFN(uint32_t, doeNativeGetLastErrorLine, (void));
DECL_PFN(uint32_t, doeNativeGetLastErrorColumn, (void));
DECL_PFN(uint32_t, doeNativeCheckShaderSource, (const char*, size_t));
DECL_PFN(size_t, doeNativeShaderModuleGetBindings, (WGPUShaderModule, DoeShaderBindingInfo*, size_t));
DECL_PFN(size_t, doeNativeShaderModuleGetBindingsForEntryPoint, (WGPUShaderModule, const char*, size_t, DoeShaderBindingInfo*, size_t));
DECL_PFN(WGPUFuture, doeNativeAdapterRequestDevice, (WGPUAdapter, const void*, WGPURequestDeviceCallbackInfo));
DECL_PFN(WGPUAdapter, doeNativeInstanceCreateAdapter, (WGPUInstance, const void*));
DECL_PFN(WGPUFuture, doeRequestAdapterFlat, (WGPUInstance, const void*, uint32_t, WGPURequestAdapterCallback, void*, void*));
DECL_PFN(WGPUFuture, doeRequestDeviceFlat, (WGPUAdapter, const void*, uint32_t, WGPURequestDeviceCallback, void*, void*));
DECL_PFN(WGPUBindGroupLayout, doeNativeDeviceCreateBufferBindGroupLayoutFlat4, (WGPUDevice, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t));
DECL_PFN(WGPUBindGroup, doeNativeDeviceCreateBufferBindGroupFlat4, (WGPUDevice, WGPUBindGroupLayout, uint32_t, uint32_t, WGPUBuffer, uint64_t, uint32_t, WGPUBuffer, uint64_t, uint32_t, WGPUBuffer, uint64_t, uint32_t, WGPUBuffer, uint64_t));
DECL_PFN(WGPUPipelineLayout, doeNativeDeviceCreatePipelineLayoutOne, (WGPUDevice, WGPUBindGroupLayout, uint32_t));
DECL_PFN(void, doeNativePackagePipelineCacheFlush, (void));
DECL_PFN(void, doeNativeQueueFlush, (void*));
DECL_PFN(void, doeNativeQueueFlushBreakdown, (void*, uint64_t*, uint64_t*, uint64_t*));
DECL_PFN(uint32_t, doeNativeQueueSyncInfo, (void*));
DECL_PFN(uint32_t, doeNativeQueuePipelineCacheInfo, (void*));
DECL_PFN(uint64_t, doeNativeQueuePipelineCacheWarmupCount, (void*));
DECL_PFN(uint64_t, doeNativeQueuePipelineCacheWarmupNs, (void*));
DECL_PFN(void, doeNativeQueuePipelineCacheFlush, (void*));
DECL_PFN(uint32_t, doeNativeQueueFamilyPolicyCode, (void*));
DECL_PFN(uint32_t, doeNativeQueueDeferredSubmissionSyncPolicyCode, (void*));
DECL_PFN(uint32_t, doeNativeQueueFamilyKindCode, (void*));
DECL_PFN(uint32_t, doeNativeQueueFamilyIndex, (void*));
DECL_PFN(uint32_t, doeNativeQueueFamilyQueueCount, (void*));
DECL_PFN(uint32_t, doeNativeQueueFamilyTimestampValidBits, (void*));
DECL_PFN(uint32_t, doeNativeQueueFamilySupportsGraphics, (void*));
DECL_PFN(void, doeNativeComputeDispatchFlush, (void*, void*, void**, uint32_t, uint32_t, uint32_t, uint32_t, void*, uint64_t, void*, uint64_t, uint64_t));
DECL_PFN(void, doeNativeComputeDispatchFlushBreakdown, (void*, void*, void**, uint32_t, uint32_t, uint32_t, uint32_t, void*, uint64_t, void*, uint64_t, uint64_t, uint64_t*));
DECL_PFN(void, doeNativeComputeDispatchBatchFlush, (void*, size_t, void**, void**, const uint32_t*, const uint32_t*));
DECL_PFN(void, doeNativeComputeDispatchBatchCopyFlush, (void*, size_t, void**, void**, const uint32_t*, const uint32_t*, void*, uint64_t, void*, uint64_t, uint64_t));
DECL_PFN(void, doeNativeComputeDispatchBatchCopyFlushBreakdown, (void*, size_t, void**, void**, const uint32_t*, const uint32_t*, void*, uint64_t, void*, uint64_t, uint64_t, uint64_t*));
DECL_PFN(uint32_t, doeNativeComputePrewarmDispatchBindings, (void*, size_t, void**, void**, const uint32_t*));
DECL_PFN(WGPUQuerySet, doeNativeDeviceCreateQuerySet, (WGPUDevice, uint32_t, uint32_t));
DECL_PFN(void, doeNativeCommandEncoderWriteTimestamp, (WGPUCommandEncoder, WGPUQuerySet, uint32_t));
DECL_PFN(void, doeNativeCommandEncoderResolveQuerySet, (WGPUCommandEncoder, WGPUQuerySet, uint32_t, uint32_t, WGPUBuffer, uint64_t));
DECL_PFN(void, doeNativeQuerySetDestroy, (WGPUQuerySet));
DECL_PFN(WGPUFuture, doeNativeBufferMapAsync, (WGPUBuffer, uint64_t, size_t, size_t, WGPUBufferMapCallbackInfo));
DECL_PFN(uint32_t, doeBufferMapReadCopyUnmapFlat, (WGPUQueue, WGPUBuffer, uint64_t, size_t, size_t, uint32_t, void*, uint64_t*));

typedef WGPUFuture (*PFN_wgpuBufferMapAsync2)(WGPUBuffer, uint64_t, size_t, size_t, WGPUBufferMapCallbackInfo);
extern PFN_wgpuBufferMapAsync2 pfn_wgpuBufferMapAsync2;

/* Manual function pointer typedefs */
typedef uint32_t (*FnAdapterGetPreferredCanvasFormat)(void* adapter);
typedef void (*FnDeviceAddEventListener)(void* dev, const char* type, size_t type_len, void* callback, void* userdata);
typedef void (*FnDeviceRemoveEventListener)(void* dev, const char* type, size_t type_len, void* callback, void* userdata);
typedef void* (*FnDeviceImportExternalTexture)(void* dev, const void* descriptor);
typedef void (*FnObjectSetLabel)(void* object, const uint8_t* label, size_t label_len);
typedef void (*FnBindingCommandsSetImmediates)(void* encoder, uint32_t index, const uint8_t* data, size_t data_len);
typedef void (*FnComputePassSetImmediates)(void* encoder, uint32_t index, const uint8_t* data, size_t data_len);
typedef void (*FnRenderPassSetImmediates)(void* encoder, uint32_t index, const uint8_t* data, size_t data_len);
typedef void (*FnRenderBundleEncoderSetImmediates)(void* encoder, uint32_t index, const uint8_t* data, size_t data_len);
typedef void (*FnRenderPassSetViewport)(void* encoder, double x, double y, double width, double height, double min_depth, double max_depth);
typedef void (*FnRenderPassSetScissorRect)(void* encoder, uint32_t x, uint32_t y, uint32_t width, uint32_t height);
typedef void (*FnRenderPassSetBlendConstant)(void* encoder, double r, double g, double b, double a);
typedef void (*FnRenderPassSetStencilReference)(void* encoder, uint32_t reference);
typedef void (*FnRenderPassBeginOcclusionQuery)(void* encoder, uint32_t query_index);
typedef void (*FnRenderPassEndOcclusionQuery)(void* encoder);
typedef void (*FnRenderPassPushDebugGroup)(void* encoder, const char* label, size_t label_len);
typedef void (*FnRenderPassPopDebugGroup)(void* encoder);
typedef void (*FnRenderPassInsertDebugMarker)(void* encoder, const char* label, size_t label_len);
typedef void (*FnRenderBundleEncoderPushDebugGroup)(void* encoder, const char* label, size_t label_len);
typedef void (*FnRenderBundleEncoderPopDebugGroup)(void* encoder);
typedef void (*FnRenderBundleEncoderInsertDebugMarker)(void* encoder, const char* label, size_t label_len);
typedef void (*FnAdapterGetInfo)(void* adapter, const char** out_vendor, const char** out_arch, const char** out_device, const char** out_desc, char** out_block);
typedef void (*FnAdapterFreeInfo)(char* block);
typedef void (*FnAdapterGetPciIdentity)(void* adapter, uint32_t* out_vendor_id, uint32_t* out_device_id, uint32_t* out_driver_version);
typedef const char* (*FnShaderModuleGetCompilationInfo)(void* module);
typedef void (*FnDevicePushErrorScope)(void* device, uint32_t filter);
typedef WGPUFuture (*FnDevicePopErrorScope)(void* device, WGPUPopErrorScopeCallbackInfo2 callback_info);
typedef void (*FnDeviceSetUncapturedErrorCallback)(void* device, void (*callback)(uint32_t, WGPUStringView, void*, void*), void* userdata1, void* userdata2);
typedef void (*FnDeviceRegisterLostCallback)(void* device, void (*callback)(uint32_t, const char*, size_t, void*), void* userdata);
typedef void* (*FnRenderPipelineGetBindGroupLayout)(void* pipeline, uint32_t group_index);
typedef void (*FnCommandEncoderClearBuffer)(void* encoder, void* buffer, uint64_t offset, uint64_t size);
typedef void (*FnCommandEncoderCopyTextureToTexture)(void* encoder, void* src_texture, uint32_t src_mip, uint32_t src_slice, uint32_t src_x, uint32_t src_y, uint32_t src_z, void* dst_texture, uint32_t dst_mip, uint32_t dst_slice, uint32_t dst_x, uint32_t dst_y, uint32_t dst_z, uint32_t width, uint32_t height, uint32_t depth_or_layers);
typedef void (*FnWgpuCommandEncoderCopyTextureToTexture)(WGPUCommandEncoder encoder, const WGPUTexelCopyTextureInfo* source, const WGPUTexelCopyTextureInfo* destination, const WGPUExtent3D* copy_size);
typedef void (*FnQueueWriteTexture)(void* queue, void* texture, const void* data, size_t data_len, uint32_t bytes_per_row, uint32_t rows_per_image, uint32_t dst_x, uint32_t dst_y, uint32_t dst_z, uint32_t dst_mip, uint32_t dst_slice, uint32_t width, uint32_t height, uint32_t depth_or_layers);
typedef void* (*FnDeviceCreateRenderBundleEncoder)(void* device, const void* desc);
typedef void  (*FnRenderBundleEncoderRelease)(void* encoder);
typedef void  (*FnRenderBundleEncoderSetPipeline)(void* encoder, void* pipeline);
typedef void  (*FnRenderBundleEncoderSetBindGroup)(void* encoder, uint32_t index, void* bind_group, size_t dynamic_offset_count, const uint32_t* dynamic_offsets);
typedef void  (*FnRenderBundleEncoderSetVertexBuffer)(void* encoder, uint32_t slot, void* buffer, uint64_t offset, uint64_t size);
typedef void  (*FnRenderBundleEncoderSetIndexBuffer)(void* encoder, void* buffer, uint32_t format, uint64_t offset, uint64_t size);
typedef void  (*FnRenderBundleEncoderDraw)(void* encoder, uint32_t vertex_count, uint32_t instance_count, uint32_t first_vertex, uint32_t first_instance);
typedef void  (*FnRenderBundleEncoderDrawIndexed)(void* encoder, uint32_t index_count, uint32_t instance_count, uint32_t first_index, int32_t base_vertex, uint32_t first_instance);
typedef void* (*FnRenderBundleEncoderFinish)(void* encoder, const void* desc);
typedef void  (*FnRenderBundleRelease)(void* bundle);
typedef void* (*FnMetalBridgeCreateSurfaceHost)(void** layer_out);
typedef void  (*FnMetalBridgeConfigureSurfaceHost)(void* host, uint32_t width, uint32_t height);
typedef void  (*FnMetalBridgeRelease)(void* handle);

/* Extern declarations for manual function pointers */
extern FnAdapterGetPreferredCanvasFormat pfn_doeNativeAdapterGetPreferredCanvasFormat;
extern FnDeviceAddEventListener pfn_doeNativeDeviceAddEventListener;
extern FnDeviceRemoveEventListener pfn_doeNativeDeviceRemoveEventListener;
extern FnDeviceImportExternalTexture pfn_doeNativeDeviceImportExternalTexture;
extern FnObjectSetLabel pfn_doeNativeObjectSetLabel;
extern FnBindingCommandsSetImmediates pfn_doeNativeBindingCommandsSetImmediates;
extern FnComputePassSetImmediates pfn_doeNativeComputePassSetImmediates;
extern FnRenderPassSetImmediates pfn_doeNativeRenderPassSetImmediates;
extern FnRenderBundleEncoderSetImmediates pfn_doeNativeRenderBundleEncoderSetImmediates;
extern FnRenderPassSetViewport pfn_doeNativeRenderPassSetViewport;
extern FnRenderPassSetScissorRect pfn_doeNativeRenderPassSetScissorRect;
extern FnRenderPassSetBlendConstant pfn_doeNativeRenderPassSetBlendConstant;
extern FnRenderPassSetStencilReference pfn_doeNativeRenderPassSetStencilReference;
extern FnRenderPassBeginOcclusionQuery pfn_doeNativeRenderPassBeginOcclusionQuery;
extern FnRenderPassEndOcclusionQuery pfn_doeNativeRenderPassEndOcclusionQuery;
extern FnRenderPassPushDebugGroup pfn_doeNativeRenderPassPushDebugGroup;
extern FnRenderPassPopDebugGroup pfn_doeNativeRenderPassPopDebugGroup;
extern FnRenderPassInsertDebugMarker pfn_doeNativeRenderPassInsertDebugMarker;
extern FnRenderBundleEncoderPushDebugGroup pfn_doeNativeRenderBundleEncoderPushDebugGroup;
extern FnRenderBundleEncoderPopDebugGroup pfn_doeNativeRenderBundleEncoderPopDebugGroup;
extern FnRenderBundleEncoderInsertDebugMarker pfn_doeNativeRenderBundleEncoderInsertDebugMarker;
extern FnAdapterGetInfo pfn_doeNativeAdapterGetInfo;
extern FnAdapterFreeInfo pfn_doeNativeAdapterFreeInfo;
extern FnAdapterGetPciIdentity pfn_doeNativeAdapterGetPciIdentity;
extern FnShaderModuleGetCompilationInfo pfn_doeNativeShaderModuleGetCompilationInfo;
extern FnDevicePushErrorScope pfn_doeNativeDevicePushErrorScope;
extern FnDevicePopErrorScope pfn_doeNativeDevicePopErrorScope;
extern FnDevicePushErrorScope pfn_wgpuDevicePushErrorScope;
extern FnDevicePopErrorScope pfn_wgpuDevicePopErrorScope;
extern FnDeviceSetUncapturedErrorCallback pfn_doeNativeDeviceSetUncapturedErrorCallback;
extern FnDeviceRegisterLostCallback pfn_doeNativeDeviceRegisterLostCallback;
extern FnRenderPipelineGetBindGroupLayout pfn_doeNativeRenderPipelineGetBindGroupLayout;
extern FnCommandEncoderClearBuffer pfn_doeNativeCommandEncoderClearBuffer;
extern FnCommandEncoderCopyTextureToTexture pfn_doeNativeCommandEncoderCopyTextureToTexture;
extern FnWgpuCommandEncoderCopyTextureToTexture pfn_wgpuCommandEncoderCopyTextureToTexture;
extern FnQueueWriteTexture pfn_doeNativeQueueWriteTexture;
extern FnDeviceCreateRenderBundleEncoder pfn_doeNativeDeviceCreateRenderBundleEncoder;
extern FnRenderBundleEncoderRelease pfn_doeNativeRenderBundleEncoderRelease;
extern FnRenderBundleEncoderSetPipeline pfn_doeNativeRenderBundleEncoderSetPipeline;
extern FnRenderBundleEncoderSetBindGroup pfn_doeNativeRenderBundleEncoderSetBindGroup;
extern FnRenderBundleEncoderSetVertexBuffer pfn_doeNativeRenderBundleEncoderSetVertexBuffer;
extern FnRenderBundleEncoderSetIndexBuffer pfn_doeNativeRenderBundleEncoderSetIndexBuffer;
extern FnRenderBundleEncoderDraw pfn_doeNativeRenderBundleEncoderDraw;
extern FnRenderBundleEncoderDrawIndexed pfn_doeNativeRenderBundleEncoderDrawIndexed;
extern FnRenderBundleEncoderFinish pfn_doeNativeRenderBundleEncoderFinish;
extern FnRenderBundleRelease pfn_doeNativeRenderBundleRelease;
extern FnMetalBridgeCreateSurfaceHost pfn_metalBridgeCreateSurfaceHost;
extern FnMetalBridgeConfigureSurfaceHost pfn_metalBridgeConfigureSurfaceHost;
extern FnMetalBridgeRelease pfn_metalBridgeRelease;

/* ================================================================
 * Shared structs and globals
 * ================================================================ */

typedef struct DeviceCallbackBinding {
    void* device;
    napi_threadsafe_function tsfn;
    napi_ref value_ref;
    struct DeviceCallbackBinding* next;
} DeviceCallbackBinding;

typedef struct { napi_env env; napi_deferred deferred; } PopErrorScopeRequest;
typedef struct { uint32_t error_type; char* message; } UncapturedCallbackData;
typedef struct { uint32_t reason; char* message; } LostCallbackData;
typedef struct { uint32_t status; WGPUAdapter adapter; uint32_t done; char message[DOE_ERROR_BUF_CAP]; } AdapterRequestResult;
typedef struct { uint32_t status; WGPUDevice device; uint32_t done; char message[DOE_ERROR_BUF_CAP]; } DeviceRequestResult;
typedef struct { uint32_t status; uint32_t done; char message[DOE_ERROR_BUF_CAP]; } BufferMapResult;
typedef struct { uint32_t status; uint32_t done; char message[DOE_ERROR_BUF_CAP]; } QueueWorkDoneResult;
typedef struct { uint32_t done; uint32_t error_type; char message[DOE_ERROR_BUF_CAP]; } DevicePopErrorScopeResult;

extern void* g_lib;
extern uint64_t g_timeout_ns;
extern DeviceCallbackBinding* g_uncaptured_bindings;
extern DeviceCallbackBinding* g_lost_bindings;

/* Native-direct property key constants */
#define DOE_DIRECT_NATIVE "__doe_native"
#define DOE_DIRECT_INSTANCE "__doe_instance"
#define DOE_DIRECT_QUEUE "__doe_queue"
#define DOE_DIRECT_QUEUE_NATIVE "__doe_queue_native"
#define DOE_DIRECT_SUBMITTED_SERIAL "__doe_submitted_serial"
#define DOE_DIRECT_COMPLETED_SERIAL "__doe_completed_serial"
#define DOE_DIRECT_DIAG_SUBMIT_WAIT_MS "__doe_diag_submit_wait_ms"
#define DOE_DIRECT_DIAG_QUEUE_FLUSH_MS "__doe_diag_queue_flush_ms"
#define DOE_DIRECT_DIAG_MAP_ASYNC_MS "__doe_diag_map_async_ms"
#define DOE_DIRECT_DIAG_MAP_QUEUE_FLUSH_MS "__doe_diag_map_queue_flush_ms"
#define DOE_DIRECT_DIAG_GET_MAPPED_RANGE_MS "__doe_diag_get_mapped_range_ms"
#define DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_QUEUE_WAIT_COMPLETED_MS "__doe_diag_map_read_copy_unmap_queue_wait_completed_ms"
#define DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_DEFERRED_COPY_MS "__doe_diag_map_read_copy_unmap_deferred_copy_ms"
#define DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_DEFERRED_RESOLVE_MS "__doe_diag_map_read_copy_unmap_deferred_resolve_ms"
#define DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_MAP_MS "__doe_diag_map_read_copy_unmap_map_ms"
#define DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_COPY_MS "__doe_diag_map_read_copy_unmap_copy_ms"
#define DOE_DIRECT_DIAG_MAP_READ_COPY_UNMAP_UNMAP_MS "__doe_diag_map_read_copy_unmap_unmap_ms"

typedef struct { WGPUInstance instance; void* native; } NativeDirectHandleCache;
typedef struct { WGPUInstance instance; WGPUQueue queue; uint32_t submitted_serial; uint32_t completed_serial; } NativeDirectQueueCache;
typedef struct {
    WGPUInstance instance; WGPUBuffer buffer; uint64_t size; uint64_t usage;
    napi_ref queue_ref; napi_ref mapped_range_ref; size_t mapped_offset; size_t mapped_size; void* mapped_ptr;
} NativeDirectBufferCache;

/* Native-direct method refs (one per cached method) */
extern napi_ref native_direct_method_gpu_request_adapter_ref;
extern napi_ref native_direct_method_adapter_request_device_ref;
extern napi_ref native_direct_method_adapter_destroy_ref;
extern napi_ref native_direct_method_queue_submit_ref;
extern napi_ref native_direct_method_queue_write_buffer_ref;
extern napi_ref native_direct_method_queue_write_buffer_batch_ref;
extern napi_ref native_direct_method_queue_on_submitted_work_done_ref;
extern napi_ref native_direct_method_device_create_buffer_ref;
extern napi_ref native_direct_method_device_create_shader_module_ref;
extern napi_ref native_direct_method_device_create_compute_pipeline_ref;
extern napi_ref native_direct_method_device_create_compute_pipeline_async_ref;
extern napi_ref native_direct_method_device_create_bind_group_layout_ref;
extern napi_ref native_direct_method_device_create_bind_group_ref;
extern napi_ref native_direct_method_device_create_pipeline_layout_ref;
extern napi_ref native_direct_method_device_create_command_encoder_ref;
extern napi_ref native_direct_method_device_destroy_ref;
extern napi_ref native_direct_method_buffer_map_async_ref;
extern napi_ref native_direct_method_buffer_get_mapped_range_ref;
extern napi_ref native_direct_method_buffer_read_copy_ref;
extern napi_ref native_direct_method_buffer_map_read_copy_unmap_ref;
extern napi_ref native_direct_method_buffer_unmap_ref;
extern napi_ref native_direct_method_buffer_destroy_ref;
extern napi_ref native_direct_method_command_encoder_begin_compute_pass_ref;
extern napi_ref native_direct_method_command_encoder_copy_buffer_to_buffer_ref;
extern napi_ref native_direct_method_command_encoder_finish_ref;
extern napi_ref native_direct_method_compute_pass_set_pipeline_ref;
extern napi_ref native_direct_method_compute_pass_set_bind_group_ref;
extern napi_ref native_direct_method_compute_pass_dispatch_workgroups_ref;
extern napi_ref native_direct_method_compute_pass_dispatch_workgroups_indirect_ref;
extern napi_ref native_direct_method_compute_pass_end_ref;
extern napi_ref native_direct_method_compute_pass_set_immediates_ref;
extern napi_ref native_direct_method_compute_pass_push_debug_group_ref;
extern napi_ref native_direct_method_compute_pass_pop_debug_group_ref;
extern napi_ref native_direct_method_compute_pass_insert_debug_marker_ref;
extern napi_ref native_direct_method_render_pass_set_immediates_ref;
extern napi_ref native_direct_method_render_pass_set_viewport_ref;
extern napi_ref native_direct_method_render_pass_set_scissor_rect_ref;
extern napi_ref native_direct_method_render_pass_set_blend_constant_ref;
extern napi_ref native_direct_method_render_pass_set_stencil_reference_ref;
extern napi_ref native_direct_method_render_pass_push_debug_group_ref;
extern napi_ref native_direct_method_render_pass_pop_debug_group_ref;
extern napi_ref native_direct_method_render_pass_insert_debug_marker_ref;
extern napi_ref native_direct_method_render_pass_draw_indirect_ref;
extern napi_ref native_direct_method_render_pass_draw_indexed_indirect_ref;
extern napi_ref native_direct_method_render_bundle_encoder_set_immediates_ref;
extern napi_ref native_direct_method_render_bundle_encoder_draw_indirect_ref;
extern napi_ref native_direct_method_render_bundle_encoder_draw_indexed_indirect_ref;
extern napi_ref native_direct_method_adapter_get_preferred_canvas_format_ref;
extern napi_ref native_direct_method_device_add_event_listener_ref;
extern napi_ref native_direct_method_device_remove_event_listener_ref;
extern napi_ref native_direct_method_device_import_external_texture_ref;
extern napi_ref native_direct_method_command_encoder_clear_buffer_ref;
extern napi_ref native_direct_method_command_encoder_copy_texture_to_texture_ref;
extern napi_ref native_direct_method_queue_write_texture_ref;
extern napi_ref native_direct_method_adapter_get_info_ref;
extern napi_ref native_direct_method_shader_module_get_compilation_info_ref;
extern napi_ref native_direct_resolved_undefined_promise_ref;

/* ================================================================
 * N-API utility macros
 * ================================================================ */

#define NAPI_THROW(env, msg) do { napi_throw_error(env, "DOE_ERROR", msg); return NULL; } while(0)
#define MAX_NAPI_ARGS 16
#define NAPI_ASSERT_ARGC(env, info, n) \
    size_t _argc = (n); napi_value _args[MAX_NAPI_ARGS]; \
    if ((n) > MAX_NAPI_ARGS) NAPI_THROW(env, "too many args"); \
    if (napi_get_cb_info(env, info, &_argc, _args, NULL, NULL) != napi_ok) NAPI_THROW(env, "napi_get_cb_info failed")
#define CHECK_LIB_LOADED(env) do { if (!g_lib) NAPI_THROW(env, "Library not loaded"); } while(0)
#define LOAD_SYM(name) pfn_##name = (PFN_##name)LIB_SYM(g_lib, #name)
#define EXPORT_FN(name, fn) { name, 0, fn, 0, 0, 0, napi_default, 0 }

/* ================================================================
 * Shared function prototypes (helpers used across files)
 * ================================================================ */

/* Property helpers */
void* unwrap_ptr(napi_env env, napi_value val);
napi_value wrap_ptr(napi_env env, void* ptr);
uint32_t get_uint32_prop(napi_env env, napi_value obj, const char* key);
int64_t get_int64_prop(napi_env env, napi_value obj, const char* key);
int64_t get_int64_value(napi_env env, napi_value value);
double get_double_prop(napi_env env, napi_value obj, const char* key);
bool get_bool_prop(napi_env env, napi_value obj, const char* key);
bool has_prop(napi_env env, napi_value obj, const char* key);
napi_value get_prop(napi_env env, napi_value obj, const char* key);
char* dup_string_value(napi_env env, napi_value value, size_t* out_len);
napi_valuetype prop_type(napi_env env, napi_value obj, const char* key);

/* Error/string helpers */
uint64_t current_timeout_ns(void);
void copy_library_error_message(char* out, size_t out_len);
void copy_library_error_meta(PFN_doeNativeCopyLastErrorMessage fn, char* out, size_t out_len);
uint64_t monotonic_now_ns(void);
void wait_slice(void);
int process_events_until(WGPUInstance inst, volatile uint32_t* done, uint64_t timeout_ns);
void copy_string_view_message(WGPUStringView message, char* out, size_t out_len);
char* dup_string_view(WGPUStringView message);
char* dup_c_string(const char* message_ptr, size_t message_len);
const char* error_type_string(uint32_t error_type);
const char* lost_reason_string(uint32_t reason);
napi_value throw_status_error(napi_env env, const char* code, const char* prefix, uint32_t status, const char* detail);

/* Callback binding helpers */
DeviceCallbackBinding* binding_take(DeviceCallbackBinding** head, void* device);
void binding_insert(DeviceCallbackBinding** head, DeviceCallbackBinding* binding);
void binding_finalize(napi_env env, void* finalize_data, void* finalize_hint);
void release_binding(DeviceCallbackBinding* binding);
DeviceCallbackBinding* create_device_callback_binding(napi_env env, void* device, napi_value js_cb, const char* resource_name, napi_threadsafe_function_call_js call_js, napi_value retained_value);
napi_value create_gpu_error_value(napi_env env, uint32_t error_type, const char* message);
void pop_error_scope_native_callback(uint32_t error_type, WGPUStringView message, void* userdata1, void* userdata2);
void js_call_uncaptured_error(napi_env env, napi_value js_cb, void* context, void* data);
void js_call_lost_callback(napi_env env, napi_value js_cb, void* context, void* data);
void uncaptured_error_native_callback(uint32_t error_type, WGPUStringView message, void* userdata1, void* userdata2);
void lost_native_callback(uint32_t reason, const char* message_ptr, size_t message_len, void* userdata);

/* Map/queue callbacks */
void buffer_map_callback(uint32_t status, WGPUStringView message, void* userdata1, void* userdata2);
void queue_work_done_callback(uint32_t status, WGPUStringView message, void* userdata1, void* userdata2);
void adapter_callback(uint32_t status, WGPUAdapter adapter, WGPUStringView message, void* userdata1, void* userdata2);
void device_callback(uint32_t status, WGPUDevice device, WGPUStringView message, void* userdata1, void* userdata2);

/* Pipeline helpers */
size_t parse_js_override_constants(napi_env env, napi_value constants_obj, WGPUConstantEntry** out_entries);
void free_override_constants(WGPUConstantEntry* entries, size_t count);

/* Format converters */
uint32_t texture_format_from_string(napi_env env, napi_value val);
uint32_t primitive_topology_from_string(napi_env env, napi_value val);
uint32_t front_face_from_string(napi_env env, napi_value val);
uint32_t cull_mode_from_string(napi_env env, napi_value val);
uint32_t buffer_binding_type_from_string(napi_env env, napi_value val);
uint32_t sampler_binding_type_from_string(napi_env env, napi_value val);
uint32_t texture_sample_type_from_string(napi_env env, napi_value val);
uint32_t texture_view_dimension_from_string(napi_env env, napi_value val);
uint32_t storage_texture_access_from_string(napi_env env, napi_value val);
uint32_t filter_mode_from_string(napi_env env, napi_value val);
uint32_t address_mode_from_string(napi_env env, napi_value val);
uint32_t compare_func_from_value(napi_env env, napi_value val);
uint32_t vertex_step_mode_from_value(napi_env env, napi_value val);
uint32_t vertex_format_from_value(napi_env env, napi_value val);
uint32_t index_format_from_value(napi_env env, napi_value val);
uint32_t blend_factor_from_string(napi_env env, napi_value val);
uint32_t blend_operation_from_string(napi_env env, napi_value val);
const char* texture_format_u32_to_string(uint32_t fmt);
const char* doe_binding_kind_name(uint32_t kind);
const char* doe_binding_space_name(uint32_t addr_space);
const char* doe_binding_access_name(uint32_t access);

/* Compilation message helpers (doe_napi_shader.c) */
void ensure_compilation_message_fields(napi_env env, napi_value msg);

/* Device label stubs */
napi_value doe_device_get_label(napi_env env, napi_callback_info info);
napi_value doe_device_set_label(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_create(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_configure(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_get_current_texture(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_present(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_unconfigure(napi_env env, napi_callback_info info);
napi_value doe_canvas_surface_release(napi_env env, napi_callback_info info);

/* Limits helper */
napi_value create_limits_object(napi_env env, const WGPULimits* limits);
void pop_error_scope_callback(uint32_t error_type, WGPUStringView message, void* userdata1, void* userdata2);
void extract_buffer_data(napi_env env, napi_value val, void** out_ptr, size_t* out_len);

/* Native-direct helpers */
napi_value native_direct_resolved_promise(napi_env env, napi_value value);
napi_value native_direct_resolved_undefined_promise(napi_env env);
void native_direct_set_external_prop(napi_env env, napi_value obj, const char* key, void* ptr);
void native_direct_set_object_prop(napi_env env, napi_value obj, const char* key, napi_value value);
void native_direct_set_uint32_prop(napi_env env, napi_value obj, const char* key, uint32_t value);
void native_direct_set_double_prop(napi_env env, napi_value obj, const char* key, double value);
double native_direct_elapsed_ms(uint64_t started_ns);
void* native_direct_unwrap_external_prop(napi_env env, napi_value obj, const char* key);
uint32_t native_direct_get_uint32_prop(napi_env env, napi_value obj, const char* key);
bool native_direct_queue_has_pending(napi_env env, napi_value queue_obj);
void native_direct_queue_mark_submitted(napi_env env, napi_value queue_obj);
void native_direct_queue_mark_done(napi_env env, napi_value queue_obj);
napi_value native_direct_create_empty_set(napi_env env);
napi_value native_direct_create_empty_object(napi_env env);
void native_direct_add_cached_method(napi_env env, napi_value obj, const char* name, napi_callback fn, napi_ref* method_ref);
void native_direct_wrap_handle_cache(napi_env env, napi_value obj, WGPUInstance instance, void* native);
void native_direct_wrap_queue_cache(napi_env env, napi_value obj, WGPUInstance instance, WGPUQueue queue);
void native_direct_wrap_buffer_cache(napi_env env, napi_value obj, WGPUInstance instance, WGPUBuffer buffer, uint64_t size, uint64_t usage, napi_value queue_obj);
NativeDirectHandleCache* native_direct_get_handle_cache(napi_env env, napi_value obj);
NativeDirectQueueCache* native_direct_get_queue_cache(napi_env env, napi_value obj);
NativeDirectBufferCache* native_direct_get_buffer_cache(napi_env env, napi_value obj);
void native_direct_invalidate_buffer_mapped_range_cache(napi_env env, NativeDirectBufferCache* cache);
WGPUAdapter native_direct_request_adapter_sync(napi_env env, WGPUInstance inst, napi_value options);
WGPUDevice native_direct_request_device_sync(napi_env env, WGPUInstance inst, WGPUAdapter adapter);
WGPULimits native_direct_query_adapter_limits(WGPUAdapter adapter, bool* ok);
WGPULimits native_direct_query_device_limits(WGPUDevice device, bool* ok);

/* Native-direct object constructors */
napi_value create_native_direct_gpu_object(napi_env env, WGPUInstance instance);
napi_value create_native_direct_adapter_object(napi_env env, WGPUInstance instance, WGPUAdapter adapter);
napi_value create_native_direct_device_object(napi_env env, WGPUInstance instance, WGPUDevice device);
napi_value create_native_direct_queue_object(napi_env env, WGPUInstance instance, WGPUQueue queue);
napi_value create_native_direct_buffer_object(napi_env env, WGPUInstance instance, napi_value queue_obj, WGPUBuffer buffer, uint64_t size, uint64_t usage);
napi_value create_native_direct_bind_group_layout_object(napi_env env, WGPUBindGroupLayout layout);
napi_value create_native_direct_bind_group_object(napi_env env, WGPUBindGroup group);
napi_value create_native_direct_pipeline_layout_object(napi_env env, WGPUPipelineLayout layout);
napi_value create_native_direct_shader_module_object(napi_env env, WGPUShaderModule shader_module);
napi_value create_native_direct_compute_pipeline_object(napi_env env, WGPUComputePipeline pipeline);
napi_value create_native_direct_command_encoder_object(napi_env env, WGPUCommandEncoder encoder);
napi_value create_native_direct_command_buffer_object(napi_env env, WGPUCommandBuffer command_buffer);
napi_value create_native_direct_compute_pass_object(napi_env env, WGPUComputePassEncoder pass);
napi_value create_native_direct_render_pass_object(napi_env env, WGPURenderPassEncoder pass);
