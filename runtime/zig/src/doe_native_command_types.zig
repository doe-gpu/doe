const std = @import("std");
const shared = @import("doe_native_shared_types.zig");
const model_compute_types = @import("model_compute_types.zig");

pub const DeferredCopy = struct {
    src: [*]const u8,
    dst: [*]u8,
    size: usize,
};

pub const MAX_DEFERRED_COPIES: u32 = 16;

pub const MAX_DEFERRED_RELEASES: u32 = 64;

pub const DeferredResolve = struct {
    counter_buffer: ?*anyopaque,
    first_query: u32,
    query_count: u32,
    dst_mtl: ?*anyopaque,
    dst_offset: u64,
};

pub const MAX_DEFERRED_RESOLVES: u32 = 8;

pub const RecordedVulkanBindingState = struct {
    valid: bool = false,
    count: usize = 0,
    flat_mask: u64 = 0,
    descriptor_hash: u64 = 0,
    bindings: [shared.MAX_FLAT_BIND]model_compute_types.KernelBinding = undefined,
};

pub const CmdTag = enum {
    dispatch,
    dispatch_indirect,
    copy_buf,
    copy_buffer_to_texture,
    copy_texture_to_buffer,
    clear_buffer,
    copy_texture_to_texture,
    render_pass,
    write_timestamp,
    resolve_query_set,
};

pub const TimestampWritePosition = enum {
    command,
    pass_begin,
    pass_end,
};

pub const RecordedCmd = union(CmdTag) {
    dispatch: struct {
        compute_pipeline: ?*anyopaque = null,
        pso: ?*anyopaque,
        needs_sizes_buf: bool,
        bufs: [shared.MAX_FLAT_BIND]?*anyopaque,
        buf_offsets: [shared.MAX_FLAT_BIND]u64,
        buf_sizes: [shared.MAX_FLAT_BIND]u64,
        buf_count: u32,
        vulkan_binding_state: RecordedVulkanBindingState = .{},
        bind_groups: [shared.MAX_COMPUTE_BIND_GROUPS]?*anyopaque = [_]?*anyopaque{null} ** shared.MAX_COMPUTE_BIND_GROUPS,
        x: u32,
        y: u32,
        z: u32,
        wg_x: u32,
        wg_y: u32,
        wg_z: u32,
        repeat_count: u32 = 1,
    },
    dispatch_indirect: struct {
        compute_pipeline: ?*anyopaque = null,
        pso: ?*anyopaque,
        needs_sizes_buf: bool,
        bufs: [shared.MAX_FLAT_BIND]?*anyopaque,
        buf_offsets: [shared.MAX_FLAT_BIND]u64,
        buf_sizes: [shared.MAX_FLAT_BIND]u64,
        buf_count: u32,
        vulkan_binding_state: RecordedVulkanBindingState = .{},
        indirect_buf: ?*anyopaque,
        offset: u64,
        wg_x: u32 = 0,
        wg_y: u32 = 0,
        wg_z: u32 = 0,
    },
    copy_buf: struct {
        src: ?*anyopaque,
        src_off: u64,
        dst: ?*anyopaque,
        dst_off: u64,
        size: u64,
    },
    copy_buffer_to_texture: struct {
        src_buffer: ?*anyopaque,
        src_offset: u64,
        src_bytes_per_row: u32,
        src_rows_per_image: u32,
        dst_texture: ?*anyopaque,
        dst_mip_level: u32,
        width: u32,
        height: u32,
        depth_or_array_layers: u32,
    },
    copy_texture_to_buffer: struct {
        src_texture: ?*anyopaque,
        src_mip_level: u32,
        dst_buffer: ?*anyopaque,
        dst_offset: u64,
        dst_bytes_per_row: u32,
        dst_rows_per_image: u32,
        width: u32,
        height: u32,
        depth_or_array_layers: u32,
    },
    clear_buffer: struct {
        buffer: ?*anyopaque,
        offset: u64,
        size: u64,
    },
    copy_texture_to_texture: struct {
        src_texture: ?*anyopaque,
        src_mip: u32,
        src_slice: u32,
        src_x: u32,
        src_y: u32,
        src_z: u32,
        dst_texture: ?*anyopaque,
        dst_mip: u32,
        dst_slice: u32,
        dst_x: u32,
        dst_y: u32,
        dst_z: u32,
        width: u32,
        height: u32,
        depth_or_layers: u32,
    },
    render_pass: struct {
        pso: ?*anyopaque,
        root_signature: ?*anyopaque = null,
        depth_state: ?*anyopaque,
        target: ?*anyopaque,
        resolve_target: ?*anyopaque = null,
        depth_target: ?*anyopaque,
        target_view_handle: u64 = 0,
        resolve_target_view_handle: u64 = 0,
        depth_target_view_handle: u64 = 0,
        target_format: u32 = 0,
        depth_stencil_format: u32 = 0,
        sample_count: u32 = 1,
        depth_slice: u32 = 0,
        depth_read_only: bool = false,
        stencil_read_only: bool = false,
        topology: u32,
        front_face: u32,
        cull_mode: u32,
        draw_count: u32,
        vertex_count: u32,
        instance_count: u32,
        first_vertex: u32,
        first_instance: u32,
        indexed: bool = false,
        index_buffer: ?*anyopaque = null,
        index_offset: u64 = 0,
        index_format: u32 = 0,
        index_buffer_size: u64 = 0,
        index_count: u32 = 0,
        first_index: u32 = 0,
        base_vertex: i32 = 0,
        bind_buffers: [shared.MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** shared.MAX_FLAT_BIND,
        bind_buffer_offsets: [shared.MAX_FLAT_BIND]u64 = [_]u64{0} ** shared.MAX_FLAT_BIND,
        bind_textures: [shared.MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** shared.MAX_FLAT_BIND,
        bind_samplers: [shared.MAX_FLAT_BIND]?*anyopaque = [_]?*anyopaque{null} ** shared.MAX_FLAT_BIND,
        vertex_buffers: [shared.MAX_VERTEX_BUFFERS]?*anyopaque = [_]?*anyopaque{null} ** shared.MAX_VERTEX_BUFFERS,
        vertex_buffer_offsets: [shared.MAX_VERTEX_BUFFERS]u64 = [_]u64{0} ** shared.MAX_VERTEX_BUFFERS,
        vertex_buffer_sizes: [shared.MAX_VERTEX_BUFFERS]u64 = [_]u64{0} ** shared.MAX_VERTEX_BUFFERS,
        indirect: bool = false,
        indirect_buffer: ?*anyopaque = null,
        indirect_offset: u64 = 0,
        blend_constant: [4]f32 = .{ 0, 0, 0, 0 },
        stencil_reference: u32 = 0,
        depth_compare: u32 = 0,
        depth_write_enabled: bool = false,
        unclipped_depth: bool = false,
        clear_r: f64 = 0,
        clear_g: f64 = 0,
        clear_b: f64 = 0,
        clear_a: f64 = 1,
    },
    write_timestamp: struct {
        counter_buffer: ?*anyopaque,
        query_set: ?*anyopaque = null,
        query_index: u32,
        position: TimestampWritePosition = .command,
    },
    resolve_query_set: struct {
        counter_buffer: ?*anyopaque,
        query_set: ?*anyopaque = null,
        first_query: u32,
        query_count: u32,
        dst_mtl: ?*anyopaque,
        dst_buffer: ?*anyopaque = null,
        dst_offset: u64,
    },
};

pub const RecordedDispatch = std.meta.TagPayload(RecordedCmd, .dispatch);

pub fn dispatchesCanMerge(left: *const RecordedDispatch, right: *const RecordedDispatch) bool {
    if (left.compute_pipeline != right.compute_pipeline) return false;
    if (left.pso != right.pso) return false;
    if (left.needs_sizes_buf != right.needs_sizes_buf) return false;
    if (left.buf_count != right.buf_count) return false;
    if (left.x != right.x or left.y != right.y or left.z != right.z) return false;
    if (left.wg_x != right.wg_x or left.wg_y != right.wg_y or left.wg_z != right.wg_z) return false;

    const count: usize = @intCast(left.buf_count);
    return std.mem.eql(?*anyopaque, left.bufs[0..count], right.bufs[0..count]) and
        std.mem.eql(u64, left.buf_offsets[0..count], right.buf_offsets[0..count]) and
        std.mem.eql(u64, left.buf_sizes[0..count], right.buf_sizes[0..count]);
}

pub fn tryMergeDispatchIntoLast(cmds: *std.ArrayListUnmanaged(RecordedCmd), cmd: *const RecordedCmd) bool {
    if (cmds.items.len == 0) return false;
    const right = switch (cmd.*) {
        .dispatch => |dispatch| dispatch,
        else => return false,
    };
    const last = &cmds.items[cmds.items.len - 1];
    switch (last.*) {
        .dispatch => |*left| {
            if (!dispatchesCanMerge(left, &right)) return false;
            const left_repeat = if (left.repeat_count == 0) 1 else left.repeat_count;
            const right_repeat = if (right.repeat_count == 0) 1 else right.repeat_count;
            left.repeat_count = std.math.add(u32, left_repeat, right_repeat) catch return false;
            return true;
        },
        else => return false,
    }
}

test "tryMergeDispatchIntoLast coalesces identical dispatch commands" {
    var cmds: std.ArrayListUnmanaged(RecordedCmd) = .{};
    defer cmds.deinit(std.testing.allocator);

    var first = RecordedCmd{ .dispatch = .{
        .compute_pipeline = @ptrFromInt(0x1000),
        .pso = @ptrFromInt(0x2000),
        .needs_sizes_buf = false,
        .bufs = [_]?*anyopaque{null} ** shared.MAX_FLAT_BIND,
        .buf_offsets = [_]u64{0} ** shared.MAX_FLAT_BIND,
        .buf_sizes = [_]u64{0} ** shared.MAX_FLAT_BIND,
        .buf_count = 1,
        .x = 1,
        .y = 1,
        .z = 1,
        .wg_x = 256,
        .wg_y = 1,
        .wg_z = 1,
    } };
    first.dispatch.bufs[0] = @ptrFromInt(0x3000);
    first.dispatch.buf_sizes[0] = 8192;
    var second = first;

    try cmds.append(std.testing.allocator, first);
    try std.testing.expect(tryMergeDispatchIntoLast(&cmds, &second));
    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqual(@as(u32, 2), cmds.items[0].dispatch.repeat_count);
}
