//! Shared, one-way planner primitives consumed by residency, reduction, and
//! collective synthesis.

const std = @import("std");
const targets = @import("../targets/mod.zig");
const tsir = @import("schema.zig");

pub const Error = error{OutOfMemory};

pub fn supportsNumericalMode(descriptor: targets.TargetDescriptor, kind: tsir.ScalarKind) bool {
    const mode = numericalModeForScalar(kind) orelse return false;
    for (descriptor.correctness.native_numerical_modes) |native| {
        if (native == mode) return true;
    }
    return false;
}

fn numericalModeForScalar(kind: tsir.ScalarKind) ?targets.NumericalMode {
    return switch (kind) {
        .f32 => .f32,
        .f16 => .f16,
        .bf16 => .bf16,
        .i32, .u32 => null,
    };
}

pub fn appendRejection(
    allocator: std.mem.Allocator,
    rejections: *std.ArrayList(tsir.RejectionEntry),
    reason: tsir.RejectionReason,
    function_index: u32,
    field: []const u8,
    node_index: u32,
    detail_text: []const u8,
) Error!void {
    const path = try std.fmt.allocPrint(
        allocator,
        "functions[{d}].{s}[{d}]",
        .{ function_index, field, node_index },
    );
    const detail = try allocator.dupe(u8, detail_text);
    try rejections.append(allocator, .{
        .reason = reason,
        .node_path = path,
        .detail = detail,
    });
}
