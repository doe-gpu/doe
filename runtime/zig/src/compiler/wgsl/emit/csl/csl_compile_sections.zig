const std = @import("std");

const spec = @import("csl_spec.zig");
const text_buffer = @import("csl_text_buffer.zig");

pub fn write(buf: []u8, pos: *usize, filename: []const u8) text_buffer.Error!void {
    try text_buffer.write(buf, pos, spec.SECTION_SEPARATOR);
    try text_buffer.write(buf, pos, filename);
    try text_buffer.write(buf, pos, spec.SECTION_SEPARATOR_END);
}

pub fn body(csl: []const u8, filename: []const u8) ?[]const u8 {
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(
        &marker_buf,
        "{s}{s}{s}",
        .{ spec.SECTION_SEPARATOR, filename, spec.SECTION_SEPARATOR_END },
    ) catch return null;

    const header_index = std.mem.indexOf(u8, csl, marker) orelse return null;
    const body_start = header_index + marker.len;
    const next_header = std.mem.indexOfPos(u8, csl, body_start, spec.SECTION_SEPARATOR) orelse csl.len;
    return csl[body_start..next_header];
}

test "compile sections round-trip named bodies" {
    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    try write(&buf, &pos, "layout.csl");
    try text_buffer.write(&buf, &pos, "layout");
    try write(&buf, &pos, "pe_program.csl");
    try text_buffer.write(&buf, &pos, "program");

    try std.testing.expectEqualStrings("layout", body(buf[0..pos], "layout.csl").?);
    try std.testing.expectEqualStrings("program", body(buf[0..pos], "pe_program.csl").?);
    try std.testing.expectEqual(@as(?[]const u8, null), body(buf[0..pos], "missing.csl"));
}
