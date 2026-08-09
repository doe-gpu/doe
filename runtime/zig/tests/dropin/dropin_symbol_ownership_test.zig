const std = @import("std");
const build_options = @import("build_options");
const ownership = @import("../../src/dropin/dropin_symbol_ownership.zig");

test "symbol ownership parser accepts doe_metal" {
    try std.testing.expect(ownership.parse_symbol_owner("doe_metal") != null);
    try std.testing.expect(ownership.parse_symbol_owner("doe_vulkan") != null);
    try std.testing.expect(ownership.parse_symbol_owner("doe_d3d12") != null);
}

test "symbol ownership config parser owns symbol names" {
    const owned = try ownership.parse_symbol_ownership_config(std.testing.allocator, build_options.dropin_symbol_ownership_config_json);
    defer {
        for (owned) |entry| {
            std.testing.allocator.free(entry.symbol);
        }
        std.testing.allocator.free(owned);
    }

    try std.testing.expectEqual(@as(usize, 18), owned.len);
    try std.testing.expect(std.mem.eql(u8, owned[0].symbol, "wgpuGetProcAddress"));
    try std.testing.expectEqual(ownership.SymbolOwner.shared, owned[0].owner);
}
