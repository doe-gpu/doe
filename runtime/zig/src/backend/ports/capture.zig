//! Outbound port interface for diagnostic buffer and texture memory capture.

const std = @import("std");

pub const CapturePortVTable = struct {
    capture_buffer: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8,
    capture_texture_2d: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, mip_level: u32, layer: u32) anyerror![]u8,
};

pub const CapturePort = struct {
    context: *anyopaque,
    vtable: *const CapturePortVTable,

    pub fn captureBuffer(self: CapturePort, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) ![]u8 {
        return self.vtable.capture_buffer(self.context, allocator, handle, offset, size);
    }

    pub fn captureTexture2d(self: CapturePort, allocator: std.mem.Allocator, handle: u64, mip_level: u32, layer: u32) ![]u8 {
        return self.vtable.capture_texture_2d(self.context, allocator, handle, mip_level, layer);
    }
};
