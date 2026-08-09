const std = @import("std");
const ast_mod = @import("ast.zig");
const ir = @import("../ir/ir.zig");
const sema_helpers = @import("sema_helpers.zig");
const sema_types = @import("sema_types.zig");

const Node = ast_mod.Node;
const AnalyzeError = sema_types.AnalyzeError;

const parse_access = sema_helpers.parse_access;
const parse_address_space = sema_helpers.parse_address_space;
const parse_wgsl_int_literal = sema_helpers.parse_wgsl_int_literal;
const parse_storage_texture_format = sema_helpers.parse_storage_texture_format;

pub fn resolve_type_parameterized(self: anytype, node: Node) !ir.TypeId {
    const name = self.module.tree.tokenSlice(node.main_token);
    const params_start = node.data.lhs;
    const params_len = node.data.rhs;
    if (std.mem.eql(u8, name, "vec2") or std.mem.eql(u8, name, "vec3") or std.mem.eql(u8, name, "vec4")) {
        if (params_len != 1) return error.InvalidType;
        const elem = try self.resolve_type_node(self.module.tree.extra_data.items[params_start]);
        const len: u8 = if (std.mem.eql(u8, name, "vec2")) 2 else if (std.mem.eql(u8, name, "vec3")) 3 else 4;
        return try self.module.types.intern(.{ .vector = .{ .elem = elem, .len = len } });
    }
    if (parse_matrix_shape(name)) |shape| {
        if (params_len != 1) return error.InvalidType;
        const elem = try self.resolve_type_node(self.module.tree.extra_data.items[params_start]);
        return try self.module.types.intern(.{ .matrix = .{ .elem = elem, .columns = shape.columns, .rows = shape.rows } });
    }
    if (std.mem.eql(u8, name, "array")) {
        if (params_len < 1 or params_len > 2) return error.InvalidType;
        const elem = try self.resolve_type_node(self.module.tree.extra_data.items[params_start]);
        var len: ?u32 = null;
        if (params_len == 2) {
            len = try resolve_array_length_expr(self, self.module.tree.extra_data.items[params_start + 1], 0);
        }
        return try self.module.types.intern(.{ .array = .{ .elem = elem, .len = len } });
    }
    if (std.mem.eql(u8, name, "atomic")) {
        if (params_len != 1) return error.InvalidType;
        return try self.module.types.intern(.{ .atomic = try self.resolve_type_node(self.module.tree.extra_data.items[params_start]) });
    }
    if (std.mem.eql(u8, name, "texture_1d")) {
        if (params_len != 1) return error.InvalidType;
        return try self.module.types.intern(.{ .texture_1d = try self.resolve_type_node(self.module.tree.extra_data.items[params_start]) });
    }
    if (std.mem.eql(u8, name, "texture_2d")) {
        if (params_len != 1) return error.InvalidType;
        return try self.module.types.intern(.{ .texture_2d = try self.resolve_type_node(self.module.tree.extra_data.items[params_start]) });
    }
    if (std.mem.eql(u8, name, "texture_3d")) {
        if (params_len != 1) return error.InvalidType;
        return try self.module.types.intern(.{ .texture_3d = try self.resolve_type_node(self.module.tree.extra_data.items[params_start]) });
    }
    if (std.mem.eql(u8, name, "texture_cube")) {
        if (params_len != 1) return error.InvalidType;
        return try self.module.types.intern(.{ .texture_cube = try self.resolve_type_node(self.module.tree.extra_data.items[params_start]) });
    }
    if (std.mem.eql(u8, name, "texture_2d_array")) {
        if (params_len != 1) return error.InvalidType;
        return try self.module.types.intern(.{ .texture_2d_array = try self.resolve_type_node(self.module.tree.extra_data.items[params_start]) });
    }
    if (std.mem.eql(u8, name, "texture_external")) {
        if (params_len != 0) return error.InvalidType;
        return try self.module.types.intern(.{ .texture_2d = self.module.f32_type });
    }
    if (std.mem.eql(u8, name, "texture_storage_2d")) {
        if (params_len != 2) return error.InvalidType;
        const format_node = self.module.tree.nodes.items[self.module.tree.extra_data.items[params_start]];
        if (format_node.tag != .type_name) return error.InvalidType;
        const access_node = self.module.tree.nodes.items[self.module.tree.extra_data.items[params_start + 1]];
        if (access_node.tag != .type_name) return error.InvalidType;
        const access = try parse_access(self.module.tree.tokenSlice(access_node.main_token));
        return try self.module.types.intern(.{ .storage_texture_2d = .{
            .format = try parse_storage_texture_format(self.module.tree.tokenSlice(format_node.main_token)),
            .access = access,
        } });
    }
    if (std.mem.eql(u8, name, "ptr")) {
        if (params_len < 2 or params_len > 3) return error.InvalidType;
        const addr_node = self.module.tree.nodes.items[self.module.tree.extra_data.items[params_start]];
        if (addr_node.tag != .type_name) return error.InvalidType;
        const addr_space = try parse_address_space(self.module.tree.tokenSlice(addr_node.main_token));
        const elem = try self.resolve_type_node(self.module.tree.extra_data.items[params_start + 1]);
        const access = if (params_len == 3) blk: {
            const access_node = self.module.tree.nodes.items[self.module.tree.extra_data.items[params_start + 2]];
            if (access_node.tag != .type_name) return error.InvalidType;
            break :blk try parse_access(self.module.tree.tokenSlice(access_node.main_token));
        } else .read_write;
        return try self.module.types.intern(.{ .ref = .{ .elem = elem, .addr_space = addr_space, .access = access } });
    }
    return error.UnknownType;
}

fn parse_matrix_shape(name: []const u8) ?struct { columns: u8, rows: u8 } {
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

const MAX_ARRAY_LENGTH_CONST_DEPTH: u8 = 32;

fn resolve_array_length_expr(self: anytype, node_idx: u32, depth: u8) AnalyzeError!u32 {
    if (depth >= MAX_ARRAY_LENGTH_CONST_DEPTH) return error.InvalidType;
    const tree = self.module.tree;
    const node = tree.nodes.items[node_idx];
    return switch (node.tag) {
        .int_literal => parse_wgsl_int_literal(u32, tree.tokenSlice(node.main_token)) catch error.InvalidType,
        .ident_expr, .type_name => resolve_named_array_length_const(self, tree.tokenSlice(node.main_token), depth + 1),
        .binary_expr => resolve_array_length_binary(self, node, depth + 1),
        else => error.InvalidType,
    };
}

fn resolve_named_array_length_const(self: anytype, name: []const u8, depth: u8) AnalyzeError!u32 {
    const global_index = self.module.global_map.get(name) orelse return error.InvalidType;
    const global_info = self.module.globals.items[global_index];
    if (global_info.class != .const_) return error.InvalidType;
    const global_node = self.module.tree.nodes.items[global_info.node_idx];
    if (global_node.tag != .const_decl or global_node.data.rhs == ast_mod.NULL_NODE) return error.InvalidType;
    return resolve_array_length_expr(self, global_node.data.rhs, depth);
}

fn resolve_array_length_binary(self: anytype, node: Node, depth: u8) AnalyzeError!u32 {
    const lhs = try resolve_array_length_expr(self, node.data.lhs, depth);
    const rhs = try resolve_array_length_expr(self, node.data.rhs, depth);
    const op = self.module.tree.tokens.items[node.main_token].tag;
    return switch (op) {
        .@"+" => std.math.add(u32, lhs, rhs) catch error.InvalidType,
        .@"-" => std.math.sub(u32, lhs, rhs) catch error.InvalidType,
        .@"*" => std.math.mul(u32, lhs, rhs) catch error.InvalidType,
        .@"/" => if (rhs == 0) error.InvalidType else @divTrunc(lhs, rhs),
        .@"%" => if (rhs == 0) error.InvalidType else @mod(lhs, rhs),
        .shift_left => if (rhs >= @bitSizeOf(u32)) error.InvalidType else lhs << @as(std.math.Log2Int(u32), @intCast(rhs)),
        .shift_right => if (rhs >= @bitSizeOf(u32)) error.InvalidType else lhs >> @as(std.math.Log2Int(u32), @intCast(rhs)),
        .@"&" => lhs & rhs,
        .@"|" => lhs | rhs,
        .@"^" => lhs ^ rhs,
        else => error.InvalidType,
    };
}
