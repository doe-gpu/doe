const std = @import("std");
const loader = @import("../wgpu_loader.zig");
const abi_core = @import("../wgpu_core_base_types.zig");
const abi_callback = @import("../wgpu_callback_descriptor_types.zig");
const abi_pipeline = @import("../wgpu_pipeline_descriptor_types.zig");
const abi_proc_aliases = @import("../wgpu_type_proc_aliases.zig");

pub const CREATE_COMPUTE_PIPELINE_ASYNC_STATUS_SUCCESS: u32 = 1;
pub const QUERY_TYPE_OCCLUSION: abi_core.WGPUQueryType = 0x00000001;

const CreateComputePipelineAsyncCallback = *const fn (
    status: u32,
    pipeline: abi_core.WGPUComputePipeline,
    message: abi_core.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void;

pub const CreateComputePipelineAsyncCallbackInfo = extern struct {
    nextInChain: ?*anyopaque,
    mode: abi_callback.WGPUCallbackMode,
    callback: ?CreateComputePipelineAsyncCallback,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
};

pub const ComputePipelineAsyncState = struct {
    done: bool = false,
    status: u32 = 0,
    pipeline: abi_core.WGPUComputePipeline = null,
};

pub const FnBufferDestroy = *const fn (abi_core.WGPUBuffer) callconv(.c) void;
pub const FnCommandEncoderClearBuffer = *const fn (abi_core.WGPUCommandEncoder, abi_core.WGPUBuffer, u64, u64) callconv(.c) void;
pub const FnCommandEncoderWriteBuffer = *const fn (abi_core.WGPUCommandEncoder, abi_core.WGPUBuffer, u64, [*]const u8, u64) callconv(.c) void;
pub const FnComputePassEncoderDispatchWorkgroupsIndirect = *const fn (abi_core.WGPUComputePassEncoder, abi_core.WGPUBuffer, u64) callconv(.c) void;
pub const FnComputePassEncoderWriteTimestamp = *const fn (abi_core.WGPUComputePassEncoder, abi_core.WGPUQuerySet, u32) callconv(.c) void;
pub const FnDeviceCreateComputePipelineAsync = *const fn (abi_core.WGPUDevice, *const abi_pipeline.WGPUComputePipelineDescriptor, CreateComputePipelineAsyncCallbackInfo) callconv(.c) abi_core.WGPUFuture;
pub const FnDeviceDestroy = *const fn (abi_core.WGPUDevice) callconv(.c) void;
pub const FnQuerySetDestroy = *const fn (abi_core.WGPUQuerySet) callconv(.c) void;
pub const FnQuerySetGetCount = *const fn (abi_core.WGPUQuerySet) callconv(.c) u32;
pub const FnQuerySetGetType = *const fn (abi_core.WGPUQuerySet) callconv(.c) abi_core.WGPUQueryType;
pub const FnRenderPassEncoderBeginOcclusionQuery = *const fn (abi_core.WGPURenderPassEncoder, u32) callconv(.c) void;
pub const FnRenderPassEncoderEndOcclusionQuery = *const fn (abi_core.WGPURenderPassEncoder) callconv(.c) void;
pub const FnRenderPassEncoderMultiDrawIndexedIndirect = *const fn (abi_core.WGPURenderPassEncoder, abi_core.WGPUBuffer, u64, u32, abi_core.WGPUBuffer, u64) callconv(.c) void;
pub const FnRenderPassEncoderMultiDrawIndirect = *const fn (abi_core.WGPURenderPassEncoder, abi_core.WGPUBuffer, u64, u32, abi_core.WGPUBuffer, u64) callconv(.c) void;
pub const FnRenderPassEncoderPixelLocalStorageBarrier = *const fn (abi_core.WGPURenderPassEncoder) callconv(.c) void;
pub const FnRenderPassEncoderWriteTimestamp = *const fn (abi_core.WGPURenderPassEncoder, abi_core.WGPUQuerySet, u32) callconv(.c) void;

pub const P0Procs = struct {
    buffer_destroy: ?FnBufferDestroy = null,
    command_encoder_clear_buffer: ?FnCommandEncoderClearBuffer = null,
    command_encoder_write_buffer: ?FnCommandEncoderWriteBuffer = null,
    compute_pass_encoder_dispatch_workgroups_indirect: ?FnComputePassEncoderDispatchWorkgroupsIndirect = null,
    compute_pass_encoder_write_timestamp: ?FnComputePassEncoderWriteTimestamp = null,
    device_create_compute_pipeline_async: ?FnDeviceCreateComputePipelineAsync = null,
    device_destroy: ?FnDeviceDestroy = null,
    query_set_destroy: ?FnQuerySetDestroy = null,
    query_set_get_count: ?FnQuerySetGetCount = null,
    query_set_get_type: ?FnQuerySetGetType = null,
    render_pass_encoder_begin_occlusion_query: ?FnRenderPassEncoderBeginOcclusionQuery = null,
    render_pass_encoder_end_occlusion_query: ?FnRenderPassEncoderEndOcclusionQuery = null,
    render_pass_encoder_multi_draw_indexed_indirect: ?FnRenderPassEncoderMultiDrawIndexedIndirect = null,
    render_pass_encoder_multi_draw_indirect: ?FnRenderPassEncoderMultiDrawIndirect = null,
    render_pass_encoder_pixel_local_storage_barrier: ?FnRenderPassEncoderPixelLocalStorageBarrier = null,
    render_pass_encoder_write_timestamp: ?FnRenderPassEncoderWriteTimestamp = null,
};

const LoadState = enum {
    uninitialized,
    ready,
};

var load_state: LoadState = .uninitialized;
var cached_procs: P0Procs = undefined;

fn loadProc(comptime T: type, lib: std.DynLib, comptime name: [:0]const u8) ?T {
    var mutable = lib;
    return mutable.lookup(T, name);
}

pub fn loadP0Procs(dyn_lib: ?std.DynLib) ?P0Procs {
    if (load_state == .ready) return cached_procs;
    const lib = dyn_lib orelse return null;
    const loaded = P0Procs{
        .buffer_destroy = loadProc(FnBufferDestroy, lib, "wgpuBufferDestroy"),
        .command_encoder_clear_buffer = loadProc(FnCommandEncoderClearBuffer, lib, "wgpuCommandEncoderClearBuffer"),
        .command_encoder_write_buffer = loadProc(FnCommandEncoderWriteBuffer, lib, "wgpuCommandEncoderWriteBuffer"),
        .compute_pass_encoder_dispatch_workgroups_indirect = loadProc(FnComputePassEncoderDispatchWorkgroupsIndirect, lib, "wgpuComputePassEncoderDispatchWorkgroupsIndirect"),
        .compute_pass_encoder_write_timestamp = loadProc(FnComputePassEncoderWriteTimestamp, lib, "wgpuComputePassEncoderWriteTimestamp"),
        .device_create_compute_pipeline_async = loadProc(FnDeviceCreateComputePipelineAsync, lib, "wgpuDeviceCreateComputePipelineAsync"),
        .device_destroy = loadProc(FnDeviceDestroy, lib, "wgpuDeviceDestroy"),
        .query_set_destroy = loadProc(FnQuerySetDestroy, lib, "wgpuQuerySetDestroy"),
        .query_set_get_count = loadProc(FnQuerySetGetCount, lib, "wgpuQuerySetGetCount"),
        .query_set_get_type = loadProc(FnQuerySetGetType, lib, "wgpuQuerySetGetType"),
        .render_pass_encoder_begin_occlusion_query = loadProc(FnRenderPassEncoderBeginOcclusionQuery, lib, "wgpuRenderPassEncoderBeginOcclusionQuery"),
        .render_pass_encoder_end_occlusion_query = loadProc(FnRenderPassEncoderEndOcclusionQuery, lib, "wgpuRenderPassEncoderEndOcclusionQuery"),
        .render_pass_encoder_multi_draw_indexed_indirect = loadProc(FnRenderPassEncoderMultiDrawIndexedIndirect, lib, "wgpuRenderPassEncoderMultiDrawIndexedIndirect"),
        .render_pass_encoder_multi_draw_indirect = loadProc(FnRenderPassEncoderMultiDrawIndirect, lib, "wgpuRenderPassEncoderMultiDrawIndirect"),
        .render_pass_encoder_pixel_local_storage_barrier = loadProc(FnRenderPassEncoderPixelLocalStorageBarrier, lib, "wgpuRenderPassEncoderPixelLocalStorageBarrier"),
        .render_pass_encoder_write_timestamp = loadProc(FnRenderPassEncoderWriteTimestamp, lib, "wgpuRenderPassEncoderWriteTimestamp"),
    };
    cached_procs = loaded;
    load_state = .ready;
    return loaded;
}

pub fn destroyBuffer(p0_procs: ?P0Procs, buffer: abi_core.WGPUBuffer) void {
    if (buffer == null) return;
    const loaded = p0_procs orelse return;
    const destroy_buffer = loaded.buffer_destroy orelse return;
    destroy_buffer(buffer);
}

pub fn destroyQuerySet(p0_procs: ?P0Procs, query_set: abi_core.WGPUQuerySet) void {
    if (query_set == null) return;
    const loaded = p0_procs orelse return;
    const destroy_query_set = loaded.query_set_destroy orelse return;
    destroy_query_set(query_set);
}

pub fn querySetMatches(
    p0_procs: ?P0Procs,
    query_set: abi_core.WGPUQuerySet,
    expected_count: u32,
    expected_type: abi_core.WGPUQueryType,
) bool {
    if (query_set == null) return false;
    const loaded = p0_procs orelse return true;
    if (loaded.query_set_get_count) |get_count| {
        if (get_count(query_set) != expected_count) return false;
    }
    if (loaded.query_set_get_type) |get_type| {
        if (get_type(query_set) != expected_type) return false;
    }
    return true;
}

pub fn createComputePipelineAsyncAndWait(
    p0_procs: P0Procs,
    instance: abi_core.WGPUInstance,
    procs: abi_proc_aliases.Procs,
    device: abi_core.WGPUDevice,
    descriptor: *const abi_pipeline.WGPUComputePipelineDescriptor,
) !abi_core.WGPUComputePipeline {
    const create_async = p0_procs.device_create_compute_pipeline_async orelse return error.AsyncProcUnavailable;
    var state = ComputePipelineAsyncState{};
    const callback_info = CreateComputePipelineAsyncCallbackInfo{
        .nextInChain = null,
        .mode = abi_callback.WGPUCallbackMode_AllowProcessEvents,
        .callback = computePipelineAsyncCallback,
        .userdata1 = &state,
        .userdata2 = null,
    };
    const future = create_async(device, descriptor, callback_info);
    if (future.id == 0) return error.AsyncFutureUnavailable;
    try processEventsUntil(instance, procs, &state.done, loader.DEFAULT_TIMEOUT_NS);
    if (!state.done) return error.AsyncFutureTimedOut;
    if (state.status != CREATE_COMPUTE_PIPELINE_ASYNC_STATUS_SUCCESS) return error.AsyncPipelineCreationFailed;
    return state.pipeline orelse error.AsyncPipelineCreationFailed;
}

fn processEventsUntil(
    instance: abi_core.WGPUInstance,
    procs: abi_proc_aliases.Procs,
    done: *const bool,
    timeout_ns: u64,
) !void {
    const start = std.time.nanoTimestamp();
    var spins: u32 = 0;
    while (!done.*) {
        procs.wgpuInstanceProcessEvents(instance);
        const elapsed = std.time.nanoTimestamp() - start;
        if (elapsed >= timeout_ns) return error.WaitTimedOut;
        spins += 1;
        if (spins > 1000) std.Thread.sleep(1_000);
    }
}

fn computePipelineAsyncCallback(
    status: u32,
    pipeline: abi_core.WGPUComputePipeline,
    message: abi_core.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    const state = @as(*ComputePipelineAsyncState, @ptrCast(@alignCast(userdata1.?)));
    state.done = true;
    state.status = status;
    state.pipeline = pipeline;
}
