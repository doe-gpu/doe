const std = @import("std");
const model = @import("../contracts/model/model_commands.zig");
const core_surface = @import("../core/surface.zig");
const command_partition = @import("command_partition.zig");
const command_dispatch = @import("command_dispatch.zig");

/// Full runtime public API surface.
///
/// The full surface is a strict superset of core: it accepts every core command
/// plus render, surface-presentation, sampler, lifecycle, and async-diagnostics
/// commands. This is the surface used by browser integration, rich application
/// bundles, and workloads that need the complete WebGPU command vocabulary.
///
/// The full surface re-exports core surface types so callers do not need to
/// import both modules.
pub const SURFACE_ID = "doe-full";
pub const SURFACE_VERSION: u32 = 1;

pub const FullCommandKind = command_partition.CommandKind;
pub const FullCommand = model.FullCommand;

/// Re-export core types for convenience.
pub const CoreCommandKind = core_surface.CoreCommandKind;
pub const CoreCommand = model.CoreCommand;

/// Number of full-only command kinds (excluding core).
pub const FULL_ONLY_COMMAND_COUNT: u32 = @typeInfo(FullCommandKind).@"enum".fields.len;

/// Total command kinds in the full surface (core + full-only).
pub const TOTAL_COMMAND_COUNT: u32 = core_surface.CORE_COMMAND_COUNT + FULL_ONLY_COMMAND_COUNT;

pub const FullSurfaceError = error{
    CommandNotRecognized,
};

/// Classify a combined Command into the full surface.
/// Every valid CommandKind is accepted by the full surface (core or full-only).
pub const CommandClassification = union(enum) {
    core: model.CoreCommand,
    full_only: model.FullCommand,
};

/// Classify a command as core or full-only. Returns explicit error if the
/// command is somehow not in either partition (should not happen with a valid
/// Command union, but prevents silent pass-through).
pub fn classify(cmd: model.Command) FullSurfaceError!CommandClassification {
    if (model.as_core_command(cmd)) |core_cmd| {
        return .{ .core = core_cmd };
    }
    if (model.as_full_command(cmd)) |full_cmd| {
        return .{ .full_only = full_cmd };
    }
    return FullSurfaceError.CommandNotRecognized;
}

/// The full surface accepts all commands.
pub fn accepts(cmd: model.Command) bool {
    return model.as_core_command(cmd) != null or model.as_full_command(cmd) != null;
}

/// Check membership by CommandKind tag.
pub fn accepts_kind(kind: model.CommandKind) bool {
    return model.is_core_command_kind(kind) or model.is_full_command_kind(kind);
}

/// Enumerate all full-only command kind names for ledger/coverage use.
pub fn full_only_command_kind_names() [FULL_ONLY_COMMAND_COUNT][]const u8 {
    var names: [FULL_ONLY_COMMAND_COUNT][]const u8 = undefined;
    inline for (@typeInfo(FullCommandKind).@"enum".fields, 0..) |field, i| {
        names[i] = field.name;
    }
    return names;
}

/// Returns the domain classification for a full-only command kind.
pub fn domain_for_kind(kind: FullCommandKind) []const u8 {
    return switch (kind) {
        .render_draw => "render",
        .draw_indirect => "render",
        .draw_indexed_indirect => "render",
        .render_pass => "render",
        .sampler_create => "resource",
        .sampler_destroy => "resource",
        .surface_create => "surface",
        .surface_capabilities => "surface",
        .surface_configure => "surface",
        .surface_acquire => "surface",
        .surface_present => "surface",
        .surface_unconfigure => "surface",
        .surface_release => "surface",
        .async_diagnostics => "lifecycle",
    };
}

/// Coverage entry for ledger generation.
pub const CoverageEntry = core_surface.CoverageEntry;
pub const CoverageStatus = core_surface.CoverageStatus;

/// Build a static coverage ledger snapshot for all full-only command kinds.
pub fn full_only_coverage_ledger() [FULL_ONLY_COMMAND_COUNT]CoverageEntry {
    var ledger: [FULL_ONLY_COMMAND_COUNT]CoverageEntry = undefined;
    inline for (@typeInfo(FullCommandKind).@"enum".fields, 0..) |field, i| {
        const kind: FullCommandKind = @enumFromInt(field.value);
        ledger[i] = .{
            .command_kind = field.name,
            .domain = domain_for_kind(kind),
            .status = .implemented,
        };
    }
    return ledger;
}

/// Build the combined full coverage ledger (core + full-only).
pub fn combined_coverage_ledger() [TOTAL_COMMAND_COUNT]CoverageEntry {
    const core_ledger = core_surface.coverage_ledger();
    const full_ledger = full_only_coverage_ledger();
    var combined: [TOTAL_COMMAND_COUNT]CoverageEntry = undefined;
    @memcpy(combined[0..core_surface.CORE_COMMAND_COUNT], &core_ledger);
    @memcpy(combined[core_surface.CORE_COMMAND_COUNT..], &full_ledger);
    return combined;
}

test "full surface accepts all commands" {
    const upload = model.Command{ .upload = .{ .bytes = 16, .align_bytes = 4 } };
    try std.testing.expect(accepts(upload));

    const render = model.Command{ .render_draw = .{ .draw_count = 1 } };
    try std.testing.expect(accepts(render));
}

test "full surface classifies core vs full-only" {
    const upload = model.Command{ .upload = .{ .bytes = 16, .align_bytes = 4 } };
    const class_upload = try classify(upload);
    try std.testing.expect(class_upload == .core);

    const render = model.Command{ .render_draw = .{ .draw_count = 1 } };
    const class_render = try classify(render);
    try std.testing.expect(class_render == .full_only);
}

test "full surface total count equals core + full-only" {
    try std.testing.expectEqual(
        core_surface.CORE_COMMAND_COUNT + FULL_ONLY_COMMAND_COUNT,
        TOTAL_COMMAND_COUNT,
    );
}

test "full surface combined ledger is exhaustive" {
    const ledger = combined_coverage_ledger();
    try std.testing.expectEqual(TOTAL_COMMAND_COUNT, ledger.len);
    for (ledger) |entry| {
        try std.testing.expect(entry.command_kind.len > 0);
        try std.testing.expect(entry.domain.len > 0);
    }
}

test "full surface domain classification" {
    try std.testing.expectEqualStrings("render", domain_for_kind(.render_draw));
    try std.testing.expectEqualStrings("surface", domain_for_kind(.surface_present));
    try std.testing.expectEqualStrings("lifecycle", domain_for_kind(.async_diagnostics));
    try std.testing.expectEqualStrings("resource", domain_for_kind(.sampler_create));
}

test "full surface command count matches combined partition" {
    const all_kinds = @typeInfo(model.CommandKind).@"enum".fields.len;
    try std.testing.expectEqual(all_kinds, TOTAL_COMMAND_COUNT);
}
