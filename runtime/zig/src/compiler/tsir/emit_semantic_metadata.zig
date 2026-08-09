const schema = @import("schema.zig");

const HEX_DIGITS = "0123456789abcdef";
const NIBBLE_SHIFT: u3 = 4;
const NIBBLE_MASK: u8 = 0x0f;

pub fn writeResidency(writer: anytype, residency: []const schema.ResidencyDecision) !void {
    try writer.print("// residency.count = {d}\n", .{residency.len});
    for (residency, 0..) |decision, index| {
        try writer.print("// residency[{d}].binding_index = {d}\n", .{ index, decision.binding_index });
        try writer.print("// residency[{d}].class = {s}\n", .{ index, @tagName(decision.class) });
        try writer.print("// residency[{d}].axis = ", .{index});
        try writeOptionalU32(writer, decision.axis);
        try writer.print("// residency[{d}].shards = ", .{index});
        try writeOptionalU32(writer, decision.shards);
        try writer.print("// residency[{d}].fabric_color = ", .{index});
        try writeOptionalU32(writer, decision.fabric_color);
        try writer.print("// residency[{d}].chunk_bytes = ", .{index});
        try writeOptionalU64(writer, decision.chunk_bytes);
    }
    try writer.writeAll("\n");
}

pub fn writeTiles(writer: anytype, tiles: []const u32) !void {
    try writer.print("// tiles.count = {d}\n", .{tiles.len});
    for (tiles, 0..) |tile, index| {
        try writer.print("// tiles.per_axis[{d}] = {d}\n", .{ index, tile });
    }
    try writer.writeAll("\n");
}

pub fn writeCollectives(writer: anytype, collectives: []const schema.CollectiveRealizationNode) !void {
    try writer.print("// collectives.count = {d}\n", .{collectives.len});
    for (collectives, 0..) |node, index| {
        try writer.print("// collectives[{d}].semantic_index = {d}\n", .{ index, node.semantic_index });
        try writer.print("// collectives[{d}].tree_shape = {s}\n", .{ index, @tagName(node.tree_shape) });
        try writer.print("// collectives[{d}].fabric_color = ", .{index});
        try writeOptionalU32(writer, node.fabric_color);
        try writer.print("// collectives[{d}].group_size = {d}\n", .{ index, node.group_size });
    }
    try writer.writeAll("\n");
}

pub fn writeReductions(writer: anytype, reductions: []const schema.ReductionRealizationNode) !void {
    try writer.print("// reductions.count = {d}\n", .{reductions.len});
    for (reductions, 0..) |node, index| {
        try writer.print("// reductions[{d}].semantic_index = {d}\n", .{ index, node.semantic_index });
        try writer.print("// reductions[{d}].tree_shape = {s}\n", .{ index, @tagName(node.tree_shape) });
    }
    try writer.writeAll("\n");
}

pub fn writeOptionalU32(writer: anytype, value: ?u32) !void {
    if (value) |present| {
        try writer.print("{d}\n", .{present});
    } else {
        try writer.writeAll("none\n");
    }
}

pub fn writeOptionalU64(writer: anytype, value: ?u64) !void {
    if (value) |present| {
        try writer.print("{d}\n", .{present});
    } else {
        try writer.writeAll("none\n");
    }
}

pub fn writeHash(writer: anytype, hash: [32]u8) !void {
    for (hash) |byte| {
        const high: usize = @intCast(byte >> NIBBLE_SHIFT);
        const low: usize = @intCast(byte & NIBBLE_MASK);
        const pair = [_]u8{ HEX_DIGITS[high], HEX_DIGITS[low] };
        try writer.writeAll(&pair);
    }
}

pub fn writeQuoted(writer: anytype, text: []const u8) !void {
    try writer.writeAll("\"");
    for (text) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeAll("\"");
}
