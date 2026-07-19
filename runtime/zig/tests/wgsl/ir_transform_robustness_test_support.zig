// ir_transform_robustness_test_support.zig - Shared helpers for sharded robustness IR transform tests.

pub const std = @import("std");
pub const testing = std.testing;
pub const ir = @import("../../src/compiler/wgsl/ir/ir.zig");
const robustness = @import("../../src/compiler/wgsl/ir/ir_transform_robustness.zig");
pub const apply = robustness.apply;

pub fn make_test_module(allocator: std.mem.Allocator) !ir.Module {
    var module = ir.Module.init(allocator);
    errdefer module.deinit();

    _ = try module.types.intern(.{ .scalar = .u32 });
    _ = try module.types.intern(.{ .scalar = .f32 });
    return module;
}

pub fn u32_type(module: *ir.Module) ir.TypeId {
    for (module.types.items.items, 0..) |item, idx| {
        if (item == .scalar and item.scalar == .u32) return @intCast(idx);
    }
    unreachable;
}

pub fn f32_type(module: *ir.Module) ir.TypeId {
    for (module.types.items.items, 0..) |item, idx| {
        if (item == .scalar and item.scalar == .f32) return @intCast(idx);
    }
    unreachable;
}

pub fn add_struct_type(
    module: *ir.Module,
    allocator: std.mem.Allocator,
    name: []const u8,
    fields: []const struct { name: []const u8, ty: ir.TypeId },
) !ir.TypeId {
    var struct_def = ir.StructDef{ .name = try ir.dup_string(allocator, name) };
    errdefer struct_def.deinit(allocator);
    for (fields) |field| {
        try struct_def.fields.append(allocator, .{
            .name = try ir.dup_string(allocator, field.name),
            .ty = field.ty,
        });
    }
    try module.structs.append(allocator, struct_def);
    const struct_id: ir.StructId = @intCast(module.structs.items.len - 1);
    return try module.types.intern(.{ .struct_ = struct_id });
}
