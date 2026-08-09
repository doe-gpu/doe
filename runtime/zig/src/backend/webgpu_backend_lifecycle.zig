const std = @import("std");
const model_profile = @import("../contracts/model/model_profile.zig");
const abi_core = @import("../core/abi/wgpu_core_base_types.zig");
const abi_feature = @import("../core/abi/wgpu_feature_base_types.zig");
const abi_callback = @import("../core/abi/wgpu_callback_descriptor_types.zig");
const abi_records = @import("../core/abi/wgpu_runtime_records.zig");
const loader = @import("../core/abi/wgpu_loader.zig");
const p0_procs_mod = @import("../core/abi/procs/wgpu_p0_procs.zig");
const surface_procs_mod = @import("../full/surface/wgpu_surface_procs.zig");
const texture_procs_mod = @import("../core/abi/procs/wgpu_texture_procs.zig");
const surface_macos_mod = @import("../full/surface/wgpu_surface_macos.zig");

pub fn preferredBackendType(profile: model_profile.DeviceProfile) abi_callback.WGPUBackendType {
    return switch (profile.api) {
        .vulkan => .vulkan,
        .metal => .metal,
        .d3d12 => .d3d12,
        .webgpu => .webgpu,
    };
}

pub fn backendTypeName(backend_type: abi_callback.WGPUBackendType) []const u8 {
    return switch (backend_type) {
        .vulkan => "vulkan",
        .metal => "metal",
        .d3d12 => "d3d12",
        .webgpu => "webgpu",
        else => "undefined",
    };
}

pub fn deinit(self: anytype) void {
    const procs = self.core.procs orelse return;
    const p0_procs = p0_procs_mod.loadP0Procs(self.core.dyn_lib);

    if (self.full.render_uniform_bind_group) |bind_group| {
        procs.wgpuBindGroupRelease(bind_group);
        self.full.render_uniform_bind_group = null;
    }
    if (self.full.render_uniform_bind_group_layout) |bind_group_layout| {
        procs.wgpuBindGroupLayoutRelease(bind_group_layout);
        self.full.render_uniform_bind_group_layout = null;
    }
    if (self.full.render_sampler) |sampler| {
        if (texture_procs_mod.loadTextureProcs(self.core.dyn_lib)) |texture_procs| {
            texture_procs.sampler_release(sampler);
        }
        self.full.render_sampler = null;
    }

    if (texture_procs_mod.loadTextureProcs(self.core.dyn_lib)) |texture_procs| {
        var sampler_it = self.full.samplers.valueIterator();
        while (sampler_it.next()) |sampler| {
            if (sampler.* != null) texture_procs.sampler_release(sampler.*);
        }
    }
    self.full.samplers.clearAndFree();

    var it = self.core.buffers.valueIterator();
    while (it.next()) |record| {
        p0_procs_mod.destroyBuffer(p0_procs, record.buffer);
        procs.wgpuBufferRelease(record.buffer);
    }
    self.core.buffers.clearAndFree();

    var target_view_it = self.full.render_target_view_cache.valueIterator();
    while (target_view_it.next()) |entry| {
        procs.wgpuTextureViewRelease(entry.view);
    }
    self.full.render_target_view_cache.clearAndFree();

    var depth_view_it = self.full.render_depth_view_cache.valueIterator();
    while (depth_view_it.next()) |entry| {
        procs.wgpuTextureViewRelease(entry.view);
    }
    self.full.render_depth_view_cache.clearAndFree();

    const texture_procs = texture_procs_mod.loadTextureProcs(self.core.dyn_lib);
    var texture_it = self.core.textures.valueIterator();
    while (texture_it.next()) |record| {
        if (texture_procs) |tp| {
            tp.texture_destroy(record.texture);
        }
        procs.wgpuTextureRelease(record.texture);
    }
    self.core.textures.clearAndFree();

    if (surface_procs_mod.loadSurfaceProcs(self.core.dyn_lib)) |surface_procs| {
        var surface_it = self.full.surfaces.valueIterator();
        while (surface_it.next()) |managed_surface| {
            if (managed_surface.*.acquired_texture != null) {
                procs.wgpuTextureRelease(managed_surface.*.acquired_texture);
            }
            if (managed_surface.*.configured) {
                surface_procs.surface_unconfigure(managed_surface.*.surface);
            }
            surface_procs.surface_release(managed_surface.*.surface);
            surface_macos_mod.releasePlatformSurface(managed_surface.*.platform_surface);
        }
    } else {
        var surface_it = self.full.surfaces.valueIterator();
        while (surface_it.next()) |managed_surface| {
            if (managed_surface.*.acquired_texture != null) {
                procs.wgpuTextureRelease(managed_surface.*.acquired_texture);
            }
            surface_macos_mod.releasePlatformSurface(managed_surface.*.platform_surface);
        }
    }
    self.full.surfaces.clearAndFree();

    var pipe_it = self.core.pipeline_cache.valueIterator();
    while (pipe_it.next()) |entry| {
        procs.wgpuComputePipelineRelease(entry.pipeline);
        procs.wgpuShaderModuleRelease(entry.shader_module);
    }
    self.core.pipeline_cache.clearAndFree();

    var render_pipe_it = self.full.render_pipeline_cache.valueIterator();
    while (render_pipe_it.next()) |entry| {
        if (procs.wgpuRenderPipelineRelease) |release_render_pipeline| {
            release_render_pipeline(entry.pipeline);
        }
        procs.wgpuShaderModuleRelease(entry.shader_module);
    }
    self.full.render_pipeline_cache.clearAndFree();
    if (self.full.render_occlusion_query_set) |query_set| {
        p0_procs_mod.destroyQuerySet(p0_procs, query_set);
        procs.wgpuQuerySetRelease(query_set);
        self.full.render_occlusion_query_set = null;
    }
    if (self.full.render_timestamp_query_set) |query_set| {
        p0_procs_mod.destroyQuerySet(p0_procs, query_set);
        procs.wgpuQuerySetRelease(query_set);
        self.full.render_timestamp_query_set = null;
    }

    if (self.core.upload_scratch.len > 0) {
        self.core.allocator.free(self.core.upload_scratch);
        self.core.upload_scratch = &[_]u8{};
    }

    if (self.core.queue) |queue| {
        procs.wgpuQueueRelease(queue);
        self.core.queue = null;
    }
    if (self.core.device) |device| {
        if (p0_procs) |loaded| {
            if (loaded.device_destroy) |destroy_device| {
                destroy_device(device);
            }
        }
        procs.wgpuDeviceRelease(device);
        self.core.device = null;
    }
    if (self.core.adapter) |adapter| {
        procs.wgpuAdapterRelease(adapter);
        self.core.adapter = null;
    }
    if (self.core.instance) |instance| {
        procs.wgpuInstanceRelease(instance);
        self.core.instance = null;
    }

    if (self.core.dyn_lib) |*lib| {
        lib.close();
        self.core.dyn_lib = null;
    }

    self.core.procs = null;
    self.core.capability_procs = null;
    self.core.resource_table_procs = null;
    self.core.lifecycle_procs = null;
}

pub fn captureAdapterLimits(self: anytype) !void {
    self.core.has_adapter_limits = false;
    self.core.adapter_limits = abi_callback.initLimits();
    const cap = self.core.capability_procs orelse return;
    const get_limits = cap.adapter_get_limits orelse return;
    if (self.core.adapter == null) return;
    if (get_limits(self.core.adapter.?, &self.core.adapter_limits) != abi_core.WGPUStatus_Success) {
        return error.AdapterLimitsQueryFailed;
    }
    self.core.has_adapter_limits = true;
}

pub fn captureDeviceLimits(self: anytype) !void {
    self.core.has_device_limits = false;
    self.core.device_limits = abi_callback.initLimits();
    const cap = self.core.capability_procs orelse return;
    const get_limits = cap.device_get_limits orelse return;
    if (self.core.device == null) return;
    if (get_limits(self.core.device.?, &self.core.device_limits) != abi_core.WGPUStatus_Success) {
        return error.DeviceLimitsQueryFailed;
    }
    self.core.has_device_limits = true;
}

pub fn requestAdapter(self: anytype) !abi_core.WGPUAdapter {
    var state = abi_records.RequestState{};
    const request_info = abi_callback.WGPURequestAdapterCallbackInfo{
        .nextInChain = null,
        .mode = abi_callback.WGPUCallbackMode_AllowProcessEvents,
        .callback = loader.adapterCallback,
        .userdata1 = &state,
        .userdata2 = null,
    };
    const options = abi_callback.WGPURequestAdapterOptions{
        .nextInChain = null,
        .featureLevel = @intFromEnum(abi_callback.WGPUFeatureLevel.undefined),
        .powerPreference = @intFromEnum(abi_callback.WGPUPowerPreference.highPerformance),
        .forceFallbackAdapter = abi_core.WGPU_FALSE,
        .backendType = @intFromEnum(self.core.requested_backend_type),
        .compatibleSurface = null,
    };
    timestampLog(
        self,
        "request_adapter backend_type={s}\n",
        .{backendTypeName(self.core.requested_backend_type)},
    );

    const adapter_request_info = request_info;
    const future = self.core.procs.?.wgpuInstanceRequestAdapter(
        self.core.instance.?,
        &options,
        adapter_request_info,
    );
    if (future.id == 0) return error.AdapterRequestFailed;

    try self.processEventsUntil(&state.done, loader.DEFAULT_TIMEOUT_NS);
    if (!state.done) return error.AdapterRequestNoCallback;
    timestampLog(self, "request_adapter_status={}\n", .{@intFromEnum(state.status)});

    return switch (state.status) {
        .success => state.adapter orelse error.AdapterRequestFailed,
        .callbackCancelled, .unavailable => error.AdapterUnavailable,
        .@"error" => error.AdapterRequestFailed,
        else => error.AdapterRequestFailed,
    };
}

pub fn requestDevice(self: anytype) !abi_core.WGPUDevice {
    self.clearUncapturedError();
    var state = abi_records.DeviceRequestState{};
    const request_info = abi_callback.WGPURequestDeviceCallbackInfo{
        .nextInChain = null,
        .mode = abi_callback.WGPUCallbackMode_AllowProcessEvents,
        .callback = loader.deviceRequestCallback,
        .userdata1 = &state,
        .userdata2 = null,
    };
    var required_features = [_]abi_feature.WGPUFeatureName{undefined} ** 7;
    var feature_count: usize = 0;
    const has_resource_table_feature = self.core.procs.?.wgpuAdapterHasFeature(self.core.adapter.?, abi_feature.WGPUFeatureName_ChromiumExperimentalSamplingResourceTable) != abi_core.WGPU_FALSE;
    if (self.core.has_timestamp_query) {
        required_features[feature_count] = abi_feature.WGPUFeatureName_TimestampQuery;
        feature_count += 1;
    }
    if (self.core.has_timestamp_inside_passes) {
        required_features[feature_count] = abi_feature.WGPUFeatureName_ChromiumExperimentalTimestampQueryInsidePasses;
        feature_count += 1;
    }
    if (self.core.has_multi_draw_indirect) {
        required_features[feature_count] = abi_feature.WGPUFeatureName_MultiDrawIndirect;
        feature_count += 1;
    }
    if (self.core.has_pixel_local_storage_coherent) {
        required_features[feature_count] = abi_feature.WGPUFeatureName_PixelLocalStorageCoherent;
        feature_count += 1;
    }
    if (self.core.has_pixel_local_storage_non_coherent) {
        required_features[feature_count] = abi_feature.WGPUFeatureName_PixelLocalStorageNonCoherent;
        feature_count += 1;
    }
    if (self.core.adapter_has_shader_f16) {
        required_features[feature_count] = abi_feature.WGPUFeatureName_ShaderF16;
        feature_count += 1;
    }
    if (has_resource_table_feature) {
        required_features[feature_count] = abi_feature.WGPUFeatureName_ChromiumExperimentalSamplingResourceTable;
        feature_count += 1;
    }
    timestampLog(self, "request_device required_features timestamp={} inside_passes={} multi_draw={} pls_coherent={} pls_noncoherent={} shader_f16={} resource_table={} count={} adapter_limits={} max_storage_binding={} max_uniform_binding={} max_buffer={}\n", .{
        self.core.has_timestamp_query,
        self.core.has_timestamp_inside_passes,
        self.core.has_multi_draw_indirect,
        self.core.has_pixel_local_storage_coherent,
        self.core.has_pixel_local_storage_non_coherent,
        self.core.adapter_has_shader_f16,
        has_resource_table_feature,
        feature_count,
        self.core.has_adapter_limits,
        self.core.adapter_limits.maxStorageBufferBindingSize,
        self.core.adapter_limits.maxUniformBufferBindingSize,
        self.core.adapter_limits.maxBufferSize,
    });
    const device_desc = abi_callback.WGPUDeviceDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
        .requiredFeatureCount = feature_count,
        .requiredFeatures = if (feature_count > 0) required_features[0..].ptr else null,
        .requiredLimits = if (self.core.has_adapter_limits) &self.core.adapter_limits else null,
        .defaultQueue = .{ .nextInChain = null, .label = loader.emptyStringView() },
        .deviceLostCallbackInfo = .{
            .nextInChain = null,
            .mode = abi_callback.WGPUCallbackMode_AllowProcessEvents,
            .callback = null,
            .userdata1 = null,
            .userdata2 = null,
        },
        .uncapturedErrorCallbackInfo = .{
            .nextInChain = null,
            .callback = loader.uncapturedErrorCallback,
            .userdata1 = &self.core.uncaptured_error_state,
            .userdata2 = null,
        },
    };
    const device_request_info = request_info;
    const future = self.core.procs.?.wgpuAdapterRequestDevice(self.core.adapter.?, &device_desc, device_request_info);
    if (future.id == 0) return error.DeviceRequestFailed;

    try self.processEventsUntil(&state.done, loader.DEFAULT_TIMEOUT_NS);
    if (!state.done) return error.DeviceRequestNoCallback;
    timestampLog(self, "request_device_status={}\n", .{@intFromEnum(state.status)});

    return switch (state.status) {
        .success => state.device orelse error.DeviceRequestFailed,
        .callbackCancelled => error.DeviceRequestCancelled,
        .@"error" => error.DeviceRequestFailed,
        else => error.DeviceRequestFailed,
    };
}

pub fn timestampLog(self: anytype, comptime fmt: []const u8, args: anytype) void {
    if (!self.core.timestamp_debug) return;
    std.log.scoped(.doe_timestamp).debug(fmt, args);
}
