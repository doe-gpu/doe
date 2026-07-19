const std = @import("std");

pub const IoMode = enum {
    sync,
    cooperative_same_thread,
    threaded_parallel,
};

pub const IoContext = struct {
    mode: IoMode,

    pub fn sync() IoContext {
        return .{ .mode = .sync };
    }

    pub fn cooperativeSameThread() IoContext {
        return .{ .mode = .cooperative_same_thread };
    }

    pub fn threadedParallel() IoContext {
        return .{ .mode = .threaded_parallel };
    }

    pub fn modeName(self: IoContext) []const u8 {
        return @tagName(self.mode);
    }

    pub fn readFileAlloc(self: IoContext, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
        _ = self;
        return std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
    }

    pub fn ensureParentDir(self: IoContext, path: []const u8) !void {
        _ = self;
        const dir_name = std.fs.path.dirname(path) orelse return;
        if (dir_name.len == 0) return;
        try std.fs.cwd().makePath(dir_name);
    }

    pub fn writeFileAll(self: IoContext, path: []const u8, data: []const u8) !void {
        try self.ensureParentDir(path);
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
    }
};

test "tooling io context reports explicit mode names" {
    try std.testing.expectEqualStrings("sync", IoContext.sync().modeName());
    try std.testing.expectEqualStrings("cooperative_same_thread", IoContext.cooperativeSameThread().modeName());
    try std.testing.expectEqualStrings("threaded_parallel", IoContext.threadedParallel().modeName());
}
