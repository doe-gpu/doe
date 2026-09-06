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

const ToggleRegistryJson = struct {
    schemaVersion: u32,
    toggles: []const struct {
        toggle_name: []const u8,
        effect: []const u8,
        description: []const u8,
    },
};

fn parseEffect(raw: []const u8) ToggleEffect {
    if (std.ascii.eqlIgnoreCase(raw, "behavioral")) return .behavioral;
    if (std.ascii.eqlIgnoreCase(raw, "informational")) return .informational;
    return .unhandled;
}

var g_lock: std.Thread.Mutex = .{};
var g_ready = std.atomic.Value(u8).init(0);
var g_registry: []const ToggleEntry = &.{};

fn ensureInit() void {
    if (g_ready.load(.acquire) != 0) return;

    g_lock.lock();
    defer g_lock.unlock();

    if (g_ready.load(.acquire) != 0) return;

    const parsed = std.json.parseFromSlice(
        ToggleRegistryJson,
        test_allocator,
        build_options.quirk_toggle_registry_json,
        .{ .ignore_unknown_fields = false },
    ) catch {
        g_ready.store(1, .release);
        return;
    };
    defer parsed.deinit();

    if (parsed.value.schemaVersion != 1) {
        g_ready.store(1, .release);
        return;
    }

    const entries = test_allocator.alloc(ToggleEntry, parsed.value.toggles.len) catch {
        g_ready.store(1, .release);
        return;
    };

    for (parsed.value.toggles, entries) |t, *dest| {
        dest.* = .{
            .toggle_name = test_allocator.dupe(u8, t.toggle_name) catch t.toggle_name,
            .effect = parseEffect(t.effect),
            .description = test_allocator.dupe(u8, t.description) catch t.description,
        };
    }

    g_registry = entries;
    g_ready.store(1, .release);
}

pub fn lookup(toggle_name: []const u8) ?ToggleEntry {
    ensureInit();
    for (g_registry) |entry| {
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
    ensureInit();
    return g_registry.len;
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
