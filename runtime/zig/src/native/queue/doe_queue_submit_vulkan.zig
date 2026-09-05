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
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_cmds = @import("../support/doe_native_command_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_rt_helpers = @import("../support/doe_native_runtime_helpers.zig");
const queue_submit_ops = @import("../../backend/dropin_queue_submit.zig");
const shared = @import("doe_queue_submit_shared.zig");
const vulkan_compute = @import("../vulkan/vulkan_compute_native.zig");
const query_native = @import("../resource/doe_query_native.zig");
const program_identity_trace = @import("../diagnostics/doe_program_identity_trace.zig");
const vk_upload = queue_submit_ops.vulkan_upload;

const cast = native_helpers.cast;
const DoeCommandBuffer = native_types.DoeCommandBuffer;
const DoeQueue = native_types.DoeQueue;

const has_vulkan = (builtin.os.tag == .linux);

const PreparedVulkanDispatchState = struct {
    valid: bool = false,
    compute_pipeline: ?*anyopaque = null,
    binding_state_valid: bool = false,
    binding_state: ?*const native_cmds.RecordedVulkanBindingState = null,
    buf_count: u32 = 0,
    bufs: ?*const [native_shared.MAX_FLAT_BIND]?*anyopaque = null,
    buf_offsets: ?*const [native_shared.MAX_FLAT_BIND]u64 = null,
    buf_sizes: ?*const [native_shared.MAX_FLAT_BIND]u64 = null,
};

fn resetPreparedDispatchState(state: *PreparedVulkanDispatchState) void {
    state.* = .{};
}

fn bindingStatesEqual(
    left: *const native_cmds.RecordedVulkanBindingState,
    right: *const native_cmds.RecordedVulkanBindingState,
) bool {
    if (left.valid != right.valid) return false;
    if (left.count != right.count) return false;
    if (left.flat_mask != right.flat_mask) return false;
    if (left.descriptor_hash != right.descriptor_hash) return false;
    for (left.bindings[0..left.count], 0..) |binding, index| {
        if (!std.meta.eql(binding, right.bindings[index])) return false;
    }
    return true;
}

fn preparedDispatchStateMatches(state: *const PreparedVulkanDispatchState, dispatch: anytype) bool {
    if (!state.valid) return false;
    if (state.compute_pipeline != dispatch.compute_pipeline) return false;
    if (state.binding_state_valid != dispatch.vulkan_binding_state.valid) return false;
    if (dispatch.vulkan_binding_state.valid) {
        const binding_state = state.binding_state orelse return false;
        return bindingStatesEqual(binding_state, &dispatch.vulkan_binding_state);
    }

    if (state.buf_count != dispatch.buf_count) return false;
    const bufs = state.bufs orelse return false;
    const buf_offsets = state.buf_offsets orelse return false;
    const buf_sizes = state.buf_sizes orelse return false;
    const count: usize = @intCast(dispatch.buf_count);
    return std.mem.eql(?*anyopaque, bufs[0..count], dispatch.bufs[0..count]) and
        std.mem.eql(u64, buf_offsets[0..count], dispatch.buf_offsets[0..count]) and
        std.mem.eql(u64, buf_sizes[0..count], dispatch.buf_sizes[0..count]);
}

fn rememberPreparedDispatchState(state: *PreparedVulkanDispatchState, dispatch: anytype) void {
    state.* = .{
        .valid = true,
        .compute_pipeline = dispatch.compute_pipeline,
        .binding_state_valid = dispatch.vulkan_binding_state.valid,
        .binding_state = &dispatch.vulkan_binding_state,
        .buf_count = dispatch.buf_count,
        .bufs = &dispatch.bufs,
        .buf_offsets = &dispatch.buf_offsets,
        .buf_sizes = &dispatch.buf_sizes,
    };
}

fn prepareRecordedDispatchIfNeeded(
    rt: *native_shared.NativeVulkanRuntime,
    dispatch: anytype,
    prepared_dispatch: *PreparedVulkanDispatchState,
) bool {
    if (preparedDispatchStateMatches(prepared_dispatch, dispatch)) return true;
    if (!vulkan_compute.vulkan_prepare_recorded_dispatch(rt, dispatch)) {
        resetPreparedDispatchState(prepared_dispatch);
        return false;
    }
    rememberPreparedDispatchState(prepared_dispatch, dispatch);
    return true;
}

fn flushRecordedReplay(q: *DoeQueue, rt: *native_shared.NativeVulkanRuntime, recorded_replay_work: *bool, context: []const u8) bool {
    if (!recorded_replay_work.*) return true;
    rt.submit_recorded_replay() catch |err| {
        shared.deliverInternalError(q.dev, "doe_queue_submit: vulkan submit {s}: {s}", .{ context, @errorName(err) });
        return false;
    };
    _ = rt.flush_queue() catch |err| {
        shared.deliverInternalError(q.dev, "doe_queue_submit: vulkan flush {s}: {s}", .{ context, @errorName(err) });
        return false;
    };
    program_identity_trace.recordVulkanSubmissionSucceeded();
    recorded_replay_work.* = false;
    return true;
}

pub fn submit_vulkan_commands(q: *DoeQueue, count: usize, cmd_bufs: [*]const ?*anyopaque) void {
    if (comptime !has_vulkan) return;
    const rt = native_rt_helpers.device_vk_runtime(q.dev) orelse return;
    const previous_replay_state = rt.recorded_submit_replay_active;
    rt.recorded_submit_replay_active = true;
    defer rt.recorded_submit_replay_active = previous_replay_state;

    var recorded_replay_work = false;
    var prepared_dispatch = PreparedVulkanDispatchState{};
    for (cmd_bufs[0..count]) |raw| {
        const cb = cast(DoeCommandBuffer, raw) orelse continue;
        for (cb.cmds.items) |*cmd| {
            switch (cmd.*) {
                .dispatch => |*dispatch_cmd| {
                    if (!prepareRecordedDispatchIfNeeded(rt, dispatch_cmd, &prepared_dispatch)) continue;
                    vulkan_compute.vulkan_run_prepared_dispatch(rt, dispatch_cmd);
                    recorded_replay_work = true;
                },
                .dispatch_indirect => |*dispatch_indirect_cmd| {
                    if (!prepareRecordedDispatchIfNeeded(rt, dispatch_indirect_cmd, &prepared_dispatch)) continue;
                    vulkan_compute.vulkan_run_prepared_dispatch_indirect(rt, dispatch_indirect_cmd);
                    recorded_replay_work = true;
                },
                .copy_buf => |copy_cmd| {
                    const src_buf = cast(native_types.DoeBuffer, copy_cmd.src) orelse continue;
                    const dst_buf = cast(native_types.DoeBuffer, copy_cmd.dst) orelse continue;
                    if (src_buf.vk_id == 0 or dst_buf.vk_id == 0) continue;
                    const scb = rt.compute_buffers.get(src_buf.vk_id) orelse continue;
                    const dcb = rt.compute_buffers.get(dst_buf.vk_id) orelse continue;
                    const copy_end_src = std.math.add(u64, copy_cmd.src_off, copy_cmd.size) catch continue;
                    const copy_end_dst = std.math.add(u64, copy_cmd.dst_off, copy_cmd.size) catch continue;
                    if (copy_end_src > scb.size or copy_end_dst > dcb.size) continue;
                    vk_upload.record_replay_buffer_copy(
                        rt,
                        scb,
                        copy_cmd.src_off,
                        dcb,
                        copy_cmd.dst_off,
                        copy_cmd.size,
                    ) catch |err| {
                        shared.deliverInternalError(q.dev, "doe_queue_submit: vulkan record copy_buf: {s}", .{@errorName(err)});
                        continue;
                    };
                    recorded_replay_work = true;
                },
                .copy_texture_to_buffer => |copy_cmd| {
                    if (!flushRecordedReplay(q, rt, &recorded_replay_work, "before copy_texture_to_buffer")) continue;
                    resetPreparedDispatchState(&prepared_dispatch);
                    const src_texture = cast(native_types.DoeTexture, copy_cmd.src_texture) orelse continue;
                    const dst_buffer = cast(native_types.DoeBuffer, copy_cmd.dst_buffer) orelse continue;
                    if (src_texture.vk_id == 0 or dst_buffer.vk_id == 0) continue;
                    const dcb = rt.compute_buffers.get(dst_buffer.vk_id) orelse continue;
                    const mapped_ptr = dcb.mapped orelse continue;
                    rt.texture_read(.{
                        .handle = src_texture.vk_id,
                        .mip_level = copy_cmd.src_mip_level,
                        .width = copy_cmd.width,
                        .height = copy_cmd.height,
                        .format = src_texture.format,
                        .dst_buffer = @as(*anyopaque, @ptrCast(mapped_ptr)),
                        .dst_offset = copy_cmd.dst_offset,
                        .dst_bytes_per_row = copy_cmd.dst_bytes_per_row,
                        .dst_rows_per_image = copy_cmd.dst_rows_per_image,
                    }) catch |err| {
                        shared.deliverInternalError(
                            q.dev,
                            "doe_queue_submit: vulkan copy_texture_to_buffer: {s}",
                            .{@errorName(err)},
                        );
                    };
                },
                .copy_texture_to_texture => |copy_cmd| {
                    if (!flushRecordedReplay(q, rt, &recorded_replay_work, "before copy_texture_to_texture")) continue;
                    resetPreparedDispatchState(&prepared_dispatch);
                    const src_texture = cast(native_types.DoeTexture, copy_cmd.src_texture) orelse continue;
                    const dst_texture = cast(native_types.DoeTexture, copy_cmd.dst_texture) orelse continue;
                    if (src_texture.vk_id == 0 or dst_texture.vk_id == 0) continue;
                    rt.texture_copy(.{
                        .src_handle = src_texture.vk_id,
                        .src_mip = copy_cmd.src_mip,
                        .src_x = copy_cmd.src_x,
                        .src_y = copy_cmd.src_y,
                        .src_z = copy_cmd.src_z,
                        .dst_handle = dst_texture.vk_id,
                        .dst_mip = copy_cmd.dst_mip,
                        .dst_x = copy_cmd.dst_x,
                        .dst_y = copy_cmd.dst_y,
                        .dst_z = copy_cmd.dst_z,
                        .width = copy_cmd.width,
                        .height = copy_cmd.height,
                        .depth_or_layers = copy_cmd.depth_or_layers,
                    }) catch |err| {
                        shared.deliverInternalError(
                            q.dev,
                            "doe_queue_submit: vulkan copy_texture_to_texture: {s}",
                            .{@errorName(err)},
                        );
                    };
                },
                .clear_buffer => |clear_cmd| {
                    const buffer = cast(native_types.DoeBuffer, clear_cmd.buffer) orelse {
                        shared.deliverInternalError(q.dev, "Vulkan clearBuffer: invalid buffer", .{});
                        return;
                    };
                    const target = rt.compute_buffers.get(buffer.vk_id) orelse {
                        shared.deliverInternalError(q.dev, "Vulkan clearBuffer: resource unavailable", .{});
                        return;
                    };
                    if (clear_cmd.offset > target.size or clear_cmd.size > target.size - clear_cmd.offset) {
                        shared.deliverInternalError(q.dev, "Vulkan clearBuffer: range exceeds buffer", .{});
                        return;
                    }
                    vk_upload.record_replay_buffer_clear(rt, target.buffer, clear_cmd.offset, clear_cmd.size) catch |err| {
                        shared.deliverInternalError(q.dev, "Vulkan clearBuffer: {s}", .{@errorName(err)});
                        return;
                    };
                    recorded_replay_work = true;
                },
                .copy_buffer_to_texture,
                .render_pass,
                => {},
                .write_timestamp => |timestamp_cmd| {
                    query_native.vulkanRecordWriteTimestamp(
                        rt,
                        timestamp_cmd.query_set,
                        timestamp_cmd.query_index,
                        timestamp_cmd.position,
                    ) catch |err| {
                        shared.deliverInternalError(
                            q.dev,
                            "doe_queue_submit: vulkan record write_timestamp: {s}",
                            .{@errorName(err)},
                        );
                    };
                    recorded_replay_work = true;
                },
                .resolve_query_set => |resolve_cmd| {
                    query_native.vulkanRecordResolveQuerySet(
                        rt,
                        resolve_cmd.query_set,
                        resolve_cmd.first_query,
                        resolve_cmd.query_count,
                        resolve_cmd.dst_buffer,
                        resolve_cmd.dst_offset,
                    ) catch |err| {
                        shared.deliverInternalError(
                            q.dev,
                            "doe_queue_submit: vulkan record resolve_query_set: {s}",
                            .{@errorName(err)},
                        );
                    };
                    recorded_replay_work = true;
                    if (flushRecordedReplay(q, rt, &recorded_replay_work, "after resolve_query_set")) {
                        resetPreparedDispatchState(&prepared_dispatch);
                        query_native.vulkanCopyQueryResultsToMappedBuffer(
                            rt,
                            resolve_cmd.query_set,
                            resolve_cmd.first_query,
                            resolve_cmd.query_count,
                            resolve_cmd.dst_buffer,
                            resolve_cmd.dst_offset,
                        ) catch |err| {
                            shared.deliverInternalError(
                                q.dev,
                                "doe_queue_submit: vulkan copy query results to mapped buffer: {s}",
                                .{@errorName(err)},
                            );
                        };
                    }
                },
            }
        }
    }
    if (recorded_replay_work) {
        const submitted = blk: {
            rt.submit_recorded_replay() catch |err| {
                shared.deliverInternalError(
                    q.dev,
                    "doe_queue_submit: vulkan submit recorded replay: {s}",
                    .{@errorName(err)},
                );
                break :blk false;
            };
            break :blk true;
        };
        if (submitted) program_identity_trace.recordVulkanSubmissionSucceeded();
        resetPreparedDispatchState(&prepared_dispatch);
    }
}
