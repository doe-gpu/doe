const std = @import("std");
const model = @import("../../src/contracts/model/model.zig");
const ffi = @import("../../src/compat/webgpu_ffi.zig");
const full_partition = @import("../../src/full/command_partition.zig");

comptime {
    if (!@hasField(ffi.WebGPUBackend, "core")) @compileError("WebGPUBackend must expose core state");
    if (!@hasField(ffi.WebGPUBackend, "full")) @compileError("WebGPUBackend must expose full state");
}

test "full command projection accepts full commands and rejects core commands" {
    const render_draw = model.Command{ .render_draw = .{ .draw_count = 1 } };
    const full_command = model.as_full_command(render_draw);
    try std.testing.expect(full_command != null);
    try std.testing.expectEqual(model.FullCommandKind.render_draw, std.meta.activeTag(full_command.?));
    try std.testing.expect(model.as_core_command(render_draw) == null);

    const upload = model.Command{ .upload = .{ .bytes = 16, .align_bytes = 4 } };
    try std.testing.expect(model.as_full_command(upload) == null);
    try std.testing.expect(model.as_core_command(upload) != null);
}

test "full partition metadata stays aligned with the combined command universe" {
    try std.testing.expect(model.is_full_command_kind(.render_draw));
    try std.testing.expect(model.is_full_command_kind(.surface_release));
    try std.testing.expect(!model.is_full_command_kind(.dispatch));
    try std.testing.expect(!model.is_full_command_kind(.texture_destroy));

    try std.testing.expectEqual(full_partition.CommandKind.surface_present, full_partition.fromCombined(.surface_present).?);
    try std.testing.expectEqualStrings("async_diagnostics", full_partition.name(.async_diagnostics));
}
