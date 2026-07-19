const std = @import("std");
const builtin = @import("builtin");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_rt_helpers = @import("../support/doe_native_runtime_helpers.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const compute_preconditions = @import("doe_compute_preconditions_native.zig");
const vulkan_compute = @import("../vulkan/vulkan_compute_native.zig");
const queue_submit_ops = @import("../../backend/dropin_queue_submit.zig");

const vk_upload = queue_submit_ops.vulkan_upload;
const DoeBuffer = native_types.DoeBuffer;
const DoeBindGroup = native_types.DoeBindGroup;
const DoeComputePipeline = native_types.DoeComputePipeline;
const DoeQueue = native_types.DoeQueue;
const MAX_COMPUTE_BIND_GROUPS = native_shared.MAX_COMPUTE_BIND_GROUPS;
const BATCH_PREPARED_CACHE_CAPACITY: usize = 64;
const has_vulkan = (builtin.os.tag == .linux);

pub const DispatchBatchCopyFlushTimings = struct {
    command_replay_ns: u64 = 0,
    command_replay_prepare_ns: u64 = 0,
    command_replay_record_ns: u64 = 0,
    command_replay_copy_ns: u64 = 0,
    queue_submit_ns: u64 = 0,
    queue_submit_command_buffer_end_ns: u64 = 0,
    queue_submit_sync_prepare_ns: u64 = 0,
    queue_submit_driver_submit_ns: u64 = 0,
};

pub fn populateRecordedDispatchBindingState(pipe: *DoeComputePipeline, dispatch: anytype) void {
    if (pipe.spirv_data == null) return;
    dispatch.vulkan_binding_state = vulkan_compute.vulkan_collect_recorded_binding_state(
        pipe,
        dispatch.bufs[0..dispatch.buf_count],
        dispatch.buf_offsets[0..dispatch.buf_count],
        dispatch.buf_sizes[0..dispatch.buf_count],
    );
}

fn monotonicNowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

const BindGroupArray = [MAX_COMPUTE_BIND_GROUPS]?*DoeBindGroup;

const PreparedDispatchCacheEntry = struct {
    pipe: *DoeComputePipeline,
    bind_groups: BindGroupArray,
    bg_count: u32,
    state: vulkan_compute.VulkanDispatchBindingState,
};

fn samePreparedDispatch(
    previous_pipe: ?*DoeComputePipeline,
    previous_bind_groups: *const BindGroupArray,
    previous_bg_count: u32,
    pipe: *DoeComputePipeline,
    bind_groups: *const BindGroupArray,
    bg_count: u32,
) bool {
    if (previous_pipe != pipe) return false;
    if (previous_bg_count != bg_count) return false;
    for (0..@intCast(bg_count)) |i| {
        if (previous_bind_groups[i] != bind_groups[i]) return false;
    }
    return true;
}

fn hasDispatchPreconditions(pipe: *const DoeComputePipeline) bool {
    return pipe.dispatch_preconditions.len != 0 or pipe.texture_dispatch_preconditions.len != 0;
}

fn findPreparedDispatchCache(
    cache: []const PreparedDispatchCacheEntry,
    pipe: *DoeComputePipeline,
    bind_groups: *const BindGroupArray,
    bg_count: u32,
) ?usize {
    for (cache, 0..) |*entry, index| {
        if (samePreparedDispatch(entry.pipe, &entry.bind_groups, entry.bg_count, pipe, bind_groups, bg_count)) {
            return index;
        }
    }
    return null;
}

fn sameBindingState(
    left: *const vulkan_compute.VulkanDispatchBindingState,
    right: *const vulkan_compute.VulkanDispatchBindingState,
) bool {
    if (left.count != right.count) return false;
    if (left.flat_mask != right.flat_mask) return false;
    if (left.descriptor_hash != right.descriptor_hash) return false;
    for (0..left.count) |index| {
        if (!std.meta.eql(left.bindings[index], right.bindings[index])) return false;
    }
    return true;
}

fn findPreparedBindingStateCache(
    cache: []const PreparedDispatchCacheEntry,
    pipe: *DoeComputePipeline,
    state: *const vulkan_compute.VulkanDispatchBindingState,
) ?usize {
    for (cache, 0..) |*entry, index| {
        if (entry.pipe == pipe and sameBindingState(&entry.state, state)) return index;
    }
    return null;
}

fn validatedBindGroups(
    pipe: *DoeComputePipeline,
    bg_ptrs: [*]const ?*anyopaque,
    bg_count: u32,
    dx: u32,
    dy: u32,
    dz: u32,
) ?BindGroupArray {
    const bind_groups = collectBindGroups(bg_ptrs, bg_count);
    if (!hasDispatchPreconditions(pipe)) return bind_groups;
    compute_preconditions.validate_bind_groups(
        pipe.dispatch_preconditions,
        pipe.texture_dispatch_preconditions,
        bind_groups[0..],
        .{ dx, dy, dz },
        .{ pipe.wg_x, pipe.wg_y, pipe.wg_z },
    ) catch {
        std.log.err("doe_compute_fast_vulkan: dispatch precondition failed for proof-elided shader", .{});
        return null;
    };
    return bind_groups;
}

fn collectBindGroups(bg_ptrs: [*]const ?*anyopaque, bg_count: u32) BindGroupArray {
    var bind_groups: BindGroupArray = [_]?*DoeBindGroup{null} ** MAX_COMPUTE_BIND_GROUPS;
    for (0..@min(bg_count, MAX_COMPUTE_BIND_GROUPS)) |i| {
        bind_groups[i] = native_helpers.cast(DoeBindGroup, bg_ptrs[i]);
    }
    return bind_groups;
}

fn recordOrExecuteCopy(
    rt: anytype,
    q: *DoeQueue,
    copy_src: ?*anyopaque,
    copy_src_off: u64,
    copy_dst: ?*anyopaque,
    copy_dst_off: u64,
    copy_size: u64,
    executed_any_dispatch: *bool,
) void {
    if (copy_size == 0) return;
    const src_buf = native_helpers.cast(DoeBuffer, copy_src) orelse return;
    const dst_buf = native_helpers.cast(DoeBuffer, copy_dst) orelse return;
    if (src_buf.vk_id == 0 or dst_buf.vk_id == 0) return;
    const scb = rt.compute_buffers.get(src_buf.vk_id) orelse return;
    const dcb = rt.compute_buffers.get(dst_buf.vk_id) orelse return;
    const copy_end_src = std.math.add(u64, copy_src_off, copy_size) catch return;
    const copy_end_dst = std.math.add(u64, copy_dst_off, copy_size) catch return;
    if (copy_end_src > scb.size or copy_end_dst > dcb.size) return;
    const src_has_pending_compute_write =
        rt.has_pending_compute_writes and
        rt.has_pending_compute_write_for_buffer(src_buf.vk_id);
    if (rt.replay_recording_active and (scb.mapped == null or src_has_pending_compute_write)) {
        vk_upload.record_replay_buffer_copy(
            rt,
            src_buf.vk_id,
            scb,
            copy_src_off,
            dst_buf.vk_id,
            dcb,
            copy_dst_off,
            copy_size,
        ) catch |err| {
            std.log.err("doe_compute_fast_vulkan: record copy_buf failed: {s}", .{@errorName(err)});
        };
        return;
    }
    if (executed_any_dispatch.*) {
        _ = rt.flush_queue() catch |err| {
            std.log.err("doe_compute_fast_vulkan: flush before copy_buf failed: {s}", .{@errorName(err)});
        };
        executed_any_dispatch.* = false;
    }
    if (scb.mapped != null and dcb.mapped != null) {
        const n: usize = @intCast(copy_size);
        const so: usize = @intCast(copy_src_off);
        const doff: usize = @intCast(copy_dst_off);
        const src: [*]const u8 = @ptrCast(scb.mapped.?);
        const dst: [*]u8 = @ptrCast(dcb.mapped.?);
        @memcpy(dst[doff .. doff + n], src[so .. so + n]);
        return;
    }
    vk_upload.copy_buffer_region_and_wait(
        rt,
        scb.buffer,
        copy_src_off,
        dcb.buffer,
        copy_dst_off,
        copy_size,
    ) catch |err| {
        std.log.err("doe_compute_fast_vulkan: copy_buf failed: {s}", .{@errorName(err)});
    };
    _ = q;
}

pub fn prewarmPreparedDispatchBindings(
    q: *DoeQueue,
    dispatch_count: usize,
    pipe_ptrs: [*]?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_counts: [*]const u32,
) u32 {
    if (comptime !has_vulkan) return 0;
    if (dispatch_count == 0) return 0;
    const rt = native_rt_helpers.device_vk_runtime(q.dev) orelse return 0;
    var prepared_cache: [BATCH_PREPARED_CACHE_CAPACITY]PreparedDispatchCacheEntry = undefined;
    var prepared_cache_count: usize = 0;
    var prepared_count: u32 = 0;
    for (0..dispatch_count) |index| {
        const pipe = native_helpers.cast(DoeComputePipeline, pipe_ptrs[index]) orelse continue;
        const bg_count = @min(bg_counts[index], MAX_COMPUTE_BIND_GROUPS);
        const bind_groups = collectBindGroups(bg_ptrs + (index * MAX_COMPUTE_BIND_GROUPS), bg_count);
        const cache_index = findPreparedDispatchCache(
            prepared_cache[0..prepared_cache_count],
            pipe,
            &bind_groups,
            bg_count,
        );
        var state = if (cache_index) |cached_index|
            prepared_cache[cached_index].state
        else
            vulkan_compute.vulkan_collect_dispatch_binding_state(pipe, bind_groups[0..]);
        var cache_slot = cache_index;
        if (cache_slot == null) {
            if (findPreparedBindingStateCache(
                prepared_cache[0..prepared_cache_count],
                pipe,
                &state,
            )) |cached_index| {
                state = prepared_cache[cached_index].state;
                cache_slot = cached_index;
            }
        }
        if (!vulkan_compute.vulkan_prepare_dispatch_binding_state(rt, pipe, &state)) continue;
        if (cache_slot == null and prepared_cache_count < BATCH_PREPARED_CACHE_CAPACITY) {
            prepared_cache[prepared_cache_count] = .{
                .pipe = pipe,
                .bind_groups = bind_groups,
                .bg_count = bg_count,
                .state = state,
            };
            prepared_cache_count += 1;
        } else if (cache_slot) |slot| {
            prepared_cache[slot] = .{
                .pipe = pipe,
                .bind_groups = bind_groups,
                .bg_count = bg_count,
                .state = state,
            };
        }
        prepared_count += 1;
    }
    return prepared_count;
}

pub fn dispatchBatchCopyFlush(
    q: *DoeQueue,
    dispatch_count: usize,
    pipe_ptrs: [*]?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_counts: [*]const u32,
    dispatch_dims: [*]const u32,
    copy_src: ?*anyopaque,
    copy_src_off: u64,
    copy_dst: ?*anyopaque,
    copy_dst_off: u64,
    copy_size: u64,
    collect_timings: bool,
) DispatchBatchCopyFlushTimings {
    var timings = DispatchBatchCopyFlushTimings{};
    if (comptime !has_vulkan) return timings;
    if (dispatch_count == 0) return timings;
    const rt = native_rt_helpers.device_vk_runtime(q.dev) orelse return timings;
    const previous_replay_state = rt.recorded_submit_replay_active;
    rt.recorded_submit_replay_active = true;
    defer rt.recorded_submit_replay_active = previous_replay_state;

    const replay_started_ns = if (collect_timings) monotonicNowNs() else 0;
    var executed_any_dispatch = false;
    var prepared_pipe: ?*DoeComputePipeline = null;
    var prepared_bind_groups: BindGroupArray = [_]?*DoeBindGroup{null} ** MAX_COMPUTE_BIND_GROUPS;
    var prepared_bg_count: u32 = 0;
    var prepared_cache: [BATCH_PREPARED_CACHE_CAPACITY]PreparedDispatchCacheEntry = undefined;
    var prepared_cache_count: usize = 0;
    var replay_command_buffer = rt.replay_command_buffer;
    for (0..dispatch_count) |index| {
        const pipe = native_helpers.cast(DoeComputePipeline, pipe_ptrs[index]) orelse continue;
        const bg_offset = index * MAX_COMPUTE_BIND_GROUPS;
        const dim_offset = index * 3;
        const bg_count = @min(bg_counts[index], MAX_COMPUTE_BIND_GROUPS);
        const bind_groups = validatedBindGroups(
            pipe,
            bg_ptrs + bg_offset,
            bg_count,
            dispatch_dims[dim_offset],
            dispatch_dims[dim_offset + 1],
            dispatch_dims[dim_offset + 2],
        ) orelse continue;
        const prepare_started_ns = if (collect_timings) monotonicNowNs() else 0;
        if (!samePreparedDispatch(prepared_pipe, &prepared_bind_groups, prepared_bg_count, pipe, &bind_groups, bg_count)) {
            prepared_pipe = null;
            const cache_index = findPreparedDispatchCache(
                prepared_cache[0..prepared_cache_count],
                pipe,
                &bind_groups,
                bg_count,
            );
            var state = if (cache_index) |cached_index|
                prepared_cache[cached_index].state
            else
                vulkan_compute.vulkan_collect_dispatch_binding_state(pipe, bind_groups[0..]);
            var cache_slot = cache_index;
            if (cache_slot == null) {
                if (findPreparedBindingStateCache(
                    prepared_cache[0..prepared_cache_count],
                    pipe,
                    &state,
                )) |cached_index| {
                    state = prepared_cache[cached_index].state;
                    cache_slot = cached_index;
                }
            }
            const prepared = vulkan_compute.vulkan_prepare_dispatch_binding_state(rt, pipe, &state);
            if (prepared and cache_slot == null and prepared_cache_count < BATCH_PREPARED_CACHE_CAPACITY) {
                prepared_cache[prepared_cache_count] = .{
                    .pipe = pipe,
                    .bind_groups = bind_groups,
                    .bg_count = bg_count,
                    .state = state,
                };
                prepared_cache_count += 1;
            } else if (prepared and cache_slot != null) {
                const slot = cache_slot.?;
                prepared_cache[slot] = .{
                    .pipe = pipe,
                    .bind_groups = bind_groups,
                    .bg_count = bg_count,
                    .state = state,
                };
            }
            if (!prepared) {
                if (collect_timings) timings.command_replay_prepare_ns += monotonicNowNs() - prepare_started_ns;
                continue;
            }
            prepared_pipe = pipe;
            prepared_bind_groups = bind_groups;
            prepared_bg_count = bg_count;
        }
        if (collect_timings) timings.command_replay_prepare_ns += monotonicNowNs() - prepare_started_ns;
        const record_started_ns = if (collect_timings) monotonicNowNs() else 0;
        if (replay_command_buffer == null) {
            replay_command_buffer = rt.begin_prepared_dispatch_replay() catch |err| {
                std.log.err("doe_compute_fast_vulkan: begin prepared replay batch failed: {s}", .{@errorName(err)});
                if (collect_timings) timings.command_replay_record_ns += monotonicNowNs() - record_started_ns;
                continue;
            };
        }
        rt.record_prepared_dispatch_replay_on(
            replay_command_buffer,
            dispatch_dims[dim_offset],
            dispatch_dims[dim_offset + 1],
            dispatch_dims[dim_offset + 2],
        ) catch |err| {
            std.log.err("doe_compute_fast_vulkan: record prepared dispatch failed: {s}", .{@errorName(err)});
            if (collect_timings) timings.command_replay_record_ns += monotonicNowNs() - record_started_ns;
            continue;
        };
        if (collect_timings) timings.command_replay_record_ns += monotonicNowNs() - record_started_ns;
        executed_any_dispatch = true;
    }

    const copy_started_ns = if (collect_timings) monotonicNowNs() else 0;
    recordOrExecuteCopy(
        rt,
        q,
        copy_src,
        copy_src_off,
        copy_dst,
        copy_dst_off,
        copy_size,
        &executed_any_dispatch,
    );
    if (collect_timings) {
        timings.command_replay_copy_ns = monotonicNowNs() - copy_started_ns;
        timings.command_replay_ns = monotonicNowNs() - replay_started_ns;
    }
    if (executed_any_dispatch) {
        if (collect_timings) {
            const submit_started_ns = monotonicNowNs();
            const submit_timings = rt.submit_recorded_replay_timed() catch |err| {
                std.log.err("doe_compute_fast_vulkan: submit recorded replay failed: {s}", .{@errorName(err)});
                timings.queue_submit_ns = monotonicNowNs() - submit_started_ns;
                return timings;
            };
            timings.queue_submit_ns = submit_timings.total();
            timings.queue_submit_command_buffer_end_ns = submit_timings.command_buffer_end_ns;
            timings.queue_submit_sync_prepare_ns = submit_timings.sync_prepare_ns;
            timings.queue_submit_driver_submit_ns = submit_timings.driver_submit_ns;
        } else {
            rt.submit_recorded_replay() catch |err| {
                std.log.err("doe_compute_fast_vulkan: submit recorded replay failed: {s}", .{@errorName(err)});
            };
        }
    }
    return timings;
}

test "samePreparedDispatch requires same pipeline, count, and bind groups" {
    var pipe_a = DoeComputePipeline{};
    var pipe_b = DoeComputePipeline{};
    var group_a = DoeBindGroup{};
    var group_b = DoeBindGroup{};
    var left: BindGroupArray = [_]?*DoeBindGroup{null} ** MAX_COMPUTE_BIND_GROUPS;
    var right = left;
    left[0] = &group_a;
    left[1] = &group_b;
    right[0] = &group_a;
    right[1] = &group_b;

    try std.testing.expect(samePreparedDispatch(&pipe_a, &left, 2, &pipe_a, &right, 2));
    try std.testing.expect(!samePreparedDispatch(&pipe_a, &left, 2, &pipe_b, &right, 2));
    try std.testing.expect(!samePreparedDispatch(&pipe_a, &left, 2, &pipe_a, &right, 1));
    right[1] = &group_a;
    try std.testing.expect(!samePreparedDispatch(&pipe_a, &left, 2, &pipe_a, &right, 2));
}

test "findPreparedDispatchCache matches repeated non-consecutive state" {
    var pipe_a = DoeComputePipeline{};
    var pipe_b = DoeComputePipeline{};
    var group_a = DoeBindGroup{};
    var group_b = DoeBindGroup{};
    var groups_a: BindGroupArray = [_]?*DoeBindGroup{null} ** MAX_COMPUTE_BIND_GROUPS;
    var groups_b = groups_a;
    groups_a[0] = &group_a;
    groups_b[0] = &group_b;
    const cache = [_]PreparedDispatchCacheEntry{
        .{
            .pipe = &pipe_a,
            .bind_groups = groups_a,
            .bg_count = 1,
            .state = .{},
        },
        .{
            .pipe = &pipe_b,
            .bind_groups = groups_b,
            .bg_count = 1,
            .state = .{},
        },
    };

    try std.testing.expectEqual(@as(?usize, 0), findPreparedDispatchCache(cache[0..], &pipe_a, &groups_a, 1));
    try std.testing.expectEqual(@as(?usize, 1), findPreparedDispatchCache(cache[0..], &pipe_b, &groups_b, 1));
    try std.testing.expectEqual(@as(?usize, null), findPreparedDispatchCache(cache[0..], &pipe_a, &groups_b, 1));
}

test "findPreparedBindingStateCache compares binding contents" {
    var pipe = DoeComputePipeline{};
    var cache = [_]PreparedDispatchCacheEntry{.{
        .pipe = &pipe,
        .bind_groups = [_]?*DoeBindGroup{null} ** MAX_COMPUTE_BIND_GROUPS,
        .bg_count = 0,
        .state = .{
            .count = 1,
            .flat_mask = 1,
            .descriptor_hash = 99,
            .bindings = undefined,
        },
    }};
    cache[0].state.bindings[0] = .{
        .group = 0,
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = 7,
        .buffer_size = 16,
    };
    var matching = cache[0].state;
    var different = matching;
    different.bindings[0].resource_handle = 8;

    try std.testing.expectEqual(@as(?usize, 0), findPreparedBindingStateCache(cache[0..], &pipe, &matching));
    try std.testing.expectEqual(@as(?usize, null), findPreparedBindingStateCache(cache[0..], &pipe, &different));
}
