const std = @import("std");
const abi_core = @import("../wgpu_core_base_types.zig");
const abi_feature = @import("../wgpu_feature_base_types.zig");
const abi_texture = @import("../wgpu_texture_base_types.zig");
const abi_callback = @import("../wgpu_callback_descriptor_types.zig");

pub const WGPUInstanceFeatureName = u32;
pub const WGPUWGSLLanguageFeatureName = u32;
pub const WGPUProc = ?*const fn () callconv(.c) void;

pub const WGPUInstanceFeatureName_TimedWaitAny: WGPUInstanceFeatureName = 0x00000001;
pub const WGPUWGSLLanguageFeatureName_ReadonlyAndReadwriteStorageTextures: WGPUWGSLLanguageFeatureName = 0x00000001;
pub const WGPUFeatureName_AdapterPropertiesMemoryHeaps: abi_feature.WGPUFeatureName = 0x00050014;
pub const WGPUFeatureName_DawnDrmFormatCapabilities: abi_feature.WGPUFeatureName = 0x00050018;
pub const WGPUFeatureName_ChromiumExperimentalSubgroupMatrix: abi_feature.WGPUFeatureName = 0x00050034;

pub const WGPUSType_AdapterPropertiesMemoryHeaps: abi_core.WGPUSType = 0x00050013;
pub const WGPUSType_DawnDrmFormatCapabilities: abi_core.WGPUSType = 0x00050018;
pub const WGPUSType_AdapterPropertiesSubgroupMatrixConfigs: abi_core.WGPUSType = 0x0005003B;

pub const MemoryHeapInfo = extern struct {
    properties: u64,
    size: u64,
};

pub const SubgroupMatrixConfig = extern struct {
    componentType: u32,
    resultComponentType: u32,
    M: u32,
    N: u32,
    K: u32,
};

pub const DawnDrmFormatProperties = extern struct {
    modifier: u64,
    modifierPlaneCount: u32,
};

pub const SupportedFeatures = extern struct {
    featureCount: usize,
    features: ?[*]const abi_feature.WGPUFeatureName,
};

pub const SupportedInstanceFeatures = extern struct {
    featureCount: usize,
    features: ?[*]const WGPUInstanceFeatureName,
};

pub const SupportedWGSLLanguageFeatures = extern struct {
    featureCount: usize,
    features: ?[*]const WGPUWGSLLanguageFeatureName,
};

pub const InstanceLimits = extern struct {
    nextInChain: ?*anyopaque,
    timedWaitAnyMaxCount: usize,
};

pub const Limits = abi_callback.WGPULimits;

pub const AdapterPropertiesMemoryHeaps = extern struct {
    chain: abi_callback.WGPUChainedStruct,
    heapCount: usize,
    heapInfo: ?[*]const MemoryHeapInfo,
};

pub const AdapterPropertiesSubgroupMatrixConfigs = extern struct {
    chain: abi_callback.WGPUChainedStruct,
    configCount: usize,
    configs: ?[*]const SubgroupMatrixConfig,
};

pub const DawnDrmFormatCapabilities = extern struct {
    chain: abi_callback.WGPUChainedStruct,
    propertiesCount: usize,
    properties: ?[*]const DawnDrmFormatProperties,
};

pub const DawnFormatCapabilities = extern struct {
    nextInChain: ?*anyopaque,
};

pub const AdapterInfo = extern struct {
    nextInChain: ?*anyopaque,
    vendor: abi_core.WGPUStringView,
    architecture: abi_core.WGPUStringView,
    device: abi_core.WGPUStringView,
    description: abi_core.WGPUStringView,
    backendType: abi_callback.WGPUBackendType,
    adapterType: u32,
    vendorID: u32,
    deviceID: u32,
    subgroupMinSize: u32,
    subgroupMaxSize: u32,
};

pub const FnAdapterGetFeatures = *const fn (abi_core.WGPUAdapter, *SupportedFeatures) callconv(.c) void;
pub const FnAdapterGetFormatCapabilities = *const fn (abi_core.WGPUAdapter, abi_texture.WGPUTextureFormat, *DawnFormatCapabilities) callconv(.c) abi_core.WGPUStatus;
pub const FnAdapterGetInfo = *const fn (abi_core.WGPUAdapter, *AdapterInfo) callconv(.c) abi_core.WGPUStatus;
pub const FnAdapterGetInstance = *const fn (abi_core.WGPUAdapter) callconv(.c) abi_core.WGPUInstance;
pub const FnAdapterGetLimits = *const fn (abi_core.WGPUAdapter, *Limits) callconv(.c) abi_core.WGPUStatus;
pub const FnAdapterInfoFreeMembers = *const fn (AdapterInfo) callconv(.c) void;
pub const FnAdapterPropertiesMemoryHeapsFreeMembers = *const fn (AdapterPropertiesMemoryHeaps) callconv(.c) void;
pub const FnAdapterPropertiesSubgroupMatrixConfigsFreeMembers = *const fn (AdapterPropertiesSubgroupMatrixConfigs) callconv(.c) void;
pub const FnDawnDrmFormatCapabilitiesFreeMembers = *const fn (DawnDrmFormatCapabilities) callconv(.c) void;
pub const FnDeviceGetAdapter = *const fn (abi_core.WGPUDevice) callconv(.c) abi_core.WGPUAdapter;
pub const FnDeviceGetAdapterInfo = *const fn (abi_core.WGPUDevice, *AdapterInfo) callconv(.c) abi_core.WGPUStatus;
pub const FnDeviceGetFeatures = *const fn (abi_core.WGPUDevice, *SupportedFeatures) callconv(.c) void;
pub const FnDeviceGetLimits = *const fn (abi_core.WGPUDevice, *Limits) callconv(.c) abi_core.WGPUStatus;
pub const FnGetInstanceFeatures = *const fn (*SupportedInstanceFeatures) callconv(.c) void;
pub const FnGetInstanceLimits = *const fn (*InstanceLimits) callconv(.c) abi_core.WGPUStatus;
pub const FnGetProcAddress = *const fn (abi_core.WGPUStringView) callconv(.c) WGPUProc;
pub const FnHasInstanceFeature = *const fn (WGPUInstanceFeatureName) callconv(.c) abi_core.WGPUBool;
pub const FnInstanceGetWGSLLanguageFeatures = *const fn (abi_core.WGPUInstance, *SupportedWGSLLanguageFeatures) callconv(.c) void;
pub const FnInstanceHasWGSLLanguageFeature = *const fn (abi_core.WGPUInstance, WGPUWGSLLanguageFeatureName) callconv(.c) abi_core.WGPUBool;
pub const FnSupportedFeaturesFreeMembers = *const fn (SupportedFeatures) callconv(.c) void;
pub const FnSupportedInstanceFeaturesFreeMembers = *const fn (SupportedInstanceFeatures) callconv(.c) void;
pub const FnSupportedWGSLLanguageFeaturesFreeMembers = *const fn (SupportedWGSLLanguageFeatures) callconv(.c) void;

pub const CapabilityProcs = struct {
    adapter_get_features: ?FnAdapterGetFeatures = null,
    adapter_get_format_capabilities: ?FnAdapterGetFormatCapabilities = null,
    adapter_get_info: ?FnAdapterGetInfo = null,
    adapter_get_instance: ?FnAdapterGetInstance = null,
    adapter_get_limits: ?FnAdapterGetLimits = null,
    adapter_info_free_members: ?FnAdapterInfoFreeMembers = null,
    adapter_properties_memory_heaps_free_members: ?FnAdapterPropertiesMemoryHeapsFreeMembers = null,
    adapter_properties_subgroup_matrix_configs_free_members: ?FnAdapterPropertiesSubgroupMatrixConfigsFreeMembers = null,
    dawn_drm_format_capabilities_free_members: ?FnDawnDrmFormatCapabilitiesFreeMembers = null,
    device_get_adapter: ?FnDeviceGetAdapter = null,
    device_get_adapter_info: ?FnDeviceGetAdapterInfo = null,
    device_get_features: ?FnDeviceGetFeatures = null,
    device_get_limits: ?FnDeviceGetLimits = null,
    get_instance_features: ?FnGetInstanceFeatures = null,
    get_instance_limits: ?FnGetInstanceLimits = null,
    get_proc_address: ?FnGetProcAddress = null,
    has_instance_feature: ?FnHasInstanceFeature = null,
    instance_get_wgsl_language_features: ?FnInstanceGetWGSLLanguageFeatures = null,
    instance_has_wgsl_language_feature: ?FnInstanceHasWGSLLanguageFeature = null,
    supported_features_free_members: ?FnSupportedFeaturesFreeMembers = null,
    supported_instance_features_free_members: ?FnSupportedInstanceFeaturesFreeMembers = null,
    supported_wgsl_language_features_free_members: ?FnSupportedWGSLLanguageFeaturesFreeMembers = null,
};

fn loadProc(comptime T: type, lib: std.DynLib, comptime name: [:0]const u8) ?T {
    var mutable = lib;
    return mutable.lookup(T, name);
}

pub fn loadCapabilityProcs(dyn_lib: ?std.DynLib) ?CapabilityProcs {
    const lib = dyn_lib orelse return null;
    return .{
        .adapter_get_features = loadProc(FnAdapterGetFeatures, lib, "wgpuAdapterGetFeatures"),
        .adapter_get_format_capabilities = loadProc(FnAdapterGetFormatCapabilities, lib, "wgpuAdapterGetFormatCapabilities"),
        .adapter_get_info = loadProc(FnAdapterGetInfo, lib, "wgpuAdapterGetInfo"),
        .adapter_get_instance = loadProc(FnAdapterGetInstance, lib, "wgpuAdapterGetInstance"),
        .adapter_get_limits = loadProc(FnAdapterGetLimits, lib, "wgpuAdapterGetLimits"),
        .adapter_info_free_members = loadProc(FnAdapterInfoFreeMembers, lib, "wgpuAdapterInfoFreeMembers"),
        .adapter_properties_memory_heaps_free_members = loadProc(FnAdapterPropertiesMemoryHeapsFreeMembers, lib, "wgpuAdapterPropertiesMemoryHeapsFreeMembers"),
        .adapter_properties_subgroup_matrix_configs_free_members = loadProc(FnAdapterPropertiesSubgroupMatrixConfigsFreeMembers, lib, "wgpuAdapterPropertiesSubgroupMatrixConfigsFreeMembers"),
        .dawn_drm_format_capabilities_free_members = loadProc(FnDawnDrmFormatCapabilitiesFreeMembers, lib, "wgpuDawnDrmFormatCapabilitiesFreeMembers"),
        .device_get_adapter = loadProc(FnDeviceGetAdapter, lib, "wgpuDeviceGetAdapter"),
        .device_get_adapter_info = loadProc(FnDeviceGetAdapterInfo, lib, "wgpuDeviceGetAdapterInfo"),
        .device_get_features = loadProc(FnDeviceGetFeatures, lib, "wgpuDeviceGetFeatures"),
        .device_get_limits = loadProc(FnDeviceGetLimits, lib, "wgpuDeviceGetLimits"),
        .get_instance_features = loadProc(FnGetInstanceFeatures, lib, "wgpuGetInstanceFeatures"),
        .get_instance_limits = loadProc(FnGetInstanceLimits, lib, "wgpuGetInstanceLimits"),
        .get_proc_address = loadProc(FnGetProcAddress, lib, "wgpuGetProcAddress"),
        .has_instance_feature = loadProc(FnHasInstanceFeature, lib, "wgpuHasInstanceFeature"),
        .instance_get_wgsl_language_features = loadProc(FnInstanceGetWGSLLanguageFeatures, lib, "wgpuInstanceGetWGSLLanguageFeatures"),
        .instance_has_wgsl_language_feature = loadProc(FnInstanceHasWGSLLanguageFeature, lib, "wgpuInstanceHasWGSLLanguageFeature"),
        .supported_features_free_members = loadProc(FnSupportedFeaturesFreeMembers, lib, "wgpuSupportedFeaturesFreeMembers"),
        .supported_instance_features_free_members = loadProc(FnSupportedInstanceFeaturesFreeMembers, lib, "wgpuSupportedInstanceFeaturesFreeMembers"),
        .supported_wgsl_language_features_free_members = loadProc(FnSupportedWGSLLanguageFeaturesFreeMembers, lib, "wgpuSupportedWGSLLanguageFeaturesFreeMembers"),
    };
}

pub fn initSupportedFeatures() SupportedFeatures {
    return .{ .featureCount = 0, .features = null };
}

pub fn initSupportedInstanceFeatures() SupportedInstanceFeatures {
    return .{ .featureCount = 0, .features = null };
}

pub fn initSupportedWGSLLanguageFeatures() SupportedWGSLLanguageFeatures {
    return .{ .featureCount = 0, .features = null };
}

pub fn initInstanceLimits() InstanceLimits {
    return .{
        .nextInChain = null,
        .timedWaitAnyMaxCount = 0,
    };
}

pub fn initLimits() Limits {
    return abi_callback.initLimits();
}

pub fn initAdapterInfo(next_in_chain: ?*anyopaque) AdapterInfo {
    return .{
        .nextInChain = next_in_chain,
        .vendor = .{ .data = null, .length = abi_core.WGPU_STRLEN },
        .architecture = .{ .data = null, .length = abi_core.WGPU_STRLEN },
        .device = .{ .data = null, .length = abi_core.WGPU_STRLEN },
        .description = .{ .data = null, .length = abi_core.WGPU_STRLEN },
        .backendType = .undefined,
        .adapterType = 0,
        .vendorID = 0,
        .deviceID = 0,
        .subgroupMinSize = 0,
        .subgroupMaxSize = 0,
    };
}

pub fn initAdapterPropertiesMemoryHeaps() AdapterPropertiesMemoryHeaps {
    return .{
        .chain = .{
            .next = null,
            .sType = WGPUSType_AdapterPropertiesMemoryHeaps,
        },
        .heapCount = 0,
        .heapInfo = null,
    };
}

pub fn initAdapterPropertiesSubgroupMatrixConfigs() AdapterPropertiesSubgroupMatrixConfigs {
    return .{
        .chain = .{
            .next = null,
            .sType = WGPUSType_AdapterPropertiesSubgroupMatrixConfigs,
        },
        .configCount = 0,
        .configs = null,
    };
}

pub fn initDawnDrmFormatCapabilities() DawnDrmFormatCapabilities {
    return .{
        .chain = .{
            .next = null,
            .sType = WGPUSType_DawnDrmFormatCapabilities,
        },
        .propertiesCount = 0,
        .properties = null,
    };
}

pub fn initDawnFormatCapabilities(next_in_chain: ?*anyopaque) DawnFormatCapabilities {
    return .{
        .nextInChain = next_in_chain,
    };
}

pub fn hasFeature(features: SupportedFeatures, feature: abi_feature.WGPUFeatureName) bool {
    const list_ptr = features.features orelse return false;
    const list = list_ptr[0..features.featureCount];
    for (list) |candidate| {
        if (candidate == feature) return true;
    }
    return false;
}

pub fn hasInstanceFeatureInList(features: SupportedInstanceFeatures, feature: WGPUInstanceFeatureName) bool {
    const list_ptr = features.features orelse return false;
    const list = list_ptr[0..features.featureCount];
    for (list) |candidate| {
        if (candidate == feature) return true;
    }
    return false;
}

pub fn hasWGSLLanguageFeatureInList(features: SupportedWGSLLanguageFeatures, feature: WGPUWGSLLanguageFeatureName) bool {
    const list_ptr = features.features orelse return false;
    const list = list_ptr[0..features.featureCount];
    for (list) |candidate| {
        if (candidate == feature) return true;
    }
    return false;
}
