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
        std.heap.page_allocator,
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

    const entries = std.heap.page_allocator.alloc(ToggleEntry, parsed.value.toggles.len) catch {
        g_ready.store(1, .release);
        return;
    };

    for (parsed.value.toggles, entries) |t, *dest| {
        dest.* = .{
            .toggle_name = std.heap.page_allocator.dupe(u8, t.toggle_name) catch t.toggle_name,
            .effect = parseEffect(t.effect),
            .description = std.heap.page_allocator.dupe(u8, t.description) catch t.description,
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
