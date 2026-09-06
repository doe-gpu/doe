
var test_allocator: std.mem.Allocator = undefined;
const FAULT_STEPS = 12;
const MAX_FREED_BLOCKS = 64;

const FreedStorage = struct {
    backing: std.mem.Allocator,
    freed: [MAX_FREED_BLOCKS]struct { start: usize, end: usize } = undefined,
    count: usize = 0,

    fn allocator(self: *FreedStorage) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *FreedStorage = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *FreedStorage = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *FreedStorage = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *FreedStorage = @ptrCast(@alignCast(ctx));
        self.freed[self.count] = .{ .start = @intFromPtr(memory.ptr), .end = @intFromPtr(memory.ptr) + memory.len };
        self.count += 1;
        self.backing.rawFree(memory, alignment, ra);
    }

    fn containsReleased(self: *const FreedStorage, bytes: []const u8) bool {
        const address = @intFromPtr(bytes.ptr);
        for (self.freed[0..self.count]) |block| {
            if (address >= block.start and address < block.end) return true;
        }
        return false;
    }
};

test "allocation fault does not publish strings from released parser storage" {
    var dangling = false;
    for (0..FAULT_STEPS) |fail_index| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var storage = FreedStorage{ .backing = arena.allocator() };
        var failing = std.testing.FailingAllocator.init(storage.allocator(), .{ .fail_index = fail_index });
        test_allocator = failing.allocator();
        if (@hasDecl(@This(), "g_ready")) {
            @field(@This(), "g_ready").store(0, .release);
            @field(@This(), "g_registry") = &.{};
        }
        const result = lookup("escaped_name");
        const released = if (result) |entry|
            storage.containsReleased(entry.toggle_name) or storage.containsReleased(entry.description)
        else
            false;
        dangling = dangling or released;
        std.debug.print("fault\t{d}\t{}\t{}\t{d}\n", .{ fail_index, result != null, released, failing.allocations });
    }
    try std.testing.expect(!dangling);
}
