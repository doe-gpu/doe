const ir = @import("../wgsl/ir/ir.zig");
const schema = @import("schema.zig");

pub const FrontendError = error{
    OutOfMemory,
};

pub fn scalarKindFromIr(scalar: ir.ScalarType) schema.ScalarKind {
    return switch (scalar) {
        .f32 => .f32,
        .f16 => .f16,
        .i32 => .i32,
        .u32 => .u32,
        .abstract_int => .i32,
        .abstract_float => .f32,
        .bool, .void => .u32,
    };
}

test "WGSL scalar kinds have one TSIR mapping" {
    const std = @import("std");

    try std.testing.expectEqual(schema.ScalarKind.f32, scalarKindFromIr(.f32));
    try std.testing.expectEqual(schema.ScalarKind.f16, scalarKindFromIr(.f16));
    try std.testing.expectEqual(schema.ScalarKind.i32, scalarKindFromIr(.abstract_int));
    try std.testing.expectEqual(schema.ScalarKind.u32, scalarKindFromIr(.bool));
}
