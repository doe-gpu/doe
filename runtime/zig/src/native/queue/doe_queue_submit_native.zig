const abi_core = @import("../../core/abi/wgpu_core_base_types.zig");
const abi_callback = @import("../../core/abi/wgpu_callback_descriptor_types.zig");
const abi_copy = @import("../../core/abi/wgpu_copy_descriptor_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const copy_ops = @import("doe_queue_copy_native.zig");
const lifecycle = @import("doe_queue_lifecycle.zig");
const shared = @import("doe_queue_submit_shared.zig");
const d3d12_submit = @import("doe_queue_submit_d3d12.zig");
const metal_submit = @import("doe_queue_submit_metal.zig");
const vulkan_submit = @import("doe_queue_submit_vulkan.zig");
const compute_program = @import("../compute/doe_compute_program_native.zig");

comptime {
    _ = &compute_program.doeNativeComputeProgramSupported;
    _ = &compute_program.doeNativeComputeProgramPrepare;
    _ = &compute_program.doeNativeComputeProgramSubmit;
    _ = &compute_program.doeNativeComputeProgramRelease;
}

const cast = native_helpers.cast;
const DoeQueue = native_types.DoeQueue;

pub export fn doeNativeComputeProgramContractVersion() callconv(.c) u32 {
    return @import("build_options").compute_program_contract_version;
}

pub const flush_pending_work = shared.flush_pending_work;
pub const flush_pending_work_timed = shared.flush_pending_work_timed;
pub const flush_before_submit_if_needed = shared.flush_before_submit_if_needed;
pub const flush_before_submit_if_needed_timed = shared.flush_before_submit_if_needed_timed;
pub const finalize_submitted_metal_command_buffer = shared.finalize_submitted_metal_command_buffer;
pub const try_schedule_deferred_copy = shared.try_schedule_deferred_copy;
pub const drain_global_work_done = lifecycle.drain_global_work_done;

pub export fn doeNativeQueueSubmit(
    q_raw: ?*anyopaque,
    count: usize,
    cmd_bufs: [*]const ?*anyopaque,
) callconv(.c) void {
    const q = cast(DoeQueue, q_raw) orelse return;
    if (q.dev.backend == .vulkan) {
        vulkan_submit.submit_vulkan_commands(q, count, cmd_bufs);
        return;
    }
    if (q.dev.backend == .d3d12) {
        d3d12_submit.submit_d3d12_commands(q, count, cmd_bufs);
        return;
    }
    metal_submit.submit_metal_commands(q, count, cmd_bufs);
}

pub export fn doeNativeQueueFlush(q_raw: ?*anyopaque) callconv(.c) void {
    lifecycle.doeNativeQueueFlush(q_raw);
}

pub export fn doeNativeQueueFlushBreakdown(
    q_raw: ?*anyopaque,
    wait_completed_ns_out: *u64,
    deferred_copy_ns_out: *u64,
    deferred_resolve_ns_out: *u64,
) callconv(.c) void {
    lifecycle.doeNativeQueueFlushBreakdown(
        q_raw,
        wait_completed_ns_out,
        deferred_copy_ns_out,
        deferred_resolve_ns_out,
    );
}

pub export fn doeNativeQueueSyncInfo(q_raw: ?*anyopaque) callconv(.c) u32 {
    return lifecycle.doeNativeQueueSyncInfo(q_raw);
}

pub fn doeNativeQueuePipelineCacheInfo(q_raw: ?*anyopaque) u32 {
    return lifecycle.doeNativeQueuePipelineCacheInfo(q_raw);
}

pub fn doeNativeQueuePipelineCacheWarmupCount(q_raw: ?*anyopaque) u64 {
    return lifecycle.doeNativeQueuePipelineCacheWarmupCount(q_raw);
}

pub fn doeNativeQueuePipelineCacheWarmupNs(q_raw: ?*anyopaque) u64 {
    return lifecycle.doeNativeQueuePipelineCacheWarmupNs(q_raw);
}

pub fn doeNativeQueuePipelineCacheFlush(q_raw: ?*anyopaque) void {
    lifecycle.doeNativeQueuePipelineCacheFlush(q_raw);
}

pub fn doeNativeQueueFamilyPolicyCode(q_raw: ?*anyopaque) u32 {
    return lifecycle.doeNativeQueueFamilyPolicyCode(q_raw);
}

pub fn doeNativeQueueDeferredSubmissionSyncPolicyCode(q_raw: ?*anyopaque) u32 {
    return lifecycle.doeNativeQueueDeferredSubmissionSyncPolicyCode(q_raw);
}

pub fn doeNativeQueueFamilyKindCode(q_raw: ?*anyopaque) u32 {
    return lifecycle.doeNativeQueueFamilyKindCode(q_raw);
}

pub fn doeNativeQueueFamilyIndex(q_raw: ?*anyopaque) u32 {
    return lifecycle.doeNativeQueueFamilyIndex(q_raw);
}

pub fn doeNativeQueueFamilyQueueCount(q_raw: ?*anyopaque) u32 {
    return lifecycle.doeNativeQueueFamilyQueueCount(q_raw);
}

pub fn doeNativeQueueFamilyTimestampValidBits(q_raw: ?*anyopaque) u32 {
    return lifecycle.doeNativeQueueFamilyTimestampValidBits(q_raw);
}

pub fn doeNativeQueueFamilySupportsGraphics(q_raw: ?*anyopaque) u32 {
    return lifecycle.doeNativeQueueFamilySupportsGraphics(q_raw);
}

pub export fn doeNativeQueueWriteBuffer(
    q_raw: ?*anyopaque,
    buf_raw: ?*anyopaque,
    offset: u64,
    data: [*]const u8,
    size: usize,
) callconv(.c) void {
    copy_ops.doeNativeQueueWriteBuffer(q_raw, buf_raw, offset, data, size);
}

pub export fn doeNativeQueueWriteBufferBatch(
    q_raw: ?*anyopaque,
    count: usize,
    buf_raws: [*]const ?*anyopaque,
    offsets: [*]const u64,
    sizes: [*]const u32,
    data: [*]const u8,
) callconv(.c) void {
    copy_ops.doeNativeQueueWriteBufferBatch(q_raw, count, buf_raws, offsets, sizes, data);
}

pub export fn doeNativeQueueWriteBufferBatchDataPtrs(
    q_raw: ?*anyopaque,
    count: usize,
    buf_raws: [*]const ?*anyopaque,
    offsets: [*]const u64,
    sizes: [*]const u32,
    data_ptrs: [*]const ?*const anyopaque,
) callconv(.c) void {
    copy_ops.doeNativeQueueWriteBufferBatchDataPtrs(q_raw, count, buf_raws, offsets, sizes, data_ptrs);
}

pub export fn doeNativeQueueCopyTextureForBrowser(
    queue_raw: ?*anyopaque,
    source_raw: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    destination_raw: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    copy_size_raw: ?*const abi_copy.WGPUExtent3D,
    options_raw: ?*const abi_copy.WGPUCopyTextureForBrowserOptions,
) callconv(.c) void {
    copy_ops.doeNativeQueueCopyTextureForBrowser(
        queue_raw,
        source_raw,
        destination_raw,
        copy_size_raw,
        options_raw,
    );
}

pub export fn doeNativeQueueRelease(raw: ?*anyopaque) callconv(.c) void {
    lifecycle.doeNativeQueueRelease(raw);
}

pub export fn doeNativeQueueAddRef(raw: ?*anyopaque) callconv(.c) void {
    lifecycle.doeNativeQueueAddRef(raw);
}

pub export fn doeNativeQueueOnSubmittedWorkDone(
    q_raw: ?*anyopaque,
    info: abi_callback.WGPUQueueWorkDoneCallbackInfo,
) callconv(.c) abi_core.WGPUFuture {
    return lifecycle.doeNativeQueueOnSubmittedWorkDone(q_raw, info);
}

pub export fn doeNativeQueueCopyExternalImageToTexture(
    queue_raw: ?*anyopaque,
    source_raw: ?*const abi_copy.WGPUImageCopyExternalTexture,
    destination_raw: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    copy_size_raw: ?*const abi_copy.WGPUExtent3D,
) callconv(.c) void {
    copy_ops.doeNativeQueueCopyExternalImageToTexture(
        queue_raw,
        source_raw,
        destination_raw,
        copy_size_raw,
    );
}

pub export fn doeNativeQueueCopyExternalTextureForBrowser(
    queue_raw: ?*anyopaque,
    source_raw: ?*const abi_copy.WGPUImageCopyExternalTexture,
    destination_raw: ?*const abi_copy.WGPUTexelCopyTextureInfo,
    copy_size_raw: ?*const abi_copy.WGPUExtent3D,
    options_raw: ?*const abi_copy.WGPUCopyTextureForBrowserOptions,
) callconv(.c) void {
    copy_ops.doeNativeQueueCopyExternalTextureForBrowser(
        queue_raw,
        source_raw,
        destination_raw,
        copy_size_raw,
        options_raw,
    );
}
