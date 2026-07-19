// d3d12_device_caps.zig — D3D12 device capability queries: feature reporting and limits.
//
// Mirrors doe_device_caps.zig for the D3D12 backend. Limits are conservative
// D3D12 Feature Level 11.0 defaults (the minimum Doe targets). Runtime hardware
// queries via bridge functions refine feature detection when a device handle is
// available (ShaderF16, Subgroups, wave lane counts).

const std = @import("std");
const builtin = @import("builtin");
const abi_callback = @import("../../core/abi/wgpu_callback_descriptor_types.zig");
const abi_feature = @import("../../core/abi/wgpu_feature_base_types.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const bridge = @import("d3d12_bridge_decls.zig");

// D3D12 is only available on Windows.
const D3D12_AVAILABLE = builtin.os.tag == .windows;

// Feature name constants — match wgpu_runtime_abi.zig
const FEATURE_DEPTH_CLIP_CONTROL: u32 = abi_feature.WGPUFeatureName_DepthClipControl;
const FEATURE_DEPTH32FLOAT_STENCIL8: u32 = abi_feature.WGPUFeatureName_Depth32FloatStencil8;
const FEATURE_TEXTURE_COMPRESSION_BC: u32 = abi_feature.WGPUFeatureName_TextureCompressionBC;
const FEATURE_TEXTURE_COMPRESSION_BC_SLICED_3D: u32 = abi_feature.WGPUFeatureName_TextureCompressionBCSliced3D;
const FEATURE_TEXTURE_COMPRESSION_ETC2: u32 = abi_feature.WGPUFeatureName_TextureCompressionETC2;
const FEATURE_TEXTURE_COMPRESSION_ASTC: u32 = abi_feature.WGPUFeatureName_TextureCompressionASTC;
const FEATURE_TEXTURE_COMPRESSION_ASTC_SLICED_3D: u32 = abi_feature.WGPUFeatureName_TextureCompressionASTCSliced3D;
const FEATURE_BGRA8UNORM_STORAGE: u32 = abi_feature.WGPUFeatureName_BGRA8UnormStorage;
const FEATURE_INDIRECT_FIRST_INSTANCE: u32 = abi_feature.WGPUFeatureName_IndirectFirstInstance;
const FEATURE_FLOAT32_FILTERABLE: u32 = abi_feature.WGPUFeatureName_Float32Filterable;
const FEATURE_FLOAT32_BLENDABLE: u32 = abi_feature.WGPUFeatureName_Float32Blendable;
const FEATURE_TIMESTAMP_QUERY: u32 = abi_feature.WGPUFeatureName_TimestampQuery;
const FEATURE_RG11B10UFLOAT_RENDERABLE: u32 = abi_feature.WGPUFeatureName_RG11B10UfloatRenderable;
const FEATURE_CLIP_DISTANCES: u32 = abi_feature.WGPUFeatureName_ClipDistances;
const FEATURE_DUAL_SOURCE_BLENDING: u32 = abi_feature.WGPUFeatureName_DualSourceBlending;
const FEATURE_CORE_FEATURES_AND_LIMITS: u32 = abi_feature.WGPUFeatureName_CoreFeaturesAndLimits;
const FEATURE_TEXTURE_FORMATS_TIER1: u32 = abi_feature.WGPUFeatureName_TextureFormatsTier1;
const FEATURE_TEXTURE_FORMATS_TIER2: u32 = abi_feature.WGPUFeatureName_TextureFormatsTier2;
const FEATURE_PRIMITIVE_INDEX: u32 = abi_feature.WGPUFeatureName_PrimitiveIndex;
const FEATURE_TEXTURE_COMPONENT_SWIZZLE: u32 = abi_feature.WGPUFeatureName_TextureComponentSwizzle;
const FEATURE_SHADER_F16: u32 = abi_feature.WGPUFeatureName_ShaderF16;
const FEATURE_SUBGROUPS: u32 = abi_feature.WGPUFeatureName_Subgroups;

// Shader model thresholds for feature gating.
const SM_6_0: c_int = 0x60; // Wave intrinsics (subgroups)
const SM_6_2: c_int = 0x62; // Native 16-bit shader ops

// D3D12 Feature Level 11.0 conservative limits.
// These match the WebGPU spec minimum where possible, and D3D12 FL11.0
// hardware guarantees otherwise.
const FALLBACK_MAX_BUFFER_SIZE: u64 = 268_435_456; // 256 MB — spec minimum
const D3D12_MAX_UNIFORM_BUFFER_BINDING_SIZE: u64 = 65_536; // 64 KB (D3D12 constant buffer limit)

const D3D12_LIMITS_STATIC = abi_callback.WGPULimits{
    .nextInChain = null,
    .maxTextureDimension1D = 16384,
    .maxTextureDimension2D = 16384,
    .maxTextureDimension3D = 2048,
    .maxTextureArrayLayers = 2048,
    .maxBindGroups = 4,
    .maxBindGroupsPlusVertexBuffers = 24,
    .maxBindingsPerBindGroup = 1000,
    .maxDynamicUniformBuffersPerPipelineLayout = 8,
    .maxDynamicStorageBuffersPerPipelineLayout = 4,
    .maxSampledTexturesPerShaderStage = 128, // D3D12 SRV limit per stage
    .maxSamplersPerShaderStage = 16,
    .maxStorageBuffersPerShaderStage = 8,
    .maxStorageTexturesPerShaderStage = 8,
    .maxUniformBuffersPerShaderStage = 14, // D3D12 CBV limit
    .maxUniformBufferBindingSize = D3D12_MAX_UNIFORM_BUFFER_BINDING_SIZE,
    .maxStorageBufferBindingSize = FALLBACK_MAX_BUFFER_SIZE,
    .minUniformBufferOffsetAlignment = 256, // D3D12 constant buffer alignment
    .minStorageBufferOffsetAlignment = 32,
    .maxVertexBuffers = 16, // D3D12 input slot count
    .maxBufferSize = FALLBACK_MAX_BUFFER_SIZE,
    .maxVertexAttributes = 32, // D3D12 input element limit
    .maxVertexBufferArrayStride = 2048,
    .maxInterStageShaderVariables = 16,
    .maxColorAttachments = 8, // D3D12 MRT limit
    .maxColorAttachmentBytesPerSample = 32,
    .maxComputeWorkgroupStorageSize = 32768, // D3D12 groupshared memory limit
    .maxComputeInvocationsPerWorkgroup = 1024,
    .maxComputeWorkgroupSizeX = 1024,
    .maxComputeWorkgroupSizeY = 1024,
    .maxComputeWorkgroupSizeZ = 64,
    .maxComputeWorkgroupsPerDimension = 65535,
    .maxImmediateSize = 0,
};

fn build_limits() abi_callback.WGPULimits {
    return D3D12_LIMITS_STATIC;
}

// ============================================================
// Bridge extern declarations — resolved by d3d12_bridge.c at link time.
// ============================================================

// ============================================================
// D3D12DeviceCaps — runtime-queried hardware capabilities.
//
// When a device handle is available, query_device_caps calls the bridge
// functions to detect shader model, wave lane counts, and 16-bit support.
// When no device handle is available (null), conservative static defaults
// apply: no ShaderF16, no Subgroups, default wave size.
// ============================================================

pub const D3D12DeviceCaps = struct {
    shader_model: c_int = SM_6_0,
    wave_lane_count_min: u32 = D3D12_DEFAULT_WAVE_SIZE,
    wave_lane_count_max: u32 = D3D12_DEFAULT_WAVE_SIZE,
    supports_native_16bit: bool = false,
    has_subgroups: bool = false,
    has_shader_f16: bool = false,
    has_subgroups_f16: bool = false,
    supports_bc_sliced_3d: bool = false,
    supports_etc2: bool = false,
    supports_astc: bool = false,
    supports_astc_sliced_3d: bool = false,
    supports_float32_blendable: bool = false,
    supports_texture_formats_tier1: bool = false,
    supports_texture_formats_tier2: bool = false,
    supports_texture_component_swizzle: bool = false,
};

const TIER1_STORAGE_FORMATS = [_]u32{
    model_gpu_types.WGPUTextureFormat_R8Unorm,
    model_gpu_types.WGPUTextureFormat_R8Snorm,
    model_gpu_types.WGPUTextureFormat_R8Uint,
    model_gpu_types.WGPUTextureFormat_R8Sint,
    model_gpu_types.WGPUTextureFormat_R16Unorm,
    model_gpu_types.WGPUTextureFormat_R16Snorm,
    model_gpu_types.WGPUTextureFormat_R16Uint,
    model_gpu_types.WGPUTextureFormat_R16Sint,
    model_gpu_types.WGPUTextureFormat_R16Float,
    model_gpu_types.WGPUTextureFormat_RG8Unorm,
    model_gpu_types.WGPUTextureFormat_RG8Snorm,
    model_gpu_types.WGPUTextureFormat_RG8Uint,
    model_gpu_types.WGPUTextureFormat_RG8Sint,
    model_gpu_types.WGPUTextureFormat_RG16Unorm,
    model_gpu_types.WGPUTextureFormat_RG16Snorm,
    model_gpu_types.WGPUTextureFormat_RG16Uint,
    model_gpu_types.WGPUTextureFormat_RG16Sint,
    model_gpu_types.WGPUTextureFormat_RG16Float,
    model_gpu_types.WGPUTextureFormat_RGBA16Unorm,
    model_gpu_types.WGPUTextureFormat_RGBA16Snorm,
    model_gpu_types.WGPUTextureFormat_RGB10A2Uint,
    model_gpu_types.WGPUTextureFormat_RGB10A2Unorm,
    model_gpu_types.WGPUTextureFormat_RG11B10Ufloat,
};

const TIER2_READ_WRITE_FORMATS = [_]u32{
    model_gpu_types.WGPUTextureFormat_R8Unorm,
    model_gpu_types.WGPUTextureFormat_R8Uint,
    model_gpu_types.WGPUTextureFormat_R8Sint,
    model_gpu_types.WGPUTextureFormat_RGBA8Unorm,
    model_gpu_types.WGPUTextureFormat_RGBA8Uint,
    model_gpu_types.WGPUTextureFormat_RGBA8Sint,
    model_gpu_types.WGPUTextureFormat_R16Uint,
    model_gpu_types.WGPUTextureFormat_R16Sint,
    model_gpu_types.WGPUTextureFormat_R16Float,
    model_gpu_types.WGPUTextureFormat_RGBA16Uint,
    model_gpu_types.WGPUTextureFormat_RGBA16Sint,
    model_gpu_types.WGPUTextureFormat_RGBA16Float,
    model_gpu_types.WGPUTextureFormat_R32Uint,
    model_gpu_types.WGPUTextureFormat_R32Sint,
    model_gpu_types.WGPUTextureFormat_R32Float,
    model_gpu_types.WGPUTextureFormat_RG32Uint,
    model_gpu_types.WGPUTextureFormat_RG32Sint,
    model_gpu_types.WGPUTextureFormat_RG32Float,
    model_gpu_types.WGPUTextureFormat_RGBA32Uint,
    model_gpu_types.WGPUTextureFormat_RGBA32Sint,
    model_gpu_types.WGPUTextureFormat_RGBA32Float,
};

const FLOAT32_BLENDABLE_FORMATS = [_]u32{
    model_gpu_types.WGPUTextureFormat_R32Float,
    model_gpu_types.WGPUTextureFormat_RG32Float,
    model_gpu_types.WGPUTextureFormat_RGBA32Float,
};

// Conservative static defaults when no device handle is available.
const D3D12_CAPS_STATIC = D3D12DeviceCaps{};
var adapter_caps_cache: std.AutoHashMapUnmanaged(usize, D3D12DeviceCaps) = .{};
const CACHE_ALLOCATOR = std.heap.page_allocator;

fn supports_all_storage_formats(device: ?*anyopaque, formats: []const u32) bool {
    for (formats) |format| {
        if (bridge.c.d3d12_bridge_device_supports_storage_binding(device, format) != 1) return false;
    }
    return true;
}

fn supports_all_storage_read_write_formats(device: ?*anyopaque, formats: []const u32) bool {
    for (formats) |format| {
        if (bridge.c.d3d12_bridge_device_supports_storage_read_write(device, format) != 1) return false;
    }
    return true;
}

fn supports_all_color_attachment_blend_formats(device: ?*anyopaque, formats: []const u32) bool {
    for (formats) |format| {
        if (bridge.c.d3d12_bridge_device_supports_color_attachment_blend(device, format) != 1) return false;
    }
    return true;
}

pub fn query_device_caps(device: ?*anyopaque) D3D12DeviceCaps {
    if (device == null) return D3D12_CAPS_STATIC;
    if (!D3D12_AVAILABLE) return D3D12_CAPS_STATIC;

    const sm = bridge.c.d3d12_bridge_device_get_shader_model(device);
    const wl_min_raw = bridge.c.d3d12_bridge_device_get_wave_lane_count_min(device);
    const wl_max_raw = bridge.c.d3d12_bridge_device_get_wave_lane_count_max(device);
    const native_16 = bridge.c.d3d12_bridge_device_supports_native_16bit(device);

    const wl_min: u32 = if (wl_min_raw > 0) @intCast(wl_min_raw) else D3D12_DEFAULT_WAVE_SIZE;
    const wl_max: u32 = if (wl_max_raw > 0) @intCast(wl_max_raw) else D3D12_DEFAULT_WAVE_SIZE;

    // Subgroups (wave intrinsics) require SM6.0+.
    const subgroups = sm >= SM_6_0;
    // ShaderF16 requires both SM6.2+ and hardware native 16-bit op support.
    const shader_f16 = sm >= SM_6_2 and native_16 == 1;
    // Subgroup f16 operations require both ShaderF16 and subgroup support.
    const sub_f16 = subgroups and shader_f16;
    const bc_sliced_3d = bridge.c.d3d12_bridge_device_supports_bc_sliced_3d(device) == 1;
    const float32_blendable = supports_all_color_attachment_blend_formats(device, &FLOAT32_BLENDABLE_FORMATS);
    const tier1 = supports_all_storage_formats(device, &TIER1_STORAGE_FORMATS);
    const tier2 = tier1 and
        supports_all_storage_read_write_formats(device, &TIER2_READ_WRITE_FORMATS) and
        bridge.c.d3d12_bridge_device_supports_render_target(device, model_gpu_types.WGPUTextureFormat_RG11B10Ufloat) == 1;
    const texture_component_swizzle = bridge.c.d3d12_bridge_device_supports_texture_component_swizzle(device) == 1;

    return .{
        .shader_model = sm,
        .wave_lane_count_min = wl_min,
        .wave_lane_count_max = wl_max,
        .supports_native_16bit = native_16 == 1,
        .has_subgroups = subgroups,
        .has_shader_f16 = shader_f16,
        .has_subgroups_f16 = sub_f16,
        .supports_bc_sliced_3d = bc_sliced_3d,
        .supports_etc2 = false,
        .supports_astc = false,
        .supports_astc_sliced_3d = false,
        .supports_float32_blendable = float32_blendable,
        .supports_texture_formats_tier1 = tier1,
        .supports_texture_formats_tier2 = tier2,
        .supports_texture_component_swizzle = texture_component_swizzle,
    };
}

// ============================================================
// Feature queries — FL11.0 unconditional + runtime-queried features
// ============================================================

// D3D12 feature support — Feature Level 11.0+ unconditional capabilities.
// Features that need runtime hardware queries (ShaderF16, Subgroups,
// ETC2, ASTC, Float32Blendable) are excluded from the
// static path and checked against the caps struct when available.
fn is_feature_supported_static(feature: u32) bool {
    return switch (feature) {
        FEATURE_DEPTH_CLIP_CONTROL,
        FEATURE_DEPTH32FLOAT_STENCIL8,
        FEATURE_TEXTURE_COMPRESSION_BC,
        FEATURE_BGRA8UNORM_STORAGE,
        FEATURE_INDIRECT_FIRST_INSTANCE,
        FEATURE_FLOAT32_FILTERABLE,
        FEATURE_TIMESTAMP_QUERY,
        FEATURE_RG11B10UFLOAT_RENDERABLE,
        FEATURE_CLIP_DISTANCES,
        FEATURE_DUAL_SOURCE_BLENDING,
        FEATURE_CORE_FEATURES_AND_LIMITS,
        => D3D12_AVAILABLE,
        else => false,
    };
}

fn is_feature_supported_with_caps(feature: u32, caps: D3D12DeviceCaps) bool {
    return switch (feature) {
        FEATURE_SHADER_F16 => D3D12_AVAILABLE and caps.has_shader_f16,
        FEATURE_SUBGROUPS => D3D12_AVAILABLE and caps.has_subgroups,
        FEATURE_TEXTURE_COMPRESSION_BC => D3D12_AVAILABLE,
        FEATURE_TEXTURE_COMPRESSION_BC_SLICED_3D => D3D12_AVAILABLE and caps.supports_bc_sliced_3d,
        FEATURE_TEXTURE_COMPRESSION_ETC2 => D3D12_AVAILABLE and caps.supports_etc2,
        FEATURE_TEXTURE_COMPRESSION_ASTC => D3D12_AVAILABLE and caps.supports_astc,
        FEATURE_TEXTURE_COMPRESSION_ASTC_SLICED_3D => D3D12_AVAILABLE and caps.supports_astc_sliced_3d,
        FEATURE_FLOAT32_BLENDABLE => D3D12_AVAILABLE and caps.supports_float32_blendable,
        FEATURE_TEXTURE_FORMATS_TIER1 => D3D12_AVAILABLE and caps.supports_texture_formats_tier1,
        FEATURE_TEXTURE_FORMATS_TIER2 => D3D12_AVAILABLE and caps.supports_texture_formats_tier2,
        FEATURE_PRIMITIVE_INDEX,
        => false,
        FEATURE_TEXTURE_COMPONENT_SWIZZLE => D3D12_AVAILABLE and caps.supports_texture_component_swizzle,
        else => is_feature_supported_static(feature),
    };
}

pub fn d3d12_adapter_has_feature(feature: u32) bool {
    return is_feature_supported_static(feature);
}

pub fn d3d12_adapter_has_feature_with_caps(feature: u32, caps: D3D12DeviceCaps) bool {
    return is_feature_supported_with_caps(feature, caps);
}

pub fn d3d12_device_has_feature(feature: u32) bool {
    return is_feature_supported_static(feature);
}

pub fn d3d12_device_has_feature_with_caps(feature: u32, caps: D3D12DeviceCaps) bool {
    return is_feature_supported_with_caps(feature, caps);
}

pub fn d3d12_device_get_limits(limits: *abi_callback.WGPULimits) void {
    limits.* = build_limits();
}

pub fn d3d12_adapter_get_limits(limits: *abi_callback.WGPULimits) void {
    limits.* = build_limits();
}

// Subgroup (wave) size. D3D12 wave size is typically 32 (NVIDIA/Intel) or 64 (AMD).
// Report 32 as conservative default; runtime query via
// D3D12_FEATURE_DATA_D3D12_OPTIONS1.WaveLaneCountMin is deferred.
const D3D12_DEFAULT_WAVE_SIZE: u32 = 32;

pub fn d3d12_device_subgroup_size() u32 {
    return if (D3D12_AVAILABLE) D3D12_DEFAULT_WAVE_SIZE else 0;
}

pub fn d3d12_device_subgroup_size_from_caps(caps: D3D12DeviceCaps) u32 {
    if (!D3D12_AVAILABLE) return 0;
    return caps.wave_lane_count_min;
}

pub fn set_adapter_caps(raw: ?*anyopaque, caps: D3D12DeviceCaps) void {
    const ptr = raw orelse return;
    adapter_caps_cache.put(CACHE_ALLOCATOR, @intFromPtr(ptr), caps) catch {};
}

pub fn get_adapter_caps(raw: ?*anyopaque) ?D3D12DeviceCaps {
    const ptr = raw orelse return null;
    return adapter_caps_cache.get(@intFromPtr(ptr));
}

pub fn remove_adapter_caps(raw: ?*anyopaque) void {
    const ptr = raw orelse return;
    _ = adapter_caps_cache.remove(@intFromPtr(ptr));
}

test "d3d12 source-backed feature publication follows queried caps" {
    try std.testing.expectEqual(D3D12_AVAILABLE, is_feature_supported_static(FEATURE_CORE_FEATURES_AND_LIMITS));
    const caps = D3D12DeviceCaps{
        .supports_bc_sliced_3d = true,
        .supports_float32_blendable = true,
        .supports_texture_formats_tier1 = true,
        .supports_texture_formats_tier2 = true,
        .supports_texture_component_swizzle = true,
    };
    try std.testing.expectEqual(D3D12_AVAILABLE, is_feature_supported_with_caps(FEATURE_TEXTURE_COMPRESSION_BC_SLICED_3D, caps));
    try std.testing.expectEqual(D3D12_AVAILABLE, is_feature_supported_with_caps(FEATURE_FLOAT32_BLENDABLE, caps));
    try std.testing.expectEqual(D3D12_AVAILABLE, is_feature_supported_with_caps(FEATURE_TEXTURE_FORMATS_TIER1, caps));
    try std.testing.expectEqual(D3D12_AVAILABLE, is_feature_supported_with_caps(FEATURE_TEXTURE_FORMATS_TIER2, caps));
    try std.testing.expectEqual(D3D12_AVAILABLE, is_feature_supported_with_caps(FEATURE_TEXTURE_COMPONENT_SWIZZLE, caps));
}

test "d3d12 unsupported compressed feature families stay explicit false" {
    try std.testing.expect(!is_feature_supported_with_caps(FEATURE_TEXTURE_COMPRESSION_ETC2, .{}));
    try std.testing.expect(!is_feature_supported_with_caps(FEATURE_TEXTURE_COMPRESSION_ASTC, .{}));
    try std.testing.expect(!is_feature_supported_with_caps(FEATURE_TEXTURE_COMPRESSION_ASTC_SLICED_3D, .{}));
    try std.testing.expect(!is_feature_supported_with_caps(FEATURE_PRIMITIVE_INDEX, .{}));
}

test "d3d12 runtime-probed subgroup and f16 features publish when caps allow" {
    const caps = D3D12DeviceCaps{
        .has_subgroups = true,
        .has_shader_f16 = true,
        .has_subgroups_f16 = true,
    };
    try std.testing.expectEqual(D3D12_AVAILABLE, is_feature_supported_with_caps(FEATURE_SUBGROUPS, caps));
    try std.testing.expectEqual(D3D12_AVAILABLE, is_feature_supported_with_caps(FEATURE_SHADER_F16, caps));
}
