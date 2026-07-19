// shader_emit_test_support.zig - Shared helpers for sharded MSL emitter tests.

pub const std = @import("std");
pub const ir = @import("../../src/compiler/wgsl/ir/ir.zig");
pub const emit_msl_vertex = @import("../../src/compiler/wgsl/emit/msl/emit_msl_vertex.zig");
pub const emit_msl_fragment = @import("../../src/compiler/wgsl/emit/msl/emit_msl_fragment.zig");
pub const emit_msl_shared = @import("../../src/compiler/wgsl/emit/msl/emit_msl_shared.zig");

pub const testing = std.testing;
pub const allocator = testing.allocator;

pub fn make_module_with_types() ir.Module {
    return ir.Module.init(allocator);
}

pub fn output_str(buf: []const u8, len: usize) []const u8 {
    return buf[0..len];
}

pub fn build_vertex_module(
    module: *ir.Module,
    struct_name: []const u8,
    fields: []const struct { name: []const u8, ty: ir.TypeId, io: ?ir.IoAttr },
    params: []const struct { name: []const u8, ty: ir.TypeId, io: ?ir.IoAttr },
    fn_name: []const u8,
) !ir.Function {
    var struct_def = ir.StructDef{ .name = try ir.dup_string(allocator, struct_name) };
    errdefer struct_def.deinit(allocator);
    for (fields) |f| {
        try struct_def.fields.append(allocator, .{
            .name = try ir.dup_string(allocator, f.name),
            .ty = f.ty,
            .io = f.io,
        });
    }
    try module.structs.append(allocator, struct_def);
    const struct_id: ir.StructId = @intCast(module.structs.items.len - 1);
    const struct_type = try module.types.intern(.{ .struct_ = struct_id });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, fn_name),
        .return_type = struct_type,
        .stage = .vertex,
    };
    errdefer allocator.free(function.name);
    for (params) |p| {
        try function.params.append(allocator, .{
            .name = try ir.dup_string(allocator, p.name),
            .ty = p.ty,
            .io = p.io,
        });
    }

    const return_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{return_stmt});
    const block_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    function.root_stmt = block_stmt;

    return function;
}

pub fn build_fragment_module(
    module: *ir.Module,
    struct_name: []const u8,
    fields: []const struct { name: []const u8, ty: ir.TypeId, io: ?ir.IoAttr },
    params: []const struct { name: []const u8, ty: ir.TypeId, io: ?ir.IoAttr },
    fn_name: []const u8,
) !ir.Function {
    var struct_def = ir.StructDef{ .name = try ir.dup_string(allocator, struct_name) };
    errdefer struct_def.deinit(allocator);
    for (fields) |f| {
        try struct_def.fields.append(allocator, .{
            .name = try ir.dup_string(allocator, f.name),
            .ty = f.ty,
            .io = f.io,
        });
    }
    try module.structs.append(allocator, struct_def);
    const struct_id: ir.StructId = @intCast(module.structs.items.len - 1);
    const struct_type = try module.types.intern(.{ .struct_ = struct_id });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, fn_name),
        .return_type = struct_type,
        .stage = .fragment,
    };
    errdefer allocator.free(function.name);
    for (params) |p| {
        try function.params.append(allocator, .{
            .name = try ir.dup_string(allocator, p.name),
            .ty = p.ty,
            .io = p.io,
        });
    }

    const return_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{return_stmt});
    const block_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    function.root_stmt = block_stmt;

    return function;
}

pub fn cleanup_function(function: *ir.Function) void {
    allocator.free(function.name);
    for (function.params.items) |*p| allocator.free(p.name);
    function.params.deinit(allocator);
    function.locals.deinit(allocator);
    for (function.exprs.items) |*e| {
        switch (e.data) {
            .call => |*call| allocator.free(call.name),
            .member => |*member| allocator.free(member.field_name),
            else => {},
        }
    }
    function.exprs.deinit(allocator);
    function.expr_args.deinit(allocator);
    function.stmts.deinit(allocator);
    function.stmt_children.deinit(allocator);
    for (function.switch_cases.items) |*case_node| case_node.deinit(allocator);
    function.switch_cases.deinit(allocator);
}
