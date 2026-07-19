const std = @import("std");
const queue_submit_ops = @import("../../backend/dropin_queue_submit.zig");
const bridge = queue_submit_ops.d3d12_bridge;
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_rt_helpers = @import("../support/doe_native_runtime_helpers.zig");
const shared = @import("doe_queue_submit_shared.zig");

const alloc = native_helpers.alloc;
const cast = native_helpers.cast;
const DoeCommandBuffer = native_types.DoeCommandBuffer;
const DoeQueue = native_types.DoeQueue;
const d3d12_native_render_pass = queue_submit_ops.d3d12_native_render_pass;

pub fn submit_d3d12_commands(q: *DoeQueue, count: usize, cmd_bufs: [*]const ?*anyopaque) void {
    const rt = native_rt_helpers.device_d3d12_runtime(q.dev) orelse return;
    rt.flush_before_dropin_submit_if_needed() catch |err| {
        shared.deliverInternalError(q.dev, "doe_queue_submit: d3d12 pre-submit flush: {s}", .{@errorName(err)});
        return;
    };

    const cmd_allocator = bridge.c.d3d12_bridge_device_create_command_allocator(rt.device) orelse return;
    var owns_cmd_allocator = true;
    defer if (owns_cmd_allocator) bridge.c.d3d12_bridge_release(cmd_allocator);

    const cmd_list = bridge.c.d3d12_bridge_device_create_command_list(rt.device, cmd_allocator) orelse return;
    var owns_cmd_list = true;
    defer if (owns_cmd_list) bridge.c.d3d12_bridge_release(cmd_list);

    var retained_handles: std.ArrayListUnmanaged(?*anyopaque) = .{};
    var owns_retained_handles = true;
    defer if (owns_retained_handles) {
        for (retained_handles.items) |maybe_handle| {
            if (maybe_handle) |handle| bridge.c.d3d12_bridge_release(handle);
        }
        retained_handles.deinit(alloc);
    };

    var has_gpu_work = false;
    for (cmd_bufs[0..count]) |raw| {
        const cb = cast(DoeCommandBuffer, raw) orelse continue;
        for (cb.cmds.items) |cmd| {
            switch (cmd) {
                .render_pass => |render_pass_cmd| {
                    d3d12_native_render_pass.record_render_pass_command(
                        alloc,
                        &retained_handles,
                        rt.device,
                        cmd_list,
                        render_pass_cmd,
                        &rt.descriptor_state,
                        &rt.texture_view_state,
                        &rt.sampler_state,
                    ) catch continue;
                    has_gpu_work = true;
                },
                else => {},
            }
        }
    }

    if (!has_gpu_work) return;

    bridge.c.d3d12_bridge_command_list_close(cmd_list);
    bridge.c.d3d12_bridge_queue_execute_command_list(rt.queue, cmd_list);
    rt.fence_value +|= 1;
    bridge.c.d3d12_bridge_queue_signal(rt.queue, rt.fence, rt.fence_value);
    rt.trackDropinSubmission(cmd_allocator, cmd_list, &retained_handles) catch {
        bridge.c.d3d12_bridge_fence_wait(rt.fence, rt.fence_value);
        rt.noteCompletedFenceWait();
        return;
    };
    owns_cmd_allocator = false;
    owns_cmd_list = false;
    owns_retained_handles = false;
}
