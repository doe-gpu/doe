const std = @import("std");
const ir = @import("../ir/ir.zig");

pub const MatrixShape = struct {
    columns: u8,
    rows: u8,
};

pub fn parseAddressSpace(name: []const u8) !ir.AddressSpace {
    if (std.mem.eql(u8, name, "function")) return .function;
    if (std.mem.eql(u8, name, "private")) return .private;
    if (std.mem.eql(u8, name, "workgroup")) return .workgroup;
    if (std.mem.eql(u8, name, "uniform")) return .uniform;
    if (std.mem.eql(u8, name, "storage")) return .storage;
    return error.InvalidAttribute;
}

pub fn parseAccess(name: []const u8) !ir.AccessMode {
    if (std.mem.eql(u8, name, "read")) return .read;
    if (std.mem.eql(u8, name, "write")) return .write;
    if (std.mem.eql(u8, name, "read_write")) return .read_write;
    return error.InvalidAttribute;
}

pub fn parseMatrixShape(name: []const u8) ?MatrixShape {
    if (!std.mem.startsWith(u8, name, "mat") or name.len != 6 or name[4] != 'x') return null;
    const columns: u8 = switch (name[3]) {
        '2' => 2,
        '3' => 3,
        '4' => 4,
        else => return null,
    };
    const rows: u8 = switch (name[5]) {
        '2' => 2,
        '3' => 3,
        '4' => 4,
        else => return null,
    };
    return .{ .columns = columns, .rows = rows };
}

test "matrix shape parser accepts WGSL matrix dimensions" {
    const shape = parseMatrixShape("mat3x4").?;
    try std.testing.expectEqual(@as(u8, 3), shape.columns);
    try std.testing.expectEqual(@as(u8, 4), shape.rows);
    try std.testing.expect(parseMatrixShape("mat5x4") == null);
}
