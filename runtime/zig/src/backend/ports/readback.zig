//! Narrow outbound port interface for memory readback and buffer capture.

const std = @import("std");

pub const ReadbackPortVTable = struct {
    capture_buffer: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8,
};

pub const ReadbackPort = struct {
    context: *anyopaque,
    vtable: *const ReadbackPortVTable,

    pub fn captureBuffer(self: ReadbackPort, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) ![]u8 {
        return self.vtable.capture_buffer(self.context, allocator, handle, offset, size);
    }
};
