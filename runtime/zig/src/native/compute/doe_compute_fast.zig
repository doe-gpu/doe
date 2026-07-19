const std = @import("std");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_cmds = @import("../support/doe_native_command_types.zig");
const vulkan_fast = @import("doe_compute_fast_vulkan.zig");
const compute_bind_groups = @import("doe_compute_bind_groups.zig");
const compute_preconditions = @import("doe_compute_preconditions_native.zig");
const queue_submit = @import("../queue/doe_queue_submit_native.zig");
const queue_submit_ops = @import("../../backend/dropin_queue_submit.zig");
const bridge = queue_submit_ops.metal_bridge;
const emit_msl = @import("../../compiler/wgsl/emit/msl/emit_msl_ir.zig");
const metal_bridge_compute_dispatch_copy_signal_commit = bridge.metal_bridge_compute_dispatch_copy_signal_commit;
const metal_bridge_buffer_contents = bridge.metal_bridge_buffer_contents;
const metal_bridge_command_buffer_commit = bridge.metal_bridge_command_buffer_commit;
const metal_bridge_command_buffer_encode_signal_event = bridge.metal_bridge_command_buffer_encode_signal_event;
const metal_bridge_create_command_buffer = bridge.metal_bridge_create_command_buffer;
const metal_bridge_cmd_buf_encode_blit_copy = bridge.metal_bridge_cmd_buf_encode_blit_copy;
const metal_bridge_cmd_buf_compute_encoder = bridge.metal_bridge_cmd_buf_compute_encoder;
const metal_bridge_compute_dispatch_batch_copy_signal_commit = bridge.metal_bridge_compute_dispatch_batch_copy_signal_commit;
const metal_bridge_compute_encoder_encode_dispatch = bridge.metal_bridge_compute_encoder_encode_dispatch;
const metal_bridge_compute_encoder_encode_dispatch_batch = bridge.metal_bridge_compute_encoder_encode_dispatch_batch;
const metal_bridge_device_new_buffer_shared = bridge.metal_bridge_device_new_buffer_shared;
const metal_bridge_end_compute_encoding = bridge.metal_bridge_end_compute_encoding;
const metal_bridge_release = bridge.metal_bridge_release;
const MAX_COMPUTE_BIND_GROUPS = compute_bind_groups.MAX_COMPUTE_BIND_GROUPS;
const MAX_FLAT_BIND = compute_bind_groups.MAX_FLAT_BIND;
const MSL_SIZES_SLOT: u32 = emit_msl.MSL_SIZES_SLOT;
const SIZES_BUF_BYTES: usize = (MSL_SIZES_SLOT + 1) * @sizeOf(u32);
const DIRECT_DISPATCH_FLUSH_BREAKDOWN_FIELD_COUNT: usize = 12;
const DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_INDEX: usize = 0;
const DIRECT_DISPATCH_FLUSH_QUEUE_SUBMIT_INDEX: usize = 1;
const DIRECT_DISPATCH_FLUSH_FLUSH_INDEX: usize = 2;
const DIRECT_DISPATCH_FLUSH_WAIT_COMPLETED_INDEX: usize = 3;
const DIRECT_DISPATCH_FLUSH_DEFERRED_COPY_INDEX: usize = 4;
const DIRECT_DISPATCH_FLUSH_DEFERRED_RESOLVE_INDEX: usize = 5;
const DIRECT_DISPATCH_FLUSH_COMMAND_BUFFER_END_INDEX: usize = 6;
const DIRECT_DISPATCH_FLUSH_SYNC_PREPARE_INDEX: usize = 7;
const DIRECT_DISPATCH_FLUSH_DRIVER_SUBMIT_INDEX: usize = 8;
const DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_PREPARE_INDEX: usize = 9;
const DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_RECORD_INDEX: usize = 10;
const DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_COPY_INDEX: usize = 11;
const MAX_DIRECT_BATCH_DISPATCHES: usize = 64;
const RecordedCmd = native_cmds.RecordedCmd;
const DoeCommandBuffer = native_types.DoeCommandBuffer;
const DoeComputePipeline = native_types.DoeComputePipeline;
const DoeDevice = native_types.DoeDevice;
const alloc = native_helpers.alloc;
const make = native_helpers.make;
const toOpaque = native_helpers.toOpaque;

fn monotonicNowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

fn resetDirectDispatchFlushBreakdown(breakdown: ?[*]u64) void {
    const fields = breakdown orelse return;
    for (0..DIRECT_DISPATCH_FLUSH_BREAKDOWN_FIELD_COUNT) |index| {
        fields[index] = 0;
    }
}

fn addDirectDispatchFlushField(breakdown: ?[*]u64, comptime index: usize, value: u64) void {
    const fields = breakdown orelse return;
    fields[index] += value;
}

fn addDirectDispatchQueueFlushBreakdown(breakdown: ?[*]u64, flush: anytype) void {
    const fields = breakdown orelse return;
    fields[DIRECT_DISPATCH_FLUSH_WAIT_COMPLETED_INDEX] += flush.waitCompletedNs;
    fields[DIRECT_DISPATCH_FLUSH_DEFERRED_COPY_INDEX] += flush.deferredCopyNs;
    fields[DIRECT_DISPATCH_FLUSH_DEFERRED_RESOLVE_INDEX] += flush.deferredResolveNs;
}

const PreparedDirectDispatch = struct {
    pso: ?*anyopaque,
    buf_count: u32,
    x: u32,
    y: u32,
    z: u32,
    wg_x: u32,
    wg_y: u32,
    wg_z: u32,
};

fn prepareDirectDispatch(
    q: *native_types.DoeQueue,
    pipe: *native_types.DoeComputePipeline,
    bg_ptrs: [*]const ?*anyopaque,
    bg_count: u32,
    dx: u32,
    dy: u32,
    dz: u32,
    bufs: *[MAX_FLAT_BIND]?*anyopaque,
    sizes_mtl_out: *?*anyopaque,
) ?PreparedDirectDispatch {
    sizes_mtl_out.* = null;
    var bind_groups: [MAX_COMPUTE_BIND_GROUPS]?*native_types.DoeBindGroup = [_]?*native_types.DoeBindGroup{null} ** MAX_COMPUTE_BIND_GROUPS;
    for (0..@min(bg_count, MAX_COMPUTE_BIND_GROUPS)) |i| {
        bind_groups[i] = native_helpers.cast(native_types.DoeBindGroup, bg_ptrs[i]);
    }
    compute_preconditions.validate_bind_groups(
        pipe.dispatch_preconditions,
        pipe.texture_dispatch_preconditions,
        bind_groups[0..],
        .{ dx, dy, dz },
        .{ pipe.wg_x, pipe.wg_y, pipe.wg_z },
    ) catch {
        std.log.err("doe_compute_fast: dispatch precondition failed for proof-elided shader", .{});
        return null;
    };

    var buf_offsets: [MAX_FLAT_BIND]u64 = [_]u64{0} ** MAX_FLAT_BIND;
    var buf_sizes: [MAX_FLAT_BIND]u64 = [_]u64{0} ** MAX_FLAT_BIND;
    var buf_total = compute_bind_groups.populateFlatBindings(bind_groups[0..], bufs, &buf_offsets, &buf_sizes);

    if (pipe.needs_sizes_buf) {
        sizes_mtl_out.* = metal_bridge_device_new_buffer_shared(q.dev.mtl_device, SIZES_BUF_BYTES);
        if (sizes_mtl_out.*) |smtl| {
            if (metal_bridge_buffer_contents(smtl)) |ptr| {
                const sizes: *[MSL_SIZES_SLOT + 1]u32 = @ptrCast(@alignCast(ptr));
                for (0..MSL_SIZES_SLOT + 1) |i| sizes[i] = 0;
                for (0..buf_total) |i| sizes[i] = @intCast(buf_sizes[i]);
            }
            bufs[MSL_SIZES_SLOT] = smtl;
            if (buf_total <= MSL_SIZES_SLOT) buf_total = MSL_SIZES_SLOT + 1;
        }
    }

    return .{
        .pso = pipe.mtl_pso,
        .buf_count = buf_total,
        .x = dx,
        .y = dy,
        .z = dz,
        .wg_x = pipe.wg_x,
        .wg_y = pipe.wg_y,
        .wg_z = pipe.wg_z,
    };
}

fn encodeDispatchToComputeEncoder(
    q: *native_types.DoeQueue,
    encoder: ?*anyopaque,
    pipe: *native_types.DoeComputePipeline,
    bg_ptrs: [*]const ?*anyopaque,
    bg_count: u32,
    dx: u32,
    dy: u32,
    dz: u32,
) bool {
    var bufs: [MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** MAX_FLAT_BIND;
    var sizes_mtl: ?*anyopaque = null;
    defer if (sizes_mtl) |smtl| metal_bridge_release(smtl);
    const prepared = prepareDirectDispatch(
        q,
        pipe,
        bg_ptrs,
        bg_count,
        dx,
        dy,
        dz,
        &bufs,
        &sizes_mtl,
    ) orelse return false;

    metal_bridge_compute_encoder_encode_dispatch(
        encoder,
        prepared.pso,
        @as(?[*]?*anyopaque, &bufs),
        prepared.buf_count,
        prepared.x,
        prepared.y,
        prepared.z,
        prepared.wg_x,
        prepared.wg_y,
        prepared.wg_z,
    );
    return true;
}

fn prepareDispatchBatch(
    q: *native_types.DoeQueue,
    dispatch_count: usize,
    pipe_ptrs: [*]?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_counts: [*]const u32,
    dispatch_dims: [*]const u32,
    pipelines: *[MAX_DIRECT_BATCH_DISPATCHES]?*anyopaque,
    bufs_flat: *[MAX_DIRECT_BATCH_DISPATCHES * MAX_FLAT_BIND]?*anyopaque,
    buf_counts: *[MAX_DIRECT_BATCH_DISPATCHES]u32,
    packed_dispatch_dims: *[MAX_DIRECT_BATCH_DISPATCHES * 3]u32,
    packed_workgroup_dims: *[MAX_DIRECT_BATCH_DISPATCHES * 3]u32,
    sizes_to_release: *[MAX_DIRECT_BATCH_DISPATCHES]?*anyopaque,
    sizes_release_count: *usize,
) usize {
    if (dispatch_count == 0 or dispatch_count > MAX_DIRECT_BATCH_DISPATCHES) return 0;
    var prepared_count: usize = 0;

    for (0..dispatch_count) |index| {
        const pipe = native_helpers.cast(native_types.DoeComputePipeline, pipe_ptrs[index]) orelse continue;
        const bg_offset = index * MAX_COMPUTE_BIND_GROUPS;
        const dim_offset = index * 3;
        const buf_offset = prepared_count * MAX_FLAT_BIND;
        const dispatch_bufs: *[MAX_FLAT_BIND]?*anyopaque = bufs_flat.*[buf_offset..][0..MAX_FLAT_BIND];
        var sizes_mtl: ?*anyopaque = null;
        const prepared = prepareDirectDispatch(
            q,
            pipe,
            bg_ptrs + bg_offset,
            bg_counts[index],
            dispatch_dims[dim_offset],
            dispatch_dims[dim_offset + 1],
            dispatch_dims[dim_offset + 2],
            dispatch_bufs,
            &sizes_mtl,
        ) orelse {
            if (sizes_mtl) |smtl| metal_bridge_release(smtl);
            continue;
        };

        if (sizes_mtl) |smtl| {
            sizes_to_release.*[sizes_release_count.*] = smtl;
            sizes_release_count.* += 1;
        }

        pipelines.*[prepared_count] = prepared.pso;
        buf_counts.*[prepared_count] = prepared.buf_count;
        const packed_dim_offset = prepared_count * 3;
        packed_dispatch_dims.*[packed_dim_offset] = prepared.x;
        packed_dispatch_dims.*[packed_dim_offset + 1] = prepared.y;
        packed_dispatch_dims.*[packed_dim_offset + 2] = prepared.z;
        packed_workgroup_dims.*[packed_dim_offset] = prepared.wg_x;
        packed_workgroup_dims.*[packed_dim_offset + 1] = prepared.wg_y;
        packed_workgroup_dims.*[packed_dim_offset + 2] = prepared.wg_z;
        prepared_count += 1;
    }

    return prepared_count;
}

fn releasePreparedDispatchSizes(
    sizes_to_release: *[MAX_DIRECT_BATCH_DISPATCHES]?*anyopaque,
    sizes_release_count: usize,
) void {
    for (0..sizes_release_count) |index| {
        if (sizes_to_release.*[index]) |smtl| metal_bridge_release(smtl);
    }
}

fn encodeDispatchBatchToComputeEncoder(
    q: *native_types.DoeQueue,
    encoder: ?*anyopaque,
    dispatch_count: usize,
    pipe_ptrs: [*]?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_counts: [*]const u32,
    dispatch_dims: [*]const u32,
) bool {
    if (dispatch_count == 0 or dispatch_count > MAX_DIRECT_BATCH_DISPATCHES) return false;

    var pipelines: [MAX_DIRECT_BATCH_DISPATCHES]?*anyopaque = [_]?*anyopaque{null} ** MAX_DIRECT_BATCH_DISPATCHES;
    var bufs_flat: [MAX_DIRECT_BATCH_DISPATCHES * MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** (MAX_DIRECT_BATCH_DISPATCHES * MAX_FLAT_BIND);
    var buf_counts: [MAX_DIRECT_BATCH_DISPATCHES]u32 = [_]u32{0} ** MAX_DIRECT_BATCH_DISPATCHES;
    var packed_dispatch_dims: [MAX_DIRECT_BATCH_DISPATCHES * 3]u32 = [_]u32{0} ** (MAX_DIRECT_BATCH_DISPATCHES * 3);
    var packed_workgroup_dims: [MAX_DIRECT_BATCH_DISPATCHES * 3]u32 = [_]u32{0} ** (MAX_DIRECT_BATCH_DISPATCHES * 3);
    var sizes_to_release: [MAX_DIRECT_BATCH_DISPATCHES]?*anyopaque = [_]?*anyopaque{null} ** MAX_DIRECT_BATCH_DISPATCHES;
    var sizes_release_count: usize = 0;
    const prepared_count = prepareDispatchBatch(
        q,
        dispatch_count,
        pipe_ptrs,
        bg_ptrs,
        bg_counts,
        dispatch_dims,
        &pipelines,
        &bufs_flat,
        &buf_counts,
        &packed_dispatch_dims,
        &packed_workgroup_dims,
        &sizes_to_release,
        &sizes_release_count,
    );
    defer releasePreparedDispatchSizes(&sizes_to_release, sizes_release_count);
    if (prepared_count == 0) return false;

    metal_bridge_compute_encoder_encode_dispatch_batch(
        encoder,
        @as(?[*]const ?*anyopaque, &pipelines),
        @as(?[*]const ?*anyopaque, &bufs_flat),
        &buf_counts,
        &packed_dispatch_dims,
        &packed_workgroup_dims,
        @intCast(prepared_count),
        @intCast(MAX_FLAT_BIND),
    );
    return true;
}

fn appendRecordedDispatch(
    cmds: *std.ArrayListUnmanaged(RecordedCmd),
    pipe: *DoeComputePipeline,
    bg_ptrs: [*]const ?*anyopaque,
    bg_count: u32,
    dx: u32,
    dy: u32,
    dz: u32,
) bool {
    var bind_groups: [MAX_COMPUTE_BIND_GROUPS]?*native_types.DoeBindGroup = [_]?*native_types.DoeBindGroup{null} ** MAX_COMPUTE_BIND_GROUPS;
    for (0..@min(bg_count, MAX_COMPUTE_BIND_GROUPS)) |i| {
        bind_groups[i] = native_helpers.cast(native_types.DoeBindGroup, bg_ptrs[i]);
    }
    compute_preconditions.validate_bind_groups(
        pipe.dispatch_preconditions,
        pipe.texture_dispatch_preconditions,
        bind_groups[0..],
        .{ dx, dy, dz },
        .{ pipe.wg_x, pipe.wg_y, pipe.wg_z },
    ) catch {
        std.log.err("doe_compute_fast: command buffer dispatch precondition failed for proof-elided shader", .{});
        return false;
    };

    var cmd = RecordedCmd{ .dispatch = .{
        .compute_pipeline = toOpaque(pipe),
        .pso = pipe.mtl_pso,
        .needs_sizes_buf = pipe.needs_sizes_buf,
        .bufs = [_]?*anyopaque{null} ** MAX_FLAT_BIND,
        .buf_offsets = [_]u64{0} ** MAX_FLAT_BIND,
        .buf_sizes = [_]u64{0} ** MAX_FLAT_BIND,
        .buf_count = 0,
        .x = dx,
        .y = dy,
        .z = dz,
        .wg_x = pipe.wg_x,
        .wg_y = pipe.wg_y,
        .wg_z = pipe.wg_z,
    } };
    cmd.dispatch.buf_count = compute_bind_groups.populateFlatBindings(
        bind_groups[0..],
        &cmd.dispatch.bufs,
        &cmd.dispatch.buf_offsets,
        &cmd.dispatch.buf_sizes,
    );
    vulkan_fast.populateRecordedDispatchBindingState(pipe, &cmd.dispatch);
    if (native_cmds.tryMergeDispatchIntoLast(cmds, &cmd)) return true;
    cmds.append(alloc, cmd) catch std.debug.panic("doe_compute_fast: OOM recording dispatch command", .{});
    return true;
}
fn appendCopyIfPresent(
    cmds: *std.ArrayListUnmanaged(RecordedCmd),
    copy_src: ?*anyopaque,
    copy_src_off: u64,
    copy_dst: ?*anyopaque,
    copy_dst_off: u64,
    copy_size: u64,
) bool {
    if (copy_size == 0) return true;
    if (copy_src == null or copy_dst == null) return false;
    cmds.append(alloc, .{ .copy_buf = .{
        .src = copy_src,
        .src_off = copy_src_off,
        .dst = copy_dst,
        .dst_off = copy_dst_off,
        .size = copy_size,
    } }) catch std.debug.panic("doe_compute_fast: OOM recording copy command", .{});
    return true;
}

fn destroyPendingCommandBuffer(cb: *DoeCommandBuffer) void {
    cb.cmds.deinit(alloc);
    alloc.destroy(cb);
}

pub export fn doeNativeCreateComputeDispatchCopyCommandBuffer(
    dev_raw: ?*anyopaque,
    pipe_raw: ?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_count: u32,
    dx: u32,
    dy: u32,
    dz: u32,
    copy_src: ?*anyopaque,
    copy_src_off: u64,
    copy_dst: ?*anyopaque,
    copy_dst_off: u64,
    copy_size: u64,
) callconv(.c) ?*anyopaque {
    const dev = native_helpers.cast(DoeDevice, dev_raw) orelse return null;
    const pipe = native_helpers.cast(DoeComputePipeline, pipe_raw) orelse return null;
    const cb = make(DoeCommandBuffer) orelse return null;
    cb.* = .{ .dev = dev };
    if (!appendRecordedDispatch(&cb.cmds, pipe, bg_ptrs, bg_count, dx, dy, dz)) {
        destroyPendingCommandBuffer(cb);
        return null;
    }
    if (!appendCopyIfPresent(&cb.cmds, copy_src, copy_src_off, copy_dst, copy_dst_off, copy_size)) {
        destroyPendingCommandBuffer(cb);
        return null;
    }
    return toOpaque(cb);
}

pub export fn doeNativeCreateComputeDispatchCopyCommandBufferOneBindGroup(
    dev_raw: ?*anyopaque,
    pipe_raw: ?*anyopaque,
    bg0_raw: ?*anyopaque,
    dx: u32,
    dy: u32,
    dz: u32,
    copy_src: ?*anyopaque,
    copy_src_off: u64,
    copy_dst: ?*anyopaque,
    copy_dst_off: u64,
    copy_size: u64,
) callconv(.c) ?*anyopaque {
    var bg_ptrs = [_]?*anyopaque{bg0_raw};
    return doeNativeCreateComputeDispatchCopyCommandBuffer(
        dev_raw,
        pipe_raw,
        &bg_ptrs,
        bg_ptrs.len,
        dx,
        dy,
        dz,
        copy_src,
        copy_src_off,
        copy_dst,
        copy_dst_off,
        copy_size,
    );
}

pub export fn doeNativeCreateComputeDispatchBatchCopyCommandBuffer(
    dev_raw: ?*anyopaque,
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
) callconv(.c) ?*anyopaque {
    const dev = native_helpers.cast(DoeDevice, dev_raw) orelse return null;
    if (dispatch_count == 0) return null;
    const cb = make(DoeCommandBuffer) orelse return null;
    cb.* = .{ .dev = dev };
    for (0..dispatch_count) |index| {
        const pipe = native_helpers.cast(DoeComputePipeline, pipe_ptrs[index]) orelse {
            destroyPendingCommandBuffer(cb);
            return null;
        };
        const bg_offset = index * MAX_COMPUTE_BIND_GROUPS;
        const dim_offset = index * 3;
        if (!appendRecordedDispatch(
            &cb.cmds,
            pipe,
            bg_ptrs + bg_offset,
            bg_counts[index],
            dispatch_dims[dim_offset],
            dispatch_dims[dim_offset + 1],
            dispatch_dims[dim_offset + 2],
        )) {
            destroyPendingCommandBuffer(cb);
            return null;
        }
    }
    if (!appendCopyIfPresent(&cb.cmds, copy_src, copy_src_off, copy_dst, copy_dst_off, copy_size)) {
        destroyPendingCommandBuffer(cb);
        return null;
    }
    return toOpaque(cb);
}

/// Single-call compute dispatch + optional same-submit copy + event signal + commit.
/// When the follow-on copy is a CPU-visible shared-buffer readback, we schedule it as
/// a deferred CPU memcpy after GPU completion to preserve macOS correctness while
/// keeping the direct dispatch path.
pub fn computeDispatchFlushDirect(
    q_raw: ?*anyopaque,
    pipe_raw: ?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_count: u32,
    dx: u32,
    dy: u32,
    dz: u32,
    copy_src: ?*anyopaque,
    copy_src_off: u64,
    copy_dst: ?*anyopaque,
    copy_dst_off: u64,
    copy_size: u64,
    breakdown: ?[*]u64,
) void {
    resetDirectDispatchFlushBreakdown(breakdown);
    const q = native_helpers.cast(native_types.DoeQueue, q_raw) orelse return;
    const pipe = native_helpers.cast(native_types.DoeComputePipeline, pipe_raw) orelse return;
    if (q.dev.backend == .vulkan) {
        var pipe_ptrs = [_]?*anyopaque{toOpaque(pipe)};
        var bg_counts = [_]u32{@min(bg_count, MAX_COMPUTE_BIND_GROUPS)};
        var dispatch_dims = [_]u32{ dx, dy, dz };
        computeDispatchBatchCopyFlushDirect(q_raw, 1, &pipe_ptrs, bg_ptrs, &bg_counts, &dispatch_dims, copy_src, copy_src_off, copy_dst, copy_dst_off, copy_size, breakdown);
        return;
    }
    if (q.dev.backend != .metal) return;
    const before_submit_flush_started_ns = monotonicNowNs();
    const before_submit_flush = queue_submit.flush_before_submit_if_needed_timed(q);
    addDirectDispatchFlushField(
        breakdown,
        DIRECT_DISPATCH_FLUSH_FLUSH_INDEX,
        monotonicNowNs() - before_submit_flush_started_ns,
    );
    addDirectDispatchQueueFlushBreakdown(breakdown, before_submit_flush);

    const replay_started_ns = monotonicNowNs();
    var bind_groups: [MAX_COMPUTE_BIND_GROUPS]?*native_types.DoeBindGroup = [_]?*native_types.DoeBindGroup{null} ** MAX_COMPUTE_BIND_GROUPS;
    for (0..@min(bg_count, MAX_COMPUTE_BIND_GROUPS)) |i| {
        bind_groups[i] = native_helpers.cast(native_types.DoeBindGroup, bg_ptrs[i]);
    }
    compute_preconditions.validate_bind_groups(
        pipe.dispatch_preconditions,
        pipe.texture_dispatch_preconditions,
        bind_groups[0..],
        .{ dx, dy, dz },
        .{ pipe.wg_x, pipe.wg_y, pipe.wg_z },
    ) catch {
        std.log.err("doe_compute_fast: dispatch precondition failed for proof-elided shader", .{});
        return;
    };

    var bufs: [MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** MAX_FLAT_BIND;
    var buf_offsets: [MAX_FLAT_BIND]u64 = [_]u64{0} ** MAX_FLAT_BIND;
    var buf_sizes: [MAX_FLAT_BIND]u64 = [_]u64{0} ** MAX_FLAT_BIND;
    var buf_total = compute_bind_groups.populateFlatBindings(bind_groups[0..], &bufs, &buf_offsets, &buf_sizes);

    var sizes_mtl: ?*anyopaque = null;
    defer if (sizes_mtl) |smtl| metal_bridge_release(smtl);
    if (pipe.needs_sizes_buf) {
        sizes_mtl = metal_bridge_device_new_buffer_shared(q.dev.mtl_device, SIZES_BUF_BYTES);
        if (sizes_mtl) |smtl| {
            if (metal_bridge_buffer_contents(smtl)) |ptr| {
                const sizes: *[MSL_SIZES_SLOT + 1]u32 = @ptrCast(@alignCast(ptr));
                for (0..MSL_SIZES_SLOT + 1) |i| sizes[i] = 0;
                for (0..buf_total) |i| sizes[i] = @intCast(buf_sizes[i]);
            }
            bufs[MSL_SIZES_SLOT] = smtl;
            if (buf_total <= MSL_SIZES_SLOT) buf_total = MSL_SIZES_SLOT + 1;
        }
    }

    // Resolve copy path. Prefer the same deferred CPU-copy path used by the
    // generic queue submission on Apple Silicon shared-memory buffers.
    var mtl_copy_src: ?*anyopaque = null;
    var mtl_copy_dst: ?*anyopaque = null;
    var copy_src_off_local = copy_src_off;
    var copy_dst_off_local = copy_dst_off;
    var copy_size_local = copy_size;
    if (copy_size_local > 0) {
        if (queue_submit.try_schedule_deferred_copy(q, copy_src, copy_src_off_local, copy_dst, copy_dst_off_local, copy_size_local)) {
            copy_src_off_local = 0;
            copy_dst_off_local = 0;
            copy_size_local = 0;
        } else {
            if (native_helpers.cast(native_types.DoeBuffer, copy_src)) |sb| mtl_copy_src = sb.mtl;
            if (native_helpers.cast(native_types.DoeBuffer, copy_dst)) |db| mtl_copy_dst = db.mtl;
        }
    }
    addDirectDispatchFlushField(
        breakdown,
        DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_INDEX,
        monotonicNowNs() - replay_started_ns,
    );

    q.event_counter += 1;
    const queue_submit_started_ns = monotonicNowNs();
    const mtl_cmd = metal_bridge_compute_dispatch_copy_signal_commit(
        q.dev.mtl_queue,
        pipe.mtl_pso,
        @ptrCast(&bufs),
        buf_total,
        dx,
        dy,
        dz,
        pipe.wg_x,
        pipe.wg_y,
        pipe.wg_z,
        mtl_copy_src,
        copy_src_off_local,
        mtl_copy_dst,
        copy_dst_off_local,
        copy_size_local,
        q.mtl_event,
        q.event_counter,
    ) orelse return;
    queue_submit.finalize_submitted_metal_command_buffer(q, mtl_cmd);
    addDirectDispatchFlushField(
        breakdown,
        DIRECT_DISPATCH_FLUSH_QUEUE_SUBMIT_INDEX,
        monotonicNowNs() - queue_submit_started_ns,
    );
}

pub export fn doeNativeComputeDispatchFlush(
    q_raw: ?*anyopaque,
    pipe_raw: ?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_count: u32,
    dx: u32,
    dy: u32,
    dz: u32,
    copy_src: ?*anyopaque,
    copy_src_off: u64,
    copy_dst: ?*anyopaque,
    copy_dst_off: u64,
    copy_size: u64,
) callconv(.c) void {
    computeDispatchFlushDirect(
        q_raw,
        pipe_raw,
        bg_ptrs,
        bg_count,
        dx,
        dy,
        dz,
        copy_src,
        copy_src_off,
        copy_dst,
        copy_dst_off,
        copy_size,
        null,
    );
}

pub export fn doeNativeComputeDispatchFlushBreakdown(
    q_raw: ?*anyopaque,
    pipe_raw: ?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_count: u32,
    dx: u32,
    dy: u32,
    dz: u32,
    copy_src: ?*anyopaque,
    copy_src_off: u64,
    copy_dst: ?*anyopaque,
    copy_dst_off: u64,
    copy_size: u64,
    breakdown: ?[*]u64,
) callconv(.c) void {
    computeDispatchFlushDirect(
        q_raw,
        pipe_raw,
        bg_ptrs,
        bg_count,
        dx,
        dy,
        dz,
        copy_src,
        copy_src_off,
        copy_dst,
        copy_dst_off,
        copy_size,
        breakdown,
    );
}

pub export fn doeNativeComputeDispatchBatchFlush(
    q_raw: ?*anyopaque,
    dispatch_count: usize,
    pipe_ptrs: [*]?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_counts: [*]const u32,
    dispatch_dims: [*]const u32,
) callconv(.c) void {
    computeDispatchBatchCopyFlushDirect(
        q_raw,
        dispatch_count,
        pipe_ptrs,
        bg_ptrs,
        bg_counts,
        dispatch_dims,
        null,
        0,
        null,
        0,
        0,
        null,
    );
}

fn computeDispatchBatchCopyFlushDirect(
    q_raw: ?*anyopaque,
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
    breakdown: ?[*]u64,
) void {
    resetDirectDispatchFlushBreakdown(breakdown);
    const q = native_helpers.cast(native_types.DoeQueue, q_raw) orelse return;
    if (q.dev.backend == .vulkan) {
        if (dispatch_count == 0) return;
        const timings = vulkan_fast.dispatchBatchCopyFlush(
            q,
            dispatch_count,
            pipe_ptrs,
            bg_ptrs,
            bg_counts,
            dispatch_dims,
            copy_src,
            copy_src_off,
            copy_dst,
            copy_dst_off,
            copy_size,
            breakdown != null,
        );
        addDirectDispatchFlushField(
            breakdown,
            DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_INDEX,
            timings.command_replay_ns,
        );
        addDirectDispatchFlushField(
            breakdown,
            DIRECT_DISPATCH_FLUSH_QUEUE_SUBMIT_INDEX,
            timings.queue_submit_ns,
        );
        addDirectDispatchFlushField(
            breakdown,
            DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_PREPARE_INDEX,
            timings.command_replay_prepare_ns,
        );
        addDirectDispatchFlushField(
            breakdown,
            DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_RECORD_INDEX,
            timings.command_replay_record_ns,
        );
        addDirectDispatchFlushField(
            breakdown,
            DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_COPY_INDEX,
            timings.command_replay_copy_ns,
        );
        addDirectDispatchFlushField(
            breakdown,
            DIRECT_DISPATCH_FLUSH_COMMAND_BUFFER_END_INDEX,
            timings.queue_submit_command_buffer_end_ns,
        );
        addDirectDispatchFlushField(
            breakdown,
            DIRECT_DISPATCH_FLUSH_SYNC_PREPARE_INDEX,
            timings.queue_submit_sync_prepare_ns,
        );
        addDirectDispatchFlushField(
            breakdown,
            DIRECT_DISPATCH_FLUSH_DRIVER_SUBMIT_INDEX,
            timings.queue_submit_driver_submit_ns,
        );
        return;
    }
    if (q.dev.backend != .metal) return;
    if (dispatch_count == 0) return;

    const before_submit_flush_started_ns = monotonicNowNs();
    const before_submit_flush = queue_submit.flush_before_submit_if_needed_timed(q);
    addDirectDispatchFlushField(
        breakdown,
        DIRECT_DISPATCH_FLUSH_FLUSH_INDEX,
        monotonicNowNs() - before_submit_flush_started_ns,
    );
    addDirectDispatchQueueFlushBreakdown(breakdown, before_submit_flush);

    const replay_started_ns = monotonicNowNs();
    if (dispatch_count <= MAX_DIRECT_BATCH_DISPATCHES) {
        var pipelines: [MAX_DIRECT_BATCH_DISPATCHES]?*anyopaque = [_]?*anyopaque{null} ** MAX_DIRECT_BATCH_DISPATCHES;
        var bufs_flat: [MAX_DIRECT_BATCH_DISPATCHES * MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** (MAX_DIRECT_BATCH_DISPATCHES * MAX_FLAT_BIND);
        var buf_counts: [MAX_DIRECT_BATCH_DISPATCHES]u32 = [_]u32{0} ** MAX_DIRECT_BATCH_DISPATCHES;
        var packed_dispatch_dims: [MAX_DIRECT_BATCH_DISPATCHES * 3]u32 = [_]u32{0} ** (MAX_DIRECT_BATCH_DISPATCHES * 3);
        var packed_workgroup_dims: [MAX_DIRECT_BATCH_DISPATCHES * 3]u32 = [_]u32{0} ** (MAX_DIRECT_BATCH_DISPATCHES * 3);
        var sizes_to_release: [MAX_DIRECT_BATCH_DISPATCHES]?*anyopaque = [_]?*anyopaque{null} ** MAX_DIRECT_BATCH_DISPATCHES;
        var sizes_release_count: usize = 0;
        const prepared_count = prepareDispatchBatch(
            q,
            dispatch_count,
            pipe_ptrs,
            bg_ptrs,
            bg_counts,
            dispatch_dims,
            &pipelines,
            &bufs_flat,
            &buf_counts,
            &packed_dispatch_dims,
            &packed_workgroup_dims,
            &sizes_to_release,
            &sizes_release_count,
        );
        defer releasePreparedDispatchSizes(&sizes_to_release, sizes_release_count);
        if (prepared_count == 0) return;

        var mtl_copy_src: ?*anyopaque = null;
        var mtl_copy_dst: ?*anyopaque = null;
        var copy_src_off_local = copy_src_off;
        var copy_dst_off_local = copy_dst_off;
        var copy_size_local = copy_size;
        if (copy_size_local > 0) {
            if (queue_submit.try_schedule_deferred_copy(q, copy_src, copy_src_off_local, copy_dst, copy_dst_off_local, copy_size_local)) {
                copy_src_off_local = 0;
                copy_dst_off_local = 0;
                copy_size_local = 0;
            } else {
                if (native_helpers.cast(native_types.DoeBuffer, copy_src)) |src| mtl_copy_src = src.mtl;
                if (native_helpers.cast(native_types.DoeBuffer, copy_dst)) |dst| mtl_copy_dst = dst.mtl;
            }
        }

        addDirectDispatchFlushField(
            breakdown,
            DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_INDEX,
            monotonicNowNs() - replay_started_ns,
        );

        q.event_counter += 1;
        const queue_submit_started_ns = monotonicNowNs();
        const mtl_cmd = metal_bridge_compute_dispatch_batch_copy_signal_commit(
            q.dev.mtl_queue,
            @as(?[*]const ?*anyopaque, &pipelines),
            @as(?[*]const ?*anyopaque, &bufs_flat),
            &buf_counts,
            &packed_dispatch_dims,
            &packed_workgroup_dims,
            @intCast(prepared_count),
            @intCast(MAX_FLAT_BIND),
            mtl_copy_src,
            copy_src_off_local,
            mtl_copy_dst,
            copy_dst_off_local,
            copy_size_local,
            q.mtl_event,
            q.event_counter,
        ) orelse return;
        queue_submit.finalize_submitted_metal_command_buffer(q, mtl_cmd);
        addDirectDispatchFlushField(
            breakdown,
            DIRECT_DISPATCH_FLUSH_QUEUE_SUBMIT_INDEX,
            monotonicNowNs() - queue_submit_started_ns,
        );
        return;
    }

    const mtl_cmd = metal_bridge_create_command_buffer(q.dev.mtl_queue) orelse return;
    const compute_encoder = metal_bridge_cmd_buf_compute_encoder(mtl_cmd) orelse {
        metal_bridge_release(mtl_cmd);
        return;
    };
    var has_gpu_work = false;

    for (0..dispatch_count) |index| {
        const pipe = native_helpers.cast(native_types.DoeComputePipeline, pipe_ptrs[index]) orelse continue;
        const bg_offset = index * MAX_COMPUTE_BIND_GROUPS;
        const dim_offset = index * 3;
        has_gpu_work = encodeDispatchToComputeEncoder(
            q,
            compute_encoder,
            pipe,
            bg_ptrs + bg_offset,
            bg_counts[index],
            dispatch_dims[dim_offset],
            dispatch_dims[dim_offset + 1],
            dispatch_dims[dim_offset + 2],
        ) or has_gpu_work;
    }
    metal_bridge_end_compute_encoding(compute_encoder);

    if (!has_gpu_work) {
        metal_bridge_release(mtl_cmd);
        return;
    }

    var copy_src_off_local = copy_src_off;
    var copy_dst_off_local = copy_dst_off;
    var copy_size_local = copy_size;
    if (copy_size_local > 0) {
        if (queue_submit.try_schedule_deferred_copy(q, copy_src, copy_src_off_local, copy_dst, copy_dst_off_local, copy_size_local)) {
            copy_src_off_local = 0;
            copy_dst_off_local = 0;
            copy_size_local = 0;
        } else {
            const src_mtl = if (native_helpers.cast(native_types.DoeBuffer, copy_src)) |src| src.mtl else copy_src;
            const dst_mtl = if (native_helpers.cast(native_types.DoeBuffer, copy_dst)) |dst| dst.mtl else copy_dst;
            metal_bridge_cmd_buf_encode_blit_copy(
                mtl_cmd,
                src_mtl,
                copy_src_off_local,
                dst_mtl,
                copy_dst_off_local,
                copy_size_local,
            );
        }
    }
    addDirectDispatchFlushField(
        breakdown,
        DIRECT_DISPATCH_FLUSH_COMMAND_REPLAY_INDEX,
        monotonicNowNs() - replay_started_ns,
    );

    q.event_counter += 1;
    const queue_submit_started_ns = monotonicNowNs();
    if (q.mtl_event) |event| {
        metal_bridge_command_buffer_encode_signal_event(mtl_cmd, event, q.event_counter);
    }
    metal_bridge_command_buffer_commit(mtl_cmd);
    queue_submit.finalize_submitted_metal_command_buffer(q, mtl_cmd);
    addDirectDispatchFlushField(
        breakdown,
        DIRECT_DISPATCH_FLUSH_QUEUE_SUBMIT_INDEX,
        monotonicNowNs() - queue_submit_started_ns,
    );
}

pub export fn doeNativeComputeDispatchBatchCopyFlush(
    q_raw: ?*anyopaque,
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
) callconv(.c) void {
    computeDispatchBatchCopyFlushDirect(
        q_raw,
        dispatch_count,
        pipe_ptrs,
        bg_ptrs,
        bg_counts,
        dispatch_dims,
        copy_src,
        copy_src_off,
        copy_dst,
        copy_dst_off,
        copy_size,
        null,
    );
}

pub fn prewarmDispatchBindingsForQueue(
    q_raw: ?*anyopaque,
    dispatch_count: usize,
    pipe_ptrs: [*]?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_counts: [*]const u32,
) callconv(.c) u32 {
    const q = native_helpers.cast(native_types.DoeQueue, q_raw) orelse return 0;
    if (q.dev.backend != .vulkan) return 0;
    return vulkan_fast.prewarmPreparedDispatchBindings(
        q,
        dispatch_count,
        pipe_ptrs,
        bg_ptrs,
        bg_counts,
    );
}

pub export fn doeNativeComputeDispatchBatchCopyFlushBreakdown(
    q_raw: ?*anyopaque,
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
    breakdown: ?[*]u64,
) callconv(.c) void {
    computeDispatchBatchCopyFlushDirect(
        q_raw,
        dispatch_count,
        pipe_ptrs,
        bg_ptrs,
        bg_counts,
        dispatch_dims,
        copy_src,
        copy_src_off,
        copy_dst,
        copy_dst_off,
        copy_size,
        breakdown,
    );
}
