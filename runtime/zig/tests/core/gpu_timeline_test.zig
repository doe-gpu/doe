const std = @import("std");
const gpu_timeline = @import("../../src/runtime/queue/gpu_timeline.zig");
const GpuTimeline = gpu_timeline.GpuTimeline;

// ============================================================
// init
// ============================================================

test "init sets submit_counter to zero" {
    const tl = GpuTimeline.init(null);
    try std.testing.expectEqual(@as(u64, 0), tl.submit_counter);
}

test "init stores provided shared_event" {
    const tl = GpuTimeline.init(null);
    try std.testing.expectEqual(@as(?*anyopaque, null), tl.shared_event);
}

test "init sets pending counts to zero" {
    const tl = GpuTimeline.init(null);
    try std.testing.expectEqual(@as(usize, 0), tl.pending_map_count);
    try std.testing.expectEqual(@as(usize, 0), tl.pending_work_done_count);
}

// ============================================================
// advance
// ============================================================

test "advance increments counter from zero to one" {
    var tl = GpuTimeline.init(null);
    const v = tl.advance();
    try std.testing.expectEqual(@as(u64, 1), v);
    try std.testing.expectEqual(@as(u64, 1), tl.submit_counter);
}

test "advance returns monotonically increasing values" {
    var tl = GpuTimeline.init(null);
    var prev: u64 = 0;
    for (0..100) |_| {
        const v = tl.advance();
        try std.testing.expect(v > prev);
        prev = v;
    }
    try std.testing.expectEqual(@as(u64, 100), tl.submit_counter);
}

test "advance wraps via +% on overflow" {
    var tl = GpuTimeline.init(null);
    tl.submit_counter = std.math.maxInt(u64);
    const v = tl.advance();
    // Wrapping addition: maxInt(u64) +% 1 == 0
    try std.testing.expectEqual(@as(u64, 0), v);
    try std.testing.expectEqual(@as(u64, 0), tl.submit_counter);
}

// ============================================================
// wait_for — null shared_event path (no extern calls)
// ============================================================

test "wait_for with null shared_event returns immediately" {
    var tl = GpuTimeline.init(null);
    _ = tl.advance();
    // Must not hang — null shared_event causes immediate return.
    tl.wait_for(1);
    tl.wait_for(999);
}

// ============================================================
// register_map — null shared_event (already_done path)
// ============================================================

test "register_map fires callback immediately when shared_event is null" {
    var tl = GpuTimeline.init(null);
    var flag: bool = false;
    var called: bool = false;

    const S = struct {
        fn cb(_: u32, _: @import("../../src/core/abi/wgpu_runtime_abi.zig").WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const ptr: *bool = @ptrCast(@alignCast(ud1));
            ptr.* = true;
        }
    };

    tl.register_map(
        1,
        null,
        0,
        0,
        64,
        &S.cb,
        @ptrCast(&called),
        null,
        &flag,
    );

    // Callback should have fired inline.
    try std.testing.expect(flag);
    try std.testing.expect(called);
    // Nothing enqueued.
    try std.testing.expectEqual(@as(usize, 0), tl.pending_map_count);
}

test "register_map sets mapped_flag even with null callback" {
    var tl = GpuTimeline.init(null);
    var flag: bool = false;

    tl.register_map(
        0,
        null,
        0,
        0,
        128,
        null,
        null,
        null,
        &flag,
    );

    try std.testing.expect(flag);
    try std.testing.expectEqual(@as(usize, 0), tl.pending_map_count);
}

// ============================================================
// register_work_done — null shared_event (already_done path)
// ============================================================

test "register_work_done fires callback immediately when shared_event is null" {
    var tl = GpuTimeline.init(null);
    _ = tl.advance(); // submit_counter = 1, but shared_event is null so always "done"

    var called: bool = false;

    const S = struct {
        fn cb(_: @import("../../src/core/abi/wgpu_runtime_abi.zig").WGPUQueueWorkDoneStatus, _: @import("../../src/core/abi/wgpu_runtime_abi.zig").WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const ptr: *bool = @ptrCast(@alignCast(ud1));
            ptr.* = true;
        }
    };

    tl.register_work_done(&S.cb, @ptrCast(&called), null);

    try std.testing.expect(called);
    try std.testing.expectEqual(@as(usize, 0), tl.pending_work_done_count);
}

test "register_work_done fires immediately when submit_counter is zero" {
    var tl = GpuTimeline.init(null);
    // submit_counter == 0 means no submits happened; already_done = true.
    var called: bool = false;

    const S = struct {
        fn cb(_: @import("../../src/core/abi/wgpu_runtime_abi.zig").WGPUQueueWorkDoneStatus, _: @import("../../src/core/abi/wgpu_runtime_abi.zig").WGPUStringView, ud1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const ptr: *bool = @ptrCast(@alignCast(ud1));
            ptr.* = true;
        }
    };

    tl.register_work_done(&S.cb, @ptrCast(&called), null);
    try std.testing.expect(called);
}

test "register_work_done with null callback does not crash" {
    var tl = GpuTimeline.init(null);
    tl.register_work_done(null, null, null);
    try std.testing.expectEqual(@as(usize, 0), tl.pending_work_done_count);
}

// ============================================================
// fire_all_remaining — via flush_all (public path)
// ============================================================

test "flush_all with no pending entries and zero counter is a no-op" {
    var tl = GpuTimeline.init(null);
    // submit_counter == 0 → flush_all returns early.
    tl.flush_all();
    try std.testing.expectEqual(@as(usize, 0), tl.pending_map_count);
    try std.testing.expectEqual(@as(usize, 0), tl.pending_work_done_count);
}

test "flush_all clears pending map entries via fire_all_remaining" {
    // With null shared_event, register_map fires inline — but we can test
    // fire_all_remaining indirectly through flush_all by verifying counts
    // remain zero after flush when nothing was enqueued.
    var tl = GpuTimeline.init(null);
    _ = tl.advance();
    tl.flush_all();
    try std.testing.expectEqual(@as(usize, 0), tl.pending_map_count);
    try std.testing.expectEqual(@as(usize, 0), tl.pending_work_done_count);
}

// ============================================================
// drain_ready — null shared_event path
// ============================================================

test "drain_ready with null shared_event returns immediately" {
    var tl = GpuTimeline.init(null);
    // Populate counters to ensure the early return is hit.
    _ = tl.advance();
    tl.drain_ready();
    // No crash, pending counts unchanged (nothing was enqueued).
    try std.testing.expectEqual(@as(usize, 0), tl.pending_map_count);
    try std.testing.expectEqual(@as(usize, 0), tl.pending_work_done_count);
}

// ============================================================
// Multiple register_map calls — inline fire
// ============================================================

test "multiple register_map calls all fire inline with null event" {
    var tl = GpuTimeline.init(null);

    var flags: [4]bool = .{ false, false, false, false };

    for (0..4) |i| {
        tl.register_map(
            @as(u64, i),
            null,
            0,
            0,
            @as(usize, 16 * (i + 1)),
            null,
            null,
            null,
            &flags[i],
        );
    }

    for (flags) |f| {
        try std.testing.expect(f);
    }
    try std.testing.expectEqual(@as(usize, 0), tl.pending_map_count);
}

// ============================================================
// Constants sanity checks
// ============================================================

test "MAX_PENDING_MAP is 64" {
    // Verified by inspecting that the pending_maps array has this capacity.
    // We cannot directly reference the const since it is file-private.
    // Instead, verify the array field size via @sizeOf.
    const tl = GpuTimeline.init(null);
    // The pending_maps field has exactly 64 entries.
    try std.testing.expectEqual(@as(usize, 64), tl.pending_maps.len);
}

test "MAX_PENDING_WORK_DONE is 64" {
    const tl = GpuTimeline.init(null);
    try std.testing.expectEqual(@as(usize, 64), tl.pending_work_done.len);
}

// ============================================================
// Advance + flush interleaving
// ============================================================

test "advance then flush_all leaves clean state" {
    var tl = GpuTimeline.init(null);
    _ = tl.advance();
    _ = tl.advance();
    _ = tl.advance();
    try std.testing.expectEqual(@as(u64, 3), tl.submit_counter);
    tl.flush_all();
    try std.testing.expectEqual(@as(usize, 0), tl.pending_map_count);
    try std.testing.expectEqual(@as(usize, 0), tl.pending_work_done_count);
}

test "advance is idempotent in direction — always increments" {
    var tl = GpuTimeline.init(null);
    const a = tl.advance();
    const b = tl.advance();
    const c = tl.advance();
    try std.testing.expect(a < b);
    try std.testing.expect(b < c);
    try std.testing.expectEqual(a + 1, b);
    try std.testing.expectEqual(b + 1, c);
}
