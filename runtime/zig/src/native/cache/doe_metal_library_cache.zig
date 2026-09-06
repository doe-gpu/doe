//! Device-owned Metal libraries. Every cache hit acquires an independent lease.
const std = @import("std");
const translation = @import("../../compiler/wgsl/runtime/runtime_translation_info.zig");

const MAX_ENTRIES: usize = 64;
pub const LibraryOps = struct {
    retain: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    release: *const fn (?*anyopaque) callconv(.c) void,
};
const Entry = struct {
    source: []const u8,
    configuration: [32]u8,
    library: *anyopaque,
    info: translation.TranslationInfo,
};
pub const Lease = struct {
    library: *anyopaque,
    info: translation.TranslationInfo,
    pub fn deinit(self: *Lease, allocator: std.mem.Allocator, ops: LibraryOps) void {
        ops.release(self.library);
        self.info.deinit(allocator);
    }
};
pub const Cache = struct {
    mutex: std.Thread.Mutex = .{},
    entries: [MAX_ENTRIES]Entry = undefined,
    count: usize = 0,
    ops: LibraryOps,

    pub fn lookup(self: *Cache, allocator: std.mem.Allocator, source: []const u8, configuration: [32]u8) error{OutOfMemory}!?Lease {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries[0..self.count]) |entry| {
            if (!std.mem.eql(u8, &entry.configuration, &configuration) or !std.mem.eql(u8, entry.source, source)) continue;
            var info = try entry.info.clone(allocator);
            errdefer info.deinit(allocator);
            const library = self.ops.retain(entry.library) orelse return error.OutOfMemory;
            return .{ .library = library, .info = info };
        }
        return null;
    }

    /// A full cache declines admission; compilation remains a valid uncached path.
    pub fn insert(self: *Cache, allocator: std.mem.Allocator, source: []const u8, configuration: [32]u8, library: *anyopaque, info: *const translation.TranslationInfo) error{OutOfMemory}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries[0..self.count]) |entry| {
            if (std.mem.eql(u8, &entry.configuration, &configuration) and std.mem.eql(u8, entry.source, source)) return;
        }
        if (self.count == MAX_ENTRIES) return;
        const owned_source = try allocator.dupe(u8, source);
        errdefer allocator.free(owned_source);
        var owned_info = try info.clone(allocator);
        errdefer owned_info.deinit(allocator);
        const retained = self.ops.retain(library) orelse return error.OutOfMemory;
        self.entries[self.count] = .{ .source = owned_source, .configuration = configuration, .library = retained, .info = owned_info };
        self.count += 1;
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries[0..self.count]) |*entry| {
            self.ops.release(entry.library);
            entry.info.deinit(allocator);
            allocator.free(entry.source);
        }
        self.count = 0;
    }
};

const TestLibrary = struct {
    references: std.atomic.Value(u32) = .init(1),
    fn retain(raw: ?*anyopaque) callconv(.c) ?*anyopaque {
        const lib: *TestLibrary = @ptrCast(@alignCast(raw.?));
        _ = lib.references.fetchAdd(1, .monotonic);
        return raw;
    }
    fn release(raw: ?*anyopaque) callconv(.c) void {
        const lib: *TestLibrary = @ptrCast(@alignCast(raw.?));
        _ = lib.references.fetchSub(1, .monotonic);
    }
    const ops = LibraryOps{ .retain = retain, .release = release };
};
const ir = @import("../../compiler/wgsl/ir/ir.zig");
const TEST_DISPATCH = [_]ir.DispatchPrecondition{.{ .gid_axis = 0, .storage_binding = .{ .group = 0, .binding = 1 }, .element_stride_bytes = 4 }};
const TEST_TEXTURE = [_]ir.TextureDispatchPrecondition{.{ .texture_binding = .{ .group = 0, .binding = 2 } }};
const TEST_INFO = translation.TranslationInfo{ .dispatch_preconditions = &TEST_DISPATCH, .texture_dispatch_preconditions = &TEST_TEXTURE };
const TEST_CONFIG = [_]u8{0} ** 32;

fn cacheAllocationFailures(allocator: std.mem.Allocator) !void {
    var library = TestLibrary{};
    defer std.debug.assert(library.references.load(.monotonic) == 1);
    var cache = Cache{ .ops = TestLibrary.ops };
    defer cache.deinit(allocator);
    try cache.insert(allocator, "source", TEST_CONFIG, &library, &TEST_INFO);
    var lease = (try cache.lookup(allocator, "source", TEST_CONFIG)).?;
    defer lease.deinit(allocator, cache.ops);
    try std.testing.expectEqual(@as(usize, 1), lease.info.dispatch_preconditions.len);
    try std.testing.expectEqual(@as(usize, 1), lease.info.texture_dispatch_preconditions.len);
}

test "Metal library cache rolls back each source and metadata allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cacheAllocationFailures, .{});
}

test "Metal library leases outlive their device cache and cannot cross device or configuration" {
    const allocator = std.testing.allocator;
    var first = Cache{ .ops = TestLibrary.ops };
    defer first.deinit(allocator);
    var second = Cache{ .ops = TestLibrary.ops };
    defer second.deinit(allocator);
    var first_library = TestLibrary{};
    var second_library = TestLibrary{};
    try first.insert(allocator, "source", TEST_CONFIG, &first_library, &TEST_INFO);
    try std.testing.expectEqual(@as(?Lease, null), try second.lookup(allocator, "source", TEST_CONFIG));
    try second.insert(allocator, "source", TEST_CONFIG, &second_library, &TEST_INFO);
    const changed = [_]u8{1} ** 32;
    try std.testing.expectEqual(@as(?Lease, null), try first.lookup(allocator, "source", changed));
    try std.testing.expectEqual(@as(?Lease, null), try first.lookup(allocator, "changed", TEST_CONFIG));
    var lease = (try first.lookup(allocator, "source", TEST_CONFIG)).?;
    first.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 2), first_library.references.load(.monotonic));
    try std.testing.expectEqual(TEST_TEXTURE[0], lease.info.texture_dispatch_preconditions[0]);
    var other = (try second.lookup(allocator, "source", TEST_CONFIG)).?;
    try std.testing.expect(lease.library != other.library);
    lease.deinit(allocator, first.ops);
    other.deinit(allocator, second.ops);
    try std.testing.expectEqual(@as(u32, 1), first_library.references.load(.monotonic));
}

const CacheThread = struct {
    cache: *Cache,
    library: *TestLibrary,
    failure: ?anyerror = null,
    fn run(self: *CacheThread) void {
        self.exercise() catch |err| {
            self.failure = err;
        };
    }
    fn exercise(self: *CacheThread) !void {
        for (0..32) |_| {
            try self.cache.insert(std.heap.page_allocator, "concurrent", TEST_CONFIG, self.library, &TEST_INFO);
            var lease = (try self.cache.lookup(std.heap.page_allocator, "concurrent", TEST_CONFIG)).?;
            lease.deinit(std.heap.page_allocator, self.cache.ops);
        }
    }
};

test "concurrent cache publication retains one entry and independent leases" {
    var cache = Cache{ .ops = TestLibrary.ops };
    defer cache.deinit(std.heap.page_allocator);
    var library = TestLibrary{};
    var workers = [_]CacheThread{ .{ .cache = &cache, .library = &library }, .{ .cache = &cache, .library = &library } };
    {
        const first = try std.Thread.spawn(.{}, CacheThread.run, .{&workers[0]});
        defer first.join();
        const second = try std.Thread.spawn(.{}, CacheThread.run, .{&workers[1]});
        defer second.join();
    }
    for (workers) |worker| if (worker.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 1), cache.count);
    try std.testing.expectEqual(@as(u32, 2), library.references.load(.monotonic));
}
