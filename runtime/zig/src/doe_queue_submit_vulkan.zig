// doe_queue_submit_vulkan.zig — process submitted command buffers on the
// Vulkan backend.
//
// Before this file existed, `doeNativeQueueSubmit` early-returned for
// Vulkan backends (see `doe_queue_submit_native.zig`). That meant every
// compute dispatch recorded into a DoeCommandEncoder was never replayed
// through the Vulkan runtime: the pipeline recorded the dispatch, the
// command buffer "finished", and submit silently did nothing. The minimum
// repro at `bench/repros/doe-runtime-zero-dispatch/repro.mjs` (a 3-line
// WGSL kernel writing u32(42)) observed readback=0 because of this path.
//
// Mirrors `submit_d3d12_commands` (`doe_queue_submit_d3d12.zig`) and
// `submit_metal_commands` (`doe_queue_submit_metal.zig`) in structure:
// iterate cmd_bufs, iterate each cb.cmds.items, dispatch each entry to
// the appropriate Vulkan replay helper. Recorded replay is finalized at
// queue-ordering boundaries; explicit queue flush/readback paths still drain.

const std = @import("std");
const builtin = @import("builtin");
const native_types = @import("doe_native_object_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const native_rt_helpers = @import("doe_native_runtime_helpers.zig");
const queue_submit_ops = @import("backend/dropin_queue_submit.zig");
const shared = @import("doe_queue_submit_shared.zig");
const vulkan_compute = @import("doe_vulkan_compute_native.zig");
const vk_upload = queue_submit_ops.vulkan_upload;

const cast = native_helpers.cast;
const DoeCommandBuffer = native_types.DoeCommandBuffer;
const DoeQueue = native_types.DoeQueue;

const has_vulkan = (builtin.os.tag == .linux);

pub fn submit_vulkan_commands(q: *DoeQueue, count: usize, cmd_bufs: [*]const ?*anyopaque) void {
    if (comptime !has_vulkan) return;
    const rt = native_rt_helpers.device_vk_runtime(q.dev) orelse return;
    const previous_replay_state = rt.recorded_submit_replay_active;
    rt.recorded_submit_replay_active = true;
    defer rt.recorded_submit_replay_active = previous_replay_state;

    var executed_any_dispatch = false;
    for (cmd_bufs[0..count]) |raw| {
        const cb = cast(DoeCommandBuffer, raw) orelse continue;
        for (cb.cmds.items) |cmd| {
            switch (cmd) {
                .dispatch => |dispatch_cmd| {
                    vulkan_compute.vulkan_submit_recorded_dispatch(rt, dispatch_cmd);
                    executed_any_dispatch = true;
                },
                .dispatch_indirect => |dispatch_indirect_cmd| {
                    vulkan_compute.vulkan_submit_recorded_dispatch_indirect(rt, dispatch_indirect_cmd);
                    executed_any_dispatch = true;
                },
                // Replay the copy in encoder-recorded order. When it follows
                // recorded dispatches, keep it in the same Vulkan command
                // buffer with an explicit compute->transfer barrier so
                // queue.submit does not synchronously drain before readback.
                .copy_buf => |copy_cmd| {
                    const src_buf = cast(native_types.DoeBuffer, copy_cmd.src) orelse continue;
                    const dst_buf = cast(native_types.DoeBuffer, copy_cmd.dst) orelse continue;
                    if (src_buf.vk_id == 0 or dst_buf.vk_id == 0) continue;
                    const scb = rt.compute_buffers.get(src_buf.vk_id) orelse continue;
                    const dcb = rt.compute_buffers.get(dst_buf.vk_id) orelse continue;
                    const copy_end_src = std.math.add(u64, copy_cmd.src_off, copy_cmd.size) catch continue;
                    const copy_end_dst = std.math.add(u64, copy_cmd.dst_off, copy_cmd.size) catch continue;
                    if (copy_end_src > scb.size or copy_end_dst > dcb.size) continue;
                    const src_has_pending_compute_write =
                        rt.has_pending_compute_writes and
                        rt.has_pending_compute_write_for_buffer(src_buf.vk_id);
                    if (rt.replay_recording_active and (scb.mapped == null or src_has_pending_compute_write)) {
                        vk_upload.record_replay_buffer_copy(
                            rt,
                            src_buf.vk_id,
                            scb,
                            copy_cmd.src_off,
                            dst_buf.vk_id,
                            dcb,
                            copy_cmd.dst_off,
                            copy_cmd.size,
                        ) catch |err| {
                            shared.deliverInternalError(
                                q.dev,
                                "doe_queue_submit: vulkan record copy_buf: {s}",
                                .{@errorName(err)},
                            );
                        };
                        continue;
                    }
                    if (executed_any_dispatch) {
                        _ = rt.flush_queue() catch |err| {
                            shared.deliverInternalError(
                                q.dev,
                                "doe_queue_submit: vulkan flush before copy_buf: {s}",
                                .{@errorName(err)},
                            );
                        };
                        executed_any_dispatch = false;
                    }
                    if (scb.mapped != null and dcb.mapped != null) {
                        const n: usize = @intCast(copy_cmd.size);
                        const so: usize = @intCast(copy_cmd.src_off);
                        const doff: usize = @intCast(copy_cmd.dst_off);
                        const s: [*]const u8 = @ptrCast(scb.mapped.?);
                        const d: [*]u8 = @ptrCast(dcb.mapped.?);
                        @memcpy(d[doff .. doff + n], s[so .. so + n]);
                        continue;
                    }
                    vk_upload.copy_buffer_region_and_wait(
                        rt,
                        scb.buffer,
                        copy_cmd.src_off,
                        dcb.buffer,
                        copy_cmd.dst_off,
                        copy_cmd.size,
                    ) catch |err| {
                        shared.deliverInternalError(
                            q.dev,
                            "doe_queue_submit: vulkan copy_buf: {s}",
                            .{@errorName(err)},
                        );
                    };
                },
                // Other command kinds (texture copies, clear_buffer,
                // render passes, timestamps, query resolves) are not
                // currently routed through the Vulkan queue by the
                // existing encoder paths; they either no-op on this
                // backend or are handled elsewhere. Leave as no-ops
                // here for now — if a caller records one and relies on
                // queue.submit executing it, that's a separate gap
                // that would surface as its own zero/missing output.
                .copy_buffer_to_texture => {},
                .copy_texture_to_buffer => {},
                .clear_buffer => {},
                .copy_texture_to_texture => {},
                .render_pass => {},
                .write_timestamp => {},
                .resolve_query_set => {},
            }
        }
    }
    if (executed_any_dispatch) {
        rt.submit_recorded_replay() catch |err| {
            shared.deliverInternalError(
                q.dev,
                "doe_queue_submit: vulkan submit recorded replay: {s}",
                .{@errorName(err)},
            );
        };
    }
}
