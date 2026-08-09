const text_buffer = @import("csl_text_buffer.zig");

pub const Error = text_buffer.Error;

pub fn emitBuffer(buf: []u8, pos: *usize, name: []const u8, ty: []const u8) Error!void {
    try text_buffer.write(buf, pos, "var ");
    try text_buffer.write(buf, pos, name);
    try text_buffer.write(buf, pos, ": ");
    try text_buffer.write(buf, pos, ty);
    try text_buffer.write(buf, pos, " = @zeros(");
    try text_buffer.write(buf, pos, ty);
    try text_buffer.write(buf, pos, ");\n");
}

pub fn emitPointer(buf: []u8, pos: *usize, name: []const u8, elem: []const u8) Error!void {
    try text_buffer.write(buf, pos, "var ");
    try text_buffer.write(buf, pos, name);
    try text_buffer.write(buf, pos, "_ptr: [*]");
    try text_buffer.write(buf, pos, elem);
    try text_buffer.write(buf, pos, " = &");
    try text_buffer.write(buf, pos, name);
    try text_buffer.write(buf, pos, ";\n");
}

pub fn emitExport(buf: []u8, pos: *usize, name: []const u8) Error!void {
    try text_buffer.write(buf, pos, "    @export_symbol(");
    try text_buffer.write(buf, pos, name);
    try text_buffer.write(buf, pos, "_ptr, \"");
    try text_buffer.write(buf, pos, name);
    try text_buffer.write(buf, pos, "\");\n");
}
