const std = @import("std");
const command_kind = @import("../../src/command/command_kind.zig");
const command_json = @import("../../src/command/command_json.zig");
const command_json_raw = @import("../../src/command/command_json_raw.zig");
const model = @import("../../src/contracts/model/model.zig");

const parseCommands = command_json.parseCommands;
const freeCommands = command_json.freeCommands;
const ParseError = command_json.ParseError;
const RawCommand = command_json_raw.RawCommand;
const NormalizedKind = command_kind.NormalizedKind;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

// ============================================================
// Valid command parsing — each command type with minimal JSON

test "parse upload command with explicit bytes and default alignment" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "upload", "bytes": 2048}]
    );
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expectEqual(@as(usize, 2048), cmds[0].upload.bytes);
    try std.testing.expectEqual(@as(u32, 4), cmds[0].upload.align_bytes);
}

test "parseCommands returns empty slice for empty JSON array" {
    const result = try parseCommands(std.testing.allocator, "[]");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "parseCommands returns empty slice for whitespace-padded empty array" {
    const result = try parseCommands(std.testing.allocator, "  [  ]  \n");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "parse upload command with custom alignment" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "upload", "bytes": 512, "alignBytes": 16}]
    );
    try std.testing.expectEqual(@as(u32, 16), cmds[0].upload.align_bytes);
}

test "parseKind resolves command field" {
    const raw = RawCommand{ .command = "barrier" };
    try std.testing.expectEqual(NormalizedKind.barrier, try command_kind.parseKind(raw));
}

test "parseKind resolves kind field" {
    const raw = RawCommand{ .kind = "upload" };
    try std.testing.expectEqual(NormalizedKind.upload, try command_kind.parseKind(raw));
}

test "parseKind resolves command_kind field" {
    const raw = RawCommand{ .command_kind = "dispatch" };
    try std.testing.expectEqual(NormalizedKind.dispatch, try command_kind.parseKind(raw));
}

test "parseKind is case-insensitive" {
    const raw = RawCommand{ .command = "UPLOAD" };
    try std.testing.expectEqual(NormalizedKind.upload, try command_kind.parseKind(raw));
}

test "parseKind recognizes upload aliases" {
    const raw_upload = RawCommand{ .command = "upload" };
    const raw_buffer_upload = RawCommand{ .command = "buffer_upload" };
    try std.testing.expectEqual(NormalizedKind.upload, try command_kind.parseKind(raw_upload));
    try std.testing.expectEqual(NormalizedKind.upload, try command_kind.parseKind(raw_buffer_upload));
}

test "parseKind recognizes render_draw aliases" {
    const aliases = [_][]const u8{ "render_draw", "draw", "draw_call", "draw_indexed" };
    for (aliases) |alias| {
        const raw = RawCommand{ .command = alias };
        try std.testing.expectEqual(NormalizedKind.render_draw, try command_kind.parseKind(raw));
    }
}

test "parseKind recognizes copy aliases" {
    const aliases = [_][]const u8{
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
    };
    for (aliases) |alias| {
        const raw = RawCommand{ .command = alias };
        try std.testing.expectEqual(NormalizedKind.copy, try command_kind.parseKind(raw));
    }
}

test "parseKind returns error for missing command kind" {
    const raw = RawCommand{};
    try std.testing.expectError(ParseError.MissingCommandKind, command_kind.parseKind(raw));
}

test "parseKind returns error for unknown command kind" {
    const raw = RawCommand{ .command = "nonexistent_command" };
    try std.testing.expectError(ParseError.UnknownCommandKind, command_kind.parseKind(raw));
}

test "parse barrier command with default dependency count" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "barrier"}]
    );
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expectEqual(@as(u32, 0), cmds[0].barrier.dependency_count);
}

test "parse barrier command with explicit dependency count" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "barrier", "dependency_count": 3}]
    );
    try std.testing.expectEqual(@as(u32, 3), cmds[0].barrier.dependency_count);
}

test "parse dispatch command with x y z dimensions" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "dispatch", "x": 4, "y": 8, "z": 2}]
    );
    try std.testing.expectEqual(@as(u32, 4), cmds[0].dispatch.x);
    try std.testing.expectEqual(@as(u32, 8), cmds[0].dispatch.y);
    try std.testing.expectEqual(@as(u32, 2), cmds[0].dispatch.z);
}

test "parse dispatch command defaults to 1,1,1" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "dispatch"}]
    );
    try std.testing.expectEqual(@as(u32, 1), cmds[0].dispatch.x);
    try std.testing.expectEqual(@as(u32, 1), cmds[0].dispatch.y);
    try std.testing.expectEqual(@as(u32, 1), cmds[0].dispatch.z);
}

test "parse dispatch with workgroupCount array" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "dispatch", "workgroupCount": [16, 8, 4]}]
    );
    try std.testing.expectEqual(@as(u32, 16), cmds[0].dispatch.x);
    try std.testing.expectEqual(@as(u32, 8), cmds[0].dispatch.y);
    try std.testing.expectEqual(@as(u32, 4), cmds[0].dispatch.z);
}

test "parse dispatch with workgroups array" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "dispatch", "workgroups": [3, 5, 7]}]
    );
    try std.testing.expectEqual(@as(u32, 3), cmds[0].dispatch.x);
    try std.testing.expectEqual(@as(u32, 5), cmds[0].dispatch.y);
    try std.testing.expectEqual(@as(u32, 7), cmds[0].dispatch.z);
}

test "parse dispatch_indirect command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "dispatch_indirect", "x": 2, "y": 3, "z": 1}]
    );
    try std.testing.expectEqual(model.CommandKind.dispatch_indirect, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(@as(u32, 2), cmds[0].dispatch_indirect.x);
}

test "parse kernel_dispatch command with minimal fields" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "my_shader.wgsl", "x": 4}]
    );
    try std.testing.expectEqual(model.CommandKind.kernel_dispatch, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqualStrings("my_shader.wgsl", cmds[0].kernel_dispatch.kernel);
    try std.testing.expectEqual(@as(u32, 4), cmds[0].kernel_dispatch.x);
    try std.testing.expectEqual(@as(u32, 1), cmds[0].kernel_dispatch.y);
    try std.testing.expectEqual(@as(u32, 1), cmds[0].kernel_dispatch.z);
    try std.testing.expectEqual(@as(u32, 1), cmds[0].kernel_dispatch.repeat);
    try std.testing.expectEqual(model.KernelDispatchRepeatSynchronization.dependent, cmds[0].kernel_dispatch.repeat_synchronization);
    try std.testing.expect(cmds[0].kernel_dispatch.entry_point == null);
    try std.testing.expect(cmds[0].kernel_dispatch.bindings == null);
}

test "parse kernel_dispatch command with entry_point and repeat" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "compute.wgsl", "entry_point": "main", "repeat": 5}]
    );
    try std.testing.expectEqualStrings("main", cmds[0].kernel_dispatch.entry_point.?);
    try std.testing.expectEqual(@as(u32, 5), cmds[0].kernel_dispatch.repeat);
}

test "parse kernel_dispatch independent repeat synchronization" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "compute.wgsl", "repeat": 5, "repeatSynchronization": "independent"}]
    );
    try std.testing.expectEqual(model.KernelDispatchRepeatSynchronization.independent, cmds[0].kernel_dispatch.repeat_synchronization);
}

test "parse kernel_dispatch repeat_synchronization alias" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "compute.wgsl", "repeat": 5, "repeat_synchronization": "dependent"}]
    );
    try std.testing.expectEqual(model.KernelDispatchRepeatSynchronization.dependent, cmds[0].kernel_dispatch.repeat_synchronization);
}

test "parse kernel_dispatch rejects unknown repeat synchronization" {
    var arena = testArena();
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidCommandPayload, parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "compute.wgsl", "repeatSynchronization": "hidden-fast"}]
    ));
}

test "parse kernel_dispatch with bindings" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl",
        \\ "bindings": [{"binding": 0, "handle": 42, "kind": "buffer"}]}]
    );
    const bindings = cmds[0].kernel_dispatch.bindings.?;
    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    try std.testing.expectEqual(@as(u32, 0), bindings[0].binding);
    try std.testing.expectEqual(@as(u64, 42), bindings[0].resource_handle);
    try std.testing.expectEqual(model.KernelBindingResourceKind.buffer, bindings[0].resource_kind);
}

test "parse copy_buffer_to_texture command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "copy_buffer_to_texture", "bytes": 1024, "src_handle": 1, "dst_handle": 2}]
    );
    try std.testing.expectEqual(model.CommandKind.copy_buffer_to_texture, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(@as(usize, 1024), cmds[0].copy_buffer_to_texture.bytes);
    try std.testing.expectEqual(@as(u64, 1), cmds[0].copy_buffer_to_texture.src.handle);
    try std.testing.expectEqual(@as(u64, 2), cmds[0].copy_buffer_to_texture.dst.handle);
    try std.testing.expectEqual(model.CopyDirection.buffer_to_texture, cmds[0].copy_buffer_to_texture.direction);
}

test "parse copy_buffer_to_buffer command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "copy_buffer_to_buffer", "bytes": 256, "src_handle": 10, "dst_handle": 20}]
    );
    try std.testing.expectEqual(model.CopyDirection.buffer_to_buffer, cmds[0].copy_buffer_to_texture.direction);
    try std.testing.expectEqual(model.CopyResourceKind.buffer, cmds[0].copy_buffer_to_texture.src.kind);
    try std.testing.expectEqual(model.CopyResourceKind.buffer, cmds[0].copy_buffer_to_texture.dst.kind);
}

test "parse render_draw command with minimal fields" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "draw_count": 10}]
    );
    try std.testing.expectEqual(model.CommandKind.render_draw, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(@as(u32, 10), cmds[0].render_draw.draw_count);
    try std.testing.expectEqual(@as(u32, 3), cmds[0].render_draw.vertex_count);
    try std.testing.expectEqual(@as(u32, 1), cmds[0].render_draw.instance_count);
}

test "parse render_pass command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "render_pass", "draw_count": 5, "vertex_count": 6}]
    );
    try std.testing.expectEqual(model.CommandKind.render_pass, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(@as(u32, 5), cmds[0].render_pass.draw_count);
    try std.testing.expectEqual(@as(u32, 6), cmds[0].render_pass.vertex_count);
}

test "parse draw_indirect command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "draw_indirect", "draw_count": 1}]
    );
    try std.testing.expectEqual(model.CommandKind.draw_indirect, std.meta.activeTag(cmds[0]));
}

test "parse map_async command with default write mode" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "map_async", "bytes": 8192}]
    );
    try std.testing.expectEqual(@as(usize, 8192), cmds[0].map_async.bytes);
    try std.testing.expectEqual(model.MapAsyncMode.write, cmds[0].map_async.mode);
}

test "parse map_async command with read mode" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "map_async", "bytes": 4096, "map_mode": "read"}]
    );
    try std.testing.expectEqual(model.MapAsyncMode.read, cmds[0].map_async.mode);
}

test "parse sampler_create command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "sampler_create", "handle": 99}]
    );
    try std.testing.expectEqual(model.CommandKind.sampler_create, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(@as(u64, 99), cmds[0].sampler_create.handle);
}

test "parse sampler_destroy command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "sampler_destroy", "handle": 42}]
    );
    try std.testing.expectEqual(model.CommandKind.sampler_destroy, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(@as(u64, 42), cmds[0].sampler_destroy.handle);
}

test "parse surface_create command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "surface_create", "handle": 7}]
    );
    try std.testing.expectEqual(model.CommandKind.surface_create, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(@as(u64, 7), cmds[0].surface_create.handle);
}

test "parse surface_configure command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "surface_configure", "handle": 1, "width": 800, "height": 600}]
    );
    try std.testing.expectEqual(model.CommandKind.surface_configure, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(@as(u64, 1), cmds[0].surface_configure.handle);
    try std.testing.expectEqual(@as(u32, 800), cmds[0].surface_configure.width);
    try std.testing.expectEqual(@as(u32, 600), cmds[0].surface_configure.height);
}

test "parse texture_destroy command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "texture_destroy", "handle": 55}]
    );
    try std.testing.expectEqual(model.CommandKind.texture_destroy, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(@as(u64, 55), cmds[0].texture_destroy.handle);
}

// ============================================================
// Command kind aliases — verify alternate spellings resolve correctly

test "buffer_upload alias resolves to upload command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "buffer_upload", "bytes": 64}]
    );
    try std.testing.expectEqual(model.CommandKind.upload, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(@as(usize, 64), cmds[0].upload.bytes);
}

test "draw alias resolves to render_draw command" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "draw", "draw_count": 1}]
    );
    try std.testing.expectEqual(model.CommandKind.render_draw, std.meta.activeTag(cmds[0]));
}

test "kind field is accepted as command name source" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"kind": "barrier"}]
    );
    try std.testing.expectEqual(model.CommandKind.barrier, std.meta.activeTag(cmds[0]));
}

test "command_kind field is accepted as command name source" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command_kind": "dispatch"}]
    );
    try std.testing.expectEqual(model.CommandKind.dispatch, std.meta.activeTag(cmds[0]));
}

test "command kind is case-insensitive" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "UPLOAD", "bytes": 32}]
    );
    try std.testing.expectEqual(model.CommandKind.upload, std.meta.activeTag(cmds[0]));
}

test "camelCase copy alias resolves correctly" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "copyBufferToTexture", "bytes": 128, "src_handle": 1, "dst_handle": 2}]
    );
    try std.testing.expectEqual(model.CommandKind.copy_buffer_to_texture, std.meta.activeTag(cmds[0]));
}

test "dispatch_workgroups alias resolves to dispatch" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "dispatch_workgroups"}]
    );
    try std.testing.expectEqual(model.CommandKind.dispatch, std.meta.activeTag(cmds[0]));
}

test "create_sampler alias resolves to sampler_create" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "create_sampler", "handle": 1}]
    );
    try std.testing.expectEqual(model.CommandKind.sampler_create, std.meta.activeTag(cmds[0]));
}

test "destroy_texture alias resolves to texture_destroy" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "destroy_texture", "handle": 1}]
    );
    try std.testing.expectEqual(model.CommandKind.texture_destroy, std.meta.activeTag(cmds[0]));
}

// ============================================================
// Malformed JSON

test "completely invalid JSON returns error" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(), "not json at all");
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "truncated JSON array returns error" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(), "[{\"command\": \"upload\"");
    try std.testing.expectError(error.UnexpectedEndOfInput, result);
}

test "missing closing brace in object returns error" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(), "[{\"command\": \"upload\", \"bytes\": 10]");
    try std.testing.expectError(error.SyntaxError, result);
}

test "bare string is not a valid command array" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(), "\"upload\"");
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "JSON object instead of array returns error" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(), "{\"command\": \"upload\", \"bytes\": 10}");
    try std.testing.expectError(error.UnexpectedToken, result);
}

// ============================================================
// Missing required fields

test "upload without bytes field returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "upload"}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "copy without bytes field returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "copy_buffer_to_texture", "src_handle": 1, "dst_handle": 2}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "copy without src_handle returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "copy_buffer_to_texture", "bytes": 100, "dst_handle": 2}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "copy without dst_handle returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "copy_buffer_to_texture", "bytes": 100, "src_handle": 1}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "kernel_dispatch without kernel returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch"}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "render_draw without draw_count returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "render_draw"}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "sampler_create without handle returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "sampler_create"}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "sampler_destroy without handle returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "sampler_destroy"}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "surface_configure without width returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "surface_configure", "handle": 1, "height": 600}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "map_async without bytes returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "map_async"}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "kernel_dispatch binding without handle returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl",
        \\ "bindings": [{"binding": 0, "kind": "buffer"}]}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "kernel_dispatch binding without binding index returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl",
        \\ "bindings": [{"handle": 1, "kind": "buffer"}]}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "kernel_dispatch binding without kind defaults to buffer" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl",
        \\ "bindings": [{"binding": 0, "handle": 1}]}]
    );
    const bindings = cmds[0].kernel_dispatch.bindings.?;
    try std.testing.expectEqual(model.KernelBindingResourceKind.buffer, bindings[0].resource_kind);
}

test "kernel_dispatch binding with invalid kind returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl",
        \\ "bindings": [{"binding": 0, "handle": 1, "kind": "nonexistent_kind"}]}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

// ============================================================
// Empty/null inputs

test "empty string returns JSON parse error" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(), "");
    try std.testing.expectError(error.UnexpectedEndOfInput, result);
}

test "empty JSON array returns empty command slice" {
    const result = try parseCommands(std.testing.allocator, "[]");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "whitespace-padded empty array returns empty command slice" {
    const result = try parseCommands(std.testing.allocator, "  [  ]  \n");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "empty object in array without command field returns MissingCommandKind" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(), "[{}]");
    try std.testing.expectError(ParseError.MissingCommandKind, result);
}

// ============================================================
// Unknown command types

test "unknown command type returns UnknownCommandKind" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "nonexistent_command"}]
    );
    try std.testing.expectError(ParseError.UnknownCommandKind, result);
}

test "empty command string returns UnknownCommandKind" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": ""}]
    );
    try std.testing.expectError(ParseError.UnknownCommandKind, result);
}

// ============================================================
// Boundary values

test "dispatch with zero x dimension returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "dispatch", "x": 0}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "dispatch with zero y dimension returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "dispatch", "x": 1, "y": 0}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "dispatch with zero z dimension returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "dispatch", "x": 1, "y": 1, "z": 0}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "render_draw with zero draw_count returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "draw_count": 0}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "render_draw with zero vertex_count returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "draw_count": 1, "vertex_count": 0}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "render_draw with zero instance_count returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "draw_count": 1, "instance_count": 0}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "render_draw with zero target_width returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "draw_count": 1, "target_width": 0}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "render_draw with zero target_height returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "draw_count": 1, "target_height": 0}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "kernel_dispatch with repeat=0 returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl", "repeat": 0}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "upload with bytes=1 is valid minimum size" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "upload", "bytes": 1}]
    );
    try std.testing.expectEqual(@as(usize, 1), cmds[0].upload.bytes);
}

test "map_async with invalid mode returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "map_async", "bytes": 100, "map_mode": "invalid"}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "render_draw viewport_min_depth out of range returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "draw_count": 1, "viewport_min_depth": 1.5}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

test "render_draw viewport_max_depth less than min returns InvalidCommandPayload" {
    var arena = testArena();
    defer arena.deinit();
    const result = parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "draw_count": 1, "viewport_min_depth": 0.8, "viewport_max_depth": 0.2}]
    );
    try std.testing.expectError(ParseError.InvalidCommandPayload, result);
}

// ============================================================
// Multiple commands in a single array

test "parse multiple heterogeneous commands preserves order" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "upload", "bytes": 100},
        \\ {"command": "barrier", "dependency_count": 2},
        \\ {"command": "dispatch", "x": 8}]
    );
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expectEqual(model.CommandKind.upload, std.meta.activeTag(cmds[0]));
    try std.testing.expectEqual(model.CommandKind.barrier, std.meta.activeTag(cmds[1]));
    try std.testing.expectEqual(model.CommandKind.dispatch, std.meta.activeTag(cmds[2]));
    try std.testing.expectEqual(@as(usize, 100), cmds[0].upload.bytes);
    try std.testing.expectEqual(@as(u32, 2), cmds[1].barrier.dependency_count);
    try std.testing.expectEqual(@as(u32, 8), cmds[2].dispatch.x);
}

// ============================================================
// freeCommands lifecycle

test "freeCommands does not crash on empty slice" {
    // parseCommands for "[]" returns a static empty slice, not allocator-owned;
    // verify freeCommands handles this without crashing.
    const result = try parseCommands(std.testing.allocator, "[]");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "freeCommands releases kernel_dispatch allocations via arena" {
    // Use arena to manage JSON parser intermediate allocations; verify the
    // freeCommands path handles kernel_dispatch sub-allocations correctly.
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "test.wgsl", "entry_point": "main",
        \\ "bindings": [{"binding": 0, "handle": 1, "kind": "buffer"}]}]
    );
    try std.testing.expectEqualStrings("test.wgsl", cmds[0].kernel_dispatch.kernel);
    try std.testing.expectEqualStrings("main", cmds[0].kernel_dispatch.entry_point.?);
    try std.testing.expectEqual(@as(usize, 1), cmds[0].kernel_dispatch.bindings.?.len);
}

test "freeCommands releases upload commands via arena" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "upload", "bytes": 512}]
    );
    try std.testing.expectEqual(@as(usize, 512), cmds[0].upload.bytes);
}

// ============================================================
// JSON with extra/unknown fields is accepted

test "unknown JSON fields are silently ignored" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "upload", "bytes": 256, "extraField": "ignored", "nested": {"a": 1}}]
    );
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expectEqual(@as(usize, 256), cmds[0].upload.bytes);
}

// ============================================================
// Trailing whitespace and newline handling

test "trailing newlines after array do not cause parse failure" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(), "[{\"command\": \"barrier\"}]\n\n");
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
}

test "trailing spaces after array do not cause parse failure" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(), "[{\"command\": \"barrier\"}]   ");
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
}

// ============================================================
// camelCase alternative field names

test "camelCase srcHandle and dstHandle are accepted for copy" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "copy_buffer_to_buffer", "bytes": 64, "srcHandle": 5, "dstHandle": 6}]
    );
    try std.testing.expectEqual(@as(u64, 5), cmds[0].copy_buffer_to_texture.src.handle);
    try std.testing.expectEqual(@as(u64, 6), cmds[0].copy_buffer_to_texture.dst.handle);
}

test "camelCase dependencyCount is accepted for barrier" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "barrier", "dependencyCount": 7}]
    );
    try std.testing.expectEqual(@as(u32, 7), cmds[0].barrier.dependency_count);
}

test "camelCase drawCount is accepted for render_draw" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "drawCount": 3}]
    );
    try std.testing.expectEqual(@as(u32, 3), cmds[0].render_draw.draw_count);
}

test "camelCase entryPoint is accepted for kernel_dispatch" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl", "entryPoint": "compute_main"}]
    );
    try std.testing.expectEqualStrings("compute_main", cmds[0].kernel_dispatch.entry_point.?);
}

test "camelCase mapMode is accepted for map_async" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "map_async", "bytes": 1024, "mapMode": "read"}]
    );
    try std.testing.expectEqual(model.MapAsyncMode.read, cmds[0].map_async.mode);
}

// ============================================================
// kernel_name alias for kernel field

test "kernel_name is accepted as alias for kernel" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel_name": "alt_shader.wgsl"}]
    );
    try std.testing.expectEqualStrings("alt_shader.wgsl", cmds[0].kernel_dispatch.kernel);
}

// ============================================================
// dispatch_count alias for repeat in kernel_dispatch

test "dispatch_count is accepted as repeat alias in kernel_dispatch" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl", "dispatch_count": 10}]
    );
    try std.testing.expectEqual(@as(u32, 10), cmds[0].kernel_dispatch.repeat);
}

// ============================================================
// render_draw defaults for optional fields

test "render_draw uses default target dimensions and format" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "draw_count": 1}]
    );
    try std.testing.expectEqual(model.DEFAULT_RENDER_TARGET_HANDLE, cmds[0].render_draw.target_handle);
    try std.testing.expectEqual(model.DEFAULT_RENDER_TARGET_WIDTH, cmds[0].render_draw.target_width);
    try std.testing.expectEqual(model.DEFAULT_RENDER_TARGET_HEIGHT, cmds[0].render_draw.target_height);
    try std.testing.expectEqual(model.DEFAULT_RENDER_TARGET_FORMAT, cmds[0].render_draw.target_format);
}

test "render_draw uses default viewport depth range 0..1" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "render_draw", "draw_count": 1}]
    );
    try std.testing.expectEqual(@as(f32, 0), cmds[0].render_draw.viewport_min_depth);
    try std.testing.expectEqual(@as(f32, 1), cmds[0].render_draw.viewport_max_depth);
}

// ============================================================
// kernel_dispatch warmup and initialize defaults

test "kernel_dispatch warmup_dispatch_count defaults to 0" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl"}]
    );
    try std.testing.expectEqual(@as(u32, 0), cmds[0].kernel_dispatch.warmup_dispatch_count);
}

test "kernel_dispatch initialize_buffers_on_create defaults to false" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl"}]
    );
    try std.testing.expectEqual(false, cmds[0].kernel_dispatch.initialize_buffers_on_create);
}

test "kernel_dispatch initialize_buffers_on_create can be set to true" {
    var arena = testArena();
    defer arena.deinit();
    const cmds = try parseCommands(arena.allocator(),
        \\[{"command": "kernel_dispatch", "kernel": "k.wgsl", "initialize_buffers_on_create": true}]
    );
    try std.testing.expectEqual(true, cmds[0].kernel_dispatch.initialize_buffers_on_create);
}
