const std = @import("std");

const CHUNK_WORDS: usize = 128;
const CHUNK_COUNT: usize = 21;

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
};

pub fn rewriteF16OutputPackInPlace(buf: []u8, pos: *usize) EmitError!void {
    try rewriteF16OutputPackInPlaceForExtent(buf, pos, "hidden_size");
}

pub fn rewriteF16OutputPackInPlaceForExtent(buf: []u8, pos: *usize, extent: []const u8) EmitError!void {
    var scratch: [24576]u8 = undefined;
    var scratch_pos: usize = 0;
    var needle: [160]u8 = undefined;

    scratch_pos = 0;
    for (0..CHUNK_COUNT) |chunk| try writeChunkDecl(&scratch, &scratch_pos, chunk);
    const output_decl = try writeNeedle(&needle, "var output: [{s}]f16 = @zeros([{s}]f16);\n", .{ extent, extent });
    try insertAfterFirst(buf, pos, output_decl, scratch[0..scratch_pos]);

    scratch_pos = 0;
    for (0..CHUNK_COUNT) |chunk| try writeChunkPtr(&scratch, &scratch_pos, chunk);
    try insertAfterFirst(buf, pos, "var output_ptr: [*]f16 = &output;\n", scratch[0..scratch_pos]);

    scratch_pos = 0;
    for (0..CHUNK_COUNT) |chunk| try writeChunkPackLoop(&scratch, &scratch_pos, chunk, extent);
    try insertBeforeFirst(buf, pos, "    sys_mod.unblock_cmd_stream();\n", scratch[0..scratch_pos]);

    scratch_pos = 0;
    for (0..CHUNK_COUNT) |chunk| try writeChunkLayoutExport(&scratch, &scratch_pos, chunk);
    try insertAfterFirst(buf, pos, "    @export_name(\"output\", [*]f16, true);\n", scratch[0..scratch_pos]);

    scratch_pos = 0;
    for (0..CHUNK_COUNT) |chunk| try writeChunkSymbolExport(&scratch, &scratch_pos, chunk);
    try insertAfterFirst(buf, pos, "    @export_symbol(output_ptr, \"output\");\n", scratch[0..scratch_pos]);
}

fn writeChunkDecl(buf: []u8, pos: *usize, chunk: usize) EmitError!void {
    try writeFmt(buf, pos, "var output_chunk_{d:0>4}: [{d}]u32 = @zeros([{d}]u32);\n", .{ chunk, CHUNK_WORDS, CHUNK_WORDS });
}

fn writeChunkPtr(buf: []u8, pos: *usize, chunk: usize) EmitError!void {
    try writeFmt(buf, pos, "var output_chunk_{d:0>4}_ptr: [*]u32 = &output_chunk_{d:0>4};\n", .{ chunk, chunk });
}

fn writeChunkPackLoop(buf: []u8, pos: *usize, chunk: usize, extent: []const u8) EmitError!void {
    try writeFmt(buf, pos,
        \\    for (@range(i16, {d})) |word| {{
        \\        const pair = @as(u32, word) + {d};
        \\        const base = pair * 2;
        \\        if (base + 1 < @as(u32, {s})) {{
        \\            const lo: u32 = @as(u32, @bitcast(u16, output[base]));
        \\            const hi: u32 = @as(u32, @bitcast(u16, output[base + 1]));
        \\            output_chunk_{d:0>4}[@as(u32, word)] = lo | (hi << 16);
        \\        }} else {{
        \\            output_chunk_{d:0>4}[@as(u32, word)] = 0;
        \\        }}
        \\    }}
        \\
    , .{ CHUNK_WORDS, chunk * CHUNK_WORDS, extent, chunk, chunk });
}

fn writeChunkLayoutExport(buf: []u8, pos: *usize, chunk: usize) EmitError!void {
    try writeFmt(buf, pos, "    @export_name(\"output_chunk_{d:0>4}\", [*]u32, true);\n", .{chunk});
}

fn writeChunkSymbolExport(buf: []u8, pos: *usize, chunk: usize) EmitError!void {
    try writeFmt(buf, pos, "    @export_symbol(output_chunk_{d:0>4}_ptr, \"output_chunk_{d:0>4}\");\n", .{ chunk, chunk });
}

fn writeFmt(buf: []u8, pos: *usize, comptime fmt: []const u8, args: anytype) EmitError!void {
    const text = std.fmt.bufPrint(buf[pos.*..], fmt, args) catch return error.OutputTooLarge;
    pos.* += text.len;
}

fn writeNeedle(buf: []u8, comptime fmt: []const u8, args: anytype) EmitError![]const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch error.OutputTooLarge;
}

fn insertAfterFirst(buf: []u8, pos: *usize, needle: []const u8, text: []const u8) EmitError!void {
    const idx = std.mem.indexOf(u8, buf[0..pos.*], needle) orelse return error.InvalidIr;
    try insertInPlace(buf, pos, idx + needle.len, text);
}

fn insertBeforeFirst(buf: []u8, pos: *usize, needle: []const u8, text: []const u8) EmitError!void {
    const idx = std.mem.indexOf(u8, buf[0..pos.*], needle) orelse return error.InvalidIr;
    try insertInPlace(buf, pos, idx, text);
}

fn insertInPlace(buf: []u8, pos: *usize, idx: usize, text: []const u8) EmitError!void {
    if (idx > pos.*) return error.InvalidIr;
    if (pos.* + text.len > buf.len) return error.OutputTooLarge;
    std.mem.copyBackwards(u8, buf[idx + text.len .. pos.* + text.len], buf[idx..pos.*]);
    @memcpy(buf[idx..][0..text.len], text);
    pos.* += text.len;
}
