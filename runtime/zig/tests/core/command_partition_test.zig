const std = @import("std");
const model = @import("../../src/contracts/model/model.zig");
const core_partition = @import("../../src/core/command_partition.zig");

test "core command projection accepts core commands and rejects full commands" {
    const upload = model.Command{ .upload = .{ .bytes = 16, .align_bytes = 4 } };
    const core_command = model.as_core_command(upload);
    try std.testing.expect(core_command != null);
    try std.testing.expectEqual(model.CoreCommandKind.upload, std.meta.activeTag(core_command.?));
    try std.testing.expect(model.as_full_command(upload) == null);

    const render_draw = model.Command{ .render_draw = .{ .draw_count = 1 } };
    try std.testing.expect(model.as_core_command(render_draw) == null);
    try std.testing.expect(model.as_full_command(render_draw) != null);
}

test "core partition metadata stays aligned with the combined command universe" {
    try std.testing.expect(model.is_core_command_kind(.upload));
    try std.testing.expect(model.is_core_command_kind(.texture_destroy));
    try std.testing.expect(!model.is_core_command_kind(.surface_present));
    try std.testing.expect(!model.is_core_command_kind(.render_draw));

    try std.testing.expectEqual(core_partition.CommandKind.dispatch, core_partition.fromCombined(.dispatch).?);
    try std.testing.expectEqualStrings("map_async", core_partition.name(.map_async));
}
