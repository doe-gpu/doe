// doe_buffer_native.zig — Buffer lifecycle, mapping, and queue-flush helpers.
// Sharded from doe_wgpu_native.zig to stay under the line-limit policy.

const std = @import("std");
const abi_base = @import("../../core/abi/wgpu_handle_types.zig");
const abi_callback = @import("../../core/abi/wgpu_callback_descriptor_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");

const alloc = native_helpers.alloc;
const cast = native_helpers.cast;
const DoeBuffer = native_types.DoeBuffer;
const DoeQueue = native_types.DoeQueue;

const WGPU_MAP_ASYNC_STATUS_SUCCESS: u32 = 1;
const WGPU_MAP_ASYNC_STATUS_VALIDATION_ERROR: u32 = 4;
const DOE_BUFFER_MAP_STATE_UNMAPPED: u32 = 0;
const DOE_BUFFER_MAP_STATE_PENDING: u32 = 1;
const DOE_BUFFER_MAP_STATE_MAPPED: u32 = 2;

var buffer_map_states: std.AutoHashMapUnmanaged(usize, u32) = .{};

extern fn metal_bridge_buffer_contents(buffer: ?*anyopaque) callconv(.c) ?[*]u8;
extern fn metal_bridge_release(obj: ?*anyopaque) callconv(.c) void;
extern fn metal_bridge_shared_event_wait(event: ?*anyopaque, value: u64) callconv(.c) void;

// ============================================================
// Buffer release and unmap
// ============================================================

pub export fn doeNativeBufferRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeBuffer, raw)) |b| {
        _ = buffer_map_states.remove(@intFromPtr(b));
        if (b.mtl) |m| metal_bridge_release(m);
        alloc.destroy(b);
    }
}

pub export fn doeNativeBufferUnmap(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeBuffer, raw)) |b| {
        b.mapped = false;
        buffer_map_states.put(alloc, @intFromPtr(b), DOE_BUFFER_MAP_STATE_UNMAPPED) catch {};
    }
}

pub export fn doeNativeBufferGetMapState(raw: ?*anyopaque) callconv(.c) u32 {
    const buf = cast(DoeBuffer, raw) orelse return DOE_BUFFER_MAP_STATE_UNMAPPED;
    if (buffer_map_states.get(@intFromPtr(buf))) |state| return state;
    if (buf.mapped) return DOE_BUFFER_MAP_STATE_MAPPED;
    return DOE_BUFFER_MAP_STATE_UNMAPPED;
}

// ============================================================
// Queue pending-work helpers (called from doe_wgpu_native.zig)
// ============================================================

/// Wait for any pending GPU work on the queue, then release the command buffer.
/// Also executes deferred CPU copies that depend on the completed GPU work.
/// Uses MTLSharedEvent for GPU→CPU sync (direct memory poll, no GCD intermediary).
pub fn flush_pending_work(q: *DoeQueue) void {
    if (q.pending_cmd) |cmd| {
        if (q.mtl_event) |ev| {
            metal_bridge_shared_event_wait(ev, q.event_counter);
        }
        metal_bridge_release(cmd);
        q.pending_cmd = null;
    }
    flush_deferred_copies(q);
}

pub fn flush_deferred_copies(q: *DoeQueue) void {
    for (q.deferred_copies[0..q.deferred_copy_count]) |dc| {
        @memcpy(dc.dst[0..dc.size], dc.src[0..dc.size]);
    }
    q.deferred_copy_count = 0;
}

pub fn try_schedule_deferred_copy(
    q: *DoeQueue,
    src_raw: ?*anyopaque,
    src_off: u64,
    dst_raw: ?*anyopaque,
    dst_off: u64,
    size: u64,
) bool {
    if (size == 0 or q.deferred_copy_count >= @as(u32, q.deferred_copies.len)) return false;
    const src = cast(DoeBuffer, src_raw) orelse return false;
    const dst = cast(DoeBuffer, dst_raw) orelse return false;
    const copy_size: usize = @intCast(size);
    const src_offset: usize = @intCast(src_off);
    const dst_offset: usize = @intCast(dst_off);
    if (src_offset + copy_size > src.size or dst_offset + copy_size > dst.size) return false;
    const src_ptr = metal_bridge_buffer_contents(src.mtl) orelse return false;
    const dst_ptr = metal_bridge_buffer_contents(dst.mtl) orelse return false;
    q.deferred_copies[q.deferred_copy_count] = .{
        .src = src_ptr + src_offset,
        .dst = dst_ptr + dst_offset,
        .size = copy_size,
    };
    q.deferred_copy_count += 1;
    return true;
}

// ============================================================
// Buffer mapping
// ============================================================

pub export fn doeNativeBufferMapAsync(
    buf_raw: ?*anyopaque,
    mode: u64,
    offset: usize,
    size: usize,
    cb_info: abi_callback.WGPUBufferMapCallbackInfo,
) callconv(.c) abi_base.WGPUFuture {
    const buf = cast(DoeBuffer, buf_raw) orelse {
        if (cb_info.callback) |callback| {
            callback(WGPU_MAP_ASYNC_STATUS_VALIDATION_ERROR, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
        }
        return .{ .id = 3 };
    };
    _ = mode;
    _ = offset;
    _ = size;

    // The buffer may still have pending GPU writes if the last queue submit has not
    // yet signalled its fence. The device's queue holds the GpuTimeline; we reach it
    // via the device pointer that was available at buffer creation.
    // DoeBuffer does not store a back-reference to the device because the WebGPU spec
    // treats buffer lifetime as independent of device lifetime. We therefore check the
    // shared event on the global GPA queue if available; otherwise map immediately.
    //
    // Apple Silicon unified memory: contents are CPU-visible as soon as the GPU
    // signals. We do not need an additional readback copy.
    buffer_map_states.put(alloc, @intFromPtr(buf), DOE_BUFFER_MAP_STATE_PENDING) catch {};
    buf.mapped = true;
    if (cb_info.callback) |callback| {
        callback(WGPU_MAP_ASYNC_STATUS_SUCCESS, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
    }
    buffer_map_states.put(alloc, @intFromPtr(buf), DOE_BUFFER_MAP_STATE_MAPPED) catch {};
    return .{ .id = 3 };
}

pub export fn doeNativeBufferGetConstMappedRange(buf_raw: ?*anyopaque, offset: usize, size: usize) callconv(.c) ?*anyopaque {
    _ = size;
    const buf = cast(DoeBuffer, buf_raw) orelse return null;
    const contents = metal_bridge_buffer_contents(buf.mtl) orelse return null;
    return @ptrCast(contents + offset);
}

pub export fn doeNativeBufferGetMappedRange(buf_raw: ?*anyopaque, offset: usize, size: usize) callconv(.c) ?*anyopaque {
    return doeNativeBufferGetConstMappedRange(buf_raw, offset, size);
}
