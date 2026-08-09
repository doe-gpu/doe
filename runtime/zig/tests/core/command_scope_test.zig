const std = @import("std");
const command = @import("../../src/contracts/command.zig");
const core_surface = @import("../../src/core/surface.zig");

test "core surface uses canonical command scope without projection" {
    const upload = command.Command{ .upload = .{ .bytes = 16, .align_bytes = 4 } };
    const accepted = try core_surface.validate(upload);
    try std.testing.expectEqual(command.Kind.upload, command.kind(accepted));

    const render = command.Command{ .render_draw = .{ .draw_count = 1 } };
    try std.testing.expectError(core_surface.CoreSurfaceError.CommandNotInCoreSurface, core_surface.validate(render));
}

test "core surface metadata comes from the canonical registry" {
    try std.testing.expect(command.isCoreKind(.upload));
    try std.testing.expect(command.isCoreKind(.texture_destroy));
    try std.testing.expect(!command.isCoreKind(.surface_present));
    try std.testing.expectEqualStrings("compute", command.domainName(.dispatch));
    try std.testing.expectEqual(@as(u32, 11), core_surface.CORE_COMMAND_COUNT);
}
