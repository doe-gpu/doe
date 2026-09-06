const std = @import("std");
const build_options = @import("build_options");

pub const ToggleEffect = enum {
    behavioral,
    informational,
    unhandled,
};

pub const ToggleEntry = struct {
    toggle_name: []const u8,
    effect: ToggleEffect,
    description: []const u8,
};

const REGISTRY: [build_options.quirk_toggle_registry.len]ToggleEntry = blk: {
    var entries: [build_options.quirk_toggle_registry.len]ToggleEntry = undefined;
    for (build_options.quirk_toggle_registry, &entries) |source, *entry| {
        entry.* = .{
            .toggle_name = source.toggle_name,
            .effect = @field(ToggleEffect, source.effect),
            .description = source.description,
        };
    }
    break :blk entries;
};

pub fn lookup(toggle_name: []const u8) ?ToggleEntry {
    for (REGISTRY) |entry| {
        if (std.ascii.eqlIgnoreCase(toggle_name, entry.toggle_name)) {
            return entry;
        }
    }
    return null;
}

pub fn effect(toggle_name: []const u8) ToggleEffect {
    if (lookup(toggle_name)) |entry| return entry.effect;
    return .unhandled;
}

pub fn knownCount() usize {
    return REGISTRY.len;
}

test "lookup finds known toggles case-insensitively" {
    const entry = lookup("vulkancooperativematrixstrideismatrixelements");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(ToggleEffect.informational, entry.?.effect);
}

test "lookup returns null for unknown toggles" {
    try std.testing.expect(lookup("nonexistent_toggle_xyz") == null);
}

test "effect returns unhandled for unknown toggles" {
    try std.testing.expectEqual(ToggleEffect.unhandled, effect("unknown_toggle"));
}

test "known toggle count" {
    try std.testing.expect(knownCount() > 0);
}

test "static toggle registry preserves every configured value and case-insensitive lookup" {
    const Config = struct {
        schemaVersion: u32,
        toggles: []const struct { toggle_name: []const u8, effect: []const u8, description: []const u8 },
    };
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, build_options.quirk_toggle_registry_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(parsed.value.toggles.len, knownCount());
    for (parsed.value.toggles, REGISTRY) |source, entry| {
        try std.testing.expectEqualStrings(source.toggle_name, entry.toggle_name);
        try std.testing.expectEqualStrings(source.effect, @tagName(entry.effect));
        try std.testing.expectEqualStrings(source.description, entry.description);
        const uppercase = try std.testing.allocator.dupe(u8, source.toggle_name);
        defer std.testing.allocator.free(uppercase);
        for (uppercase) |*byte| byte.* = std.ascii.toUpper(byte.*);
        const found = lookup(uppercase).?;
        @memset(uppercase, 0);
        try std.testing.expectEqualStrings(source.toggle_name, found.toggle_name);
        try std.testing.expectEqualStrings(source.description, found.description);
        try std.testing.expectEqual(entry.effect, found.effect);
    }
}

test "static toggle registry lookups share immutable storage across threads" {
    const Worker = struct {
        fn run(result: *?ToggleEntry) void {
            result.* = lookup("USE_TEMPORARY_BUFFER_IN_TEXTURE_TO_TEXTURE_COPY");
        }
    };
    var results: [4]?ToggleEntry = @splat(null);
    var threads: [results.len]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&threads, &results) |*thread, *result| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{result});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    const expected = lookup("use_temporary_buffer_in_texture_to_texture_copy").?;
    for (results) |result| {
        try std.testing.expectEqualDeep(expected, result.?);
        try std.testing.expectEqual(expected.toggle_name.ptr, result.?.toggle_name.ptr);
        try std.testing.expectEqual(expected.description.ptr, result.?.description.ptr);
    }
}


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
