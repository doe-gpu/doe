const std = @import("std");
const ast_mod = @import("ast.zig");
const ir = @import("../ir/ir.zig");

const Node = ast_mod.Node;
const NULL_NODE = ast_mod.NULL_NODE;

pub fn analyze_stmt(self: anytype, node_idx: u32, body: anytype) !void {
    const node = self.module.tree.nodes.items[node_idx];
    switch (node.tag) {
        .block => {
            try body.push_scope();
            const stmt_start = node.data.lhs;
            const stmt_count = node.data.rhs;
            var i: u32 = 0;
            while (i < stmt_count) : (i += 1) {
                try analyze_stmt(self, self.module.tree.extra_data.items[stmt_start + i], body);
            }
            body.pop_scope();
        },
        .var_stmt, .let_stmt, .const_stmt => try analyze_local_decl(self, node, body),
        .return_stmt => {
            const expr_node = node.data.lhs;
            if (expr_node != NULL_NODE) {
                const expr_ty = try analyze_expr(self, expr_node, body);
                if (!self.type_compatible(body.function().return_type, expr_ty)) return error.TypeMismatch;
            }
        },
        .if_stmt => {
            const extra = self.module.tree.extra_data.items;
            const then_block = extra[node.data.rhs + 0];
            const else_block = extra[node.data.rhs + 1];
            _ = try analyze_expr(self, node.data.lhs, body);
            try analyze_stmt(self, then_block, body);
            if (else_block != NULL_NODE) try analyze_stmt(self, else_block, body);
        },
        .for_stmt => {
            const extra = self.module.tree.extra_data.items;
            const base = node.data.lhs;
            try body.push_scope();
            body.loop_depth += 1;
            defer body.loop_depth -= 1;
            if (extra[base + 0] != NULL_NODE) try analyze_stmt(self, extra[base + 0], body);
            if (extra[base + 1] != NULL_NODE) _ = try analyze_expr(self, extra[base + 1], body);
            if (extra[base + 2] != NULL_NODE) try analyze_stmt(self, extra[base + 2], body);
            try analyze_stmt(self, node.data.rhs, body);
            body.pop_scope();
        },
        .while_stmt => {
            body.loop_depth += 1;
            defer body.loop_depth -= 1;
            _ = try analyze_expr(self, node.data.lhs, body);
            try analyze_stmt(self, node.data.rhs, body);
        },
        .loop_stmt => {
            body.loop_depth += 1;
            defer body.loop_depth -= 1;
            try analyze_stmt(self, node.data.lhs, body);
        },
        .break_stmt => {
            if (body.loop_depth == 0 and body.switch_depth == 0) return error.InvalidWgsl;
            if (node.data.lhs != NULL_NODE) {
                if (body.loop_depth == 0) return error.InvalidWgsl;
                const cond_ty = try analyze_expr(self, node.data.lhs, body);
                if (!self.type_compatible(self.module.bool_type, cond_ty)) return error.TypeMismatch;
            }
        },
        .continue_stmt => {
            if (body.loop_depth == 0) return error.InvalidWgsl;
        },
        .continuing_stmt => {
            if (body.loop_depth == 0) return error.InvalidWgsl;
            try analyze_stmt(self, node.data.lhs, body);
        },
        .switch_stmt => {
            const extra = self.module.tree.extra_data.items;
            const case_start = node.data.rhs & 0xFFFF;
            const case_count = node.data.rhs >> 16;
            _ = try analyze_expr(self, node.data.lhs, body);
            body.switch_depth += 1;
            defer body.switch_depth -= 1;
            var i: u32 = 0;
            while (i < case_count) : (i += 1) {
                const case_node = self.module.tree.nodes.items[extra[case_start + i]];
                const selector_start = case_node.data.rhs & 0xFFFF;
                const selector_count = case_node.data.rhs >> 16;
                var j: u32 = 0;
                while (j < selector_count) : (j += 1) {
                    _ = try analyze_expr(self, extra[selector_start + j], body);
                }
                try analyze_stmt(self, case_node.data.lhs, body);
            }
        },
        .switch_case => try analyze_stmt(self, node.data.lhs, body),
        .discard_stmt => {},
        .expr_stmt => _ = try analyze_expr(self, node.data.lhs, body),
        .assign_stmt => {
            const lhs_ty = try analyze_expr(self, node.data.lhs, body);
            const lhs_info = self.module.node_info.items[node.data.lhs];
            if (lhs_info.category != .ref) return error.InvalidWgsl;
            const rhs_ty = try analyze_expr(self, node.data.rhs, body);
            if (!self.type_compatible(lhs_ty, rhs_ty)) return error.TypeMismatch;
            self.module.node_info.items[node_idx].ty = lhs_ty;
        },
        .inc_stmt, .dec_stmt => {
            const lhs_ty = try analyze_expr(self, node.data.lhs, body);
            const lhs_info = self.module.node_info.items[node.data.lhs];
            if (lhs_info.category != .ref) return error.InvalidWgsl;
            self.module.node_info.items[node_idx].ty = lhs_ty;
        },
        else => {},
    }
}

pub fn analyze_local_decl(self: anytype, node: Node, body: anytype) !void {
    const name = self.module.tree.tokenSlice(node.main_token + 1);
    const explicit_type = if (node.data.lhs != NULL_NODE) try self.resolve_type_node(node.data.lhs) else ir.INVALID_TYPE;
    const init_ty = if (node.data.rhs != NULL_NODE) try analyze_expr(self, node.data.rhs, body) else ir.INVALID_TYPE;
    const resolved_type = blk: {
        if (explicit_type != ir.INVALID_TYPE) break :blk explicit_type;
        if (init_ty != ir.INVALID_TYPE) break :blk init_ty;
        return error.InvalidType;
    };
    if (explicit_type != ir.INVALID_TYPE and init_ty != ir.INVALID_TYPE and !self.type_compatible(explicit_type, init_ty)) {
        return error.TypeMismatch;
    }
    const local_index: u32 = @intCast(body.function().locals.items.len);
    try body.function().locals.append(self.module.allocator, .{
        .name = try ir.dup_string(self.module.allocator, name),
        .ty = resolved_type,
        .mutable = node.tag == .var_stmt,
    });
    try body.bind_name(body.function().locals.items[local_index].name, .{ .local = local_index });
}

pub fn analyze_expr(self: anytype, node_idx: u32, body: anytype) !ir.TypeId {
    const existing = self.module.node_info.items[node_idx];
    if (existing.ty != ir.INVALID_TYPE) return existing.ty;

    const node = self.module.tree.nodes.items[node_idx];
    var info = self.module.node_info.items[node_idx];
    info = .{};
    info.ty = switch (node.tag) {
        .int_literal => self.module.abstract_int_type,
        .float_literal => self.module.abstract_float_type,
        .bool_literal => self.module.bool_type,
        .ident_expr => try resolve_ident_expr(self, node, body, &info),
        .unary_expr => try analyze_unary(self, node, body),
        .binary_expr => try analyze_binary(self, node, body),
        .call_expr => try analyze_call(self, node, body),
        .member_expr => try analyze_member(self, node, body, &info),
        .index_expr => try analyze_index(self, node, body, &info),
        else => return error.UnsupportedConstruct,
    };
    if (node.tag != .ident_expr and node.tag != .member_expr and node.tag != .index_expr) {
        info.category = .value;
    }
    self.module.node_info.items[node_idx] = info;
    return info.ty;
}

pub fn resolve_ident_expr(self: anytype, node: Node, body: anytype, out: anytype) !ir.TypeId {
    const name = self.module.tree.tokenSlice(node.main_token);
    const symbol = if (body) |ctx| ctx.resolve_name(name) else null;
    if (symbol == null) return error.UnknownIdentifier;
    out.symbol = symbol.?;
    return switch (symbol.?) {
        .global => |index| blk: {
            out.category = .ref;
            break :blk self.module.globals.items[index].ty;
        },
        .param => |index| blk: {
            out.category = .ref;
            break :blk body.?.function().params.items[index].ty;
        },
        .local => |index| blk: {
            out.category = .ref;
            break :blk body.?.function().locals.items[index].ty;
        },
        .function => |index| self.module.functions.items[index].return_type,
        .none => return error.UnknownIdentifier,
    };
}

pub fn analyze_unary(self: anytype, node: Node, body: anytype) !ir.TypeId {
    const operand_ty = try analyze_expr(self, node.data.lhs, body);
    return switch (self.module.tree.tokens.items[node.main_token].tag) {
        .@"-", .@"~" => operand_ty,
        .@"!" => self.module.bool_type,
        // Address-of (&expr): pointer types are not tracked by sema; return the
        // underlying type so callers (e.g. arrayLength(&buf)) can type-check.
        .@"&" => operand_ty,
        else => error.InvalidWgsl,
    };
}

pub fn analyze_binary(self: anytype, node: Node, body: anytype) !ir.TypeId {
    const lhs_ty = try analyze_expr(self, node.data.lhs, body);
    const rhs_ty = try analyze_expr(self, node.data.rhs, body);
    const op = self.module.tree.tokens.items[node.main_token].tag;
    return switch (op) {
        .eq_eq, .not_eq, .@"<", .lte, .@">", .gte, .and_and, .or_or => self.module.bool_type,
        else => if (self.type_compatible(lhs_ty, rhs_ty)) self.concrete_numeric_type(self.module, lhs_ty, rhs_ty) else error.TypeMismatch,
    };
}

pub fn analyze_call(self: anytype, node: Node, body: anytype) !ir.TypeId {
    const name = self.module.tree.tokenSlice(node.main_token);
    const args_start = node.data.lhs;
    const args_len = node.data.rhs;

    var arg_types_buf: [16]ir.TypeId = undefined;
    if (args_len > arg_types_buf.len) return error.UnsupportedConstruct;
    var i: u32 = 0;
    while (i < args_len) : (i += 1) {
        arg_types_buf[i] = try analyze_expr(self, self.module.tree.extra_data.items[args_start + i], body);
    }

    if (self.try_resolve_named_type(name)) |ty| {
        return ty;
    }
    if (self.module.function_map.get(name)) |function_index| {
        const fn_info = self.module.functions.items[function_index];
        if (fn_info.params.items.len != args_len) return error.TypeMismatch;
        for (fn_info.params.items, 0..) |param, arg_index| {
            if (!self.type_compatible(param.ty, arg_types_buf[arg_index])) return error.TypeMismatch;
        }
        return fn_info.return_type;
    }
    return try self.infer_builtin_call(name, arg_types_buf[0..args_len]);
}

pub fn analyze_member(self: anytype, node: Node, body: anytype, out: anytype) !ir.TypeId {
    const base_ty = try analyze_expr(self, node.data.lhs, body);
    const field_name = self.module.tree.tokenSlice(node.data.rhs);
    switch (self.module.types.get(base_ty)) {
        .struct_ => |struct_id| {
            const struct_info = self.module.structs.items[struct_id];
            for (struct_info.fields.items) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    out.category = self.module.node_info.items[node.data.lhs].category;
                    return field.ty;
                }
            }
            return error.UnknownIdentifier;
        },
        .vector => |vec| {
            const swizzle_len = field_name.len;
            if (swizzle_len == 0 or swizzle_len > 4) return error.InvalidWgsl;
            if (swizzle_len == 1) return vec.elem;
            return try self.module.types.intern(.{ .vector = .{ .elem = vec.elem, .len = @intCast(swizzle_len) } });
        },
        else => return error.InvalidWgsl,
    }
}

pub fn analyze_index(self: anytype, node: Node, body: anytype, out: anytype) !ir.TypeId {
    const base_ty = try analyze_expr(self, node.data.lhs, body);
    _ = try analyze_expr(self, node.data.rhs, body);
    out.category = self.module.node_info.items[node.data.lhs].category;
    return switch (self.module.types.get(base_ty)) {
        .array => |arr| arr.elem,
        .vector => |vec| vec.elem,
        .matrix => |mat| try self.module.types.intern(.{ .vector = .{ .elem = mat.elem, .len = mat.rows } }),
        else => error.InvalidWgsl,
    };
}
