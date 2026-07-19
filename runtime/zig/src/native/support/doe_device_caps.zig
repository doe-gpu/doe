// doe_device_caps.zig — Device capability queries: feature reporting and limits.
// Sharded from doe_wgpu_native.zig to stay under the line-limit policy.
//
// Limits are queried from the hardware at runtime where possible, then cached.
// Static fallbacks apply on non-Metal targets or when hardware query fails.

const builtin = @import("builtin");
const has_vulkan = (builtin.os.tag == .linux);
const abi_callback = @import("../../core/abi/wgpu_callback_descriptor_types.zig");
const abi_core = @import("../../core/abi/wgpu_core_base_types.zig");
const abi_feature = @import("../../core/abi/wgpu_feature_base_types.zig");
const backend_capabilities = @import("../../backend/dropin_capabilities.zig");
const native_shared = @import("doe_native_shared_types.zig");
const native_types = @import("doe_native_object_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const d3d12_device_caps = backend_capabilities.d3d12_device_caps;
const vk_feature_caps = if (has_vulkan) backend_capabilities.vk_feature_caps else struct {};
const vk_device_caps = if (has_vulkan) backend_capabilities.vk_device_caps else struct {};
const vk_feature_probe = if (has_vulkan) backend_capabilities.vk_feature_probe else struct {};
const vulkan_feature_cache = if (has_vulkan) @import("../vulkan/vulkan_feature_cache.zig") else struct {};
const DoeDevice = native_types.DoeDevice;
const DoeAdapter = native_types.DoeAdapter;
const alloc = native_helpers.alloc;

// Metal bridge — only linked on macOS; guarded by comptime platform check.
const BRIDGE_AVAILABLE = builtin.os.tag == .macos;

// ============================================================
// Feature name constants — match wgpu_runtime_abi.zig and capabilities.js
// ============================================================

const FEATURE_DEPTH_CLIP_CONTROL: u32 = abi_feature.WGPUFeatureName_DepthClipControl;
const FEATURE_DEPTH32FLOAT_STENCIL8: u32 = abi_feature.WGPUFeatureName_Depth32FloatStencil8;
const FEATURE_TEXTURE_COMPRESSION_ASTC: u32 = abi_feature.WGPUFeatureName_TextureCompressionASTC;
const FEATURE_TEXTURE_COMPRESSION_BC_SLICED_3D: u32 = abi_feature.WGPUFeatureName_TextureCompressionBCSliced3D;
const FEATURE_TEXTURE_COMPRESSION_ASTC_SLICED_3D: u32 = abi_feature.WGPUFeatureName_TextureCompressionASTCSliced3D;
const FEATURE_BGRA8UNORM_STORAGE: u32 = abi_feature.WGPUFeatureName_BGRA8UnormStorage;
const FEATURE_SHADER_F16: u32 = abi_feature.WGPUFeatureName_ShaderF16;
const FEATURE_INDIRECT_FIRST_INSTANCE: u32 = abi_feature.WGPUFeatureName_IndirectFirstInstance;
const FEATURE_FLOAT32_FILTERABLE: u32 = abi_feature.WGPUFeatureName_Float32Filterable;
const FEATURE_FLOAT32_BLENDABLE: u32 = abi_feature.WGPUFeatureName_Float32Blendable;
pub const FEATURE_SUBGROUPS: u32 = abi_feature.WGPUFeatureName_Subgroups;
const FEATURE_TEXTURE_COMPRESSION_BC: u32 = abi_feature.WGPUFeatureName_TextureCompressionBC;
const FEATURE_TEXTURE_COMPRESSION_ETC2: u32 = abi_feature.WGPUFeatureName_TextureCompressionETC2;
const FEATURE_RG11B10UFLOAT_RENDERABLE: u32 = abi_feature.WGPUFeatureName_RG11B10UfloatRenderable;
const FEATURE_TIMESTAMP_QUERY: u32 = abi_feature.WGPUFeatureName_TimestampQuery;
const FEATURE_CLIP_DISTANCES: u32 = abi_feature.WGPUFeatureName_ClipDistances;
const FEATURE_DUAL_SOURCE_BLENDING: u32 = abi_feature.WGPUFeatureName_DualSourceBlending;
const FEATURE_CORE_FEATURES_AND_LIMITS: u32 = abi_feature.WGPUFeatureName_CoreFeaturesAndLimits;
const FEATURE_TEXTURE_FORMATS_TIER1: u32 = abi_feature.WGPUFeatureName_TextureFormatsTier1;
const FEATURE_TEXTURE_FORMATS_TIER2: u32 = abi_feature.WGPUFeatureName_TextureFormatsTier2;
const FEATURE_PRIMITIVE_INDEX: u32 = abi_feature.WGPUFeatureName_PrimitiveIndex;
const FEATURE_TEXTURE_COMPONENT_SWIZZLE: u32 = abi_feature.WGPUFeatureName_TextureComponentSwizzle;

// ============================================================
// Limits: Apple Silicon hardware-specific defaults.
//
// maxBufferSize and maxStorageBufferBindingSize are queried from the
// device at runtime through the backend capability seam when a device
// handle is available. The constants below are conservative
// fallbacks for static/headless contexts.
// ============================================================

// Apple Silicon GPUs support buffers up to ~32 GB.
// The spec minimum is 256 MB; report the true hardware limit when possible.
const FALLBACK_MAX_BUFFER_SIZE: u64 = 268_435_456; // 256 MB — spec minimum

// Metal uniform buffer binding size limit (hardware-imposed, not tunable).
const METAL_MAX_UNIFORM_BUFFER_BINDING_SIZE: u64 = 65_536; // 64 KB

// Metal subgroup (SIMD-group) size on Apple Silicon (all known variants).
pub const METAL_SIMD_GROUP_SIZE: u32 = 32;
const METAL_MAX_IMMEDIATE_SIZE: u32 = 64;

// Default Metal limits (used when no device handle is available).
const METAL_LIMITS_STATIC = abi_callback.WGPULimits{
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
    .maxSampledTexturesPerShaderStage = 16,
    .maxSamplersPerShaderStage = 16,
    .maxStorageBuffersPerShaderStage = 8,
    .maxStorageTexturesPerShaderStage = 4,
    .maxUniformBuffersPerShaderStage = 12,
    .maxUniformBufferBindingSize = METAL_MAX_UNIFORM_BUFFER_BINDING_SIZE,
    .maxStorageBufferBindingSize = FALLBACK_MAX_BUFFER_SIZE,
    .minUniformBufferOffsetAlignment = 256,
    .minStorageBufferOffsetAlignment = 32,
    .maxVertexBuffers = 8,
    .maxBufferSize = FALLBACK_MAX_BUFFER_SIZE,
    .maxVertexAttributes = 16,
    .maxVertexBufferArrayStride = 2048,
    .maxInterStageShaderVariables = 16,
    .maxColorAttachments = 8,
    .maxColorAttachmentBytesPerSample = 32,
    .maxComputeWorkgroupStorageSize = 32768,
    .maxComputeInvocationsPerWorkgroup = 1024,
    .maxComputeWorkgroupSizeX = 1024,
    .maxComputeWorkgroupSizeY = 1024,
    .maxComputeWorkgroupSizeZ = 64,
    .maxComputeWorkgroupsPerDimension = 65535,
    .maxImmediateSize = METAL_MAX_IMMEDIATE_SIZE,
};

// Conservative Vulkan limits matching Vulkan 1.0 minimum guarantees.
// Storage buffer binding size and maxBufferSize use the 128 MB minimum
// rather than querying VkPhysicalDeviceProperties at init time.
const VULKAN_MAX_STORAGE_BUFFER_BINDING_SIZE: u64 = 134_217_728; // 128 MB
const VULKAN_MAX_BUFFER_SIZE: u64 = 268_435_456; // 256 MB
const VULKAN_MIN_STORAGE_BUFFER_OFFSET_ALIGNMENT: u32 = 64;

pub const VULKAN_LIMITS_STATIC = abi_callback.WGPULimits{
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
    .maxSampledTexturesPerShaderStage = 16,
    .maxSamplersPerShaderStage = 16,
    .maxStorageBuffersPerShaderStage = 8,
    .maxStorageTexturesPerShaderStage = 4,
    .maxUniformBuffersPerShaderStage = 12,
    .maxUniformBufferBindingSize = METAL_MAX_UNIFORM_BUFFER_BINDING_SIZE,
    .maxStorageBufferBindingSize = VULKAN_MAX_STORAGE_BUFFER_BINDING_SIZE,
    .minUniformBufferOffsetAlignment = 256,
    .minStorageBufferOffsetAlignment = VULKAN_MIN_STORAGE_BUFFER_OFFSET_ALIGNMENT,
    .maxVertexBuffers = 8,
    .maxBufferSize = VULKAN_MAX_BUFFER_SIZE,
    .maxVertexAttributes = 16,
    .maxVertexBufferArrayStride = 2048,
    .maxInterStageShaderVariables = 16,
    .maxColorAttachments = 8,
    .maxColorAttachmentBytesPerSample = 32,
    .maxComputeWorkgroupStorageSize = 32768,
    .maxComputeInvocationsPerWorkgroup = 1024,
    .maxComputeWorkgroupSizeX = 1024,
    .maxComputeWorkgroupSizeY = 1024,
    .maxComputeWorkgroupSizeZ = 64,
    .maxComputeWorkgroupsPerDimension = 65535,
    .maxImmediateSize = 0,
};

// Resolved by metal_bridge.m at link time. This file is only compiled on
// macOS (doe_wgpu_native.zig — its only importer — is platform-guarded).
// Query the actual device max buffer length from a raw MTLDevice handle.
// The `raw` argument here must be an MTLDevice (not a DoeDevice wrapper).
// Falls back to the static conservative value when unavailable.
fn query_max_buffer_length(mtl_device: ?*anyopaque) u64 {
    if (mtl_device == null) return FALLBACK_MAX_BUFFER_SIZE;
    const hw_limit = backend_capabilities.metal_device_max_buffer_length(mtl_device);
    return if (hw_limit > 0) hw_limit else FALLBACK_MAX_BUFFER_SIZE;
}

// Build a WGPULimits struct with runtime-queried buffer sizes.
// mtl_device may be null — in that case static fallback values apply.
fn build_limits(mtl_device: ?*anyopaque) abi_callback.WGPULimits {
    const buf_limit = query_max_buffer_length(mtl_device);
    var limits = METAL_LIMITS_STATIC;
    limits.maxBufferSize = buf_limit;
    // Storage buffer binding size is capped at the buffer allocation limit.
    limits.maxStorageBufferBindingSize = buf_limit;
    return limits;
}

// ============================================================
// Feature queries
// ============================================================

fn is_metal_feature_supported(feature: u32) bool {
    return switch (feature) {
        // Universally enabled on Doe Metal.
        FEATURE_SHADER_F16 => true,
        // Apple Silicon Metal features — all supported on this target.
        FEATURE_DEPTH_CLIP_CONTROL,
        FEATURE_DEPTH32FLOAT_STENCIL8,
        FEATURE_TEXTURE_COMPRESSION_BC,
        FEATURE_TEXTURE_COMPRESSION_ETC2,
        FEATURE_TEXTURE_COMPRESSION_ASTC,
        FEATURE_BGRA8UNORM_STORAGE,
        FEATURE_RG11B10UFLOAT_RENDERABLE,
        FEATURE_TIMESTAMP_QUERY,
        FEATURE_INDIRECT_FIRST_INSTANCE,
        FEATURE_FLOAT32_FILTERABLE,
        FEATURE_FLOAT32_BLENDABLE,
        FEATURE_SUBGROUPS,
        FEATURE_CLIP_DISTANCES,
        FEATURE_DUAL_SOURCE_BLENDING,
        FEATURE_CORE_FEATURES_AND_LIMITS,
        FEATURE_TEXTURE_FORMATS_TIER1,
        FEATURE_TEXTURE_FORMATS_TIER2,
        FEATURE_PRIMITIVE_INDEX,
        FEATURE_TEXTURE_COMPONENT_SWIZZLE,
        => BRIDGE_AVAILABLE,
        else => false,
    };
}

// Vulkan feature support combines dynamic probes (vk_feature_caps) with
// hardware-queried device caps (vk_device_caps) for features that depend
// on native VkPhysicalDeviceFeatures or format-capability publication.
fn is_vulkan_feature_supported(
    feature: u32,
    caps: if (has_vulkan) ?vk_feature_caps.VulkanFeatureCaps else ?void,
    hw_caps: if (has_vulkan) ?vk_device_caps.VulkanDeviceCaps else ?void,
) bool {
    if (comptime !has_vulkan) return false;
    return switch (feature) {
        // Dynamic features probed via vk_feature_caps (format queries, subgroups, etc.).
        FEATURE_SHADER_F16,
        FEATURE_FLOAT32_BLENDABLE,
        FEATURE_SUBGROUPS,
        FEATURE_DUAL_SOURCE_BLENDING,
        FEATURE_TEXTURE_FORMATS_TIER1,
        FEATURE_TEXTURE_FORMATS_TIER2,
        => if (caps) |resolved| vk_feature_caps.dynamic_feature_supported(feature, resolved) else false,
        // Hardware-queried features: use actual VkPhysicalDeviceFeatures when available.
        FEATURE_DEPTH_CLIP_CONTROL => if (hw_caps) |hc| hc.has_depth_clip_control else true,
        FEATURE_DEPTH32FLOAT_STENCIL8 => true,
        FEATURE_TEXTURE_COMPRESSION_BC => if (hw_caps) |hc| hc.has_texture_compression_bc else true,
        FEATURE_TEXTURE_COMPRESSION_ETC2 => if (hw_caps) |hc| hc.has_texture_compression_etc2 else true,
        FEATURE_TEXTURE_COMPRESSION_ASTC => if (hw_caps) |hc| hc.has_texture_compression_astc else true,
        FEATURE_INDIRECT_FIRST_INSTANCE => if (hw_caps) |hc| hc.has_draw_indirect_first_instance else true,
        FEATURE_FLOAT32_FILTERABLE => if (hw_caps) |hc| hc.has_float32_filterable else true,
        FEATURE_TIMESTAMP_QUERY => if (hw_caps) |hc| hc.has_timestamp_query else true,
        // Features that remain unconditional on Vulkan.
        FEATURE_TEXTURE_COMPRESSION_BC_SLICED_3D,
        FEATURE_TEXTURE_COMPRESSION_ASTC_SLICED_3D,
        FEATURE_BGRA8UNORM_STORAGE,
        FEATURE_RG11B10UFLOAT_RENDERABLE,
        FEATURE_CLIP_DISTANCES,
        FEATURE_PRIMITIVE_INDEX,
        FEATURE_TEXTURE_COMPONENT_SWIZZLE,
        => true,
        else => false,
    };
}

fn d3d12_runtime(device: *DoeDevice) ?*native_shared.NativeD3D12Runtime {
    const ptr = device.d3d12_runtime orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn ensure_vulkan_adapter_caps(raw: ?*anyopaque) void {
    if (comptime !has_vulkan) return;
    if (raw == null) return;
    if (vulkan_feature_cache.get_adapter(raw) == null) {
        const caps: vk_feature_caps.VulkanFeatureCaps =
            vk_feature_probe.probe_default_feature_caps(alloc) catch .{};
        vulkan_feature_cache.set_adapter(raw, caps);
    }
    if (vulkan_feature_cache.get_adapter_device_caps(raw) == null) {
        const hw_caps = vk_device_caps.probe_device_caps(alloc) catch return;
        vulkan_feature_cache.set_adapter_device_caps(raw, hw_caps);
    }
}

pub export fn doeNativeAdapterHasFeature(raw: ?*anyopaque, feature: u32) callconv(.c) u32 {
    if (native_helpers.cast(DoeAdapter, raw)) |a| {
        if (comptime has_vulkan) {
            if (a.backend == .vulkan) {
                ensure_vulkan_adapter_caps(raw);
                const caps = vulkan_feature_cache.get_adapter(raw);
                const hw_caps = vulkan_feature_cache.get_adapter_device_caps(raw);
                return if (is_vulkan_feature_supported(feature, caps, hw_caps)) 1 else 0;
            }
        }
        if (a.backend == .d3d12) {
            if (d3d12_device_caps.get_adapter_caps(raw)) |caps| {
                return if (d3d12_device_caps.d3d12_adapter_has_feature_with_caps(feature, caps)) 1 else 0;
            }
            return if (d3d12_device_caps.d3d12_adapter_has_feature(feature)) 1 else 0;
        }
        if (feature == FEATURE_TIMESTAMP_QUERY) {
            return if (BRIDGE_AVAILABLE and backend_capabilities.metal_supports_timestamp_query(a.mtl_device)) 1 else 0;
        }
    }
    return if (is_metal_feature_supported(feature)) 1 else 0;
}

pub export fn doeNativeDeviceHasFeature(raw: ?*anyopaque, feature: u32) callconv(.c) u32 {
    if (native_helpers.cast(DoeDevice, raw)) |d| {
        for (d.enabled_features) |enabled_feature| {
            if (enabled_feature == feature) return 1;
        }
        return 0;
    }
    return if (is_metal_feature_supported(feature)) 1 else 0;
}

// ============================================================
// Device / Adapter limits — runtime queries
// ============================================================

// doeNativeDeviceGetLimits — dispatches to Vulkan or Metal limits based on backend.
// Vulkan limits are hardware-queried at adapter/device creation and cached; falls
// back to conservative static limits when the cache entry is absent.
pub export fn doeNativeDeviceGetLimits(raw: ?*anyopaque, limits: ?*abi_callback.WGPULimits) callconv(.c) abi_core.WGPUStatus {
    if (native_helpers.cast(DoeDevice, raw)) |d| {
        if (comptime has_vulkan) {
            if (d.backend == .vulkan) {
                if (limits) |l| {
                    if (vulkan_feature_cache.get_device_device_caps(raw)) |hw_caps| {
                        l.* = hw_caps.limits;
                    } else {
                        l.* = VULKAN_LIMITS_STATIC;
                    }
                }
                return abi_core.WGPUStatus_Success;
            }
        }
        if (d.backend == .d3d12) {
            if (limits) |l| {
                if (d3d12_runtime(d)) |rt| {
                    rt.get_limits(l);
                } else {
                    d3d12_device_caps.d3d12_device_get_limits(l);
                }
            }
            return abi_core.WGPUStatus_Success;
        }
    }
    if (limits) |l| l.* = build_limits(null);
    return abi_core.WGPUStatus_Success;
}

pub export fn doeNativeAdapterGetLimits(raw: ?*anyopaque, limits: ?*abi_callback.WGPULimits) callconv(.c) abi_core.WGPUStatus {
    if (native_helpers.cast(DoeAdapter, raw)) |a| {
        if (comptime has_vulkan) {
            if (a.backend == .vulkan) {
                ensure_vulkan_adapter_caps(raw);
                if (limits) |l| {
                    if (vulkan_feature_cache.get_adapter_device_caps(raw)) |hw_caps| {
                        l.* = hw_caps.limits;
                    } else {
                        l.* = VULKAN_LIMITS_STATIC;
                    }
                }
                return abi_core.WGPUStatus_Success;
            }
        }
        if (a.backend == .d3d12) {
            if (limits) |l| d3d12_device_caps.d3d12_adapter_get_limits(l);
            return abi_core.WGPUStatus_Success;
        }
    }
    if (limits) |l| l.* = build_limits(null);
    return abi_core.WGPUStatus_Success;
}

// doeNativeDeviceGetLimitsFromMtl — accepts a raw MTLDevice pointer and
// queries maxBufferLength at runtime for accurate large-buffer reporting.
pub export fn doeNativeDeviceGetLimitsFromMtl(mtl_device: ?*anyopaque, limits: ?*abi_callback.WGPULimits) callconv(.c) abi_core.WGPUStatus {
    if (limits) |l| l.* = build_limits(mtl_device);
    return abi_core.WGPUStatus_Success;
}

// ============================================================
// Subgroup size query
// ============================================================

pub export fn doeNativeDeviceSubgroupSize(raw: ?*anyopaque) callconv(.c) u32 {
    if (native_helpers.cast(DoeDevice, raw)) |d| {
        if (d.backend == .d3d12) {
            if (d3d12_runtime(d)) |rt| {
                return d3d12_device_caps.d3d12_device_subgroup_size_from_caps(rt.device_caps);
            }
            return d3d12_device_caps.d3d12_device_subgroup_size();
        }
    }
    // Metal SIMD-group size is 32 on all Apple Silicon variants known at time
    // of writing.  Report 0 when Metal is unavailable (non-macOS).
    return if (BRIDGE_AVAILABLE) METAL_SIMD_GROUP_SIZE else 0;
}
