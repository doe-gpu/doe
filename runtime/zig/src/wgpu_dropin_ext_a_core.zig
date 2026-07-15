pub const std = @import("std");
pub const abi_core = @import("core/abi/wgpu_core_base_types.zig");
pub const abi_feature = @import("core/abi/wgpu_feature_base_types.zig");
pub const abi_texture = @import("core/abi/wgpu_texture_base_types.zig");
pub const abi_pipeline = @import("core/abi/wgpu_pipeline_descriptor_types.zig");
pub const types = struct {
    pub const WGPUAdapter = abi_core.WGPUAdapter;
    pub const WGPUBindGroup = abi_core.WGPUBindGroup;
    pub const WGPUBindGroupLayout = abi_core.WGPUBindGroupLayout;
    pub const WGPUBool = abi_core.WGPUBool;
    pub const WGPUBuffer = abi_core.WGPUBuffer;
    pub const WGPUCommandBuffer = abi_core.WGPUCommandBuffer;
    pub const WGPUCommandEncoder = abi_core.WGPUCommandEncoder;
    pub const WGPUComputePassEncoder = abi_core.WGPUComputePassEncoder;
    pub const WGPUComputePipeline = abi_core.WGPUComputePipeline;
    pub const WGPUDevice = abi_core.WGPUDevice;
    pub const WGPUFuture = abi_core.WGPUFuture;
    pub const WGPUInstance = abi_core.WGPUInstance;
    pub const WGPUPipelineLayout = abi_core.WGPUPipelineLayout;
    pub const WGPUQuerySet = abi_core.WGPUQuerySet;
    pub const WGPUQueryType = abi_core.WGPUQueryType;
    pub const WGPUQueue = abi_core.WGPUQueue;
    pub const WGPURenderPipeline = abi_core.WGPURenderPipeline;
    pub const WGPUStatus = abi_core.WGPUStatus;
    pub const WGPUStatus_Success = abi_core.WGPUStatus_Success;
    pub const WGPUStringView = abi_core.WGPUStringView;
    pub const WGPUTextureFormat = abi_texture.WGPUTextureFormat;
    pub const WGPU_FALSE = abi_core.WGPU_FALSE;
    pub const WGPUConstantEntry = abi_pipeline.WGPUConstantEntry;
    pub const WGPUComputePipelineDescriptor = abi_pipeline.WGPUComputePipelineDescriptor;
};
pub const p1cap = @import("wgpu_p1_capability_procs.zig");
pub const p0 = @import("wgpu_p0_procs.zig");
pub const p1res = @import("wgpu_p1_resource_table_procs.zig");
pub const p2life = @import("wgpu_p2_lifecycle_procs.zig");
pub const surface = @import("full/surface/wgpu_surface_procs.zig");
pub const texture = @import("wgpu_texture_procs.zig");
pub const render = @import("full/render/wgpu_render_api.zig");
pub const async_procs = @import("wgpu_async_procs.zig");
pub const native = @import("doe_wgpu_native.zig");
pub const query_native = @import("doe_query_native.zig");
pub const error_scope = @import("error_scope.zig");
pub const task_pool = @import("runtime/task_pool.zig");
pub const singleflight = @import("runtime/pipeline_singleflight.zig");
pub const pipeline_cache_integration = @import("runtime/pipeline_cache_integration.zig");

pub extern fn wgpuGetProcAddress(name: abi_core.WGPUStringView) callconv(.c) p1cap.WGPUProc;
pub extern fn doeWgpuDropinAbortMissingRequiredSymbol(name: abi_core.WGPUStringView) callconv(.c) noreturn;
pub const doeNativeComputePassSetImmediates = native.doeNativeComputePassSetImmediates;
pub const doeNativeQuerySetDestroy = native.doeNativeQuerySetDestroy;
pub const doeNativeQuerySetGetCount = native.doeNativeQuerySetGetCount;
pub const doeNativeQuerySetGetType = native.doeNativeQuerySetGetType;

pub const FEATURE_CANDIDATES = [_]abi_feature.WGPUFeatureName{
    abi_feature.WGPUFeatureName_CoreFeaturesAndLimits,
    abi_feature.WGPUFeatureName_DepthClipControl,
    abi_feature.WGPUFeatureName_Depth32FloatStencil8,
    abi_feature.WGPUFeatureName_TextureCompressionBC,
    abi_feature.WGPUFeatureName_TextureCompressionBCSliced3D,
    abi_feature.WGPUFeatureName_TextureCompressionETC2,
    abi_feature.WGPUFeatureName_TextureCompressionASTC,
    abi_feature.WGPUFeatureName_TextureCompressionASTCSliced3D,
    abi_feature.WGPUFeatureName_RG11B10UfloatRenderable,
    abi_feature.WGPUFeatureName_TimestampQuery,
    abi_feature.WGPUFeatureName_BGRA8UnormStorage,
    abi_feature.WGPUFeatureName_ShaderF16,
    abi_feature.WGPUFeatureName_IndirectFirstInstance,
    abi_feature.WGPUFeatureName_Float32Filterable,
    abi_feature.WGPUFeatureName_Subgroups,
    abi_feature.WGPUFeatureName_Float32Blendable,
    abi_feature.WGPUFeatureName_ClipDistances,
    abi_feature.WGPUFeatureName_DualSourceBlending,
    abi_feature.WGPUFeatureName_TextureFormatsTier1,
    abi_feature.WGPUFeatureName_TextureFormatsTier2,
    abi_feature.WGPUFeatureName_PrimitiveIndex,
    abi_feature.WGPUFeatureName_TextureComponentSwizzle,
};

pub const LoggingCallback = *const fn (u32, abi_core.WGPUStringView, ?*anyopaque, ?*anyopaque) callconv(.c) void;
pub const PopErrorScopeCallback = *const fn (u32, u32, abi_core.WGPUStringView, ?*anyopaque, ?*anyopaque) callconv(.c) void;

pub const LoggingCallbackInfo = extern struct {
    nextInChain: ?*anyopaque,
    callback: ?LoggingCallback,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
};

pub const PopErrorScopeBridgeState = struct {
    callback: ?PopErrorScopeCallback,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
};

pub fn string_view_slice(view: abi_core.WGPUStringView) []const u8 {
    const data = view.data orelse return "";
    if (view.length == abi_core.WGPU_STRLEN) {
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(data)), 0);
    }
    return data[0..view.length];
}

pub fn dup_string_view(view: abi_core.WGPUStringView) ?[]u8 {
    const src = string_view_slice(view);
    if (src.len == 0) return null;
    return std.heap.c_allocator.dupe(u8, src) catch null;
}

pub fn make_string_view(bytes: ?[]u8) abi_core.WGPUStringView {
    if (bytes) |owned| {
        return .{ .data = owned.ptr, .length = owned.len };
    }
    return .{ .data = null, .length = 0 };
}

pub fn bridge_pop_error_scope_callback(
    error_type: u32,
    msg: abi_core.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const state = userdata1 orelse return;
    const bridge_state: *PopErrorScopeBridgeState = @ptrCast(@alignCast(state));
    const callback = bridge_state.callback orelse return;
    callback(async_procs.POP_ERROR_SCOPE_STATUS_SUCCESS, error_type, msg, bridge_state.userdata1, bridge_state.userdata2);
}

pub fn static_string_view(comptime text: []const u8) abi_core.WGPUStringView {
    return .{ .data = text.ptr, .length = text.len };
}

const abi_callback = @import("core/abi/wgpu_callback_descriptor_types.zig");
pub fn backend_type_for(adapter: *native.DoeAdapter) abi_callback.WGPUBackendType {
    return switch (adapter.backend) {
        .metal => .metal,
        .vulkan => .vulkan,
        .d3d12 => .d3d12,
    };
}

pub fn fill_adapter_info_struct(adapter_raw: abi_core.WGPUAdapter, out: *p1cap.AdapterInfo) abi_core.WGPUStatus {
    const adapter = native.cast(native.DoeAdapter, adapter_raw) orelse return 0;
    out.* = p1cap.initAdapterInfo(out.nextInChain);
    out.vendor = static_string_view("Doe");
    out.architecture = switch (adapter.backend) {
        .metal => static_string_view("metal"),
        .vulkan => static_string_view("vulkan"),
        .d3d12 => static_string_view("d3d12"),
    };
    out.device = switch (adapter.backend) {
        .metal => static_string_view("Doe Metal Adapter"),
        .vulkan => static_string_view("Doe Vulkan Adapter"),
        .d3d12 => static_string_view("Doe D3D12 Adapter"),
    };
    out.description = out.device;
    out.backendType = backend_type_for(adapter);
    out.adapterType = 0x00000004; // Unknown
    out.vendorID = 0;
    out.deviceID = 0;
    out.subgroupMinSize = 0;
    out.subgroupMaxSize = 0;
    return abi_core.WGPUStatus_Success;
}

pub fn fill_supported_features_from_adapter(adapter_raw: abi_core.WGPUAdapter, out: *p1cap.SupportedFeatures) void {
    out.* = p1cap.initSupportedFeatures();
    var count: usize = 0;
    for (FEATURE_CANDIDATES) |feature| {
        if (native.doeNativeAdapterHasFeature(adapter_raw, feature) != 0) count += 1;
    }
    if (count == 0) return;
    const owned = std.heap.c_allocator.alloc(abi_feature.WGPUFeatureName, count) catch return;
    var write_index: usize = 0;
    for (FEATURE_CANDIDATES) |feature| {
        if (native.doeNativeAdapterHasFeature(adapter_raw, feature) == 0) continue;
        owned[write_index] = feature;
        write_index += 1;
    }
    out.featureCount = write_index;
    out.features = owned.ptr;
}

pub fn fill_supported_features_from_device(device_raw: abi_core.WGPUDevice, out: *p1cap.SupportedFeatures) void {
    out.* = p1cap.initSupportedFeatures();
    const device = native.cast(native.DoeDevice, device_raw) orelse return;
    if (device.enabled_features.len == 0) return;
    const owned = std.heap.c_allocator.alloc(
        abi_feature.WGPUFeatureName,
        device.enabled_features.len,
    ) catch return;
    @memcpy(owned, device.enabled_features);
    out.featureCount = owned.len;
    out.features = owned.ptr;
}

pub fn symbolView(comptime name: []const u8) abi_core.WGPUStringView {
    return .{ .data = name.ptr, .length = name.len };
}

pub fn resolveRequiredProc(comptime FnType: type, comptime symbol_name: []const u8) FnType {
    const proc = wgpuGetProcAddress(symbolView(symbol_name)) orelse
        doeWgpuDropinAbortMissingRequiredSymbol(symbolView(symbol_name));
    return @as(FnType, @ptrCast(proc));
}
