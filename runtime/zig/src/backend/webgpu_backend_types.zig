const std = @import("std");
const abi_callback = @import("../core/abi/wgpu_callback_descriptor_types.zig");
const abi_handle = @import("../core/abi/wgpu_handle_types.zig");
const abi_records = @import("../core/abi/wgpu_runtime_records.zig");
const abi_proc_aliases = @import("../core/abi/wgpu_type_proc_aliases.zig");
const runtime_state = @import("../core/abi/wgpu_runtime_state_defs.zig");
const runtime_types = @import("../contracts/runtime_types.zig");
const loader = @import("../core/abi/wgpu_loader.zig");
const p1_capability_procs_mod = @import("../core/abi/procs/wgpu_p1_capability_procs.zig");
const p1_resource_table_procs_mod = @import("../core/abi/procs/wgpu_p1_resource_table_procs.zig");
const p2_lifecycle_procs_mod = @import("../core/abi/procs/wgpu_p2_lifecycle_procs.zig");
const surface_procs_mod = @import("../full/surface/wgpu_surface_procs.zig");
const surface_macos_mod = @import("../full/surface/wgpu_surface_macos.zig");

const UploadBufferUsageMode = runtime_types.UploadBufferUsageMode;
const QueueWaitMode = runtime_types.QueueWaitMode;
const QueueSyncMode = runtime_types.QueueSyncMode;
const GpuTimestampMode = runtime_types.GpuTimestampMode;
pub const BufferRecord = abi_records.BufferRecord;
pub const TextureRecord = abi_records.TextureRecord;
pub const RenderPipelineCacheEntry = abi_records.RenderPipelineCacheEntry;
pub const RenderTextureViewCacheEntry = abi_records.RenderTextureViewCacheEntry;
pub const PipelineCacheEntry = runtime_state.PipelineCacheEntry;
pub const UncapturedErrorState = runtime_state.UncapturedErrorState;

pub const ManagedSurface = struct {
    surface: surface_procs_mod.Surface,
    platform_surface: ?surface_macos_mod.ManagedPlatformSurface = null,
    configured: bool = false,
    acquired_texture: abi_handle.WGPUTexture = null,
    last_texture_status: u32 = 0,
};

pub const CoreWebGPUBackend = struct {
    allocator: std.mem.Allocator,
    dyn_lib: ?std.DynLib = null,
    procs: ?abi_proc_aliases.Procs = null,
    capability_procs: ?p1_capability_procs_mod.CapabilityProcs = null,
    resource_table_procs: ?p1_resource_table_procs_mod.ResourceTableProcs = null,
    lifecycle_procs: ?p2_lifecycle_procs_mod.LifecycleProcs = null,
    instance: abi_handle.WGPUInstance = null,
    adapter: abi_handle.WGPUAdapter = null,
    device: abi_handle.WGPUDevice = null,
    queue: abi_handle.WGPUQueue = null,
    buffers: std.AutoHashMap(u64, BufferRecord),
    textures: std.AutoHashMap(u64, TextureRecord),
    pipeline_cache: std.AutoHashMap(u64, PipelineCacheEntry),
    upload_scratch: []u8 = &[_]u8{},
    upload_buffer_usage_mode: UploadBufferUsageMode = .copy_dst_copy_src,
    upload_submit_every: u32 = 1,
    upload_submit_pending: u32 = 0,
    queue_wait_mode: QueueWaitMode = .process_events,
    webgpu_ffi_queue_wait_timeout_ns: u64 = loader.QUEUE_WAIT_TIMEOUT_NS,
    queue_sync_mode: QueueSyncMode = .per_command,
    gpu_timestamp_mode: GpuTimestampMode = .auto,
    kernel_root: ?[]const u8 = null,
    library_error: []const u8 = "",
    requested_backend_type: abi_callback.WGPUBackendType = .undefined,
    adapter_has_timestamp_query: bool = false,
    adapter_has_multi_draw_indirect: bool = false,
    adapter_has_pixel_local_storage_coherent: bool = false,
    adapter_has_pixel_local_storage_non_coherent: bool = false,
    adapter_has_shader_f16: bool = false,
    has_timestamp_query: bool = false,
    has_timestamp_inside_passes: bool = false,
    has_multi_draw_indirect: bool = false,
    has_pixel_local_storage_coherent: bool = false,
    has_pixel_local_storage_non_coherent: bool = false,
    has_shader_f16: bool = false,
    has_adapter_limits: bool = false,
    has_device_limits: bool = false,
    adapter_limits: abi_callback.WGPULimits = std.mem.zeroes(abi_callback.WGPULimits),
    device_limits: abi_callback.WGPULimits = std.mem.zeroes(abi_callback.WGPULimits),
    uncaptured_error_state: UncapturedErrorState = .{},
    timestamp_debug: bool = false,
};

pub const FullWebGPUBackendState = struct {
    render_pipeline_cache: std.AutoHashMap(u32, RenderPipelineCacheEntry),
    render_target_view_cache: std.AutoHashMap(u64, RenderTextureViewCacheEntry),
    render_depth_view_cache: std.AutoHashMap(u64, RenderTextureViewCacheEntry),
    samplers: std.AutoHashMap(u64, abi_handle.WGPUSampler),
    surfaces: std.AutoHashMap(u64, ManagedSurface),
    render_uniform_bind_group_layout: abi_handle.WGPUBindGroupLayout = null,
    render_uniform_bind_group: abi_handle.WGPUBindGroup = null,
    render_sampler: abi_handle.WGPUSampler = null,
    render_occlusion_query_set: abi_handle.WGPUQuerySet = null,
    render_timestamp_query_set: abi_handle.WGPUQuerySet = null,
};
