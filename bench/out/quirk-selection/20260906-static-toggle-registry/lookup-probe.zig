const std = @import("std");
const registry = @import("registry");

const WARMUP_COUNT = 20;
const LOOKUP_COUNT = 100_000;
const SAMPLE_COUNT = 7;

pub fn main() !void {
    var names = [_][]const u8{
        "use_temporary_buffer_in_texture_to_texture_copy",
        "VULKANCOOPERATIVEMATRIXSTRIDEISMATRIXELEMENTS",
        "unknown-toggle",
    };
    std.mem.doNotOptimizeAway(&names);
    var timer = try std.time.Timer.start();
    const first = registry.lookup(names[0]).?;
    const first_ns = timer.read();
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(first.toggle_name);
    for (names) |name| {
        if (registry.lookup(name)) |entry| {
            hash.update(entry.toggle_name);
            hash.update(@tagName(entry.effect));
            hash.update(entry.description);
        } else hash.update("unhandled");
    }
    std.debug.print("identity\t{x}\t{d}\n", .{ hash.finalResult(), registry.knownCount() });
    std.debug.print("first_lookup_ns\t{d}\n", .{first_ns});
    for (0..WARMUP_COUNT) |index| std.mem.doNotOptimizeAway(registry.lookup(names[index % names.len]));
    for (0..SAMPLE_COUNT) |sample| {
        timer.reset();
        for (0..LOOKUP_COUNT) |index| std.mem.doNotOptimizeAway(registry.lookup(names[index % names.len]));
        std.debug.print("sample\t{d}\t{d}\t{d}\n", .{ sample, LOOKUP_COUNT, timer.read() });
    }
}
