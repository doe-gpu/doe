const std = @import("std");
const queue_submit_ops = @import("../../backend/dropin_queue_submit.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_cmds = @import("../support/doe_native_command_types.zig");
const compute_bind_groups = @import("../compute/doe_compute_bind_groups.zig");
const queue_flush_breakdown = @import("doe_queue_flush_breakdown.zig");
const metal_browser_trace = @import("../diagnostics/doe_metal_browser_trace.zig");
const emit_msl = @import("../../compiler/wgsl/emit/msl/emit_msl_ir.zig");
const shared = @import("doe_queue_submit_shared.zig");
const render_state_native = @import("../render/doe_render_state_native.zig");

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

fn recordedDispatchResources(bind_groups: [native_shared.MAX_COMPUTE_BIND_GROUPS]?*anyopaque) compute_bind_groups.FlatResources {
    return compute_bind_groups.collectFlatResourcesFromRaw(
        @as([*]const ?*anyopaque, @ptrCast(&bind_groups)),
        native_shared.MAX_COMPUTE_BIND_GROUPS,
    );
}

fn recordedDispatchHasNonBufferResources(bind_groups: [native_shared.MAX_COMPUTE_BIND_GROUPS]?*anyopaque) bool {
    const resources = recordedDispatchResources(bind_groups);
    return resources.hasNonBufferResources();
}

fn bindRecordedDispatchResources(
    encoder: ?*anyopaque,
    bind_groups: [native_shared.MAX_COMPUTE_BIND_GROUPS]?*anyopaque,
) void {
    var resources = recordedDispatchResources(bind_groups);
    if (!resources.hasNonBufferResources()) return;
    bridge.metal_bridge_compute_encoder_bind_resources(
        encoder,
        @as(?[*]?*anyopaque, &resources.textures),
        resources.texture_count,
        @as(?[*]?*anyopaque, &resources.samplers),
        resources.sampler_count,
    );
}

fn submittedBuffersHaveRecordedCommands(count: usize, cmd_bufs: [*]const ?*anyopaque) bool {
    for (cmd_bufs[0..count]) |raw| {
        const cb = cast(DoeCommandBuffer, raw) orelse continue;
        if (cb.cmds.items.len != 0) return true;
    }
    return false;
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

const MetalRenderStateCache = struct {
    pipeline: ?*anyopaque = null,
    front_face: ?u32 = null,
    cull_mode: ?u32 = null,
    depth_state: ?*anyopaque = null,
    unclipped_depth: bool = false,
    viewport_x: f32 = 0,
    viewport_y: f32 = 0,
    viewport_width: ?f32 = null,
    viewport_height: ?f32 = null,
    viewport_min_depth: f32 = 0,
    viewport_max_depth: f32 = 1,
    scissor_x: u32 = 0,
    scissor_y: u32 = 0,
    scissor_width: ?u32 = null,
    scissor_height: ?u32 = null,
    blend_constant: [4]f32 = .{ 0, 0, 0, 0 },
    stencil_reference: u32 = 0,
    bind_buffers: [MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** MAX_FLAT_BIND,
    bind_buffer_offsets: [MAX_FLAT_BIND]u64 = [_]u64{0} ** MAX_FLAT_BIND,
    bind_textures: [MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** MAX_FLAT_BIND,
    bind_samplers: [MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** MAX_FLAT_BIND,
    vertex_buffers: [native_shared.MAX_VERTEX_BUFFERS]?*anyopaque = [_]?*anyopaque{null} ** native_shared.MAX_VERTEX_BUFFERS,
    vertex_buffer_offsets: [native_shared.MAX_VERTEX_BUFFERS]u64 = [_]u64{0} ** native_shared.MAX_VERTEX_BUFFERS,
};

fn end_active_render_encoder(active_render_encoder: *?*anyopaque, state: *MetalRenderStateCache) void {
    if (active_render_encoder.*) |encoder| {
        bridge.metal_bridge_render_encoder_end(encoder);
        bridge.metal_bridge_release(encoder);
        active_render_encoder.* = null;
    }
    state.* = .{};
}

fn apply_render_state(
    encoder: ?*anyopaque,
    state: *MetalRenderStateCache,
    cmd: *const native_cmds.RecordedRender,
) void {
    if (state.pipeline != cmd.pso) {
        bridge.metal_bridge_render_encoder_set_pipeline(encoder, cmd.pso);
        state.pipeline = cmd.pso;
    }
    if (state.front_face == null or state.front_face.? != cmd.front_face) {
        bridge.metal_bridge_render_encoder_set_front_facing(encoder, cmd.front_face);
        state.front_face = cmd.front_face;
    }
    if (state.cull_mode == null or state.cull_mode.? != cmd.cull_mode) {
        bridge.metal_bridge_render_encoder_set_cull_mode(encoder, cmd.cull_mode);
        state.cull_mode = cmd.cull_mode;
    }
    if (state.unclipped_depth != cmd.unclipped_depth) {
        bridge.metal_bridge_render_encoder_set_depth_clip_mode(encoder, @intFromBool(cmd.unclipped_depth));
        state.unclipped_depth = cmd.unclipped_depth;
    }
    if (state.depth_state != cmd.depth_state) {
        bridge.metal_bridge_render_encoder_set_depth_stencil_state(encoder, cmd.depth_state);
        state.depth_state = cmd.depth_state;
    }

    for (cmd.bind_buffers, cmd.bind_buffer_offsets, 0..) |buffer, raw_offset, slot| {
        const offset = if (buffer == null) 0 else raw_offset;
        if (state.bind_buffers[slot] != buffer or state.bind_buffer_offsets[slot] != offset) {
            bridge.metal_bridge_render_encoder_set_bind_buffer(encoder, @intCast(slot), buffer, offset);
            state.bind_buffers[slot] = buffer;
            state.bind_buffer_offsets[slot] = offset;
        }
    }
    for (cmd.bind_textures, 0..) |texture, slot| {
        if (state.bind_textures[slot] != texture) {
            bridge.metal_bridge_render_encoder_set_bind_texture(encoder, @intCast(slot), texture);
            state.bind_textures[slot] = texture;
        }
    }
    for (cmd.bind_samplers, 0..) |sampler, slot| {
        if (state.bind_samplers[slot] != sampler) {
            bridge.metal_bridge_render_encoder_set_bind_sampler(encoder, @intCast(slot), sampler);
            state.bind_samplers[slot] = sampler;
        }
    }
    for (cmd.vertex_buffers, cmd.vertex_buffer_offsets, 0..) |buffer, raw_offset, slot| {
        const offset = if (buffer == null) 0 else raw_offset;
        if (state.vertex_buffers[slot] != buffer or state.vertex_buffer_offsets[slot] != offset) {
            bridge.metal_bridge_render_encoder_set_vertex_buffer(
                encoder,
                VERTEX_BUFFER_SLOT_BASE + @as(u32, @intCast(slot)),
                buffer,
                offset,
            );
            state.vertex_buffers[slot] = buffer;
            state.vertex_buffer_offsets[slot] = offset;
        }
    }

    if (cmd.viewport_width != null and cmd.viewport_height != null and
        (state.viewport_width == null or state.viewport_height == null or
            state.viewport_x != cmd.viewport_x or state.viewport_y != cmd.viewport_y or
            state.viewport_width.? != cmd.viewport_width.? or state.viewport_height.? != cmd.viewport_height.? or
            state.viewport_min_depth != cmd.viewport_min_depth or state.viewport_max_depth != cmd.viewport_max_depth))
    {
        render_state_native.doeNativeRenderPassEncoderSetViewport(
            encoder,
            cmd.viewport_x,
            cmd.viewport_y,
            cmd.viewport_width.?,
            cmd.viewport_height.?,
            cmd.viewport_min_depth,
            cmd.viewport_max_depth,
        );
        state.viewport_x = cmd.viewport_x;
        state.viewport_y = cmd.viewport_y;
        state.viewport_width = cmd.viewport_width;
        state.viewport_height = cmd.viewport_height;
        state.viewport_min_depth = cmd.viewport_min_depth;
        state.viewport_max_depth = cmd.viewport_max_depth;
    }
    if (cmd.scissor_width != null and cmd.scissor_height != null and
        (state.scissor_width == null or state.scissor_height == null or
            state.scissor_x != cmd.scissor_x or state.scissor_y != cmd.scissor_y or
            state.scissor_width.? != cmd.scissor_width.? or state.scissor_height.? != cmd.scissor_height.?))
    {
        render_state_native.doeNativeRenderPassEncoderSetScissorRect(
            encoder,
            cmd.scissor_x,
            cmd.scissor_y,
            cmd.scissor_width.?,
            cmd.scissor_height.?,
        );
        state.scissor_x = cmd.scissor_x;
        state.scissor_y = cmd.scissor_y;
        state.scissor_width = cmd.scissor_width;
        state.scissor_height = cmd.scissor_height;
    }
    if (!std.meta.eql(state.blend_constant, cmd.blend_constant)) {
        render_state_native.doeNativeRenderPassEncoderSetBlendConstant(
            encoder,
            cmd.blend_constant[0],
            cmd.blend_constant[1],
            cmd.blend_constant[2],
            cmd.blend_constant[3],
        );
        state.blend_constant = cmd.blend_constant;
    }
    if (state.stencil_reference != cmd.stencil_reference) {
        render_state_native.doeNativeRenderPassEncoderSetStencilReference(encoder, cmd.stencil_reference);
        state.stencil_reference = cmd.stencil_reference;
    }
}

const PassTimestampEnd = struct {
    command_index: usize,
    query_index: u32,
};

fn findPassTimestampEnd(
    cmds: []const native_cmds.RecordedCmd,
    begin_command_index: usize,
    counter_buffer: ?*anyopaque,
    query_set: ?*anyopaque,
) ?PassTimestampEnd {
    if (begin_command_index + 1 >= cmds.len) return null;
    for (cmds[begin_command_index + 1 ..], begin_command_index + 1..) |cmd, command_index| {
        switch (cmd) {
            .write_timestamp => |timestamp| {
                if (timestamp.position == .pass_end and
                    timestamp.counter_buffer == counter_buffer and
                    timestamp.query_set == query_set)
                {
                    return .{
                        .command_index = command_index,
                        .query_index = timestamp.query_index,
                    };
                }
            },
            else => {},
        }
    }
    return null;
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
        if (recordedDispatchHasNonBufferResources(d.bind_groups)) break;

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
    var active_render_encoder: ?*anyopaque = null;
    var active_render_state: MetalRenderStateCache = .{};
    defer end_active_compute_encoder(&active_compute_encoder);
    defer end_active_render_encoder(&active_render_encoder, &active_render_state);

    for (cmd_bufs[0..count]) |raw| {
        const cb = cast(DoeCommandBuffer, raw) orelse continue;
        var cmd_index: usize = 0;
        var active_timestamp_end_command_index: ?usize = null;
        while (cmd_index < cb.cmds.items.len) {
            const cmd = cb.cmds.items[cmd_index];
            if (std.meta.activeTag(cmd) != .render_pass) {
                end_active_render_encoder(&active_render_encoder, &active_render_state);
            }
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
                        bindRecordedDispatchResources(encoder, d.bind_groups);
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
                    var bufs_copy = d.bufs;
                    var buf_count = d.buf_count;
                    var sizes_mtl: ?*anyopaque = null;
                    if (d.needs_sizes_buf) {
                        sizes_mtl = bridge.metal_bridge_device_new_buffer_shared(
                            q.dev.mtl_device,
                            SIZES_BUF_BYTES,
                        );
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
                    if (active_compute_encoder == null) {
                        active_compute_encoder = bridge.metal_bridge_cmd_buf_compute_encoder(mtl_cmd);
                    }
                    const indirect_buffer = cast(DoeBuffer, d.indirect_buf) orelse {
                        if (sizes_mtl) |smtl| bridge.metal_bridge_release(smtl);
                        continue;
                    };
                    if (active_compute_encoder) |encoder| {
                        bindRecordedDispatchResources(encoder, d.bind_groups);
                        bridge.metal_bridge_compute_encoder_encode_dispatch_indirect(
                            encoder,
                            d.pso,
                            @as(?[*]?*anyopaque, &bufs_copy),
                            buf_count,
                            indirect_buffer.mtl,
                            d.offset,
                            d.wg_x,
                            d.wg_y,
                            d.wg_z,
                        );
                    } else {
                        std.log.err("doe: Metal compute encoder creation failed for indirect dispatch", .{});
                    }
                    if (sizes_mtl) |smtl| bridge.metal_bridge_release(smtl);
                    has_gpu_work = true;
                },
                .render_pass => |r| {
                    end_active_compute_encoder(&active_compute_encoder);
                    if (r.pass_start) {
                        end_active_render_encoder(&active_render_encoder, &active_render_state);
                    }
                    if (active_render_encoder == null) {
                        const ops = bridge.MetalRenderPassOps{
                            .color_load_op = r.color_load_op,
                            .color_store_op = r.color_store_op,
                            .depth_load_op = r.depth_load_op,
                            .depth_store_op = r.depth_store_op,
                            .stencil_load_op = r.stencil_load_op,
                            .stencil_store_op = r.stencil_store_op,
                            .depth_read_only = @intFromBool(r.depth_read_only),
                            .stencil_read_only = @intFromBool(r.stencil_read_only),
                            .clear_r = r.clear_r,
                            .clear_g = r.clear_g,
                            .clear_b = r.clear_b,
                            .clear_a = r.clear_a,
                            .depth_clear_value = r.depth_clear_value,
                            .stencil_clear_value = r.stencil_clear_value,
                        };
                        active_render_encoder = bridge.metal_bridge_cmd_buf_render_encoder(
                            mtl_cmd,
                            null,
                            r.target,
                            r.resolve_target,
                            r.depth_target,
                            &ops,
                        );
                    }
                    if (active_render_encoder) |e| {
                        if (r.draw_count > 0 and r.pso != null) {
                            apply_render_state(e, &active_render_state, &r);
                        }
                        if (r.draw_count == 0 or r.pso == null) {
                            // An empty pass still applies attachment load/store operations.
                        } else if (r.indirect) {
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
                        has_gpu_work = true;
                        if (r.pass_end) {
                            end_active_render_encoder(&active_render_encoder, &active_render_state);
                        }
                    } else {
                        std.log.err("doe: Metal render encoder creation failed", .{});
                    }
                },
                .write_timestamp => |ts| {
                    _ = bridge.metal_bridge_command_buffer_retain_object_until_complete(
                        mtl_cmd,
                        ts.counter_buffer,
                    );
                    switch (ts.position) {
                        .pass_begin => {
                            end_active_compute_encoder(&active_compute_encoder);
                            if (findPassTimestampEnd(
                                cb.cmds.items,
                                cmd_index,
                                ts.counter_buffer,
                                ts.query_set,
                            )) |timestamp_end| {
                                active_compute_encoder = bridge.metal_bridge_cmd_buf_compute_encoder_with_timestamps(
                                    mtl_cmd,
                                    ts.counter_buffer,
                                    ts.query_index,
                                    timestamp_end.query_index,
                                );
                                if (active_compute_encoder != null) {
                                    active_timestamp_end_command_index = timestamp_end.command_index;
                                } else {
                                    bridge.metal_bridge_sample_timestamp(mtl_cmd, ts.counter_buffer, ts.query_index);
                                }
                            } else {
                                bridge.metal_bridge_sample_timestamp(mtl_cmd, ts.counter_buffer, ts.query_index);
                            }
                        },
                        .pass_end => {
                            end_active_compute_encoder(&active_compute_encoder);
                            if (active_timestamp_end_command_index == cmd_index) {
                                active_timestamp_end_command_index = null;
                            } else {
                                bridge.metal_bridge_sample_timestamp(mtl_cmd, ts.counter_buffer, ts.query_index);
                            }
                        },
                        .command => {
                            end_active_compute_encoder(&active_compute_encoder);
                            bridge.metal_bridge_sample_timestamp(mtl_cmd, ts.counter_buffer, ts.query_index);
                        },
                    }
                    has_gpu_work = true;
                },
                .resolve_query_set => |rs| {
                    end_active_compute_encoder(&active_compute_encoder);
                    _ = bridge.metal_bridge_command_buffer_retain_object_until_complete(
                        mtl_cmd,
                        rs.counter_buffer,
                    );
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
    end_active_render_encoder(&active_render_encoder, &active_render_state);
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

test "compute pass timestamp markers pair by query set and counter buffer" {
    const counter_buffer: ?*anyopaque = @ptrFromInt(0x1000);
    const query_set: ?*anyopaque = @ptrFromInt(0x2000);
    const commands = [_]native_cmds.RecordedCmd{
        .{ .write_timestamp = .{
            .counter_buffer = counter_buffer,
            .query_set = query_set,
            .query_index = 3,
            .position = .pass_begin,
        } },
        .{ .write_timestamp = .{
            .counter_buffer = @ptrFromInt(0x3000),
            .query_set = query_set,
            .query_index = 4,
            .position = .pass_end,
        } },
        .{ .write_timestamp = .{
            .counter_buffer = counter_buffer,
            .query_set = query_set,
            .query_index = 5,
            .position = .pass_end,
        } },
    };

    const timestamp_end = findPassTimestampEnd(&commands, 0, counter_buffer, query_set) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), timestamp_end.command_index);
    try std.testing.expectEqual(@as(u32, 5), timestamp_end.query_index);
}
