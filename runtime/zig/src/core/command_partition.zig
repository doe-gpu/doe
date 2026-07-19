const std = @import("std");
const model_resource_types = @import("../contracts/model/model_resource_types.zig");
const model_compute_types = @import("../contracts/model/model_compute_types.zig");
const model_texture_types = @import("../contracts/model/model_texture_types.zig");
const model_async_types = @import("../contracts/model/model_async_types.zig");

pub const CommandKind = enum(u8) {
    upload,
    buffer_write,
    copy_buffer_to_texture,
    barrier,
    dispatch,
    dispatch_indirect,
    kernel_dispatch,
    texture_write,
    texture_query,
    texture_destroy,
    map_async,
};

/// Core command union — owns compute, copy, resource, and queue-sync commands.
/// This is the authoritative definition; model.zig re-exports it.
pub const Command = union(CommandKind) {
    upload: model_resource_types.UploadCommand,
    buffer_write: model_resource_types.BufferWriteCommand,
    copy_buffer_to_texture: model_resource_types.CopyCommand,
    barrier: model_resource_types.BarrierCommand,
    dispatch: model_compute_types.DispatchCommand,
    dispatch_indirect: model_compute_types.DispatchIndirectCommand,
    kernel_dispatch: model_compute_types.KernelDispatchCommand,
    texture_write: model_texture_types.TextureWriteCommand,
    texture_query: model_texture_types.TextureQueryCommand,
    texture_destroy: model_texture_types.TextureDestroyCommand,
    map_async: model_async_types.MapAsyncCommand,
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
