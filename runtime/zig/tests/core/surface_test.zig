const std = @import("std");
const model = @import("../../src/contracts/command.zig");
const core_surface = @import("../../src/core/surface.zig");

test "core surface ID and version" {
    try std.testing.expectEqualStrings("doe-core", core_surface.SURFACE_ID);
    try std.testing.expectEqual(@as(u32, 1), core_surface.SURFACE_VERSION);
}

test "core surface validate accepts core commands" {
    const upload = model.Command{ .upload = .{ .bytes = 64, .align_bytes = 4 } };
    const result = try core_surface.validate(upload);
    try std.testing.expectEqual(model.CommandKind.upload, std.meta.activeTag(result));
}

test "core surface validate rejects full commands" {
    const render = model.Command{ .render_draw = .{ .draw_count = 1 } };
    try std.testing.expectError(core_surface.CoreSurfaceError.CommandNotInCoreSurface, core_surface.validate(render));

    const sampler = model.Command{ .sampler_create = .{ .handle = 42 } };
    try std.testing.expectError(core_surface.CoreSurfaceError.CommandNotInCoreSurface, core_surface.validate(sampler));

    const surface = model.Command{ .surface_present = .{ .handle = 1 } };
    try std.testing.expectError(core_surface.CoreSurfaceError.CommandNotInCoreSurface, core_surface.validate(surface));
}

test "core surface accepts/rejects via bool helpers" {
    const dispatch = model.Command{ .dispatch = .{ .x = 1, .y = 1, .z = 1 } };
    try std.testing.expect(core_surface.accepts(dispatch));
    try std.testing.expect(core_surface.accepts_kind(.dispatch));
    try std.testing.expect(core_surface.accepts_kind(.upload));
    try std.testing.expect(core_surface.accepts_kind(.buffer_write));
    try std.testing.expect(core_surface.accepts_kind(.kernel_dispatch));
    try std.testing.expect(core_surface.accepts_kind(.map_async));

    try std.testing.expect(!core_surface.accepts_kind(.render_draw));
    try std.testing.expect(!core_surface.accepts_kind(.surface_present));
    try std.testing.expect(!core_surface.accepts_kind(.async_diagnostics));
}

test "core surface command count" {
    try std.testing.expectEqual(@as(u32, 11), core_surface.CORE_COMMAND_COUNT);
}

test "core surface command_kind_names returns correct names" {
    const names = core_surface.command_kind_names();
    try std.testing.expectEqual(@as(usize, 11), names.len);
    try std.testing.expectEqualStrings("upload", names[0]);
    try std.testing.expectEqualStrings("buffer_write", names[1]);
    try std.testing.expectEqualStrings("map_async", names[names.len - 1]);
}

test "core surface coverage_ledger is exhaustive and well-formed" {
    const ledger = core_surface.coverage_ledger();
    try std.testing.expectEqual(core_surface.CORE_COMMAND_COUNT, ledger.len);
    for (ledger) |entry| {
        try std.testing.expect(entry.command_kind.len > 0);
        try std.testing.expect(entry.domain.len > 0);
        try std.testing.expectEqual(core_surface.CoverageStatus.implemented, entry.status);
    }
}

test "core surface domain classification correctness" {
    try std.testing.expectEqualStrings("copy", core_surface.domain_for_kind(.upload));
    try std.testing.expectEqualStrings("copy", core_surface.domain_for_kind(.buffer_write));
    try std.testing.expectEqualStrings("copy", core_surface.domain_for_kind(.copy_buffer_to_texture));
    try std.testing.expectEqualStrings("compute", core_surface.domain_for_kind(.barrier));
    try std.testing.expectEqualStrings("compute", core_surface.domain_for_kind(.dispatch));
    try std.testing.expectEqualStrings("compute", core_surface.domain_for_kind(.dispatch_indirect));
    try std.testing.expectEqualStrings("compute", core_surface.domain_for_kind(.kernel_dispatch));
    try std.testing.expectEqualStrings("resource", core_surface.domain_for_kind(.texture_write));
    try std.testing.expectEqualStrings("resource", core_surface.domain_for_kind(.texture_query));
    try std.testing.expectEqualStrings("resource", core_surface.domain_for_kind(.texture_destroy));
    try std.testing.expectEqualStrings("resource", core_surface.domain_for_kind(.map_async));
}
