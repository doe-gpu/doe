const std = @import("std");
const native_types = @import("../support/doe_native_object_types.zig");
const native_cmds = @import("../support/doe_native_command_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const queue_submit_ops = @import("../../backend/dropin_queue_submit.zig");
const metal_browser_trace = @import("../diagnostics/doe_metal_browser_trace.zig");
const bridge = queue_submit_ops.metal_bridge;

const DoeBuffer = native_types.DoeBuffer;
const DoeQueue = native_types.DoeQueue;
const cast = native_helpers.cast;
const metal_bridge_buffer_contents = bridge.metal_bridge_buffer_contents;
const metal_bridge_command_buffer_commit = bridge.metal_bridge_command_buffer_commit;
const metal_bridge_command_buffer_encode_signal_event = bridge.metal_bridge_command_buffer_encode_signal_event;
const metal_bridge_command_buffer_spin_wait = bridge.metal_bridge_command_buffer_spin_wait;
const metal_bridge_end_blit_encoding = bridge.metal_bridge_end_blit_encoding;
const metal_bridge_release = bridge.metal_bridge_release;
const metal_bridge_resolve_timestamps = bridge.metal_bridge_resolve_timestamps;
const metal_bridge_shared_event_wait = bridge.metal_bridge_shared_event_wait;

pub const QueueFlushBreakdown = extern struct {
    waitCompletedNs: u64 = 0,
    deferredCopyNs: u64 = 0,
    deferredResolveNs: u64 = 0,
};

pub const DirectReadbackFlush = struct {
    breakdown: QueueFlushBreakdown = .{},
    copied_direct: bool = false,
};

const DIRECT_READBACK_COPY_MAX_BYTES: usize = 4096;

fn monotonicNowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

fn waitSubmittedCommandBuffer(cmd: ?*anyopaque) void {
    metal_bridge_command_buffer_spin_wait(cmd);
}

pub fn executeDeferredCopies(q: *DoeQueue) void {
    for (q.deferred_copies[0..q.deferred_copy_count]) |dc| {
        @memcpy(dc.dst[0..dc.size], dc.src[0..dc.size]);
    }
    q.deferred_copy_count = 0;
}

fn executeDeferredCopiesWithDirectReadback(
    q: *DoeQueue,
    readback_dst: ?[*]u8,
    readback_size: usize,
    host_dst: ?[*]u8,
) bool {
    var copied_direct = false;
    for (q.deferred_copies[0..q.deferred_copy_count]) |dc| {
        if (!copied_direct and readback_dst != null and host_dst != null and dc.size == readback_size and
            @intFromPtr(dc.dst) == @intFromPtr(readback_dst.?))
        {
            @memcpy(host_dst.?[0..readback_size], dc.src[0..readback_size]);
            copied_direct = true;
        }
        @memcpy(dc.dst[0..dc.size], dc.src[0..dc.size]);
    }
    q.deferred_copy_count = 0;
    return copied_direct;
}

pub fn executeDeferredResolves(q: *DoeQueue) void {
    for (q.deferred_resolves[0..q.deferred_resolve_count]) |dr| {
        const contents = metal_bridge_buffer_contents(dr.dst_mtl) orelse continue;
        const d_off: usize = @intCast(dr.dst_offset);
        const dest: [*]u64 = @ptrCast(@alignCast(contents + d_off));
        _ = metal_bridge_resolve_timestamps(
            dr.counter_buffer,
            dr.first_query,
            dr.query_count,
            dest,
        );
    }
    q.deferred_resolve_count = 0;
}

pub fn releaseDeferredMetalObjects(q: *DoeQueue) void {
    for (q.deferred_releases[0..q.deferred_release_count]) |obj| {
        if (obj) |handle| metal_bridge_release(handle);
    }
    q.deferred_release_count = 0;
}

pub fn appendDeferredMetalObject(q: *DoeQueue, obj: ?*anyopaque) void {
    const handle = obj orelse return;
    if (q.deferred_release_count < native_cmds.MAX_DEFERRED_RELEASES) {
        q.deferred_releases[q.deferred_release_count] = handle;
        q.deferred_release_count += 1;
        return;
    }
    if (q.mtl_event != null and q.event_counter > q.completed_event_counter) {
        if (q.pending_cmd) |pending| {
            waitSubmittedCommandBuffer(pending);
            metal_bridge_release(pending);
            q.pending_cmd = null;
        } else {
            metal_bridge_shared_event_wait(q.mtl_event, q.event_counter);
        }
        q.completed_event_counter = q.event_counter;
    } else if (q.pending_cmd) |pending| {
        waitSubmittedCommandBuffer(pending);
        metal_bridge_release(pending);
        q.pending_cmd = null;
    }
    releaseDeferredMetalObjects(q);
    metal_bridge_release(handle);
}

pub fn commitStagedWriteBlits(q: *DoeQueue) void {
    if (q.staged_write_blit) |blit| {
        metal_bridge_end_blit_encoding(blit);
        q.staged_write_blit = null;
    }
    const cmd = q.staged_write_cmd orelse return;
    q.staged_write_cmd = null;
    const staged_buffer = q.staged_write_buffer;
    q.staged_write_buffer = null;
    q.staged_write_contents = null;
    q.staged_write_capacity = 0;
    q.staged_write_offset = 0;
    q.staged_write_count = 0;

    if (q.mtl_event == null) {
        if (q.pending_cmd) |pending| {
            waitSubmittedCommandBuffer(pending);
            metal_bridge_release(pending);
            q.pending_cmd = null;
        }
    }
    q.event_counter += 1;
    if (q.mtl_event) |event| {
        metal_bridge_command_buffer_encode_signal_event(cmd, event, q.event_counter);
    }
    metal_bridge_command_buffer_commit(cmd);
    if (q.mtl_event != null) {
        if (q.pending_cmd) |pending| metal_bridge_release(pending);
        q.pending_cmd = cmd;
    } else {
        q.pending_cmd = cmd;
    }
    appendDeferredMetalObject(q, staged_buffer);
}

pub fn flushPendingWorkTimed(q: *DoeQueue) QueueFlushBreakdown {
    var out = QueueFlushBreakdown{};
    commitStagedWriteBlits(q);
    if (q.mtl_event != null and q.event_counter > q.completed_event_counter) {
        const wait_started_ns = monotonicNowNs();
        if (q.pending_cmd) |cmd| {
            waitSubmittedCommandBuffer(cmd);
            metal_bridge_release(cmd);
            q.pending_cmd = null;
        } else {
            metal_bridge_shared_event_wait(q.mtl_event, q.event_counter);
        }
        out.waitCompletedNs = monotonicNowNs() - wait_started_ns;
        q.completed_event_counter = q.event_counter;
    } else if (q.pending_cmd) |cmd| {
        const wait_started_ns = monotonicNowNs();
        waitSubmittedCommandBuffer(cmd);
        out.waitCompletedNs = monotonicNowNs() - wait_started_ns;
        metal_bridge_release(cmd);
        q.pending_cmd = null;
    }
    // Timestamp resolves populate source buffers consumed by deferred copies.
    const deferred_resolve_started_ns = monotonicNowNs();
    executeDeferredResolves(q);
    out.deferredResolveNs = monotonicNowNs() - deferred_resolve_started_ns;
    const deferred_copy_started_ns = monotonicNowNs();
    executeDeferredCopies(q);
    out.deferredCopyNs = monotonicNowNs() - deferred_copy_started_ns;
    releaseDeferredMetalObjects(q);
    metal_browser_trace.recordFlush(
        out.waitCompletedNs,
        out.deferredCopyNs,
        out.deferredResolveNs,
        false,
    );
    return out;
}

pub fn flushPendingWorkTimedDirectReadback(
    q: *DoeQueue,
    readback_buffer_raw: ?*anyopaque,
    readback_offset: usize,
    readback_size: usize,
    host_dst: [*]u8,
) DirectReadbackFlush {
    var out = DirectReadbackFlush{};
    commitStagedWriteBlits(q);
    if (q.mtl_event != null and q.event_counter > q.completed_event_counter) {
        const wait_started_ns = monotonicNowNs();
        if (q.pending_cmd) |cmd| {
            waitSubmittedCommandBuffer(cmd);
            metal_bridge_release(cmd);
            q.pending_cmd = null;
        } else {
            metal_bridge_shared_event_wait(q.mtl_event, q.event_counter);
        }
        out.breakdown.waitCompletedNs = monotonicNowNs() - wait_started_ns;
        q.completed_event_counter = q.event_counter;
    } else if (q.pending_cmd) |cmd| {
        const wait_started_ns = monotonicNowNs();
        waitSubmittedCommandBuffer(cmd);
        out.breakdown.waitCompletedNs = monotonicNowNs() - wait_started_ns;
        metal_bridge_release(cmd);
        q.pending_cmd = null;
    }

    var readback_dst: ?[*]u8 = null;
    if (readback_size <= DIRECT_READBACK_COPY_MAX_BYTES) {
        if (cast(DoeBuffer, readback_buffer_raw)) |buf| {
            const readback_offset_u64: u64 = @intCast(readback_offset);
            const readback_size_u64: u64 = @intCast(readback_size);
            if (readback_offset_u64 <= buf.size and readback_size_u64 <= buf.size - readback_offset_u64) {
                if (metal_bridge_buffer_contents(buf.mtl)) |contents| {
                    readback_dst = contents + readback_offset;
                }
            }
        }
    }

    // Timestamp resolves populate source buffers consumed by deferred copies.
    const deferred_resolve_started_ns = monotonicNowNs();
    executeDeferredResolves(q);
    out.breakdown.deferredResolveNs = monotonicNowNs() - deferred_resolve_started_ns;
    const deferred_copy_started_ns = monotonicNowNs();
    out.copied_direct = executeDeferredCopiesWithDirectReadback(q, readback_dst, readback_size, host_dst);
    out.breakdown.deferredCopyNs = monotonicNowNs() - deferred_copy_started_ns;
    releaseDeferredMetalObjects(q);
    metal_browser_trace.recordFlush(
        out.breakdown.waitCompletedNs,
        out.breakdown.deferredCopyNs,
        out.breakdown.deferredResolveNs,
        true,
    );
    return out;
}

pub fn flushPendingWork(q: *DoeQueue) void {
    _ = flushPendingWorkTimed(q);
}
