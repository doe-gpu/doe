const std = @import("std");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const abi_core = @import("../../core/abi/wgpu_core_base_types.zig");
const resources = @import("../../core/resource/wgpu_resources.zig");

pub const DEFAULT_INDEX_BUFFER_HANDLE: u64 = 0x8C9F_2700_0000_0000;
pub const INDEX_FORMAT_UINT16: u32 = 0x00000001;
pub const INDEX_FORMAT_UINT32: u32 = 0x00000002;

pub const PreparedIndexBuffer = struct {
    buffer: abi_core.WGPUBuffer,
    format: u32,
};

pub fn prepareIndexBuffer(self: anytype, render: model_render_types.RenderDrawCommand) !?PreparedIndexBuffer {
    const requested_count = render.index_count orelse return null;
    if (requested_count == 0) return error.InvalidIndexedDrawData;

    const index_data = render.index_data orelse return error.InvalidIndexedDrawData;
    const index_usage = abi_core.WGPUBufferUsage_Index | abi_core.WGPUBufferUsage_CopyDst;
    const Selected = struct {
        format: u32,
        bytes: []const u8,

        fn from(values: anytype, first_index: u32, count: u32, format: u32) !@This() {
            const total_count = std.math.cast(u32, values.len) orelse return error.InvalidIndexedDrawData;
            const end = std.math.add(u32, first_index, count) catch return error.InvalidIndexedDrawData;
            if (end > total_count) return error.InvalidIndexedDrawData;
            return .{ .format = format, .bytes = std.mem.sliceAsBytes(values) };
        }
    };
    const selected: Selected = switch (index_data) {
        .uint16 => |values| try Selected.from(values, render.first_index, requested_count, INDEX_FORMAT_UINT16),
        .uint32 => |values| try Selected.from(values, render.first_index, requested_count, INDEX_FORMAT_UINT32),
    };

    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const requested_size = std.math.cast(u64, selected.bytes.len) orelse return error.InvalidIndexedDrawData;
    const aligned_size = try resources.requiredBytes(requested_size, 0);
    const index_buffer = try resources.getOrCreateBuffer(
        self,
        DEFAULT_INDEX_BUFFER_HANDLE,
        aligned_size,
        index_usage,
    );
    if ((selected.bytes.len & 3) == 0) {
        procs.wgpuQueueWriteBuffer(
            self.core.queue.?,
            index_buffer,
            0,
            selected.bytes.ptr,
            selected.bytes.len,
        );
    } else {
        const aligned_len = std.math.cast(usize, aligned_size) orelse return error.InvalidIndexedDrawData;
        const padded = try self.core.allocator.alloc(u8, aligned_len);
        defer self.core.allocator.free(padded);
        @memset(padded, 0);
        @memcpy(padded[0..selected.bytes.len], selected.bytes);
        procs.wgpuQueueWriteBuffer(
            self.core.queue.?,
            index_buffer,
            0,
            padded.ptr,
            padded.len,
        );
    }
    return .{
        .buffer = index_buffer,
        .format = selected.format,
    };
}
