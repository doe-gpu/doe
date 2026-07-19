const std = @import("std");
const command_json_raw = @import("command_json_raw.zig");

pub const ParseError = command_json_raw.ParseError;
pub const RawCommand = command_json_raw.RawCommand;

pub const NormalizedKind = enum {
    upload,
    buffer_write,
    copy,
    barrier,
    dispatch,
    dispatch_indirect,
    kernel_dispatch,
    render_draw,
    draw_indirect,
    draw_indexed_indirect,
    render_pass,
    sampler_create,
    sampler_destroy,
    texture_write,
    texture_query,
    texture_destroy,
    surface_create,
    surface_capabilities,
    surface_configure,
    surface_acquire,
    surface_present,
    surface_unconfigure,
    surface_release,
    async_diagnostics,
    map_async,
};

pub fn commandKindEquals(raw_kind: []const u8, kind: []const u8) bool {
    return std.ascii.eqlIgnoreCase(raw_kind, kind);
}

pub fn getCommandName(raw: RawCommand) ?[]const u8 {
    if (raw.map_async != null) return "map_async";
    return raw.command orelse raw.kind orelse raw.command_kind;
}

fn matchesAny(raw_kind: []const u8, comptime candidates: []const []const u8) bool {
    inline for (candidates) |candidate| {
        if (commandKindEquals(raw_kind, candidate)) {
            return true;
        }
    }
    return false;
}

const KindAliases = struct {
    kind: NormalizedKind,
    aliases: []const []const u8,
};

const KIND_ALIASES = [_]KindAliases{
    .{ .kind = .upload, .aliases = &.{ "upload", "buffer_upload" } },
    .{ .kind = .buffer_write, .aliases = &.{ "buffer_write", "write_buffer", "queue_write_buffer" } },
    .{ .kind = .copy, .aliases = &.{
        "copy_buffer_to_texture",
        "copy_texture",
        "texture_copy",
        "copy_texture_to_buffer",
        "copy_buffer_to_buffer",
        "buffer_copy",
        "copyBufferToTexture",
        "copyTextureToBuffer",
        "copyBufferToBuffer",
        "copy_texture_to_texture",
    } },
    .{ .kind = .barrier, .aliases = &.{"barrier"} },
    .{ .kind = .dispatch, .aliases = &.{ "dispatch", "dispatch_workgroups", "dispatch_invocations" } },
    .{ .kind = .dispatch_indirect, .aliases = &.{"dispatch_indirect"} },
    .{ .kind = .kernel_dispatch, .aliases = &.{"kernel_dispatch"} },
    .{ .kind = .draw_indirect, .aliases = &.{"draw_indirect"} },
    .{ .kind = .draw_indexed_indirect, .aliases = &.{"draw_indexed_indirect"} },
    .{ .kind = .render_pass, .aliases = &.{"render_pass"} },
    .{ .kind = .render_draw, .aliases = &.{ "render_draw", "draw", "draw_call", "draw_indexed" } },
    .{ .kind = .sampler_create, .aliases = &.{ "sampler_create", "create_sampler" } },
    .{ .kind = .sampler_destroy, .aliases = &.{ "sampler_destroy", "destroy_sampler" } },
    .{ .kind = .texture_write, .aliases = &.{ "texture_write", "write_texture", "queue_write_texture" } },
    .{ .kind = .texture_query, .aliases = &.{ "texture_query", "query_texture" } },
    .{ .kind = .texture_destroy, .aliases = &.{ "texture_destroy", "destroy_texture" } },
    .{ .kind = .surface_create, .aliases = &.{ "surface_create", "create_surface" } },
    .{ .kind = .surface_capabilities, .aliases = &.{ "surface_capabilities", "surface_get_capabilities" } },
    .{ .kind = .surface_configure, .aliases = &.{ "surface_configure", "configure_surface" } },
    .{ .kind = .surface_acquire, .aliases = &.{ "surface_acquire", "surface_get_current_texture", "surface_current_texture" } },
    .{ .kind = .surface_present, .aliases = &.{ "surface_present", "present_surface" } },
    .{ .kind = .surface_unconfigure, .aliases = &.{ "surface_unconfigure", "unconfigure_surface" } },
    .{ .kind = .surface_release, .aliases = &.{ "surface_release", "release_surface" } },
    .{ .kind = .async_diagnostics, .aliases = &.{ "async_diagnostics", "pipeline_async_diagnostics" } },
    .{ .kind = .map_async, .aliases = &.{ "map_async", "buffer_map_async" } },
};

pub fn parseKind(raw: RawCommand) ParseError!NormalizedKind {
    const kind = getCommandName(raw) orelse return ParseError.MissingCommandKind;
    inline for (KIND_ALIASES) |entry| {
        if (matchesAny(kind, entry.aliases)) return entry.kind;
    }
    return ParseError.UnknownCommandKind;
}
