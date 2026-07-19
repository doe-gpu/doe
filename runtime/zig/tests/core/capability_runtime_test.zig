const std = @import("std");
const testing = std.testing;

const capability_runtime = @import("../../src/core/runtime/wgpu_capability_runtime.zig");
const types = @import("../../src/core/abi/wgpu_runtime_abi.zig");
const p1_procs = @import("../../src/core/abi/procs/wgpu_p1_capability_procs.zig");

// ============================================================
// AdapterProbeResult — default construction and field values

test "AdapterProbeResult can be constructed with all false defaults" {
    const result = capability_runtime.AdapterProbeResult{
        .adapter_has_timestamp_query = false,
        .has_timestamp_inside_passes = false,
        .adapter_has_multi_draw_indirect = false,
        .adapter_has_pixel_local_storage_coherent = false,
        .adapter_has_pixel_local_storage_non_coherent = false,
    };
    try testing.expect(!result.adapter_has_timestamp_query);
    try testing.expect(!result.has_timestamp_inside_passes);
    try testing.expect(!result.adapter_has_multi_draw_indirect);
    try testing.expect(!result.adapter_has_pixel_local_storage_coherent);
    try testing.expect(!result.adapter_has_pixel_local_storage_non_coherent);
}

test "AdapterProbeResult fields are independently settable" {
    const result = capability_runtime.AdapterProbeResult{
        .adapter_has_timestamp_query = true,
        .has_timestamp_inside_passes = false,
        .adapter_has_multi_draw_indirect = true,
        .adapter_has_pixel_local_storage_coherent = false,
        .adapter_has_pixel_local_storage_non_coherent = true,
    };
    try testing.expect(result.adapter_has_timestamp_query);
    try testing.expect(!result.has_timestamp_inside_passes);
    try testing.expect(result.adapter_has_multi_draw_indirect);
    try testing.expect(!result.adapter_has_pixel_local_storage_coherent);
    try testing.expect(result.adapter_has_pixel_local_storage_non_coherent);
}

// ============================================================
// DeviceProbeResult — default construction and field values

test "DeviceProbeResult can be constructed with all false defaults" {
    const result = capability_runtime.DeviceProbeResult{
        .has_timestamp_query = false,
        .has_multi_draw_indirect = false,
        .has_pixel_local_storage_coherent = false,
        .has_pixel_local_storage_non_coherent = false,
    };
    try testing.expect(!result.has_timestamp_query);
    try testing.expect(!result.has_multi_draw_indirect);
    try testing.expect(!result.has_pixel_local_storage_coherent);
    try testing.expect(!result.has_pixel_local_storage_non_coherent);
}

test "DeviceProbeResult fields are independently settable" {
    const result = capability_runtime.DeviceProbeResult{
        .has_timestamp_query = true,
        .has_multi_draw_indirect = true,
        .has_pixel_local_storage_coherent = true,
        .has_pixel_local_storage_non_coherent = true,
    };
    try testing.expect(result.has_timestamp_query);
    try testing.expect(result.has_multi_draw_indirect);
    try testing.expect(result.has_pixel_local_storage_coherent);
    try testing.expect(result.has_pixel_local_storage_non_coherent);
}

test "DeviceProbeResult has exactly four capability fields" {
    const fields = @typeInfo(capability_runtime.DeviceProbeResult).@"struct".fields;
    try testing.expectEqual(@as(usize, 4), fields.len);
}

test "AdapterProbeResult has exactly five capability fields" {
    const fields = @typeInfo(capability_runtime.AdapterProbeResult).@"struct".fields;
    try testing.expectEqual(@as(usize, 5), fields.len);
}

// ============================================================
// probeAdapterCapabilities — null/absent input handling

test "probeAdapterCapabilities returns defaults when capability_procs is null" {
    const defaults = capability_runtime.AdapterProbeResult{
        .adapter_has_timestamp_query = false,
        .has_timestamp_inside_passes = false,
        .adapter_has_multi_draw_indirect = false,
        .adapter_has_pixel_local_storage_coherent = false,
        .adapter_has_pixel_local_storage_non_coherent = false,
    };
    const result = try capability_runtime.probeAdapterCapabilities(null, null, null, defaults);
    try testing.expect(!result.adapter_has_timestamp_query);
    try testing.expect(!result.has_timestamp_inside_passes);
    try testing.expect(!result.adapter_has_multi_draw_indirect);
    try testing.expect(!result.adapter_has_pixel_local_storage_coherent);
    try testing.expect(!result.adapter_has_pixel_local_storage_non_coherent);
}

test "probeAdapterCapabilities preserves true defaults when capability_procs is null" {
    const defaults = capability_runtime.AdapterProbeResult{
        .adapter_has_timestamp_query = true,
        .has_timestamp_inside_passes = true,
        .adapter_has_multi_draw_indirect = true,
        .adapter_has_pixel_local_storage_coherent = true,
        .adapter_has_pixel_local_storage_non_coherent = true,
    };
    const result = try capability_runtime.probeAdapterCapabilities(null, null, null, defaults);
    try testing.expect(result.adapter_has_timestamp_query);
    try testing.expect(result.has_timestamp_inside_passes);
    try testing.expect(result.adapter_has_multi_draw_indirect);
    try testing.expect(result.adapter_has_pixel_local_storage_coherent);
    try testing.expect(result.adapter_has_pixel_local_storage_non_coherent);
}

test "probeAdapterCapabilities returns defaults when adapter is null" {
    // Even with a non-null (but empty) CapabilityProcs, null adapter returns defaults
    const cap = std.mem.zeroes(p1_procs.CapabilityProcs);
    const defaults = capability_runtime.AdapterProbeResult{
        .adapter_has_timestamp_query = true,
        .has_timestamp_inside_passes = false,
        .adapter_has_multi_draw_indirect = false,
        .adapter_has_pixel_local_storage_coherent = false,
        .adapter_has_pixel_local_storage_non_coherent = false,
    };
    const result = try capability_runtime.probeAdapterCapabilities(cap, null, null, defaults);
    try testing.expect(result.adapter_has_timestamp_query);
    try testing.expect(!result.has_timestamp_inside_passes);
}

// ============================================================
// probeDeviceCapabilities — null/absent input handling

test "probeDeviceCapabilities returns defaults when capability_procs is null" {
    const defaults = capability_runtime.DeviceProbeResult{
        .has_timestamp_query = false,
        .has_multi_draw_indirect = false,
        .has_pixel_local_storage_coherent = false,
        .has_pixel_local_storage_non_coherent = false,
    };
    const result = try capability_runtime.probeDeviceCapabilities(null, null, null, defaults);
    try testing.expect(!result.has_timestamp_query);
    try testing.expect(!result.has_multi_draw_indirect);
    try testing.expect(!result.has_pixel_local_storage_coherent);
    try testing.expect(!result.has_pixel_local_storage_non_coherent);
}

test "probeDeviceCapabilities preserves true defaults when capability_procs is null" {
    const defaults = capability_runtime.DeviceProbeResult{
        .has_timestamp_query = true,
        .has_multi_draw_indirect = true,
        .has_pixel_local_storage_coherent = true,
        .has_pixel_local_storage_non_coherent = true,
    };
    const result = try capability_runtime.probeDeviceCapabilities(null, null, null, defaults);
    try testing.expect(result.has_timestamp_query);
    try testing.expect(result.has_multi_draw_indirect);
    try testing.expect(result.has_pixel_local_storage_coherent);
    try testing.expect(result.has_pixel_local_storage_non_coherent);
}

test "probeDeviceCapabilities returns defaults when device is null" {
    const cap = std.mem.zeroes(p1_procs.CapabilityProcs);
    const defaults = capability_runtime.DeviceProbeResult{
        .has_timestamp_query = false,
        .has_multi_draw_indirect = true,
        .has_pixel_local_storage_coherent = false,
        .has_pixel_local_storage_non_coherent = false,
    };
    const result = try capability_runtime.probeDeviceCapabilities(cap, null, null, defaults);
    try testing.expect(!result.has_timestamp_query);
    try testing.expect(result.has_multi_draw_indirect);
}

// ============================================================
// probeInstanceCapabilities — null input handling

test "probeInstanceCapabilities does not error when capability_procs is null" {
    // Should return immediately without error
    try capability_runtime.probeInstanceCapabilities(null, null);
}

test "probeInstanceCapabilities does not error when instance is null" {
    const cap = std.mem.zeroes(p1_procs.CapabilityProcs);
    try capability_runtime.probeInstanceCapabilities(cap, null);
}

// ============================================================
// touchPrimaryObjectRefs — null input handling
// Note: touchPrimaryObjectRefs requires a valid Procs struct with non-nullable
// function pointers, so it cannot be tested without a real GPU backend.
// The null lifecycle_procs early-return path is verified by code inspection.

// ============================================================
// p1_procs helper functions — feature matching

test "hasFeature returns false for empty feature list" {
    const features = p1_procs.SupportedFeatures{
        .featureCount = 0,
        .features = null,
    };
    try testing.expect(!p1_procs.hasFeature(features, types.WGPUFeatureName_TimestampQuery));
}

test "hasFeature returns true when feature is present in list" {
    const feature_list = [_]types.WGPUFeatureName{
        types.WGPUFeatureName_TimestampQuery,
        types.WGPUFeatureName_BGRA8UnormStorage,
    };
    const features = p1_procs.SupportedFeatures{
        .featureCount = feature_list.len,
        .features = &feature_list,
    };
    try testing.expect(p1_procs.hasFeature(features, types.WGPUFeatureName_TimestampQuery));
    try testing.expect(p1_procs.hasFeature(features, types.WGPUFeatureName_BGRA8UnormStorage));
}

test "hasFeature returns false when feature is not in list" {
    const feature_list = [_]types.WGPUFeatureName{
        types.WGPUFeatureName_TimestampQuery,
    };
    const features = p1_procs.SupportedFeatures{
        .featureCount = feature_list.len,
        .features = &feature_list,
    };
    try testing.expect(!p1_procs.hasFeature(features, types.WGPUFeatureName_MultiDrawIndirect));
}

test "hasFeature checks all features in list" {
    const feature_list = [_]types.WGPUFeatureName{
        types.WGPUFeatureName_DepthClipControl,
        types.WGPUFeatureName_Depth32FloatStencil8,
        types.WGPUFeatureName_TextureCompressionBC,
        types.WGPUFeatureName_TimestampQuery,
        types.WGPUFeatureName_ShaderF16,
        types.WGPUFeatureName_MultiDrawIndirect,
    };
    const features = p1_procs.SupportedFeatures{
        .featureCount = feature_list.len,
        .features = &feature_list,
    };
    try testing.expect(p1_procs.hasFeature(features, types.WGPUFeatureName_DepthClipControl));
    try testing.expect(p1_procs.hasFeature(features, types.WGPUFeatureName_MultiDrawIndirect));
    try testing.expect(p1_procs.hasFeature(features, types.WGPUFeatureName_ShaderF16));
    try testing.expect(!p1_procs.hasFeature(features, types.WGPUFeatureName_Subgroups));
    try testing.expect(!p1_procs.hasFeature(features, types.WGPUFeatureName_Float32Filterable));
}

// ============================================================
// Feature name constants — value sanity checks

test "WGPUFeatureName_TimestampQuery has expected value 0x9" {
    try testing.expectEqual(@as(u32, 0x00000009), types.WGPUFeatureName_TimestampQuery);
}

test "WGPUFeatureName_ShaderF16 has expected value 0xB" {
    try testing.expectEqual(@as(u32, 0x0000000B), types.WGPUFeatureName_ShaderF16);
}

test "WGPUFeatureName_MultiDrawIndirect has expected Chromium extension value" {
    try testing.expectEqual(@as(u32, 0x00050031), types.WGPUFeatureName_MultiDrawIndirect);
}

test "ChromiumExperimentalTimestampQueryInsidePasses has expected extension value" {
    try testing.expectEqual(@as(u32, 0x00050003), types.WGPUFeatureName_ChromiumExperimentalTimestampQueryInsidePasses);
}

test "PixelLocalStorage feature names are distinct" {
    try testing.expect(types.WGPUFeatureName_PixelLocalStorageCoherent != types.WGPUFeatureName_PixelLocalStorageNonCoherent);
}

// ============================================================
// CapabilityProcs struct — zero initialization safety

test "CapabilityProcs zero-initialized has all null function pointers" {
    const cap = std.mem.zeroes(p1_procs.CapabilityProcs);
    try testing.expect(cap.adapter_get_features == null);
    try testing.expect(cap.adapter_get_info == null);
    try testing.expect(cap.adapter_get_instance == null);
    try testing.expect(cap.adapter_get_limits == null);
    try testing.expect(cap.device_get_adapter == null);
    try testing.expect(cap.device_get_features == null);
    try testing.expect(cap.device_get_limits == null);
    try testing.expect(cap.get_instance_features == null);
    try testing.expect(cap.get_instance_limits == null);
    try testing.expect(cap.has_instance_feature == null);
    try testing.expect(cap.get_proc_address == null);
}

// ============================================================
// WGPULimits — zero initialization and field access

test "WGPULimits zero-initialized has all zero limits" {
    const limits = std.mem.zeroes(types.WGPULimits);
    try testing.expectEqual(@as(u32, 0), limits.maxTextureDimension1D);
    try testing.expectEqual(@as(u32, 0), limits.maxTextureDimension2D);
    try testing.expectEqual(@as(u32, 0), limits.maxTextureDimension3D);
    try testing.expectEqual(@as(u32, 0), limits.maxBindGroups);
    try testing.expectEqual(@as(u64, 0), limits.maxBufferSize);
    try testing.expectEqual(@as(u64, 0), limits.maxUniformBufferBindingSize);
    try testing.expectEqual(@as(u64, 0), limits.maxStorageBufferBindingSize);
    try testing.expectEqual(@as(u32, 0), limits.maxComputeWorkgroupSizeX);
    try testing.expectEqual(@as(u32, 0), limits.maxComputeWorkgroupSizeY);
    try testing.expectEqual(@as(u32, 0), limits.maxComputeWorkgroupSizeZ);
    try testing.expectEqual(@as(u32, 0), limits.maxComputeWorkgroupsPerDimension);
}

test "WGPULimits allows setting individual limits" {
    var limits = std.mem.zeroes(types.WGPULimits);
    limits.maxBufferSize = 256 * 1024 * 1024;
    limits.maxUniformBufferBindingSize = 65536;
    limits.maxStorageBufferBindingSize = 128 * 1024 * 1024;
    limits.maxComputeWorkgroupSizeX = 256;
    limits.maxComputeWorkgroupSizeY = 256;
    limits.maxComputeWorkgroupSizeZ = 64;
    limits.maxComputeInvocationsPerWorkgroup = 256;

    try testing.expectEqual(@as(u64, 256 * 1024 * 1024), limits.maxBufferSize);
    try testing.expectEqual(@as(u64, 65536), limits.maxUniformBufferBindingSize);
    try testing.expectEqual(@as(u64, 128 * 1024 * 1024), limits.maxStorageBufferBindingSize);
    try testing.expectEqual(@as(u32, 256), limits.maxComputeWorkgroupSizeX);
}

// ============================================================
// Capability constant coherence — Chromium extension value ranges

test "Chromium extension features are in the 0x0005xxxx range" {
    try testing.expect(types.WGPUFeatureName_ChromiumExperimentalTimestampQueryInsidePasses >= 0x00050000);
    try testing.expect(types.WGPUFeatureName_PixelLocalStorageCoherent >= 0x00050000);
    try testing.expect(types.WGPUFeatureName_PixelLocalStorageNonCoherent >= 0x00050000);
    try testing.expect(types.WGPUFeatureName_MultiDrawIndirect >= 0x00050000);
}

test "Standard WebGPU features are below 0x00050000" {
    try testing.expect(types.WGPUFeatureName_TimestampQuery < 0x00050000);
    try testing.expect(types.WGPUFeatureName_ShaderF16 < 0x00050000);
    try testing.expect(types.WGPUFeatureName_DepthClipControl < 0x00050000);
    try testing.expect(types.WGPUFeatureName_Depth32FloatStencil8 < 0x00050000);
    try testing.expect(types.WGPUFeatureName_Subgroups < 0x00050000);
    try testing.expect(types.WGPUFeatureName_Float32Filterable < 0x00050000);
}

// ============================================================
// p1_procs initialization helpers — struct zero construction

test "initSupportedFeatures returns empty feature set" {
    const features = p1_procs.initSupportedFeatures();
    try testing.expectEqual(@as(usize, 0), features.featureCount);
    try testing.expect(features.features == null);
}

test "initInstanceLimits returns zeroed limits" {
    const limits = p1_procs.initInstanceLimits();
    try testing.expect(limits.nextInChain == null);
    try testing.expectEqual(@as(usize, 0), limits.timedWaitAnyMaxCount);
}

// ============================================================
// Buffer usage flag constants — bitwise distinctness

test "buffer usage flags are distinct bits" {
    try testing.expect(types.WGPUBufferUsage_MapRead != types.WGPUBufferUsage_MapWrite);
    try testing.expect(types.WGPUBufferUsage_CopySrc != types.WGPUBufferUsage_CopyDst);
    try testing.expect(types.WGPUBufferUsage_Uniform != types.WGPUBufferUsage_Storage);
    try testing.expect(types.WGPUBufferUsage_Index != types.WGPUBufferUsage_Vertex);

    // Verify no overlap between common usage flags
    try testing.expectEqual(@as(u64, 0), types.WGPUBufferUsage_CopySrc & types.WGPUBufferUsage_CopyDst);
    try testing.expectEqual(@as(u64, 0), types.WGPUBufferUsage_MapRead & types.WGPUBufferUsage_MapWrite);
    try testing.expectEqual(@as(u64, 0), types.WGPUBufferUsage_Uniform & types.WGPUBufferUsage_Storage);
}

test "buffer usage flags can be combined with bitwise OR" {
    const combined = types.WGPUBufferUsage_CopySrc | types.WGPUBufferUsage_CopyDst;
    try testing.expect(combined & types.WGPUBufferUsage_CopySrc != 0);
    try testing.expect(combined & types.WGPUBufferUsage_CopyDst != 0);
    try testing.expect(combined & types.WGPUBufferUsage_Uniform == 0);
}

// ============================================================
// Texture usage flag constants — bitwise distinctness

test "texture usage flags are distinct bits" {
    try testing.expect(types.WGPUTextureUsage_CopySrc != types.WGPUTextureUsage_CopyDst);
    try testing.expect(types.WGPUTextureUsage_TextureBinding != types.WGPUTextureUsage_StorageBinding);
    try testing.expect(types.WGPUTextureUsage_RenderAttachment != types.WGPUTextureUsage_StorageBinding);

    try testing.expectEqual(@as(u64, 0), types.WGPUTextureUsage_CopySrc & types.WGPUTextureUsage_CopyDst);
    try testing.expectEqual(@as(u64, 0), types.WGPUTextureUsage_TextureBinding & types.WGPUTextureUsage_StorageBinding);
}

// ============================================================
// WGPUQueryType constant

test "WGPUQueryType_Timestamp has expected value" {
    try testing.expectEqual(@as(u32, 0x00000002), types.WGPUQueryType_Timestamp);
}

// ============================================================
// Timestamp buffer size constant

test "TIMESTAMP_BUFFER_SIZE is 16 bytes for two u64 timestamps" {
    try testing.expectEqual(@as(u64, 16), types.TIMESTAMP_BUFFER_SIZE);
}

// ============================================================
// NativeExecutionResult status — all variants

test "NativeExecutionResult status can be ok" {
    const result = types.NativeExecutionResult{ .status = .ok, .status_message = "success" };
    try testing.expect(result.status == .ok);
}

test "NativeExecutionResult status can be unsupported" {
    const result = types.NativeExecutionResult{ .status = .unsupported, .status_message = "not available" };
    try testing.expect(result.status == .unsupported);
}

test "NativeExecutionResult status can be error" {
    const result = types.NativeExecutionResult{ .status = .@"error", .status_message = "failed" };
    try testing.expect(result.status == .@"error");
}

// ============================================================
// SupportedFeatures — iteration contract

test "SupportedFeatures with multiple features exposes all via pointer" {
    const feature_list = [_]types.WGPUFeatureName{
        types.WGPUFeatureName_DepthClipControl,
        types.WGPUFeatureName_Depth32FloatStencil8,
        types.WGPUFeatureName_TextureCompressionBC,
    };
    const features = p1_procs.SupportedFeatures{
        .featureCount = 3,
        .features = &feature_list,
    };
    try testing.expectEqual(@as(usize, 3), features.featureCount);
    try testing.expectEqual(types.WGPUFeatureName_DepthClipControl, features.features.?[0]);
    try testing.expectEqual(types.WGPUFeatureName_Depth32FloatStencil8, features.features.?[1]);
    try testing.expectEqual(types.WGPUFeatureName_TextureCompressionBC, features.features.?[2]);
}

// ============================================================
// Capability probe with zeroed procs but non-null adapter — safe no-op

test "probeAdapterCapabilities with zeroed procs and non-null adapter returns defaults unmodified" {
    const cap = std.mem.zeroes(p1_procs.CapabilityProcs);
    // Use a non-null sentinel to simulate having an adapter handle
    var sentinel: u8 = 0;
    const adapter: types.WGPUAdapter = @ptrCast(&sentinel);
    const defaults = capability_runtime.AdapterProbeResult{
        .adapter_has_timestamp_query = false,
        .has_timestamp_inside_passes = false,
        .adapter_has_multi_draw_indirect = false,
        .adapter_has_pixel_local_storage_coherent = false,
        .adapter_has_pixel_local_storage_non_coherent = false,
    };
    // With all function pointers null, the probe should skip all checks
    const result = try capability_runtime.probeAdapterCapabilities(cap, adapter, null, defaults);
    try testing.expect(!result.adapter_has_timestamp_query);
    try testing.expect(!result.has_timestamp_inside_passes);
    try testing.expect(!result.adapter_has_multi_draw_indirect);
}

test "probeDeviceCapabilities with zeroed procs and non-null device returns defaults unmodified" {
    const cap = std.mem.zeroes(p1_procs.CapabilityProcs);
    var sentinel: u8 = 0;
    const device: types.WGPUDevice = @ptrCast(&sentinel);
    const defaults = capability_runtime.DeviceProbeResult{
        .has_timestamp_query = true,
        .has_multi_draw_indirect = false,
        .has_pixel_local_storage_coherent = true,
        .has_pixel_local_storage_non_coherent = false,
    };
    const result = try capability_runtime.probeDeviceCapabilities(cap, device, null, defaults);
    // Defaults should pass through since all function pointers are null
    try testing.expect(result.has_timestamp_query);
    try testing.expect(!result.has_multi_draw_indirect);
    try testing.expect(result.has_pixel_local_storage_coherent);
    try testing.expect(!result.has_pixel_local_storage_non_coherent);
}
