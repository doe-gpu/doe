const std = @import("std");
const command = @import("../../src/contracts/command.zig");
const ffi = @import("../../src/compat/webgpu_ffi.zig");
const full_surface = @import("../../src/full/surface_api.zig");

comptime {
    if (!@hasField(ffi.WebGPUBackend, "core")) @compileError("WebGPUBackend must expose core state");
    if (!@hasField(ffi.WebGPUBackend, "full")) @compileError("WebGPUBackend must expose full state");
}

test "full surface classifies the canonical command without projection" {
    const render = command.Command{ .render_draw = .{ .draw_count = 1 } };
    try std.testing.expectEqual(full_surface.CommandClassification.full_only, full_surface.classify(render));

    const upload = command.Command{ .upload = .{ .bytes = 16, .align_bytes = 4 } };
    try std.testing.expectEqual(full_surface.CommandClassification.core, full_surface.classify(upload));
}

test "full-only metadata comes from the canonical registry" {
    try std.testing.expect(command.isFullOnlyKind(.render_draw));
    try std.testing.expect(command.isFullOnlyKind(.surface_release));
    try std.testing.expect(!command.isFullOnlyKind(.dispatch));
    try std.testing.expectEqualStrings("async_diagnostics", command.name(.async_diagnostics));
    try std.testing.expectEqual(@as(u32, 14), full_surface.FULL_ONLY_COMMAND_COUNT);
}
