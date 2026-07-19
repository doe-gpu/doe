const std = @import("std");
const model_commands = @import("../contracts/model/model_commands.zig");
const model_async_types = @import("../contracts/model/model_async_types.zig");
const command_kind = @import("command_kind.zig");
const command_parse_copy = @import("command_parse_copy.zig");
const command_parse_dispatch = @import("command_parse_dispatch.zig");
const command_parse_render = @import("command_parse_render.zig");
const parse_extra = @import("command_json_extra.zig");

const Allocator = std.mem.Allocator;

const command_json_raw = @import("command_json_raw.zig");
const RawCommand = command_json_raw.RawCommand;
pub const ParseError = command_json_raw.ParseError;

const model = struct {
    pub const Command = model_commands.Command;
    pub const MapAsyncMode = model_async_types.MapAsyncMode;
};

pub fn parseCommands(allocator: Allocator, text: []const u8) ![]model.Command {
    if (std.mem.eql(u8, std.mem.trim(u8, text, " \n\r\t"), "[]")) {
        return &[_]model.Command{};
    }

    // Zig's strict parser crashes if the string has a trailing newline after the valid JSON array end.
    const cleanly_trimmed = std.mem.trimRight(u8, text, " \n\r\t\\n");
    var parsed = try std.json.parseFromSlice([]const RawCommand, allocator, cleanly_trimmed, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var list = std.ArrayList(model.Command).empty;
    errdefer {
        for (list.items) |command| {
            freeCommandPayload(allocator, command);
        }
        list.deinit(allocator);
    }
    try list.ensureTotalCapacity(allocator, parsed.value.len);

    for (parsed.value) |raw| {
        list.appendAssumeCapacity(try parseOne(allocator, raw));
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeCommands(allocator: Allocator, commands: []model.Command) void {
    for (commands) |command| {
        freeCommandPayload(allocator, command);
    }
    allocator.free(commands);
}

fn freeCommandPayload(allocator: Allocator, command: model.Command) void {
    switch (command) {
        .kernel_dispatch => |kernel_command| {
            allocator.free(kernel_command.kernel);
            if (kernel_command.entry_point) |entry_point| allocator.free(entry_point);
            if (kernel_command.bindings) |bindings| allocator.free(bindings);
        },
        .buffer_write => |buffer_write| allocator.free(buffer_write.data),
        .render_draw, .draw_indirect, .draw_indexed_indirect, .render_pass => |render_command| {
            if (render_command.index_data) |index_data| {
                switch (index_data) {
                    .uint16 => |values| allocator.free(values),
                    .uint32 => |values| allocator.free(values),
                }
            }
            if (render_command.bind_group_dynamic_offsets) |offsets| {
                allocator.free(offsets);
            }
        },
        .texture_write => |write_texture| allocator.free(write_texture.data),
        else => {},
    }
}

fn parseOne(allocator: Allocator, raw: RawCommand) !model.Command {
    const kind = try command_kind.parseKind(raw);

    if (kind == .upload) {
        const bytes = raw.bytes orelse return ParseError.InvalidCommandPayload;
        const align_bytes = raw.alignBytes orelse raw.alignmentBytes orelse 4;
        return .{ .upload = .{ .bytes = bytes, .align_bytes = align_bytes } };
    }

    if (kind == .buffer_write) {
        const handle = raw.handle orelse raw.resource_handle orelse raw.resourceHandle orelse return ParseError.InvalidCommandPayload;
        const data = raw.data orelse return ParseError.InvalidCommandPayload;
        if (data.len == 0) return ParseError.InvalidCommandPayload;
        const owned_data = try allocator.dupe(u32, data);
        errdefer allocator.free(owned_data);
        return .{ .buffer_write = .{
            .handle = handle,
            .offset = raw.offset orelse 0,
            .buffer_size = raw.buffer_size orelse raw.bufferSize orelse 0,
            .data = owned_data,
        } };
    }

    if (kind == .copy) {
        return command_parse_copy.parseCopyCommand(raw);
    }

    if (kind == .barrier) {
        const dependency_count = raw.dependency_count orelse raw.dependencyCount orelse 0;
        return .{ .barrier = .{ .dependency_count = dependency_count } };
    }

    if (kind == .kernel_dispatch or kind == .dispatch or kind == .dispatch_indirect) {
        return command_parse_dispatch.parseDispatchCommand(allocator, kind, raw);
    }

    if (kind == .render_draw or kind == .draw_indirect or kind == .draw_indexed_indirect or kind == .render_pass) {
        return command_parse_render.parseRenderCommand(allocator, kind, raw);
    }

    if (kind == .sampler_create) return .{ .sampler_create = parse_extra.parseSamplerCreateCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .sampler_destroy) return .{ .sampler_destroy = parse_extra.parseSamplerDestroyCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .texture_write) return .{ .texture_write = parse_extra.parseTextureWriteCommand(allocator, raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .texture_query) return .{ .texture_query = parse_extra.parseTextureQueryCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .texture_destroy) return .{ .texture_destroy = parse_extra.parseTextureDestroyCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .surface_create) return .{ .surface_create = parse_extra.parseSurfaceCreateCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .surface_capabilities) return .{ .surface_capabilities = parse_extra.parseSurfaceCapabilitiesCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .surface_configure) return .{ .surface_configure = parse_extra.parseSurfaceConfigureCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .surface_acquire) return .{ .surface_acquire = parse_extra.parseSurfaceAcquireCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .surface_present) return .{ .surface_present = parse_extra.parseSurfacePresentCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .surface_unconfigure) return .{ .surface_unconfigure = parse_extra.parseSurfaceUnconfigureCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .surface_release) return .{ .surface_release = parse_extra.parseSurfaceReleaseCommand(raw) catch return ParseError.InvalidCommandPayload };
    if (kind == .async_diagnostics) return .{ .async_diagnostics = parse_extra.parseAsyncDiagnosticsCommand(raw) catch return ParseError.InvalidCommandPayload };

    if (kind == .map_async) {
        if (raw.map_async) |m| return .{ .map_async = m };
        const bytes = raw.bytes orelse return ParseError.InvalidCommandPayload;
        const mode_str = raw.map_mode orelse raw.mapMode orelse "write";
        const mode: model.MapAsyncMode = if (std.mem.eql(u8, mode_str, "read")) .read else if (std.mem.eql(u8, mode_str, "write")) .write else return ParseError.InvalidCommandPayload;
        return .{ .map_async = .{ .bytes = bytes, .mode = mode } };
    }

    return ParseError.UnknownCommandKind;
}

// --- inline tests ---
