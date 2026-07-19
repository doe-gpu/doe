const std = @import("std");
const model_resource_types = @import("model_resource_types.zig");
const model_compute_types = @import("model_compute_types.zig");
const model_render_types = @import("model_render_types.zig");
const model_texture_types = @import("model_texture_types.zig");
const model_surface_control_types = @import("model_surface_control_types.zig");
const model_async_types = @import("model_async_types.zig");
const core_partition = @import("../../core/command_partition.zig");
const full_partition = @import("../../full/command_partition.zig");

pub const CoreCommandKind = core_partition.CommandKind;
pub const FullCommandKind = full_partition.CommandKind;
pub const CoreCommand = core_partition.Command;
pub const FullCommand = full_partition.Command;

pub const CommandKind = enum(u8) {
    upload,
    buffer_write,
    copy_buffer_to_texture,
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

pub const Command = union(CommandKind) {
    upload: model_resource_types.UploadCommand,
    buffer_write: model_resource_types.BufferWriteCommand,
    copy_buffer_to_texture: model_resource_types.CopyCommand,
    barrier: model_resource_types.BarrierCommand,
    dispatch: model_compute_types.DispatchCommand,
    dispatch_indirect: model_compute_types.DispatchIndirectCommand,
    kernel_dispatch: model_compute_types.KernelDispatchCommand,
    render_draw: model_render_types.RenderDrawCommand,
    draw_indirect: model_render_types.DrawIndirectCommand,
    draw_indexed_indirect: model_render_types.DrawIndexedIndirectCommand,
    render_pass: model_render_types.RenderPassCommand,
    sampler_create: model_render_types.SamplerCreateCommand,
    sampler_destroy: model_render_types.SamplerDestroyCommand,
    texture_write: model_texture_types.TextureWriteCommand,
    texture_query: model_texture_types.TextureQueryCommand,
    texture_destroy: model_texture_types.TextureDestroyCommand,
    surface_create: model_surface_control_types.SurfaceCreateCommand,
    surface_capabilities: model_surface_control_types.SurfaceCapabilitiesCommand,
    surface_configure: model_surface_control_types.SurfaceConfigureCommand,
    surface_acquire: model_surface_control_types.SurfaceAcquireCommand,
    surface_present: model_surface_control_types.SurfacePresentCommand,
    surface_unconfigure: model_surface_control_types.SurfaceUnconfigureCommand,
    surface_release: model_surface_control_types.SurfaceReleaseCommand,
    async_diagnostics: model_async_types.AsyncDiagnosticsCommand,
    map_async: model_async_types.MapAsyncCommand,
};

comptime {
    const core_fields = @typeInfo(CoreCommand).@"union".fields;
    const full_fields = @typeInfo(FullCommand).@"union".fields;
    const combined_fields = @typeInfo(Command).@"union".fields;
    if (combined_fields.len != core_fields.len + full_fields.len) {
        @compileError("Command variant count does not equal CoreCommand + FullCommand");
    }
    for (core_fields) |core_field| {
        var found = false;
        for (combined_fields) |combined_field| {
            if (std.mem.eql(u8, core_field.name, combined_field.name)) {
                if (core_field.type != combined_field.type) {
                    @compileError("Command." ++ core_field.name ++ " payload type differs from CoreCommand");
                }
                found = true;
                break;
            }
        }
        if (!found) @compileError("CoreCommand." ++ core_field.name ++ " missing from Command");
    }
    for (full_fields) |full_field| {
        var found = false;
        for (combined_fields) |combined_field| {
            if (std.mem.eql(u8, full_field.name, combined_field.name)) {
                if (full_field.type != combined_field.type) {
                    @compileError("Command." ++ full_field.name ++ " payload type differs from FullCommand");
                }
                found = true;
                break;
            }
        }
        if (!found) @compileError("FullCommand." ++ full_field.name ++ " missing from Command");
    }
}

pub fn core_command_kind(kind: CommandKind) ?CoreCommandKind {
    return core_partition.fromCombined(kind);
}

pub fn full_command_kind(kind: CommandKind) ?FullCommandKind {
    return full_partition.fromCombined(kind);
}

pub fn is_core_command_kind(kind: CommandKind) bool {
    return core_command_kind(kind) != null;
}

pub fn is_full_command_kind(kind: CommandKind) bool {
    return full_command_kind(kind) != null;
}

pub fn as_core_command(cmd: Command) ?CoreCommand {
    return switch (cmd) {
        .upload => |payload| .{ .upload = payload },
        .buffer_write => |payload| .{ .buffer_write = payload },
        .copy_buffer_to_texture => |payload| .{ .copy_buffer_to_texture = payload },
        .barrier => |payload| .{ .barrier = payload },
        .dispatch => |payload| .{ .dispatch = payload },
        .dispatch_indirect => |payload| .{ .dispatch_indirect = payload },
        .kernel_dispatch => |payload| .{ .kernel_dispatch = payload },
        .texture_write => |payload| .{ .texture_write = payload },
        .texture_query => |payload| .{ .texture_query = payload },
        .texture_destroy => |payload| .{ .texture_destroy = payload },
        .map_async => |payload| .{ .map_async = payload },
        else => null,
    };
}

pub fn as_full_command(cmd: Command) ?FullCommand {
    return switch (cmd) {
        .render_draw => |payload| .{ .render_draw = payload },
        .draw_indirect => |payload| .{ .draw_indirect = payload },
        .draw_indexed_indirect => |payload| .{ .draw_indexed_indirect = payload },
        .render_pass => |payload| .{ .render_pass = payload },
        .sampler_create => |payload| .{ .sampler_create = payload },
        .sampler_destroy => |payload| .{ .sampler_destroy = payload },
        .surface_create => |payload| .{ .surface_create = payload },
        .surface_capabilities => |payload| .{ .surface_capabilities = payload },
        .surface_configure => |payload| .{ .surface_configure = payload },
        .surface_acquire => |payload| .{ .surface_acquire = payload },
        .surface_present => |payload| .{ .surface_present = payload },
        .surface_unconfigure => |payload| .{ .surface_unconfigure = payload },
        .surface_release => |payload| .{ .surface_release = payload },
        .async_diagnostics => |payload| .{ .async_diagnostics = payload },
        else => null,
    };
}

pub fn command_kind(cmd: Command) CommandKind {
    return std.meta.activeTag(cmd);
}

pub fn command_kind_name(cmd: CommandKind) []const u8 {
    return @tagName(cmd);
}

const testing = std.testing;

test "command_kind_name returns correct string for selected kinds" {
    try testing.expectEqualStrings("upload", command_kind_name(.upload));
    try testing.expectEqualStrings("buffer_write", command_kind_name(.buffer_write));
    try testing.expectEqualStrings("kernel_dispatch", command_kind_name(.kernel_dispatch));
    try testing.expectEqualStrings("render_draw", command_kind_name(.render_draw));
    try testing.expectEqualStrings("map_async", command_kind_name(.map_async));
}

test "is_core_command_kind and is_full_command_kind partition correctly" {
    try testing.expect(is_core_command_kind(.upload));
    try testing.expect(is_core_command_kind(.buffer_write));
    try testing.expect(is_core_command_kind(.dispatch));
    try testing.expect(is_core_command_kind(.kernel_dispatch));
    try testing.expect(is_core_command_kind(.map_async));
    try testing.expect(!is_full_command_kind(.upload));
    try testing.expect(!is_full_command_kind(.dispatch));

    try testing.expect(is_full_command_kind(.render_draw));
    try testing.expect(is_full_command_kind(.sampler_create));
    try testing.expect(is_full_command_kind(.async_diagnostics));
    try testing.expect(!is_core_command_kind(.render_draw));
    try testing.expect(!is_core_command_kind(.sampler_create));
}

test "as_core_command converts core union variants" {
    const cmd = Command{ .upload = .{ .bytes = 1024, .align_bytes = 256 } };
    const core = as_core_command(cmd);
    try testing.expect(core != null);
    try testing.expectEqual(@as(usize, 1024), core.?.upload.bytes);
    try testing.expectEqual(@as(u32, 256), core.?.upload.align_bytes);
}

test "as_core_command returns null for full-only variants" {
    const cmd = Command{ .render_draw = .{ .draw_count = 1 } };
    try testing.expect(as_core_command(cmd) == null);
}

test "as_full_command converts full union variants" {
    const cmd = Command{ .sampler_create = .{ .handle = 42 } };
    const full = as_full_command(cmd);
    try testing.expect(full != null);
    try testing.expectEqual(@as(u64, 42), full.?.sampler_create.handle);
}

test "as_full_command returns null for core-only variants" {
    const cmd = Command{ .barrier = .{ .dependency_count = 3 } };
    try testing.expect(as_full_command(cmd) == null);
}

test "command_kind extracts tag from Command union" {
    const cmd = Command{ .dispatch = .{ .x = 1, .y = 2, .z = 3 } };
    try testing.expectEqual(CommandKind.dispatch, command_kind(cmd));
}
