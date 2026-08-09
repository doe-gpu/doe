const std = @import("std");

const INTEGER_TEXT_CAPACITY: usize = 32;

pub const Error = error{
    OutputTooLarge,
};

pub fn write(buf: []u8, pos: *usize, text: []const u8) Error!void {
    if (pos.* + text.len > buf.len) return error.OutputTooLarge;
    @memcpy(buf[pos.*..][0..text.len], text);
    pos.* += text.len;
}

pub fn writeInt(buf: []u8, pos: *usize, value: anytype) Error!void {
    var tmp: [INTEGER_TEXT_CAPACITY]u8 = undefined;
    const slice = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return error.OutputTooLarge;
    try write(buf, pos, slice);
}

pub fn writeJsonString(buf: []u8, pos: *usize, value: []const u8) Error!void {
    try write(buf, pos, "\"");
    for (value) |byte| {
        switch (byte) {
            '"' => try write(buf, pos, "\\\""),
            '\\' => try write(buf, pos, "\\\\"),
            '\n' => try write(buf, pos, "\\n"),
            '\r' => try write(buf, pos, "\\r"),
            '\t' => try write(buf, pos, "\\t"),
            else => {
                if (pos.* == buf.len) return error.OutputTooLarge;
                buf[pos.*] = byte;
                pos.* += 1;
            },
        }
    }
    try write(buf, pos, "\"");
}

test "text buffer writes integers and escaped JSON strings" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    try writeInt(&buf, &pos, 42);
    try write(&buf, &pos, ":");
    try writeJsonString(&buf, &pos, "a\n\"b");
    try std.testing.expectEqualStrings("42:\"a\\n\\\"b\"", buf[0..pos]);
}

test "text buffer fails closed before exceeding capacity" {
    var buf: [2]u8 = undefined;
    var pos: usize = 0;
    try std.testing.expectError(error.OutputTooLarge, write(&buf, &pos, "abc"));
    try std.testing.expectEqual(@as(usize, 0), pos);
}
