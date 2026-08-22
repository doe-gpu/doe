//! Narrow outbound port interface for queue submission and synchronization.

const std = @import("std");

pub const QueuePortVTable = struct {
    flush: *const fn (ctx: *anyopaque) anyerror!u64,
    sync: *const fn (ctx: *anyopaque) anyerror!void,
};

pub const QueuePort = struct {
    context: *anyopaque,
    vtable: *const QueuePortVTable,

    pub fn flush(self: QueuePort) !u64 {
        return self.vtable.flush(self.context);
    }

    pub fn sync(self: QueuePort) !void {
        return self.vtable.sync(self.context);
    }
};
