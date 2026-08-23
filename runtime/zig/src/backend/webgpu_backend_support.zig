const std = @import("std");
const abi_base = @import("../core/abi/wgpu_handle_types.zig");
const abi_callback = @import("../core/abi/wgpu_callback_descriptor_types.zig");
const runtime_types = @import("../contracts/runtime_types.zig");
const capability_runtime_mod = @import("../core/runtime/wgpu_capability_runtime.zig");
const p1_resource_table_procs_mod = @import("../core/abi/procs/wgpu_p1_resource_table_procs.zig");
const p2_lifecycle_procs_mod = @import("../core/abi/procs/wgpu_p2_lifecycle_procs.zig");

const UploadBufferUsageMode = runtime_types.UploadBufferUsageMode;
const QueueWaitMode = runtime_types.QueueWaitMode;
const QueueSyncMode = runtime_types.QueueSyncMode;
const GpuTimestampMode = runtime_types.GpuTimestampMode;

pub fn backendAvailable(self: anytype) bool {
    return self.core.procs != null and self.core.instance != null and self.core.adapter != null and self.core.device != null and self.core.queue != null;
}

pub fn runCapabilityIntrospection(self: anytype) !void {
    try capability_runtime_mod.probeInstanceCapabilities(self.core.capability_procs, self.core.instance);
    const adapter_probe = try capability_runtime_mod.probeAdapterCapabilities(
        self.core.capability_procs,
        self.core.adapter,
        self.core.instance,
        .{
            .adapter_has_timestamp_query = self.core.adapter_has_timestamp_query,
            .has_timestamp_inside_passes = self.core.has_timestamp_inside_passes,
            .adapter_has_multi_draw_indirect = self.core.adapter_has_multi_draw_indirect,
            .adapter_has_pixel_local_storage_coherent = self.core.adapter_has_pixel_local_storage_coherent,
            .adapter_has_pixel_local_storage_non_coherent = self.core.adapter_has_pixel_local_storage_non_coherent,
        },
    );
    self.core.adapter_has_timestamp_query = adapter_probe.adapter_has_timestamp_query;
    self.core.has_timestamp_inside_passes = adapter_probe.has_timestamp_inside_passes;
    self.core.adapter_has_multi_draw_indirect = adapter_probe.adapter_has_multi_draw_indirect;
    self.core.adapter_has_pixel_local_storage_coherent = adapter_probe.adapter_has_pixel_local_storage_coherent;
    self.core.adapter_has_pixel_local_storage_non_coherent = adapter_probe.adapter_has_pixel_local_storage_non_coherent;
    const device_probe = try capability_runtime_mod.probeDeviceCapabilities(
        self.core.capability_procs,
        self.core.device,
        self.core.adapter,
        .{
            .has_timestamp_query = self.core.has_timestamp_query,
            .has_multi_draw_indirect = self.core.has_multi_draw_indirect,
            .has_pixel_local_storage_coherent = self.core.has_pixel_local_storage_coherent,
            .has_pixel_local_storage_non_coherent = self.core.has_pixel_local_storage_non_coherent,
        },
    );
    self.core.has_timestamp_query = device_probe.has_timestamp_query;
    self.core.has_multi_draw_indirect = device_probe.has_multi_draw_indirect;
    self.core.has_pixel_local_storage_coherent = device_probe.has_pixel_local_storage_coherent;
    self.core.has_pixel_local_storage_non_coherent = device_probe.has_pixel_local_storage_non_coherent;
}

pub fn getResourceTableProcs(self: anytype) ?p1_resource_table_procs_mod.ResourceTableProcs {
    return self.core.resource_table_procs;
}

pub fn getLifecycleProcs(self: anytype) ?p2_lifecycle_procs_mod.LifecycleProcs {
    return self.core.lifecycle_procs;
}

pub fn setUploadBehavior(self: anytype, usage_mode: UploadBufferUsageMode, submit_every: u32) void {
    self.core.upload_buffer_usage_mode = usage_mode;
    self.core.upload_submit_every = if (submit_every == 0) 1 else submit_every;
    self.core.upload_submit_pending = 0;
}

pub fn setQueueWaitMode(self: anytype, wait_mode: QueueWaitMode) void {
    self.core.queue_wait_mode = wait_mode;
}

pub fn setWebgpuFfiQueueWaitTimeoutNs(self: anytype, timeout_ns: u64) void {
    if (timeout_ns == 0) return;
    self.core.webgpu_ffi_queue_wait_timeout_ns = timeout_ns;
}

pub fn setQueueSyncMode(self: anytype, sync_mode: QueueSyncMode) void {
    self.core.queue_sync_mode = sync_mode;
}

pub fn setGpuTimestampMode(self: anytype, timestamp_mode: GpuTimestampMode) void {
    self.core.gpu_timestamp_mode = timestamp_mode;
}

pub fn gpuTimestampsEnabled(self: anytype) bool {
    return self.core.has_timestamp_query and self.core.gpu_timestamp_mode != .off;
}

pub fn gpuTimestampsRequired(self: anytype) bool {
    return self.core.gpu_timestamp_mode == .require;
}

pub fn clearUncapturedError(self: anytype) void {
    self.core.uncaptured_error_state.error_type.store(@intFromEnum(abi_callback.WGPUErrorType.noError), .release);
    self.core.uncaptured_error_state.pending.store(0, .release);
}

pub fn takeUncapturedError(self: anytype) ?abi_callback.WGPUErrorType {
    if (self.core.uncaptured_error_state.pending.swap(0, .acq_rel) == 0) return null;
    const raw = self.core.uncaptured_error_state.error_type.load(.acquire);
    return @enumFromInt(raw);
}

pub fn uncapturedErrorStatusMessage(error_type: abi_callback.WGPUErrorType) []const u8 {
    return switch (error_type) {
        .validation => "uncaptured WebGPU validation error",
        .outOfMemory => "uncaptured WebGPU out-of-memory error",
        .internal => "uncaptured WebGPU internal error",
        .unknown => "uncaptured WebGPU unknown error",
        else => "uncaptured WebGPU error",
    };
}

pub fn effectiveLimits(self: anytype) ?*const abi_callback.WGPULimits {
    if (self.core.has_device_limits) return &self.core.device_limits;
    if (self.core.has_adapter_limits) return &self.core.adapter_limits;
    return null;
}

pub fn releaseFullTextureViewsForTexture(self: anytype, texture: abi_base.WGPUTexture) void {
    const procs = self.core.procs orelse return;

    var target_keys = std.ArrayList(u64).empty;
    defer target_keys.deinit(self.core.allocator);
    var target_it = self.full.render_target_view_cache.iterator();
    while (target_it.next()) |entry| {
        if (entry.value_ptr.texture == texture) target_keys.append(self.core.allocator, entry.key_ptr.*) catch return;
    }
    for (target_keys.items) |key| {
        if (self.full.render_target_view_cache.fetchRemove(key)) |removed| {
            procs.wgpuTextureViewRelease(removed.value.view);
        }
    }

    var depth_keys = std.ArrayList(u64).empty;
    defer depth_keys.deinit(self.core.allocator);
    var depth_it = self.full.render_depth_view_cache.iterator();
    while (depth_it.next()) |entry| {
        if (entry.value_ptr.texture == texture) depth_keys.append(self.core.allocator, entry.key_ptr.*) catch return;
    }
    for (depth_keys.items) |key| {
        if (self.full.render_depth_view_cache.fetchRemove(key)) |removed| {
            procs.wgpuTextureViewRelease(removed.value.view);
        }
    }
}
