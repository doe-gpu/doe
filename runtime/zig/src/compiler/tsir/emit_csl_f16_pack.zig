pub fn writeBufferArray(
    writer: anytype,
    prefix: []const u8,
    name: []const u8,
    extent: []const u8,
) !void {
    try writer.print(
        "var {s}{s}_bits: [{s} / 2]u32 = @zeros([{s} / 2]u32);\n",
        .{ prefix, name, extent, extent },
    );
}

pub fn writeBufferPointer(writer: anytype, prefix: []const u8, name: []const u8) !void {
    try writer.print(
        "var {s}{s}_bits_ptr: [*]u32 = &{s}{s}_bits;\n",
        .{ prefix, name, prefix, name },
    );
}

pub fn writePackLoop(
    writer: anytype,
    prefix: []const u8,
    name: []const u8,
    extent: []const u8,
) !void {
    try writer.print("    for (@range(i16, {s} / 2)) |pair| {{\n", .{extent});
    try writer.writeAll("        const base = @as(u32, pair) * 2;\n");
    try writer.print(
        "        const lo: u32 = @as(u32, @bitcast(u16, {s}{s}[base]));\n",
        .{ prefix, name },
    );
    try writer.print(
        "        const hi: u32 = @as(u32, @bitcast(u16, {s}{s}[base + 1]));\n",
        .{ prefix, name },
    );
    try writer.print(
        "        {s}{s}_bits[@as(u32, pair)] = lo | (hi << 16);\n",
        .{ prefix, name },
    );
    try writer.writeAll("    }\n");
}

pub fn writeExportSymbol(writer: anytype, prefix: []const u8, name: []const u8) !void {
    try writer.print(
        "    @export_symbol({s}{s}_bits_ptr, \"{s}\");\n",
        .{ prefix, name, name },
    );
}
