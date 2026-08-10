const std = @import("std");

const ir = @import("../../ir/ir.zig");
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

pub fn emitPointerExports(buf: []u8, pos: *usize, module: *const ir.Module) Error!void {
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const address_space = global.addr_space orelse continue;
        if (address_space != .storage) continue;
        try emitExport(buf, pos, global.name);
    }
}

pub fn storageExportName(
    module: *const ir.Module,
    target_index: usize,
    fallback: []const u8,
) []const u8 {
    var index: usize = 0;
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const address_space = global.addr_space orelse continue;
        if (address_space != .storage) continue;
        if (index == target_index) return global.name;
        index += 1;
    }
    return fallback;
}

test "pointer exports include bound storage globals only" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    try module.globals.append(allocator, .{
        .name = try ir.dup_string(allocator, "values"),
        .ty = ir.INVALID_TYPE,
        .class = .var_,
        .addr_space = .storage,
        .binding = .{ .group = 0, .binding = 0 },
    });
    try module.globals.append(allocator, .{
        .name = try ir.dup_string(allocator, "params"),
        .ty = ir.INVALID_TYPE,
        .class = .var_,
        .addr_space = .uniform,
        .binding = .{ .group = 0, .binding = 1 },
    });

    var output: [128]u8 = undefined;
    var position: usize = 0;
    try emitPointerExports(&output, &position, &module);
    try std.testing.expectEqualStrings(
        "    @export_symbol(values_ptr, \"values\");\n",
        output[0..position],
    );
    try std.testing.expectEqualStrings("values", storageExportName(&module, 0, "missing"));
    try std.testing.expectEqualStrings("missing", storageExportName(&module, 1, "missing"));
}
