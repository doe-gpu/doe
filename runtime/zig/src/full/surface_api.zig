const std = @import("std");
const command = @import("../contracts/command.zig");
const core_surface = @import("../core/surface.zig");
const command_dispatch = @import("command_dispatch.zig");

/// Full runtime public API surface.
pub const SURFACE_ID = "doe-full";
pub const SURFACE_VERSION: u32 = 1;
pub const FULL_ONLY_COMMAND_COUNT: u32 = command.countForScope(.full);
pub const TOTAL_COMMAND_COUNT: u32 = command.KIND_COUNT;

pub const CommandClassification = enum {
    core,
    full_only,
};

pub fn classify(value: command.Command) CommandClassification {
    return switch (command.scope(command.kind(value))) {
        .core => .core,
        .full => .full_only,
    };
}

pub fn accepts(_: command.Command) bool {
    return true;
}

pub fn accepts_kind(_: command.Kind) bool {
    return true;
}

pub fn full_only_command_kind_names() [FULL_ONLY_COMMAND_COUNT][]const u8 {
    var names: [FULL_ONLY_COMMAND_COUNT][]const u8 = undefined;
    var output_index: usize = 0;
    inline for (@typeInfo(command.Kind).@"enum".fields) |field| {
        const kind: command.Kind = @enumFromInt(field.value);
        if (comptime command.isFullOnlyKind(kind)) {
            names[output_index] = command.name(kind);
            output_index += 1;
        }
    }
    return names;
}

pub fn domain_for_kind(kind: command.Kind) []const u8 {
    if (!command.isFullOnlyKind(kind)) unreachable;
    return command.domainName(kind);
}

pub const CoverageEntry = core_surface.CoverageEntry;
pub const CoverageStatus = core_surface.CoverageStatus;

pub fn full_only_coverage_ledger() [FULL_ONLY_COMMAND_COUNT]CoverageEntry {
    var ledger: [FULL_ONLY_COMMAND_COUNT]CoverageEntry = undefined;
    var output_index: usize = 0;
    inline for (@typeInfo(command.Kind).@"enum".fields) |field| {
        const kind: command.Kind = @enumFromInt(field.value);
        if (comptime command.isFullOnlyKind(kind)) {
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

pub fn combined_coverage_ledger() [TOTAL_COMMAND_COUNT]CoverageEntry {
    var combined: [TOTAL_COMMAND_COUNT]CoverageEntry = undefined;
    inline for (@typeInfo(command.Kind).@"enum".fields, 0..) |field, index| {
        const kind: command.Kind = @enumFromInt(field.value);
        combined[index] = .{
            .command_kind = command.name(kind),
            .domain = command.domainName(kind),
            .status = .implemented,
        };
    }
    return combined;
}

test "full surface accepts and classifies the canonical command" {
    const upload = command.Command{ .upload = .{ .bytes = 16, .align_bytes = 4 } };
    try std.testing.expect(accepts(upload));
    try std.testing.expectEqual(CommandClassification.core, classify(upload));

    const render = command.Command{ .render_draw = .{ .draw_count = 1 } };
    try std.testing.expect(accepts(render));
    try std.testing.expectEqual(CommandClassification.full_only, classify(render));
}

test "full surface ledgers are registry-derived and exhaustive" {
    try std.testing.expectEqual(command.KIND_COUNT, TOTAL_COMMAND_COUNT);
    try std.testing.expectEqual(
        core_surface.CORE_COMMAND_COUNT + FULL_ONLY_COMMAND_COUNT,
        TOTAL_COMMAND_COUNT,
    );
    try std.testing.expectEqual(TOTAL_COMMAND_COUNT, combined_coverage_ledger().len);
}

test "full surface domain classification" {
    try std.testing.expectEqualStrings("render", domain_for_kind(.render_draw));
    try std.testing.expectEqualStrings("surface", domain_for_kind(.surface_present));
    try std.testing.expectEqualStrings("lifecycle", domain_for_kind(.async_diagnostics));
    try std.testing.expectEqualStrings("resource", domain_for_kind(.sampler_create));
}

comptime {
    _ = command_dispatch;
}
