const std = @import("std");
const abi_core = @import("core/abi/wgpu_core_base_types.zig");
const loader = @import("core/abi/wgpu_loader.zig");
const resources = @import("core/resource/wgpu_resources.zig");
const compute_commands = @import("core/compute/wgpu_commands_compute.zig");
const queue_sync = @import("core/queue/wgpu_ffi_sync.zig");
const queue_capture = @import("core/queue/wgpu_ffi_capture.zig");
const surface = @import("full/surface/wgpu_ffi_surface.zig");

pub const syncAfterSubmit = queue_sync.syncAfterSubmit;
pub const submitEmpty = queue_sync.submitEmpty;
pub const submitCommandBuffers = queue_sync.submitCommandBuffers;
pub const submitInternal = queue_sync.submitInternal;
pub const flushQueue = queue_sync.flushQueue;
pub const captureBuffer = queue_capture.captureBuffer;
pub const waitForQueue = queue_sync.waitForQueue;
pub const waitForQueueOnce = queue_sync.waitForQueueOnce;
pub const shouldRetryQueueWait = queue_sync.shouldRetryQueueWait;
pub const waitForQueueProcessEvents = queue_sync.waitForQueueProcessEvents;
pub const waitForQueueWaitAny = queue_sync.waitForQueueWaitAny;
pub const readTimestampBuffer = queue_sync.readTimestampBuffer;
pub const readTimestampBufferOnce = queue_sync.readTimestampBufferOnce;
pub const shouldRetryTimestampMap = queue_sync.shouldRetryTimestampMap;
pub const processEventsUntil = queue_sync.processEventsUntil;
pub const createSurface = surface.createSurface;
pub const getSurfaceCapabilities = surface.getSurfaceCapabilities;
pub const freeSurfaceCapabilities = surface.freeSurfaceCapabilities;
pub const configureSurface = surface.configureSurface;
pub const getCurrentSurfaceTexture = surface.getCurrentSurfaceTexture;
pub const presentSurface = surface.presentSurface;
pub const unconfigureSurface = surface.unconfigureSurface;
pub const releaseSurface = surface.releaseSurface;

pub fn prewarmUploadPath(self: anytype, max_upload_bytes: u64) !void {
    if (max_upload_bytes == 0) return;
    if (!self.backendAvailable()) return error.NativeQueueUnavailable;

    const usage = switch (self.core.upload_buffer_usage_mode) {
        .copy_dst_copy_src => abi_core.WGPUBufferUsage_CopyDst | abi_core.WGPUBufferUsage_CopySrc,
        .copy_dst => abi_core.WGPUBufferUsage_CopyDst,
    };
    _ = try resources.getOrCreateBuffer(self, loader.BUFFER_UPLOAD_KEY, max_upload_bytes, usage);

    const bytes_usize = std.math.cast(usize, max_upload_bytes) orelse {
        return error.BufferAllocationFailed;
    };
    if (bytes_usize <= self.core.upload_scratch.len) return;

    if (self.core.upload_scratch.len > 0) {
        self.core.allocator.free(self.core.upload_scratch);
    }
    self.core.upload_scratch = try self.core.allocator.alloc(u8, bytes_usize);
    @memset(self.core.upload_scratch, 0);
}

pub fn prewarmKernelPipeline(self: anytype, kernel: []const u8, bindings: anytype) !void {
    if (!self.backendAvailable()) return;
    const source = compute_commands.resolveKernelSource(self, kernel) catch return;
    defer if (source.owned) self.core.allocator.free(source.source);
    const entry_point = "main";
    const cache_key = compute_commands.pipelineCacheKey(source.source, entry_point);
    if (self.core.pipeline_cache.get(cache_key) != null) return;
    const procs = self.core.procs orelse return;
    const shader_module = resources.createShaderModule(self, source.source) catch return;
    const pipeline = resources.createComputePipeline(self, kernel, shader_module, entry_point, null) catch {
        procs.wgpuShaderModuleRelease(shader_module);
        return;
    };
    self.core.pipeline_cache.put(cache_key, .{ .shader_module = shader_module, .pipeline = pipeline }) catch |err| {
        self.timestampLog("prewarm_pipeline_cache_put_error={s}\n", .{@errorName(err)});
    };
    if (bindings) |bs| {
        for (bs) |b| {
            if (b.resource_kind != .buffer) continue;
            const usage = abi_core.WGPUBufferUsage_Storage | abi_core.WGPUBufferUsage_CopyDst | abi_core.WGPUBufferUsage_CopySrc;
            _ = resources.getOrCreateBuffer(self, b.resource_handle, b.buffer_size, usage) catch |err| {
                self.timestampLog("prewarm_buffer_error={s}\n", .{@errorName(err)});
            };
        }
    }
}
