const std = @import("std");
const ast_mod = @import("ast.zig");
const ir = @import("../ir/ir.zig");
const sema_types = @import("sema_types.zig");

const Ast = ast_mod.Ast;
const SemanticModule = sema_types.SemanticModule;

pub fn init_builtin_types(module: *SemanticModule) !void {
    module.void_type = try module.types.intern(.{ .scalar = .void });
    module.bool_type = try module.types.intern(.{ .scalar = .bool });
    module.abstract_int_type = try module.types.intern(.{ .scalar = .abstract_int });
    module.abstract_float_type = try module.types.intern(.{ .scalar = .abstract_float });
    module.i32_type = try module.types.intern(.{ .scalar = .i32 });
    module.u32_type = try module.types.intern(.{ .scalar = .u32 });
    module.f32_type = try module.types.intern(.{ .scalar = .f32 });
    module.f16_type = try module.types.intern(.{ .scalar = .f16 });
    module.sampler_type = try module.types.intern(.{ .sampler = {} });
    module.sampler_comparison_type = try module.types.intern(.{ .sampler_comparison = {} });
}

pub fn concrete_numeric_type(module: *SemanticModule, lhs: ir.TypeId, rhs: ir.TypeId) ir.TypeId {
    if (lhs == rhs) return lhs;
    if (lhs == module.abstract_int_type) return rhs;
    if (rhs == module.abstract_int_type) return lhs;
    if (lhs == module.abstract_float_type) return rhs;
    if (rhs == module.abstract_float_type) return lhs;
    return lhs;
}

const SPAN_START_MASK: u32 = 0xFFFF;
const SPAN_LEN_SHIFT: u5 = 16;

pub fn decode_packed_span(raw: u32) struct { start: u32, len: u32 } {
    return .{ .start = raw & SPAN_START_MASK, .len = raw >> SPAN_LEN_SHIFT };
}

pub fn parse_single_int_attr(tree: *const Ast, attr_idx: u32) !u32 {
    const attr = tree.nodes.items[attr_idx];
    const span = decode_packed_span(attr.data.rhs);
    if (span.len == 0) return error.InvalidAttribute;
    const arg = tree.nodes.items[tree.extra_data.items[span.start]];
    if (arg.tag != .int_literal) return error.InvalidAttribute;
    return try parse_wgsl_int_literal(u32, tree.tokenSlice(arg.main_token));
}

pub fn parse_builtin_attr(tree: *const Ast, attr_idx: u32) !ir.Builtin {
    const attr = tree.nodes.items[attr_idx];
    const span = decode_packed_span(attr.data.rhs);
    if (span.len == 0) return error.InvalidAttribute;
    const arg = tree.nodes.items[tree.extra_data.items[span.start]];
    if (arg.tag != .ident_expr) return error.InvalidAttribute;
    const name = tree.tokenSlice(arg.main_token);
    if (std.mem.eql(u8, name, "position")) return .position;
    if (std.mem.eql(u8, name, "frag_depth")) return .frag_depth;
    if (std.mem.eql(u8, name, "front_facing")) return .front_facing;
    if (std.mem.eql(u8, name, "global_invocation_id")) return .global_invocation_id;
    if (std.mem.eql(u8, name, "local_invocation_id")) return .local_invocation_id;
    if (std.mem.eql(u8, name, "local_invocation_index")) return .local_invocation_index;
    if (std.mem.eql(u8, name, "workgroup_id")) return .workgroup_id;
    if (std.mem.eql(u8, name, "num_workgroups")) return .num_workgroups;
    if (std.mem.eql(u8, name, "sample_index")) return .sample_index;
    if (std.mem.eql(u8, name, "sample_mask")) return .sample_mask;
    if (std.mem.eql(u8, name, "vertex_index")) return .vertex_index;
    if (std.mem.eql(u8, name, "instance_index")) return .instance_index;
    if (std.mem.eql(u8, name, "subgroup_size")) return .subgroup_size;
    if (std.mem.eql(u8, name, "subgroup_invocation_id")) return .subgroup_invocation_id;
    if (std.mem.eql(u8, name, "clip_distances")) return .clip_distances;
    if (std.mem.eql(u8, name, "primitive_index")) return .primitive_index;
    return error.InvalidAttribute;
}

pub fn parse_address_space(name: []const u8) !ir.AddressSpace {
    if (std.mem.eql(u8, name, "function")) return .function;
    if (std.mem.eql(u8, name, "private")) return .private;
    if (std.mem.eql(u8, name, "workgroup")) return .workgroup;
    if (std.mem.eql(u8, name, "uniform")) return .uniform;
    if (std.mem.eql(u8, name, "storage")) return .storage;
    return error.InvalidAttribute;
}

pub fn parse_access(name: []const u8) !ir.AccessMode {
    if (std.mem.eql(u8, name, "read")) return .read;
    if (std.mem.eql(u8, name, "write")) return .write;
    if (std.mem.eql(u8, name, "read_write")) return .read_write;
    return error.InvalidAttribute;
}

pub fn parse_storage_texture_format(name: []const u8) !ir.TextureFormat {
    if (std.mem.eql(u8, name, "rgba8unorm")) return .rgba8unorm;
    if (std.mem.eql(u8, name, "rgba8snorm")) return .rgba8snorm;
    if (std.mem.eql(u8, name, "rgba8uint")) return .rgba8uint;
    if (std.mem.eql(u8, name, "rgba8sint")) return .rgba8sint;
    if (std.mem.eql(u8, name, "rgba16uint")) return .rgba16uint;
    if (std.mem.eql(u8, name, "rgba16sint")) return .rgba16sint;
    if (std.mem.eql(u8, name, "rgba16float")) return .rgba16float;
    if (std.mem.eql(u8, name, "r32uint")) return .r32uint;
    if (std.mem.eql(u8, name, "r32sint")) return .r32sint;
    if (std.mem.eql(u8, name, "r32float")) return .r32float;
    if (std.mem.eql(u8, name, "rg32uint")) return .rg32uint;
    if (std.mem.eql(u8, name, "rg32sint")) return .rg32sint;
    if (std.mem.eql(u8, name, "rg32float")) return .rg32float;
    if (std.mem.eql(u8, name, "rgba32uint")) return .rgba32uint;
    if (std.mem.eql(u8, name, "rgba32sint")) return .rgba32sint;
    if (std.mem.eql(u8, name, "rgba32float")) return .rgba32float;
    return error.InvalidAttribute;
}

fn trim_numeric_suffix(literal: []const u8) []const u8 {
    return trim_int_suffix(literal);
}

fn trim_int_suffix(literal: []const u8) []const u8 {
    if (literal.len == 0) return literal;
    const last = literal[literal.len - 1];
    return switch (last) {
        'u', 'i' => literal[0 .. literal.len - 1],
        else => literal,
    };
}

fn trim_float_suffix(literal: []const u8) []const u8 {
    if (literal.len == 0) return literal;
    const last = literal[literal.len - 1];
    return switch (last) {
        'f', 'h' => literal[0 .. literal.len - 1],
        else => literal,
    };
}

pub fn int_literal_suffix(literal: []const u8) enum { none, i, u } {
    if (literal.len == 0) return .none;
    return switch (literal[literal.len - 1]) {
        'i' => .i,
        'u' => .u,
        else => .none,
    };
}

pub fn float_literal_suffix(literal: []const u8) enum { none, f, h } {
    if (literal.len == 0) return .none;
    return switch (literal[literal.len - 1]) {
        'f' => .f,
        'h' => .h,
        else => .none,
    };
}

pub fn parse_wgsl_int_literal(comptime T: type, literal: []const u8) !T {
    const trimmed = trim_int_suffix(literal);
    const base: u8 = if (std.mem.startsWith(u8, trimmed, "0x")) 16 else if (std.mem.startsWith(u8, trimmed, "0o")) 8 else if (std.mem.startsWith(u8, trimmed, "0b")) 2 else 10;
    const digits = if (base == 10) trimmed else trimmed[2..];
    return try std.fmt.parseInt(T, digits, base);
}

pub fn parse_wgsl_float_literal(literal: []const u8) !f64 {
    return try std.fmt.parseFloat(f64, trim_float_suffix(literal));
}

pub const ParsedSwizzle = struct {
    len: u8,
    indices: [4]u32,
};

pub fn parse_vector_swizzle(field_name: []const u8, vector_len: u8) error{InvalidSwizzle}!ParsedSwizzle {
    if (field_name.len == 0 or field_name.len > 4) return error.InvalidSwizzle;

    const family: u8 = switch (field_name[0]) {
        'x', 'y', 'z', 'w' => 'x',
        'r', 'g', 'b', 'a' => 'r',
        else => return error.InvalidSwizzle,
    };

    var result = ParsedSwizzle{
        .len = @intCast(field_name.len),
        .indices = .{ 0, 0, 0, 0 },
    };
    for (field_name, 0..) |component, index| {
        const resolved: u32 = switch (family) {
            'x' => switch (component) {
                'x' => 0,
                'y' => 1,
                'z' => 2,
                'w' => 3,
                else => return error.InvalidSwizzle,
            },
            'r' => switch (component) {
                'r' => 0,
                'g' => 1,
                'b' => 2,
                'a' => 3,
                else => return error.InvalidSwizzle,
            },
            else => unreachable,
        };
        if (resolved >= vector_len) return error.InvalidSwizzle;
        result.indices[index] = resolved;
    }
    return result;
}

test "parse wgsl numeric literals trims suffixes and keeps prefixes" {
    try std.testing.expectEqual(@as(u32, 1), try parse_wgsl_int_literal(u32, "1u"));
    try std.testing.expectEqual(@as(u32, 7), try parse_wgsl_int_literal(u32, "7i"));
    try std.testing.expectEqual(@as(u32, 255), try parse_wgsl_int_literal(u32, "0xFFu"));
    try std.testing.expectEqual(@as(u32, 255), try parse_wgsl_int_literal(u32, "0xff"));
    try std.testing.expectEqual(@as(u32, 10), try parse_wgsl_int_literal(u32, "0b1010u"));
    try std.testing.expectEqual(@as(u32, 63), try parse_wgsl_int_literal(u32, "0o77u"));
    try std.testing.expectEqual(@as(f64, 2.0), try parse_wgsl_float_literal("2.0f"));
    try std.testing.expectEqual(@as(f64, 7.0), try parse_wgsl_float_literal("7f"));
    try std.testing.expectEqual(@as(f64, 3.5), try parse_wgsl_float_literal("3.5h"));
}

test "parse vector swizzles validates component sets" {
    const xyw = try parse_vector_swizzle("xyw", 4);
    try std.testing.expectEqual(@as(u8, 3), xyw.len);
    try std.testing.expectEqual(@as(u32, 0), xyw.indices[0]);
    try std.testing.expectEqual(@as(u32, 1), xyw.indices[1]);
    try std.testing.expectEqual(@as(u32, 3), xyw.indices[2]);
    try std.testing.expectError(error.InvalidSwizzle, parse_vector_swizzle("xrg", 4));
    try std.testing.expectError(error.InvalidSwizzle, parse_vector_swizzle("w", 3));
}
