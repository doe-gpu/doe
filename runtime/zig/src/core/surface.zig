const std = @import("std");
const model = @import("../contracts/model/model_commands.zig");
const command_partition = @import("command_partition.zig");
const command_dispatch = @import("command_dispatch.zig");

/// Core runtime public API surface.
///
/// The core surface exposes compute, copy, resource, and queue-sync commands
/// only. Render, surface-presentation, sampler, and async-diagnostics commands
/// belong to the full surface and are rejected here with an explicit error.
///
/// Consumers that need only compute/upload/copy workloads (headless AI/ML,
/// benchmarking, CI) should use this surface to get a smaller dependency
/// footprint and faster compilation.
pub const SURFACE_ID = "doe-core";
pub const SURFACE_VERSION: u32 = 1;

pub const CoreCommandKind = command_partition.CommandKind;
pub const CoreCommand = model.CoreCommand;

/// Number of command kinds in the core surface.
pub const CORE_COMMAND_COUNT: u32 = @typeInfo(CoreCommandKind).@"enum".fields.len;

pub const CoreSurfaceError = error{
    CommandNotInCoreSurface,
};

/// Validate that a combined Command belongs to the core surface.
/// Returns the projected CoreCommand or an explicit error.
pub fn validate(cmd: model.Command) CoreSurfaceError!CoreCommand {
    return model.as_core_command(cmd) orelse CoreSurfaceError.CommandNotInCoreSurface;
}

/// Check membership without extracting the payload.
pub fn accepts(cmd: model.Command) bool {
    return model.as_core_command(cmd) != null;
}

/// Check membership by CommandKind tag.
pub fn accepts_kind(kind: model.CommandKind) bool {
    return model.is_core_command_kind(kind);
}

/// Enumerate all core command kind names for ledger/coverage use.
pub fn command_kind_names() [CORE_COMMAND_COUNT][]const u8 {
    var names: [CORE_COMMAND_COUNT][]const u8 = undefined;
    inline for (@typeInfo(CoreCommandKind).@"enum".fields, 0..) |field, i| {
        names[i] = field.name;
    }
    return names;
}

/// Core coverage entry for ledger generation.
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

/// Returns the domain classification for a core command kind.
pub fn domain_for_kind(kind: CoreCommandKind) []const u8 {
    return switch (kind) {
        .upload => "copy",
        .buffer_write => "copy",
        .copy_buffer_to_texture => "copy",
        .barrier => "compute",
        .dispatch => "compute",
        .dispatch_indirect => "compute",
        .kernel_dispatch => "compute",
        .texture_write => "resource",
        .texture_query => "resource",
        .texture_destroy => "resource",
        .map_async => "resource",
    };
}

/// Build a static coverage ledger snapshot for all core command kinds.
/// Status reflects the current implementation state (all core commands
/// are implemented in the Zig runtime).
pub fn coverage_ledger() [CORE_COMMAND_COUNT]CoverageEntry {
    const kind_names = command_kind_names();
    var ledger: [CORE_COMMAND_COUNT]CoverageEntry = undefined;
    inline for (@typeInfo(CoreCommandKind).@"enum".fields, 0..) |field, i| {
        const kind: CoreCommandKind = @enumFromInt(field.value);
        ledger[i] = .{
            .command_kind = kind_names[i],
            .domain = domain_for_kind(kind),
            .status = .implemented,
        };
    }
    return ledger;
}

test "core surface accepts core commands and rejects full commands" {
    const upload = model.Command{ .upload = .{ .bytes = 16, .align_bytes = 4 } };
    const core_cmd = validate(upload) catch unreachable;
    try std.testing.expectEqual(CoreCommandKind.upload, std.meta.activeTag(core_cmd));

    const render = model.Command{ .render_draw = .{ .draw_count = 1 } };
    try std.testing.expectError(CoreSurfaceError.CommandNotInCoreSurface, validate(render));
}

test "core surface command count matches partition" {
    const partition_count = @typeInfo(CoreCommandKind).@"enum".fields.len;
    try std.testing.expectEqual(CORE_COMMAND_COUNT, partition_count);
}

test "core surface coverage ledger is exhaustive" {
    const ledger = coverage_ledger();
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
