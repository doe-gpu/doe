const std = @import("std");
const command = @import("../contracts/command.zig");
const command_dispatch = @import("command_dispatch.zig");

/// Core runtime public API surface.
pub const SURFACE_ID = "doe-core";
pub const SURFACE_VERSION: u32 = 1;
pub const CORE_COMMAND_COUNT: u32 = command.countForScope(.core);

pub const CoreSurfaceError = error{
    CommandNotInCoreSurface,
};

/// Validate that a command belongs to the core surface without projecting it
/// into a second command union.
pub fn validate(value: command.Command) CoreSurfaceError!command.Command {
    if (!accepts(value)) return CoreSurfaceError.CommandNotInCoreSurface;
    return value;
}

pub fn accepts(value: command.Command) bool {
    return command.isCoreKind(command.kind(value));
}

pub fn accepts_kind(kind: command.Kind) bool {
    return command.isCoreKind(kind);
}

pub fn command_kind_names() [CORE_COMMAND_COUNT][]const u8 {
    var names: [CORE_COMMAND_COUNT][]const u8 = undefined;
    var output_index: usize = 0;
    inline for (@typeInfo(command.Kind).@"enum".fields) |field| {
        const kind: command.Kind = @enumFromInt(field.value);
        if (comptime command.isCoreKind(kind)) {
            names[output_index] = command.name(kind);
            output_index += 1;
        }
    }
    return names;
}

pub const CoverageEntry = struct {
    command_kind: []const u8,
    domain: []const u8,
    status: CoverageStatus,
};

pub const CoverageStatus = enum {
    implemented,
    partial,
    planned,
};

pub fn domain_for_kind(kind: command.Kind) []const u8 {
    if (!command.isCoreKind(kind)) unreachable;
    return command.domainName(kind);
}

pub fn coverage_ledger() [CORE_COMMAND_COUNT]CoverageEntry {
    var ledger: [CORE_COMMAND_COUNT]CoverageEntry = undefined;
    var output_index: usize = 0;
    inline for (@typeInfo(command.Kind).@"enum".fields) |field| {
        const kind: command.Kind = @enumFromInt(field.value);
        if (comptime command.isCoreKind(kind)) {
            ledger[output_index] = .{
                .command_kind = command.name(kind),
                .domain = command.domainName(kind),
                .status = .implemented,
            };
            output_index += 1;
        }
    }
    return ledger;
}

test "core surface accepts core commands and rejects full commands" {
    const upload = command.Command{ .upload = .{ .bytes = 16, .align_bytes = 4 } };
    const core_command = validate(upload) catch unreachable;
    try std.testing.expectEqual(command.Kind.upload, command.kind(core_command));

    const render = command.Command{ .render_draw = .{ .draw_count = 1 } };
    try std.testing.expectError(CoreSurfaceError.CommandNotInCoreSurface, validate(render));
}

test "core surface coverage is registry-derived and exhaustive" {
    const names = command_kind_names();
    const ledger = coverage_ledger();
    try std.testing.expectEqual(CORE_COMMAND_COUNT, names.len);
    try std.testing.expectEqual(CORE_COMMAND_COUNT, ledger.len);
    for (ledger) |entry| {
        try std.testing.expect(entry.command_kind.len > 0);
        try std.testing.expect(entry.domain.len > 0);
    }
}

test "core surface domain classification" {
    try std.testing.expectEqualStrings("copy", domain_for_kind(.upload));
    try std.testing.expectEqualStrings("compute", domain_for_kind(.dispatch));
    try std.testing.expectEqualStrings("resource", domain_for_kind(.texture_query));
}

comptime {
    _ = command_dispatch;
}
