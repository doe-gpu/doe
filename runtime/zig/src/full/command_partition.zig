const std = @import("std");
const model_render_types = @import("../contracts/model/model_render_types.zig");
const model_surface_control_types = @import("../contracts/model/model_surface_control_types.zig");
const model_async_types = @import("../contracts/model/model_async_types.zig");

pub const CommandKind = enum(u8) {
    render_draw,
    draw_indirect,
    draw_indexed_indirect,
    render_pass,
    sampler_create,
    sampler_destroy,
    surface_create,
    surface_capabilities,
    surface_configure,
    surface_acquire,
    surface_present,
    surface_unconfigure,
    surface_release,
    async_diagnostics,
};

/// Full-only command union — owns render, surface, sampler, and lifecycle commands.
/// This is the authoritative definition; model.zig re-exports it.
pub const Command = union(CommandKind) {
    render_draw: model_render_types.RenderDrawCommand,
    draw_indirect: model_render_types.DrawIndirectCommand,
    draw_indexed_indirect: model_render_types.DrawIndexedIndirectCommand,
    render_pass: model_render_types.RenderPassCommand,
    sampler_create: model_render_types.SamplerCreateCommand,
    sampler_destroy: model_render_types.SamplerDestroyCommand,
    surface_create: model_surface_control_types.SurfaceCreateCommand,
    surface_capabilities: model_surface_control_types.SurfaceCapabilitiesCommand,
    surface_configure: model_surface_control_types.SurfaceConfigureCommand,
    surface_acquire: model_surface_control_types.SurfaceAcquireCommand,
    surface_present: model_surface_control_types.SurfacePresentCommand,
    surface_unconfigure: model_surface_control_types.SurfaceUnconfigureCommand,
    surface_release: model_surface_control_types.SurfaceReleaseCommand,
    async_diagnostics: model_async_types.AsyncDiagnosticsCommand,
};

pub fn fromCombined(kind: anytype) ?CommandKind {
    return std.meta.stringToEnum(CommandKind, @tagName(kind));
}

pub fn contains(kind: anytype) bool {
    return fromCombined(kind) != null;
}

pub fn name(kind: CommandKind) []const u8 {
    return @tagName(kind);
}
