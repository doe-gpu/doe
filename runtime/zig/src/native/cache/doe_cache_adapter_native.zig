// doe_cache_adapter_native.zig — C ABI re-exports for pipeline cache and multi-adapter.
// Sharded from doe_wgpu_native.zig to stay under the line-limit policy.

const pipeline_cache = @import("../../runtime/cache/pipeline_cache.zig");
const multi_adapter = @import("../../runtime/device/multi_adapter.zig");

// Force both modules into the build so their exports are linked.
comptime {
    _ = pipeline_cache;
    _ = multi_adapter;
}

// ============================================================
// Pipeline cache

pub const doeNativeDeviceCreatePipelineCacheDescriptor = pipeline_cache.doeNativeDeviceCreatePipelineCacheDescriptor;
pub const doeNativePipelineCacheDescriptorRelease = pipeline_cache.doeNativePipelineCacheDescriptorRelease;
pub const doeNativeDeviceCreatePipelineCache = pipeline_cache.doeNativeDeviceCreatePipelineCache;
pub const doeNativePipelineCacheGetData = pipeline_cache.doeNativePipelineCacheGetData;
pub const doeNativePipelineCacheDataFree = pipeline_cache.doeNativePipelineCacheDataFree;
pub const doeNativePipelineCacheRelease = pipeline_cache.doeNativePipelineCacheRelease;

// ============================================================
// Multi-adapter

pub const doeNativeInstanceEnumerateAdapters = multi_adapter.doeNativeInstanceEnumerateAdapters;
pub const doeNativeAdapterListGetCount = multi_adapter.doeNativeAdapterListGetCount;
pub const doeNativeAdapterListGetInfo = multi_adapter.doeNativeAdapterListGetInfo;
pub const doeNativeAdapterListRetainDevice = multi_adapter.doeNativeAdapterListRetainDevice;
pub const doeNativeAdapterListRelease = multi_adapter.doeNativeAdapterListRelease;
pub const doeNativeInstanceSelectAdapter = multi_adapter.doeNativeInstanceSelectAdapter;
pub const doeNativeAdapterGetInfoStruct = multi_adapter.doeNativeAdapterGetInfoStruct;
pub const doeNativeDeviceRegisterLostCallback = multi_adapter.doeNativeDeviceRegisterLostCallback;
pub const doeNativeDeviceNotifyLost = multi_adapter.doeNativeDeviceNotifyLost;
