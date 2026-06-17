const std = @import("std");
const proc_types = @import("../abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const abi_proc_aliases = @import("../abi/wgpu_type_proc_aliases.zig");
const runtime_state = @import("../abi/wgpu_runtime_state_defs.zig");
const loader = @import("../abi/wgpu_loader.zig");

const QUEUE_SYNC_RETRY_LIMIT: u32 = 3;
const QUEUE_SYNC_RETRY_BACKOFF_NS: u64 = 1_000_000;
const TIMESTAMP_MAP_RETRY_LIMIT: u32 = 3;
const TIMESTAMP_MAP_RETRY_BACKOFF_NS: u64 = 1_000_000;

pub fn syncAfterSubmit(self: anytype) !void {
    if (self.core.queue_sync_mode == .per_command) {
        try self.waitForQueue();
    }
}

pub fn submitEmpty(self: anytype) !u64 {
    return try self.submitInternal(0, null);
}

pub fn submitCommandBuffers(self: anytype, command_buffers: []abi_base.WGPUCommandBuffer) !u64 {
    return try self.submitInternal(command_buffers.len, command_buffers.ptr);
}

pub fn submitInternal(
    self: anytype,
    command_count: usize,
    command_ptr: ?[*]abi_base.WGPUCommandBuffer,
) !u64 {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const submit_start_ns = std.time.nanoTimestamp();
    procs.wgpuQueueSubmit(self.core.queue.?, command_count, if (command_count == 0) null else command_ptr.?);
    try self.syncAfterSubmit();
    const submit_end_ns = std.time.nanoTimestamp();
    return if (submit_end_ns > submit_start_ns)
        @as(u64, @intCast(submit_end_ns - submit_start_ns))
    else
        0;
}

pub fn flushQueue(self: anytype) !u64 {
    const start = std.time.nanoTimestamp();
    try self.waitForQueue();
    const end = std.time.nanoTimestamp();
    return if (end > start) @as(u64, @intCast(end - start)) else 0;
}

pub fn waitForQueue(self: anytype) !void {
    var attempt: u32 = 0;
    while (attempt < QUEUE_SYNC_RETRY_LIMIT) : (attempt += 1) {
        if (self.waitForQueueOnce()) |_| {
            return;
        } else |err| {
            if (attempt + 1 < QUEUE_SYNC_RETRY_LIMIT and shouldRetryQueueWait(err)) {
                std.Thread.sleep(QUEUE_SYNC_RETRY_BACKOFF_NS);
                continue;
            }
            return err;
        }
    }
    return error.QueueSubmitTimeout;
}

pub fn waitForQueueOnce(self: anytype) !void {
    switch (self.core.queue_wait_mode) {
        .process_events => try self.waitForQueueProcessEvents(),
        .wait_any => try self.waitForQueueWaitAny(),
    }
}

pub fn shouldRetryQueueWait(err: anyerror) bool {
    return switch (err) {
        error.WaitTimedOut,
        error.QueueSubmitTimeout,
        error.WaitAnyIncomplete,
        => true,
        else => false,
    };
}

pub fn waitForQueueProcessEvents(self: anytype) !void {
    if (self.core.procs == null) return error.ProceduralNotReady;

    var done_state = runtime_state.QueueSubmitState{};

    const queue_done_callback_info = abi_descriptor.WGPUQueueWorkDoneCallbackInfo{
        .nextInChain = null,
        .mode = abi_descriptor.WGPUCallbackMode_AllowProcessEvents,
        .callback = loader.queueWorkDoneCallback,
        .userdata1 = &done_state,
        .userdata2 = null,
    };
    const queue_done_future = self.core.procs.?.wgpuQueueOnSubmittedWorkDone(
        self.core.queue.?,
        queue_done_callback_info,
    );
    if (queue_done_future.id == 0) return error.QueueFutureUnavailable;
    try self.processEventsUntil(&done_state.done, self.core.webgpu_ffi_queue_wait_timeout_ns);
    if (!done_state.done) return error.QueueSubmitTimeout;
    if (done_state.status == .@"error") {
        return error.QueueSubmissionError;
    }
}

pub fn waitForQueueWaitAny(self: anytype) !void {
    const procs = self.core.procs orelse return error.ProceduralNotReady;

    var done_state = runtime_state.QueueSubmitState{};
    const queue_done_callback_info = abi_descriptor.WGPUQueueWorkDoneCallbackInfo{
        .nextInChain = null,
        .mode = abi_descriptor.WGPUCallbackMode_WaitAnyOnly,
        .callback = loader.queueWorkDoneCallback,
        .userdata1 = &done_state,
        .userdata2 = null,
    };
    const queue_done_future = procs.wgpuQueueOnSubmittedWorkDone(
        self.core.queue.?,
        queue_done_callback_info,
    );
    if (queue_done_future.id == 0) return error.QueueFutureUnavailable;

    var wait_infos = [_]abi_descriptor.WGPUFutureWaitInfo{
        .{
            .future = queue_done_future,
            .completed = abi_base.WGPU_FALSE,
        },
    };
    const wait_status = procs.wgpuInstanceWaitAny(
        self.core.instance.?,
        wait_infos.len,
        wait_infos[0..].ptr,
        self.core.webgpu_ffi_queue_wait_timeout_ns,
    );
    switch (wait_status) {
        .success => {},
        .timedOut => return error.WaitTimedOut,
        .@"error" => return error.WaitAnyFailed,
        else => return error.WaitAnyUnsupported,
    }

    if (!done_state.done) {
        try self.processEventsUntil(&done_state.done, loader.DEFAULT_WAIT_SLICE_NS);
    }
    if (!done_state.done) return error.WaitAnyIncomplete;
    if (done_state.status == .@"error") {
        return error.QueueSubmissionError;
    }
}

pub fn readTimestampBuffer(self: anytype, readback_buffer: abi_base.WGPUBuffer) !u64 {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    var attempt: u32 = 0;
    while (attempt < TIMESTAMP_MAP_RETRY_LIMIT) : (attempt += 1) {
        if (self.readTimestampBufferOnce(procs, readback_buffer)) |delta| {
            return delta;
        } else |err| {
            if (attempt + 1 < TIMESTAMP_MAP_RETRY_LIMIT and shouldRetryTimestampMap(err)) {
                self.timestampLog(
                    "timestamp_readback_retry attempt={} error={s}\n",
                    .{ attempt + 1, @errorName(err) },
                );
                std.Thread.sleep(TIMESTAMP_MAP_RETRY_BACKOFF_NS);
                continue;
            }
            return err;
        }
    }
    return error.BufferMapFailed;
}

pub fn readTimestampBufferOnce(
    self: anytype,
    procs: abi_proc_aliases.Procs,
    readback_buffer: abi_base.WGPUBuffer,
) !u64 {
    var map_state = runtime_state.BufferMapState{};
    const map_callback_info = abi_descriptor.WGPUBufferMapCallbackInfo{
        .nextInChain = null,
        .mode = abi_descriptor.WGPUCallbackMode_AllowProcessEvents,
        .callback = loader.bufferMapCallback,
        .userdata1 = &map_state,
        .userdata2 = null,
    };
    const map_future = procs.wgpuBufferMapAsync(
        readback_buffer,
        abi_base.WGPUMapMode_Read,
        0,
        abi_base.TIMESTAMP_BUFFER_SIZE,
        map_callback_info,
    );
    if (map_future.id == 0) {
        self.timestampLog("map_async_future_id=0\n", .{});
        return error.BufferMapFailed;
    }
    try self.processEventsUntil(&map_state.done, loader.DEFAULT_TIMEOUT_NS);
    if (!map_state.done) {
        self.timestampLog("map_async_timeout\n", .{});
        return error.BufferMapTimeout;
    }
    if (map_state.status != abi_base.WGPUMapAsyncStatus_Success) {
        self.timestampLog("map_async_status={}\n", .{map_state.status});
        return error.BufferMapFailed;
    }

    const mapped_ptr = procs.wgpuBufferGetConstMappedRange(readback_buffer, 0, abi_base.TIMESTAMP_BUFFER_SIZE);
    if (mapped_ptr == null) {
        self.timestampLog("mapped_range=null\n", .{});
        return error.BufferMapFailed;
    }
    const timestamps = @as(*const [2]u64, @ptrCast(@alignCast(mapped_ptr)));
    const begin_ts = timestamps[0];
    const end_ts = timestamps[1];
    procs.wgpuBufferUnmap(readback_buffer);
    if (end_ts < begin_ts) {
        self.timestampLog("mapped_invalid_range begin={} end={}\n", .{ begin_ts, end_ts });
        return error.TimestampRangeInvalid;
    }
    const delta = end_ts - begin_ts;
    self.timestampLog("mapped_begin={} mapped_end={} mapped_delta={}\n", .{ begin_ts, end_ts, delta });
    return delta;
}

pub fn shouldRetryTimestampMap(err: anyerror) bool {
    return switch (err) {
        error.BufferMapTimeout,
        error.BufferMapFailed,
        => true,
        else => false,
    };
}

pub fn processEventsUntil(self: anytype, done: *const bool, timeout_ns: u64) !void {
    const start = std.time.nanoTimestamp();
    var spins: u32 = 0;
    while (!done.*) {
        self.core.procs.?.wgpuInstanceProcessEvents(self.core.instance.?);
        const elapsed = std.time.nanoTimestamp() - start;
        if (elapsed >= timeout_ns) return error.WaitTimedOut;
        spins += 1;
        if (spins > 1000) {
            std.Thread.sleep(1_000);
        }
    }
}
