const std = @import("std");
const build = @import("../../build.zig");

const TEST_QUIRK_REGISTRY =
    \\{"schemaVersion":1,"toggles":[{"toggle_name":"escaped\u005fname","effect":"behavioral","description":"quoted \"value\"\nnext line"}]}
;

fn testParseQuirkRegistry(allocator: std.mem.Allocator) !void {
    const parsed = try build.parseQuirkToggleRegistry(allocator, TEST_QUIRK_REGISTRY);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("escaped_name", parsed.value.toggles[0].toggle_name);
    try std.testing.expectEqualStrings("quoted \"value\"\nnext line", parsed.value.toggles[0].description);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try build.writeQuirkToggleRegistry(allocator, &output, parsed.value.toggles);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "escaped_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "quoted \\\"value\\\"\\nnext line") != null);
}

test "quirk registry build parsing owns decoded strings and releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testParseQuirkRegistry, .{});
}

test "quirk registry build rejects invalid policy without retaining parser storage" {
    const cases = .{
        .{ error.InvalidToggleRegistryVersion, "{\"schemaVersion\":2,\"toggles\":[]}" },
        .{ error.EmptyToggleName, "{\"schemaVersion\":1,\"toggles\":[{\"toggle_name\":\"\",\"effect\":\"behavioral\",\"description\":\"escaped\\ntext\"}]}" },
        .{ error.InvalidToggleEffect, "{\"schemaVersion\":1,\"toggles\":[{\"toggle_name\":\"a\",\"effect\":\"unhandled\",\"description\":\"\"}]}" },
        .{ error.UnexpectedToken, "{\"schemaVersion\":1,\"toggles\":[{\"toggle_name\":\"a\",\"effect\":0,\"description\":\"\"}]}" },
        .{ error.UnknownField, "{\"schemaVersion\":1,\"toggles\":[],\"extra\":true}" },
        .{ error.MissingField, "{\"schemaVersion\":1}" },
    };
    inline for (cases) |case| {
        try std.testing.expectError(case[0], build.parseQuirkToggleRegistry(std.testing.allocator, case[1]));
    }
}
