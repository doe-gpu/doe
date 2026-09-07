#include "webgpu.h"
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

extern WGPUCommandBuffer doeNativeCreateComputeDispatchCopyCommandBuffer(
    WGPUDevice, WGPUComputePipeline, WGPUBindGroup*, uint32_t, uint32_t, uint32_t, uint32_t,
    WGPUBuffer, uint64_t, WGPUBuffer, uint64_t, uint64_t);
extern WGPUCommandBuffer doeNativeCreateComputeDispatchBatchCopyCommandBuffer(
    WGPUDevice, size_t, WGPUComputePipeline*, WGPUBindGroup*, const uint32_t*, const uint32_t*,
    WGPUBuffer, uint64_t, WGPUBuffer, uint64_t, uint64_t);

enum { ELEMENT_COUNT = 4, NATIVE_BIND_GROUP_STRIDE = 4, AMD_PCI_VENDOR_ID = 0x1002 };

static void adapter_ready(WGPURequestAdapterStatus status, WGPUAdapter adapter,
                          WGPUStringView message, void* result, void* unused) {
    (void)message; (void)unused;
    if (status == WGPURequestAdapterStatus_Success) *(WGPUAdapter*)result = adapter;
}

static void device_ready(WGPURequestDeviceStatus status, WGPUDevice device,
                         WGPUStringView message, void* result, void* unused) {
    (void)message; (void)unused;
    if (status == WGPURequestDeviceStatus_Success) *(WGPUDevice*)result = device;
}

static void map_ready(WGPUMapAsyncStatus status, WGPUStringView message, void* result, void* unused) {
    (void)message; (void)unused;
    *(bool*)result = status == WGPUMapAsyncStatus_Success;
}

static void scope_ready(WGPUPopErrorScopeStatus status, WGPUErrorType type, WGPUStringView message,
                        void* result, void* unused) {
    (void)message; (void)unused;
    *(bool*)result = status == WGPUPopErrorScopeStatus_Success && type == WGPUErrorType_Validation;
}

static bool pop_validation(WGPUInstance instance, WGPUDevice device) {
    bool validation = false;
    WGPUPopErrorScopeCallbackInfo callback = WGPU_POP_ERROR_SCOPE_CALLBACK_INFO_INIT;
    callback.mode = WGPUCallbackMode_AllowSpontaneous;
    callback.callback = scope_ready;
    callback.userdata1 = &validation;
    wgpuDevicePopErrorScope(device, callback);
    wgpuInstanceProcessEvents(instance);
    return validation;
}

static bool invalid_pass_lifetimes(WGPUInstance instance, WGPUDevice device, WGPUQueue queue) {
    enum { FINISH_OPEN, END_TWICE, STALE_PASS, NESTED_PASS, PASS_CASE_COUNT };
    for (unsigned scenario = 0; scenario < PASS_CASE_COUNT; ++scenario) {
        WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(device, NULL);
        if (!encoder) return false;
        WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass(encoder, NULL);
        if (!pass) { wgpuCommandEncoderRelease(encoder); return false; }
        WGPUComputePassEncoder next = NULL;
        wgpuDevicePushErrorScope(device, WGPUErrorFilter_Validation);
        if (scenario == END_TWICE) {
            wgpuComputePassEncoderEnd(pass);
            wgpuComputePassEncoderEnd(pass);
        } else if (scenario == STALE_PASS) {
            wgpuComputePassEncoderEnd(pass);
            next = wgpuCommandEncoderBeginComputePass(encoder, NULL);
            wgpuComputePassEncoderInsertDebugMarker(pass, (WGPUStringView){"stale", 5});
        } else if (scenario == NESTED_PASS) {
            next = wgpuCommandEncoderBeginComputePass(encoder, NULL);
        }
        WGPUCommandBuffer commands = wgpuCommandEncoderFinish(encoder, NULL);
        const bool rejected_recording = pop_validation(instance, device);
        if (next) wgpuComputePassEncoderRelease(next);
        wgpuComputePassEncoderRelease(pass);
        wgpuCommandEncoderRelease(encoder);
        bool rejected_submit = false;
        if (commands) {
            wgpuDevicePushErrorScope(device, WGPUErrorFilter_Validation);
            wgpuQueueSubmit(queue, 1, &commands);
            rejected_submit = pop_validation(instance, device);
            wgpuCommandBufferRelease(commands);
        }
        if (!rejected_recording || !rejected_submit) {
            fprintf(stderr, "native pass lifecycle failed: case=%u recording=%u submission=%u\n",
                scenario, rejected_recording, rejected_submit);
            return false;
        }
    }
    printf("passed: open, ended, stale, and nested passes reject recording and submission\n");
    return true;
}

static bool texture_is_zero(WGPUInstance instance, WGPUDevice device, WGPUQueue queue,
                            WGPUTexture texture, WGPUBuffer readback) {
    WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(device, NULL);
    if (!encoder) return false;
    WGPUTexelCopyTextureInfo source = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    source.texture = texture;
    WGPUTexelCopyBufferInfo target = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
    target.buffer = readback;
    target.layout.bytesPerRow = 256;
    target.layout.rowsPerImage = 1;
    WGPUExtent3D extent = {ELEMENT_COUNT, 1, 1};
    wgpuCommandEncoderCopyTextureToBuffer(encoder, &source, &target, &extent);
    WGPUCommandBuffer commands = wgpuCommandEncoderFinish(encoder, NULL);
    wgpuCommandEncoderRelease(encoder);
    if (!commands) return false;
    wgpuQueueSubmit(queue, 1, &commands);
    wgpuCommandBufferRelease(commands);
    bool mapped = false;
    WGPUBufferMapCallbackInfo mapping = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    mapping.mode = WGPUCallbackMode_AllowSpontaneous;
    mapping.callback = map_ready;
    mapping.userdata1 = &mapped;
    wgpuBufferMapAsync(readback, WGPUMapMode_Read, 0, ELEMENT_COUNT * sizeof(uint32_t), mapping);
    wgpuInstanceProcessEvents(instance);
    if (!mapped) return false;
    const uint32_t* output = wgpuBufferGetConstMappedRange(readback, 0, ELEMENT_COUNT * sizeof(uint32_t));
    bool zero = output != NULL;
    for (size_t index = 0; output && index < ELEMENT_COUNT; ++index) zero &= output[index] == 0;
    wgpuBufferUnmap(readback);
    return zero;
}

static bool execute(WGPUInstance instance, WGPUDevice device, WGPUQueue queue, bool batch, bool via_texture) {
    bool success = false, mapped = false;
    WGPUShaderModule shader = NULL;
    WGPUComputePipeline pipeline = NULL;
    WGPUBindGroupLayout layout = NULL;
    WGPUBindGroup group = NULL;
    WGPUBuffer storage = NULL, readback = NULL;
    WGPUTexture texture = NULL;
    WGPUCommandBuffer commands = NULL;
    const uint32_t input[ELEMENT_COUNT] = {17, 29, 43, 71};
    static const char wgsl[] =
        "@group(0) @binding(0) var<storage, read_write> values: array<u32>;"
        "@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3<u32>) {"
        "values[id.x] = values[id.x] + 1u; }";
#define REQUIRE(condition) do { if (!(condition)) { \
    fprintf(stderr, "native recorded compute failed at line %d: %s\n", __LINE__, #condition); \
    goto cleanup; } } while (0)
    WGPUShaderSourceWGSL source = WGPU_SHADER_SOURCE_WGSL_INIT;
    source.code = (WGPUStringView){wgsl, sizeof(wgsl) - 1};
    WGPUShaderModuleDescriptor shader_desc = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
    shader_desc.nextInChain = &source.chain;
    shader = wgpuDeviceCreateShaderModule(device, &shader_desc);
    REQUIRE(shader);
    WGPUComputePipelineDescriptor pipeline_desc = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
    pipeline_desc.compute.module = shader;
    pipeline_desc.compute.entryPoint = (WGPUStringView){"main", 4};
    pipeline = wgpuDeviceCreateComputePipeline(device, &pipeline_desc);
    REQUIRE(pipeline);
    layout = wgpuComputePipelineGetBindGroupLayout(pipeline, 0);
    REQUIRE(layout);
    WGPUBufferDescriptor buffer_desc = WGPU_BUFFER_DESCRIPTOR_INIT;
    buffer_desc.size = sizeof(input);
    buffer_desc.usage = WGPUBufferUsage_Storage | WGPUBufferUsage_CopySrc | WGPUBufferUsage_CopyDst;
    storage = wgpuDeviceCreateBuffer(device, &buffer_desc);
    if (via_texture) buffer_desc.size = 256;
    buffer_desc.usage = WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst;
    readback = wgpuDeviceCreateBuffer(device, &buffer_desc);
    REQUIRE(storage && readback);
    wgpuQueueWriteBuffer(queue, storage, 0, input, sizeof(input));
    WGPUBindGroupEntry entry = WGPU_BIND_GROUP_ENTRY_INIT;
    entry.buffer = storage;
    entry.size = sizeof(input);
    WGPUBindGroupDescriptor group_desc = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
    group_desc.layout = layout;
    group_desc.entryCount = 1;
    group_desc.entries = &entry;
    group = wgpuDeviceCreateBindGroup(device, &group_desc);
    REQUIRE(group);

    WGPUCommandBuffer invalid = doeNativeCreateComputeDispatchCopyCommandBuffer(
        device, pipeline, &group, 1, ELEMENT_COUNT, 1, 1, storage, 0, NULL, 0, sizeof(input));
    if (invalid) wgpuCommandBufferRelease(invalid);
    REQUIRE(!invalid);
    if (via_texture) {
        WGPUTextureDescriptor texture_desc = WGPU_TEXTURE_DESCRIPTOR_INIT;
        texture_desc.size = (WGPUExtent3D){ELEMENT_COUNT, 1, 1};
        texture_desc.dimension = WGPUTextureDimension_2D;
        texture_desc.format = WGPUTextureFormat_RGBA8Unorm;
        texture_desc.usage = WGPUTextureUsage_CopySrc | WGPUTextureUsage_CopyDst;
        texture = wgpuDeviceCreateTexture(device, &texture_desc);
        REQUIRE(texture);
        WGPUTexelCopyTextureInfo image = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
        image.texture = texture;
        WGPUTexelCopyBufferInfo source_buffer = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
        source_buffer.buffer = storage;
        source_buffer.layout.bytesPerRow = 256;
        source_buffer.layout.rowsPerImage = 1;
        WGPUTexelCopyBufferInfo target_buffer = source_buffer;
        target_buffer.buffer = readback;
        const uint32_t zeros[ELEMENT_COUNT] = {0};
        wgpuQueueWriteTexture(queue, &image, zeros, sizeof(zeros), &source_buffer.layout, &texture_desc.size);
        WGPUCommandEncoder abandoned = wgpuDeviceCreateCommandEncoder(device, NULL);
        REQUIRE(abandoned);
        wgpuCommandEncoderCopyBufferToTexture(abandoned, &source_buffer, &image, &texture_desc.size);
        wgpuCommandEncoderRelease(abandoned);
        REQUIRE(texture_is_zero(instance, device, queue, texture, readback));
        WGPUCommandEncoder encoder = wgpuDeviceCreateCommandEncoder(device, NULL);
        REQUIRE(encoder);
        WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass(encoder, NULL);
        if (!pass) { wgpuCommandEncoderRelease(encoder); REQUIRE(pass); }
        wgpuComputePassEncoderSetPipeline(pass, pipeline);
        wgpuComputePassEncoderSetBindGroup(pass, 0, group, 0, NULL);
        wgpuComputePassEncoderDispatchWorkgroups(pass, ELEMENT_COUNT, 1, 1);
        wgpuComputePassEncoderEnd(pass);
        wgpuComputePassEncoderRelease(pass);
        wgpuCommandEncoderCopyBufferToTexture(encoder, &source_buffer, &image, &texture_desc.size);
        wgpuCommandEncoderCopyTextureToBuffer(encoder, &image, &target_buffer, &texture_desc.size);
        commands = wgpuCommandEncoderFinish(encoder, NULL);
        wgpuCommandEncoderRelease(encoder);
        wgpuTextureRelease(texture); texture = NULL;
    } else if (batch) {
        WGPUComputePipeline pipelines[] = {pipeline, pipeline};
        WGPUBindGroup groups[2 * NATIVE_BIND_GROUP_STRIDE] = {0};
        groups[0] = group;
        groups[NATIVE_BIND_GROUP_STRIDE] = group;
        const uint32_t counts[] = {1, 1};
        const uint32_t dimensions[] = {ELEMENT_COUNT, 1, 1, ELEMENT_COUNT, 1, 1};
        commands = doeNativeCreateComputeDispatchBatchCopyCommandBuffer(
            device, 2, pipelines, groups, counts, dimensions, storage, 0, readback, 0, sizeof(input));
    } else {
        commands = doeNativeCreateComputeDispatchCopyCommandBuffer(
            device, pipeline, &group, 1, ELEMENT_COUNT, 1, 1, storage, 0, readback, 0, sizeof(input));
    }
    REQUIRE(commands);
    wgpuBindGroupRelease(group); group = NULL;
    wgpuComputePipelineRelease(pipeline); pipeline = NULL;
    wgpuShaderModuleRelease(shader); shader = NULL;
    wgpuBindGroupLayoutRelease(layout); layout = NULL;
    wgpuBufferRelease(storage); storage = NULL;
    wgpuQueueSubmit(queue, 1, &commands);
    wgpuCommandBufferRelease(commands); commands = NULL;
    WGPUBufferMapCallbackInfo mapping = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    mapping.mode = WGPUCallbackMode_AllowSpontaneous;
    mapping.callback = map_ready;
    mapping.userdata1 = &mapped;
    wgpuBufferMapAsync(readback, WGPUMapMode_Read, 0, sizeof(input), mapping);
    wgpuInstanceProcessEvents(instance);
    REQUIRE(mapped);
    const uint32_t* output = wgpuBufferGetConstMappedRange(readback, 0, sizeof(input));
    REQUIRE(output);
    for (size_t index = 0; index < ELEMENT_COUNT; ++index)
        REQUIRE(output[index] == input[index] + (batch ? 2u : 1u));
    if (via_texture)
        printf("passed: abandoned texture copy, caller release, ordered GPU dispatch/texture copy/readback\n");
    else
        printf("passed: %s native constructor, failed construction, caller release, dispatch/copy/readback\n", batch ? "batch" : "single");
    success = true;
cleanup:
    if (mapped && readback) wgpuBufferUnmap(readback);
    if (commands) wgpuCommandBufferRelease(commands);
    if (group) wgpuBindGroupRelease(group);
    if (layout) wgpuBindGroupLayoutRelease(layout);
    if (pipeline) wgpuComputePipelineRelease(pipeline);
    if (shader) wgpuShaderModuleRelease(shader);
    if (storage) wgpuBufferRelease(storage);
    if (readback) wgpuBufferRelease(readback);
    if (texture) wgpuTextureRelease(texture);
    return success;
#undef REQUIRE
}

int main(void) {
    int result = 1;
    WGPUInstance instance = wgpuCreateInstance(NULL);
    WGPUAdapter adapter = NULL;
    WGPUDevice device = NULL;
    WGPUQueue queue = NULL;
    if (!instance) goto cleanup;
    WGPURequestAdapterOptions options = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
    options.backendType = WGPUBackendType_Vulkan;
    WGPURequestAdapterCallbackInfo adapter_callback = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
    adapter_callback.mode = WGPUCallbackMode_AllowSpontaneous;
    adapter_callback.callback = adapter_ready;
    adapter_callback.userdata1 = &adapter;
    wgpuInstanceRequestAdapter(instance, &options, adapter_callback);
    wgpuInstanceProcessEvents(instance);
    if (!adapter) goto cleanup;
    WGPUAdapterInfo info = WGPU_ADAPTER_INFO_INIT;
    if (wgpuAdapterGetInfo(adapter, &info) != WGPUStatus_Success) goto cleanup;
    const bool hardware_vulkan = info.backendType == WGPUBackendType_Vulkan &&
        info.adapterType != WGPUAdapterType_CPU && info.vendorID == AMD_PCI_VENDOR_ID;
    printf("backend=%u adapter=%u vendor=%u device=%u GPU=%.*s description=%.*s\n",
        info.backendType, info.adapterType, info.vendorID, info.deviceID,
        (int)info.device.length, info.device.data, (int)info.description.length, info.description.data);
    wgpuAdapterInfoFreeMembers(info);
    if (!hardware_vulkan) goto cleanup;
    WGPURequestDeviceCallbackInfo device_callback = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
    device_callback.mode = WGPUCallbackMode_AllowSpontaneous;
    device_callback.callback = device_ready;
    device_callback.userdata1 = &device;
    wgpuAdapterRequestDevice(adapter, NULL, device_callback);
    wgpuInstanceProcessEvents(instance);
    if (!device) goto cleanup;
    queue = wgpuDeviceGetQueue(device);
    if (queue && invalid_pass_lifetimes(instance, device, queue) && execute(instance, device, queue, false, false) &&
        execute(instance, device, queue, true, false) && execute(instance, device, queue, false, true)) result = 0;
cleanup:
    if (queue) wgpuQueueRelease(queue);
    if (device) { wgpuDeviceDestroy(device); wgpuDeviceRelease(device); }
    if (adapter) wgpuAdapterRelease(adapter);
    if (instance) wgpuInstanceRelease(instance);
    return result;
}
