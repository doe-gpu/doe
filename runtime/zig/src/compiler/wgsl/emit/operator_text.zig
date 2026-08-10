const std = @import("std");

const ir = @import("../ir/ir.zig");

pub fn unaryOp(op: ir.UnaryOp) []const u8 {
    return switch (op) {
        .neg => "-",
        .not => "!",
        .bit_not => "~",
    };
}

pub fn binaryOp(op: ir.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .rem => "%",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shift_left => "<<",
        .shift_right => ">>",
        .equal => "==",
        .not_equal => "!=",
        .less => "<",
        .less_equal => "<=",
        .greater => ">",
        .greater_equal => ">=",
        .logical_and => "&&",
        .logical_or => "||",
    };
}

pub fn assignOp(op: ir.AssignOp) []const u8 {
    return switch (op) {
        .assign => "=",
        .add => "+=",
        .sub => "-=",
        .mul => "*=",
        .div => "/=",
        .rem => "%=",
        .bit_and => "&=",
        .bit_or => "|=",
        .bit_xor => "^=",
    };
}

test "C-family operator spellings are exhaustive" {
    try std.testing.expectEqualStrings("~", unaryOp(.bit_not));
    try std.testing.expectEqualStrings("&&", binaryOp(.logical_and));
    try std.testing.expectEqualStrings("^=", assignOp(.bit_xor));
}
