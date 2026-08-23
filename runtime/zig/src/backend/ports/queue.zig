//! Narrow outbound port interface for queue submission and synchronization.

const std = @import("std");
const configuration = @import("../../contracts/runtime_configuration.zig");

pub const QueuePortVTable = struct {
    flush: *const fn (ctx: *anyopaque) anyerror!u64,
    sync: *const fn (ctx: *anyopaque) anyerror!void,
    set_wait_mode: *const fn (ctx: *anyopaque, mode: configuration.QueueWaitMode) void,
    set_wait_timeout_ns: *const fn (ctx: *anyopaque, timeout_ns: u64) void,
    set_sync_mode: *const fn (ctx: *anyopaque, mode: configuration.QueueSyncMode) void,
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

    pub fn setWaitMode(self: QueuePort, mode: configuration.QueueWaitMode) void {
        self.vtable.set_wait_mode(self.context, mode);
    }

    pub fn setWaitTimeoutNs(self: QueuePort, timeout_ns: u64) void {
        self.vtable.set_wait_timeout_ns(self.context, timeout_ns);
    }

    pub fn setSyncMode(self: QueuePort, mode: configuration.QueueSyncMode) void {
        self.vtable.set_sync_mode(self.context, mode);
    }
};
