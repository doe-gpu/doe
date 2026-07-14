const queue_submit_ops = @import("backend/dropin_queue_submit.zig");
const native_types = @import("doe_native_object_types.zig");
const native_shared = @import("doe_native_shared_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const native_cmds = @import("doe_native_command_types.zig");
const queue_flush_breakdown = @import("doe_queue_flush_breakdown.zig");
const metal_browser_trace = @import("doe_metal_browser_trace.zig");
const emit_msl = @import("doe_wgsl/emit_msl_ir.zig");
const shared = @import("doe_queue_submit_shared.zig");

const cast = native_helpers.cast;
const DoeBuffer = native_types.DoeBuffer;
const DoeCommandBuffer = native_types.DoeCommandBuffer;
const DoeQueue = native_types.DoeQueue;
const MAX_DEFERRED_COPIES: usize = @as(usize, native_cmds.MAX_DEFERRED_COPIES);
const MAX_DEFERRED_RESOLVES = native_cmds.MAX_DEFERRED_RESOLVES;
const MAX_FLAT_BIND = native_shared.MAX_FLAT_BIND;
const MAX_RECORDED_DISPATCH_BATCH: usize = 64;
const VERTEX_BUFFER_SLOT_BASE = native_shared.VERTEX_BUFFER_SLOT_BASE;
const MSL_SIZES_SLOT: u32 = emit_msl.MSL_SIZES_SLOT;
const SIZES_BUF_BYTES: usize = (MSL_SIZES_SLOT + 1) * @sizeOf(u32);
const bridge = queue_submit_ops.metal_bridge;

fn submittedBuffersHaveRecordedCommands(count: usize, cmd_bufs: [*]const ?*anyopaque) bool {
    for (cmd_bufs[0..count]) |raw| {
        const cb = cast(DoeCommandBuffer, raw) orelse continue;
        if (cb.cmds.items.len != 0) return true;
    }
    return false;
}

fn read_indirect_dispatch_counts(buffer_raw: ?*anyopaque, offset: u64) ?struct { x: u32, y: u32, z: u32 } {
    const buffer = cast(DoeBuffer, buffer_raw) orelse return null;
    const byte_offset: usize = @intCast(offset);
    const counts_bytes = 3 * @sizeOf(u32);
    if (byte_offset + counts_bytes > buffer.size) return null;
    const contents = bridge.metal_bridge_buffer_contents(buffer.mtl) orelse return null;
    const base = contents + byte_offset;
    const ints: *align(1) const [3]u32 = @ptrCast(base);
    return .{ .x = ints[0], .y = ints[1], .z = ints[2] };
}

fn try_execute_copy_only_deferred(q: *DoeQueue, count: usize, cmd_bufs: [*]const ?*anyopaque) bool {
    var plans: [MAX_DEFERRED_COPIES]shared.DeferredCopyPlan = undefined;
    var plan_count: usize = 0;
    var saw_command = false;

    for (cmd_bufs[0..count]) |raw| {
        const cb = cast(DoeCommandBuffer, raw) orelse continue;
        for (cb.cmds.items) |cmd| {
            saw_command = true;
            switch (cmd) {
                .copy_buf => |c| {
                    if (plan_count >= plans.len) return false;
                    plans[plan_count] = shared.make_deferred_copy_plan(c.src, c.src_off, c.dst, c.dst_off, c.size) orelse return false;
                    plan_count += 1;
                },
                else => return false,
            }
        }
    }

    if (!saw_command) return true;
    shared.flush_pending_work(q);
    for (plans[0..plan_count]) |plan| {
        _ = shared.append_deferred_copy_plan(q, plan);
    }
    queue_flush_breakdown.executeDeferredCopies(q);
    return true;
}

fn end_active_compute_encoder(active_compute_encoder: *?*anyopaque) void {
    if (active_compute_encoder.*) |encoder| {
        bridge.metal_bridge_end_compute_encoding(encoder);
        active_compute_encoder.* = null;
    }
}

fn encode_recorded_dispatch_batch(
    q: *DoeQueue,
    encoder: ?*anyopaque,
    cmds: []const native_cmds.RecordedCmd,
    start_index: usize,
) usize {
    if (encoder == null or start_index >= cmds.len) return 0;

    var pipelines: [MAX_RECORDED_DISPATCH_BATCH]?*anyopaque = [_]?*anyopaque{null} ** MAX_RECORDED_DISPATCH_BATCH;
    var bufs_flat: [MAX_RECORDED_DISPATCH_BATCH * MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** (MAX_RECORDED_DISPATCH_BATCH * MAX_FLAT_BIND);
    var buf_counts: [MAX_RECORDED_DISPATCH_BATCH]u32 = [_]u32{0} ** MAX_RECORDED_DISPATCH_BATCH;
    var repeat_counts: [MAX_RECORDED_DISPATCH_BATCH]u32 = [_]u32{1} ** MAX_RECORDED_DISPATCH_BATCH;
    var dispatch_dims: [MAX_RECORDED_DISPATCH_BATCH * 3]u32 = [_]u32{0} ** (MAX_RECORDED_DISPATCH_BATCH * 3);
    var workgroup_dims: [MAX_RECORDED_DISPATCH_BATCH * 3]u32 = [_]u32{0} ** (MAX_RECORDED_DISPATCH_BATCH * 3);
    var sizes_to_release: [MAX_RECORDED_DISPATCH_BATCH]?*anyopaque = [_]?*anyopaque{null} ** MAX_RECORDED_DISPATCH_BATCH;
    var sizes_release_count: usize = 0;
    var count: usize = 0;

    while (start_index + count < cmds.len and count < MAX_RECORDED_DISPATCH_BATCH) {
        const d = switch (cmds[start_index + count]) {
            .dispatch => |dispatch| dispatch,
            else => break,
        };
        if (d.pso == null) break;

        var bufs_copy = d.bufs;
        var buf_count = d.buf_count;
        if (d.needs_sizes_buf) {
            const sizes_mtl = bridge.metal_bridge_device_new_buffer_shared(q.dev.mtl_device, SIZES_BUF_BYTES);
            if (sizes_mtl) |smtl| {
                if (bridge.metal_bridge_buffer_contents(smtl)) |ptr| {
                    const sizes: *[MSL_SIZES_SLOT + 1]u32 = @ptrCast(@alignCast(ptr));
                    for (0..MSL_SIZES_SLOT + 1) |i| sizes[i] = 0;
                    for (0..d.buf_count) |i| sizes[i] = @intCast(d.buf_sizes[i]);
                }
                bufs_copy[MSL_SIZES_SLOT] = smtl;
                if (buf_count <= MSL_SIZES_SLOT) buf_count = MSL_SIZES_SLOT + 1;
                sizes_to_release[sizes_release_count] = smtl;
                sizes_release_count += 1;
            }
        }

        pipelines[count] = d.pso;
        buf_counts[count] = buf_count;
        repeat_counts[count] = if (d.repeat_count == 0) 1 else d.repeat_count;
        const buf_offset = count * MAX_FLAT_BIND;
        for (0..MAX_FLAT_BIND) |slot| {
            bufs_flat[buf_offset + slot] = bufs_copy[slot];
        }
        const dim_offset = count * 3;
        dispatch_dims[dim_offset] = d.x;
        dispatch_dims[dim_offset + 1] = d.y;
        dispatch_dims[dim_offset + 2] = d.z;
        workgroup_dims[dim_offset] = d.wg_x;
        workgroup_dims[dim_offset + 1] = d.wg_y;
        workgroup_dims[dim_offset + 2] = d.wg_z;
        count += 1;
    }

    if (count > 0) {
        bridge.metal_bridge_compute_encoder_encode_dispatch_batch_repeated(
            encoder,
            @as(?[*]const ?*anyopaque, &pipelines),
            @as(?[*]const ?*anyopaque, &bufs_flat),
            &buf_counts,
            &repeat_counts,
            &dispatch_dims,
            &workgroup_dims,
            @intCast(count),
            @intCast(MAX_FLAT_BIND),
        );
    }

    for (0..sizes_release_count) |index| {
        if (sizes_to_release[index]) |smtl| bridge.metal_bridge_release(smtl);
    }
    return count;
}

pub fn submit_metal_commands(q: *DoeQueue, count: usize, cmd_bufs: [*]const ?*anyopaque) void {
    const queue = q.dev.mtl_queue;
    shared.flush_before_submit_if_needed(q);

    if (!submittedBuffersHaveRecordedCommands(count, cmd_bufs)) {
        return;
    }
    if (try_execute_copy_only_deferred(q, count, cmd_bufs)) {
        return;
    }

    const trace_enabled = metal_browser_trace.enabled();
    const create_started_ns = if (trace_enabled) metal_browser_trace.nowNs() else 0;
    const mtl_cmd = bridge.metal_bridge_create_command_buffer(queue) orelse return;
    const command_buffer_create_ns = if (trace_enabled)
        metal_browser_trace.elapsedSince(create_started_ns)
    else
        0;
    const encode_started_ns = if (trace_enabled) metal_browser_trace.nowNs() else 0;
    var has_gpu_work = false;
    var active_compute_encoder: ?*anyopaque = null;
    defer end_active_compute_encoder(&active_compute_encoder);

    for (cmd_bufs[0..count]) |raw| {
        const cb = cast(DoeCommandBuffer, raw) orelse continue;
        var cmd_index: usize = 0;
        while (cmd_index < cb.cmds.items.len) {
            const cmd = cb.cmds.items[cmd_index];
            switch (cmd) {
                .dispatch => |d| {
                    if (active_compute_encoder == null) {
                        active_compute_encoder = bridge.metal_bridge_cmd_buf_compute_encoder(mtl_cmd);
                    }
                    if (active_compute_encoder) |encoder| {
                        const encoded_count = encode_recorded_dispatch_batch(q, encoder, cb.cmds.items, cmd_index);
                        if (encoded_count > 0) {
                            has_gpu_work = true;
                            cmd_index += encoded_count;
                            continue;
                        }
                        var bufs_copy = d.bufs;
                        var buf_count = d.buf_count;
                        var sizes_mtl: ?*anyopaque = null;
                        if (d.needs_sizes_buf) {
                            sizes_mtl = bridge.metal_bridge_device_new_buffer_shared(q.dev.mtl_device, SIZES_BUF_BYTES);
                            if (sizes_mtl) |smtl| {
                                if (bridge.metal_bridge_buffer_contents(smtl)) |ptr| {
                                    const sizes: *[MSL_SIZES_SLOT + 1]u32 = @ptrCast(@alignCast(ptr));
                                    for (0..MSL_SIZES_SLOT + 1) |i| sizes[i] = 0;
                                    for (0..d.buf_count) |i| sizes[i] = @intCast(d.buf_sizes[i]);
                                }
                                bufs_copy[MSL_SIZES_SLOT] = smtl;
                                if (buf_count <= MSL_SIZES_SLOT) buf_count = MSL_SIZES_SLOT + 1;
                            }
                        }
                        const repeat_count = if (d.repeat_count == 0) 1 else d.repeat_count;
                        var repeat_index: u32 = 0;
                        while (repeat_index < repeat_count) : (repeat_index += 1) {
                            bridge.metal_bridge_compute_encoder_encode_dispatch(
                                encoder,
                                d.pso,
                                @as(?[*]?*anyopaque, &bufs_copy),
                                buf_count,
                                d.x,
                                d.y,
                                d.z,
                                d.wg_x,
                                d.wg_y,
                                d.wg_z,
                            );
                        }
                        if (sizes_mtl) |smtl| bridge.metal_bridge_release(smtl);
                    } else {
                        var bufs_copy = d.bufs;
                        var buf_count = d.buf_count;
                        var sizes_mtl: ?*anyopaque = null;
                        if (d.needs_sizes_buf) {
                            sizes_mtl = bridge.metal_bridge_device_new_buffer_shared(q.dev.mtl_device, SIZES_BUF_BYTES);
                            if (sizes_mtl) |smtl| {
                                if (bridge.metal_bridge_buffer_contents(smtl)) |ptr| {
                                    const sizes: *[MSL_SIZES_SLOT + 1]u32 = @ptrCast(@alignCast(ptr));
                                    for (0..MSL_SIZES_SLOT + 1) |i| sizes[i] = 0;
                                    for (0..d.buf_count) |i| sizes[i] = @intCast(d.buf_sizes[i]);
                                }
                                bufs_copy[MSL_SIZES_SLOT] = smtl;
                                if (buf_count <= MSL_SIZES_SLOT) buf_count = MSL_SIZES_SLOT + 1;
                            }
                        }
                        const repeat_count = if (d.repeat_count == 0) 1 else d.repeat_count;
                        var repeat_index: u32 = 0;
                        while (repeat_index < repeat_count) : (repeat_index += 1) {
                            bridge.metal_bridge_cmd_buf_encode_compute_dispatch(
                                mtl_cmd,
                                d.pso,
                                @as(?[*]?*anyopaque, &bufs_copy),
                                buf_count,
                                d.x,
                                d.y,
                                d.z,
                                d.wg_x,
                                d.wg_y,
                                d.wg_z,
                            );
                        }
                        if (sizes_mtl) |smtl| bridge.metal_bridge_release(smtl);
                    }
                    has_gpu_work = true;
                },
                .copy_buf => |c| {
                    if (!shared.try_schedule_deferred_copy(q, c.src, c.src_off, c.dst, c.dst_off, c.size)) {
                        end_active_compute_encoder(&active_compute_encoder);
                        const src_buf = cast(DoeBuffer, c.src);
                        const dst_buf = cast(DoeBuffer, c.dst);
                        const src_mtl = if (src_buf) |src| src.mtl else c.src;
                        const dst_mtl = if (dst_buf) |dst| dst.mtl else c.dst;
                        bridge.metal_bridge_cmd_buf_encode_blit_copy(
                            mtl_cmd,
                            src_mtl,
                            @intCast(c.src_off),
                            dst_mtl,
                            @intCast(c.dst_off),
                            @intCast(c.size),
                        );
                        has_gpu_work = true;
                    }
                },
                .copy_buffer_to_texture => |c| {
                    end_active_compute_encoder(&active_compute_encoder);
                    const blit = bridge.metal_bridge_cmd_buf_blit_encoder(mtl_cmd) orelse continue;
                    bridge.metal_bridge_blit_encoder_copy_buffer_to_texture(
                        blit,
                        c.src_buffer,
                        c.src_offset,
                        c.src_bytes_per_row,
                        c.src_rows_per_image,
                        c.dst_texture,
                        c.dst_mip_level,
                        c.width,
                        c.height,
                        c.depth_or_array_layers,
                    );
                    bridge.metal_bridge_end_blit_encoding(blit);
                    has_gpu_work = true;
                },
                .copy_texture_to_buffer => |c| {
                    end_active_compute_encoder(&active_compute_encoder);
                    const blit = bridge.metal_bridge_cmd_buf_blit_encoder(mtl_cmd) orelse continue;
                    bridge.metal_bridge_blit_encoder_copy_texture_to_buffer(
                        blit,
                        c.src_texture,
                        c.src_mip_level,
                        c.dst_buffer,
                        c.dst_offset,
                        c.dst_bytes_per_row,
                        c.dst_rows_per_image,
                        c.width,
                        c.height,
                        c.depth_or_array_layers,
                    );
                    bridge.metal_bridge_end_blit_encoding(blit);
                    has_gpu_work = true;
                },
                .clear_buffer => |c| {
                    end_active_compute_encoder(&active_compute_encoder);
                    bridge.metal_bridge_cmd_buf_fill_buffer(mtl_cmd, c.buffer, c.offset, c.size);
                    has_gpu_work = true;
                },
                .copy_texture_to_texture => |c| {
                    end_active_compute_encoder(&active_compute_encoder);
                    bridge.metal_bridge_cmd_buf_copy_texture_to_texture(
                        mtl_cmd,
                        c.src_texture,
                        c.src_mip,
                        c.src_slice,
                        c.src_x,
                        c.src_y,
                        c.src_z,
                        c.dst_texture,
                        c.dst_mip,
                        c.dst_slice,
                        c.dst_x,
                        c.dst_y,
                        c.dst_z,
                        c.width,
                        c.height,
                        c.depth_or_layers,
                    );
                    has_gpu_work = true;
                },
                .dispatch_indirect => |d| {
                    end_active_compute_encoder(&active_compute_encoder);
                    var bufs_copy = d.bufs;
                    if (read_indirect_dispatch_counts(d.indirect_buf, d.offset)) |counts| {
                        bridge.metal_bridge_cmd_buf_encode_compute_dispatch(
                            mtl_cmd,
                            d.pso,
                            @as(?[*]?*anyopaque, &bufs_copy),
                            d.buf_count,
                            counts.x,
                            counts.y,
                            counts.z,
                            d.wg_x,
                            d.wg_y,
                            d.wg_z,
                        );
                    } else {
                        const indirect_buffer = cast(DoeBuffer, d.indirect_buf) orelse continue;
                        bridge.metal_bridge_cmd_buf_encode_compute_dispatch_indirect(
                            mtl_cmd,
                            d.pso,
                            @as(?[*]?*anyopaque, &bufs_copy),
                            d.buf_count,
                            indirect_buffer.mtl,
                            d.offset,
                            d.wg_x,
                            d.wg_y,
                            d.wg_z,
                        );
                    }
                    has_gpu_work = true;
                },
                .render_pass => |r| {
                    end_active_compute_encoder(&active_compute_encoder);
                    const renc = bridge.metal_bridge_cmd_buf_render_encoder(
                        mtl_cmd,
                        r.pso,
                        r.target,
                        r.depth_target,
                        if (r.depth_write_enabled) 1 else 0,
                        r.clear_r,
                        r.clear_g,
                        r.clear_b,
                        r.clear_a,
                    );
                    if (renc) |e| {
                        bridge.metal_bridge_render_encoder_set_front_facing(e, r.front_face);
                        bridge.metal_bridge_render_encoder_set_cull_mode(e, r.cull_mode);
                        if (r.unclipped_depth) {
                            bridge.metal_bridge_render_encoder_set_depth_clip_mode(e, 1);
                        }
                        if (r.depth_state) |depth_state| {
                            bridge.metal_bridge_render_encoder_set_depth_stencil_state(e, depth_state);
                            bridge.metal_bridge_render_encoder_set_depth_stencil_values(e, r.depth_compare, if (r.depth_write_enabled) 1 else 0);
                        }
                        for (r.bind_buffers, r.bind_buffer_offsets, 0..) |maybe_buf, offset, slot| {
                            if (maybe_buf) |buf| {
                                bridge.metal_bridge_render_encoder_set_bind_buffer(e, @intCast(slot), buf, offset);
                            }
                        }
                        for (r.bind_textures, 0..) |maybe_tex, slot| {
                            if (maybe_tex) |tex| {
                                bridge.metal_bridge_render_encoder_set_bind_texture(e, @intCast(slot), tex);
                            }
                        }
                        for (r.bind_samplers, 0..) |maybe_sampler, slot| {
                            if (maybe_sampler) |sampler| {
                                bridge.metal_bridge_render_encoder_set_bind_sampler(e, @intCast(slot), sampler);
                            }
                        }
                        for (r.vertex_buffers, r.vertex_buffer_offsets, 0..) |maybe_buf, offset, slot| {
                            if (maybe_buf) |buf| {
                                bridge.metal_bridge_render_encoder_set_vertex_buffer(e, VERTEX_BUFFER_SLOT_BASE + @as(u32, @intCast(slot)), buf, offset);
                            }
                        }
                        if (r.indirect) {
                            if (r.indexed) {
                                bridge.metal_bridge_render_encoder_draw_indexed_indirect(
                                    e,
                                    r.index_buffer,
                                    r.index_offset,
                                    r.index_format,
                                    r.indirect_buffer,
                                    r.indirect_offset,
                                );
                            } else {
                                bridge.metal_bridge_render_encoder_draw_indirect(
                                    e,
                                    r.indirect_buffer,
                                    r.indirect_offset,
                                );
                            }
                        } else if (r.indexed) {
                            bridge.metal_bridge_render_encoder_draw_indexed(
                                e,
                                r.topology,
                                r.draw_count,
                                r.index_count,
                                r.instance_count,
                                r.index_buffer,
                                r.index_offset,
                                r.index_format,
                                r.base_vertex,
                                r.first_instance,
                            );
                        } else {
                            bridge.metal_bridge_render_encoder_draw(
                                e,
                                r.topology,
                                r.draw_count,
                                r.vertex_count,
                                r.instance_count,
                                r.first_vertex,
                                r.first_instance,
                                0,
                                r.pso,
                            );
                        }
                        bridge.metal_bridge_render_encoder_end(e);
                        bridge.metal_bridge_release(e);
                    }
                    has_gpu_work = true;
                },
                .write_timestamp => |ts| {
                    end_active_compute_encoder(&active_compute_encoder);
                    bridge.metal_bridge_sample_timestamp(mtl_cmd, ts.counter_buffer, ts.query_index);
                    has_gpu_work = true;
                },
                .resolve_query_set => |rs| {
                    end_active_compute_encoder(&active_compute_encoder);
                    if (q.deferred_resolve_count < MAX_DEFERRED_RESOLVES) {
                        q.deferred_resolves[q.deferred_resolve_count] = .{
                            .counter_buffer = rs.counter_buffer,
                            .first_query = rs.first_query,
                            .query_count = rs.query_count,
                            .dst_mtl = rs.dst_mtl,
                            .dst_offset = rs.dst_offset,
                        };
                        q.deferred_resolve_count += 1;
                    }
                    has_gpu_work = true;
                },
            }
            cmd_index += 1;
        }
    }

    end_active_compute_encoder(&active_compute_encoder);
    if (has_gpu_work) {
        q.event_counter += 1;
        if (q.mtl_event) |event| {
            bridge.metal_bridge_command_buffer_encode_signal_event(mtl_cmd, event, q.event_counter);
        }
        const command_encode_ns = if (trace_enabled)
            metal_browser_trace.elapsedSince(encode_started_ns)
        else
            0;
        const commit_started_ns = if (trace_enabled) metal_browser_trace.nowNs() else 0;
        bridge.metal_bridge_command_buffer_commit(mtl_cmd);
        const command_commit_ns = if (trace_enabled)
            metal_browser_trace.elapsedSince(commit_started_ns)
        else
            0;
        if (trace_enabled) {
            var source_command_buffer_count: usize = 0;
            var recorded_command_count: usize = 0;
            for (cmd_bufs[0..count]) |raw| {
                const cb = cast(DoeCommandBuffer, raw) orelse continue;
                source_command_buffer_count += 1;
                recorded_command_count += cb.cmds.items.len;
            }
            metal_browser_trace.recordSubmission(
                source_command_buffer_count,
                recorded_command_count,
                command_buffer_create_ns,
                command_encode_ns,
                command_commit_ns,
            );
        }
        shared.finalize_submitted_metal_command_buffer(q, mtl_cmd);
    } else {
        bridge.metal_bridge_release(mtl_cmd);
        queue_flush_breakdown.executeDeferredCopies(q);
    }
}
