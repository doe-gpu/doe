const builtin = @import("builtin");
const std = @import("std");
const native_shared = @import("doe_native_shared_types.zig");

const has_vulkan = (builtin.os.tag == .linux);

pub fn flushBeforeDestroy(rt_raw: ?*anyopaque) void {
    if (comptime !has_vulkan) return;
    const raw = rt_raw orelse return;
    const rt: *native_shared.NativeVulkanRuntime = @ptrCast(@alignCast(raw));
    if (!hasPendingQueueWork(rt)) return;
    _ = rt.flush_queue() catch |err| {
        std.log.err("doe_vulkan_lifetime: flush before destroy failed: {s}", .{@errorName(err)});
    };
}

fn hasPendingQueueWork(rt: *const native_shared.NativeVulkanRuntime) bool {
    return rt.replay_recording_active or
        rt.replay_prefix_copy_pending or
        rt.upload_recording_active or
        rt.streaming_copy_active or
        rt.streaming_copy_pending_count != 0 or
        rt.has_deferred_submissions or
        rt.hot_pending_upload != null or
        rt.pending_uploads.items.len != 0;
}
