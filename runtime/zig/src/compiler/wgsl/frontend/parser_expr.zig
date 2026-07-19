// doe_wgsl/parser_expr.zig — Expression and type-expression parsing.
//
// Precedence-climbing expression parser, postfix/primary parsing,
// call expressions, type constructors, and type expression parsing.
// All functions take an `anytype` self matching the Parser interface.

const ast_mod = @import("ast.zig");
const token_mod = @import("token.zig");
const NodeTag = ast_mod.NodeTag;
const NULL_NODE = ast_mod.NULL_NODE;
const Tag = token_mod.Tag;

// ============================================================
// Expressions (precedence climbing)
// ============================================================

pub fn parseExpr(self: anytype) @TypeOf(self.*).Error!u32 {
    return parseOr(self);
}

fn parseOr(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseAnd(self);
    while (self.peekTag() == .or_or) {
        const op = self.token_idx;
        self.advance();
        const rhs = try parseAnd(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseAnd(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseBitwiseOr(self);
    while (self.peekTag() == .and_and) {
        const op = self.token_idx;
        self.advance();
        const rhs = try parseBitwiseOr(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseBitwiseOr(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseBitwiseXor(self);
    while (self.peekTag() == .@"|") {
        const op = self.token_idx;
        self.advance();
        const rhs = try parseBitwiseXor(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseBitwiseXor(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseBitwiseAnd(self);
    while (self.peekTag() == .@"^") {
        const op = self.token_idx;
        self.advance();
        const rhs = try parseBitwiseAnd(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseBitwiseAnd(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseEquality(self);
    while (self.peekTag() == .@"&") {
        const op = self.token_idx;
        self.advance();
        const rhs = try parseEquality(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseEquality(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseRelational(self);
    while (self.peekTag() == .eq_eq or self.peekTag() == .not_eq) {
        const op = self.token_idx;
        self.advance();
        const rhs = try parseRelational(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseRelational(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseShift(self);
    while (self.peekTag() == .@"<" or self.peekTag() == .@">" or
        self.peekTag() == .lte or self.peekTag() == .gte)
    {
        const op = self.token_idx;
        self.advance();
        const rhs = try parseShift(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseShift(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseAddSub(self);
    while (self.peekTag() == .shift_left or self.peekTag() == .shift_right) {
        const op = self.token_idx;
        self.advance();
        const rhs = try parseAddSub(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseAddSub(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseMulDiv(self);
    while (self.peekTag() == .@"+" or self.peekTag() == .@"-") {
        const op = self.token_idx;
        self.advance();
        const rhs = try parseMulDiv(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseMulDiv(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseUnary(self);
    while (self.peekTag() == .@"*" or self.peekTag() == .@"/" or self.peekTag() == .@"%") {
        const op = self.token_idx;
        self.advance();
        const rhs = try parseUnary(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseUnary(self: anytype) @TypeOf(self.*).Error!u32 {
    const tag = self.peekTag();
    if (tag == .@"-" or tag == .@"!" or tag == .@"~" or tag == .@"&" or tag == .@"*") {
        const op = self.token_idx;
        self.advance();
        const operand = try parseUnary(self);
        return self.tree.addNode(.{
            .tag = .unary_expr,
            .main_token = op,
            .data = .{ .lhs = operand },
        });
    }
    return parsePostfix(self);
}

fn parsePostfix(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parsePrimary(self);
    while (true) {
        switch (self.peekTag()) {
            .@"." => {
                const dot_token = self.token_idx;
                self.advance();
                const field_token = self.token_idx;
                self.advance();
                lhs = try self.tree.addNode(.{
                    .tag = .member_expr,
                    .main_token = dot_token,
                    .data = .{ .lhs = lhs, .rhs = field_token },
                });
            },
            .@"[" => {
                const bracket_token = self.token_idx;
                self.advance();
                const index = try parseExpr(self);
                _ = try self.expect(.@"]");
                lhs = try self.tree.addNode(.{
                    .tag = .index_expr,
                    .main_token = bracket_token,
                    .data = .{ .lhs = lhs, .rhs = index },
                });
            },
            else => break,
        }
    }
    return lhs;
}

fn parsePrimary(self: anytype) @TypeOf(self.*).Error!u32 {
    const tag = self.peekTag();
    switch (tag) {
        .int_literal => {
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .int_literal,
                .main_token = tok,
                .data = .{},
            });
        },
        .float_literal => {
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .float_literal,
                .main_token = tok,
                .data = .{},
            });
        },
        .kw_true, .kw_false => {
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .bool_literal,
                .main_token = tok,
                .data = .{},
            });
        },
        .@"(" => {
            self.advance();
            const expr = try parseExpr(self);
            _ = try self.expect(.@")");
            return expr;
        },
        .ident => return parseIdentOrCall(self),

        // Type constructors: vec4f(...), array(...), etc.
        .kw_vec2f,
        .kw_vec3f,
        .kw_vec4f,
        .kw_vec2h,
        .kw_vec3h,
        .kw_vec4h,
        .kw_vec2i,
        .kw_vec3i,
        .kw_vec4i,
        .kw_vec2u,
        .kw_vec3u,
        .kw_vec4u,
        .kw_mat2x2f,
        .kw_mat3x3f,
        .kw_mat4x4f,
        .kw_mat2x2h,
        .kw_mat3x3h,
        .kw_mat4x4h,
        => return parseTypeConstructor(self),

        // Parameterized type constructors: vec4<f32>(...), array<T>(...).
        .kw_vec2,
        .kw_vec3,
        .kw_vec4,
        .kw_mat2x2,
        .kw_mat3x3,
        .kw_mat4x4,
        .kw_mat2x3,
        .kw_mat2x4,
        .kw_mat3x2,
        .kw_mat3x4,
        .kw_mat4x2,
        .kw_mat4x3,
        .kw_array,
        .kw_atomic,
        => return parseTypeConstructor(self),

        // Scalar type constructors: f32(x), u32(x), i32(x), f16(x), bool(x).
        .kw_f32,
        .kw_f16,
        .kw_u32,
        .kw_i32,
        .kw_bool,
        => return parseTypeConstructor(self),

        else => {
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .ident_expr,
                .main_token = tok,
                .data = .{},
            });
        },
    }
}

fn parseIdentOrCall(self: anytype) @TypeOf(self.*).Error!u32 {
    const name_token = self.token_idx;
    self.advance();

    // Check for type-parameterized call: ident<T>(...).
    if (self.peekTag() == .@"<" and looksLikeTypeArgs(self)) {
        return parseGenericCall(self, name_token);
    }

    // Check for function call: ident(...).
    if (self.peekTag() == .@"(") {
        return parseCallArgs(self, name_token);
    }

    return self.tree.addNode(.{
        .tag = .ident_expr,
        .main_token = name_token,
        .data = .{},
    });
}

fn parseTypeConstructor(self: anytype) @TypeOf(self.*).Error!u32 {
    const type_node = switch (self.peekTag()) {
        .kw_vec2f,
        .kw_vec3f,
        .kw_vec4f,
        .kw_vec2h,
        .kw_vec3h,
        .kw_vec4h,
        .kw_vec2i,
        .kw_vec3i,
        .kw_vec4i,
        .kw_vec2u,
        .kw_vec3u,
        .kw_vec4u,
        => blk: {
            const tok = self.token_idx;
            self.advance();
            break :blk try self.tree.addNode(.{
                .tag = .type_vec_shorthand,
                .main_token = tok,
                .data = .{},
            });
        },
        .kw_mat2x2f,
        .kw_mat3x3f,
        .kw_mat4x4f,
        .kw_mat2x2h,
        .kw_mat3x3h,
        .kw_mat4x4h,
        => blk: {
            const tok = self.token_idx;
            self.advance();
            break :blk try self.tree.addNode(.{
                .tag = .type_mat_shorthand,
                .main_token = tok,
                .data = .{},
            });
        },
        .kw_vec2,
        .kw_vec3,
        .kw_vec4,
        .kw_mat2x2,
        .kw_mat3x3,
        .kw_mat4x4,
        .kw_mat2x3,
        .kw_mat2x4,
        .kw_mat3x2,
        .kw_mat3x4,
        .kw_mat4x2,
        .kw_mat4x3,
        .kw_array,
        .kw_atomic,
        .kw_ptr,
        .kw_sampler,
        .kw_texture_1d,
        .kw_texture_2d,
        .kw_texture_external,
        .kw_f32,
        .kw_f16,
        .kw_u32,
        .kw_i32,
        .kw_bool,
        => try parseTypeExpr(self),
        else => return error.UnexpectedToken,
    };

    if (self.peekTag() == .@"(") {
        return parseConstructArgs(self, type_node);
    }

    return type_node;
}

fn parseGenericCall(self: anytype, name_token: u32) @TypeOf(self.*).Error!u32 {
    _ = try self.expect(.@"<");
    const target_type = try parseTypeExpr(self);
    _ = try self.expect(.@">");

    if (self.peekTag() == .@"(") {
        return parseGenericCallArgs(self, name_token, target_type);
    }

    return self.tree.addNode(.{
        .tag = .ident_expr,
        .main_token = name_token,
        .data = .{},
    });
}

pub fn parseCallArgs(self: anytype, name_token: u32) @TypeOf(self.*).Error!u32 {
    _ = try self.expect(.@"(");

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (self.peekTag() != .@")" and self.peekTag() != .eof) {
        const arg = try parseExpr(self);
        try self.scratch.append(self.allocator, arg);
        if (self.peekTag() == .@",") self.advance();
    }
    _ = try self.expect(.@")");

    const args = self.scratch.items[scratch_top..];
    const extra_start = try self.tree.addExtraSlice(args);
    const count: u32 = @intCast(args.len);

    return self.tree.addNode(.{
        .tag = .call_expr,
        .main_token = name_token,
        .data = .{ .lhs = extra_start, .rhs = count },
    });
}

fn parseGenericCallArgs(self: anytype, name_token: u32, target_type: u32) @TypeOf(self.*).Error!u32 {
    _ = try self.expect(.@"(");

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (self.peekTag() != .@")" and self.peekTag() != .eof) {
        const arg = try parseExpr(self);
        try self.scratch.append(self.allocator, arg);
        if (self.peekTag() == .@",") self.advance();
    }
    _ = try self.expect(.@")");

    const args = self.scratch.items[scratch_top..];
    const extra_start = try self.tree.addExtraSlice(args);
    const count: u32 = @intCast(args.len);

    return self.tree.addNode(.{
        .tag = .generic_call_expr,
        .main_token = name_token,
        .data = .{ .lhs = target_type, .rhs = extra_start | (count << 16) },
    });
}

fn parseConstructArgs(self: anytype, type_node: u32) @TypeOf(self.*).Error!u32 {
    _ = try self.expect(.@"(");

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (self.peekTag() != .@")" and self.peekTag() != .eof) {
        const arg = try parseExpr(self);
        try self.scratch.append(self.allocator, arg);
        if (self.peekTag() == .@",") self.advance();
    }
    _ = try self.expect(.@")");

    const args = self.scratch.items[scratch_top..];
    const extra_start = try self.tree.addExtraSlice(args);
    const count: u32 = @intCast(args.len);
    const main_token = self.tree.nodes.items[type_node].main_token;

    return self.tree.addNode(.{
        .tag = .construct_expr,
        .main_token = main_token,
        .data = .{ .lhs = type_node, .rhs = extra_start | (count << 16) },
    });
}

/// Heuristic: does `<` start type arguments (vs a less-than comparison)?
/// Check if we see a closing `>` before `;`, `{`, `}`, or binary operators.
fn looksLikeTypeArgs(self: anytype) bool {
    var i = self.token_idx + 1;
    var depth: u32 = 1;
    while (i < self.tree.tokens.items.len and depth > 0) {
        const t = self.tree.tokens.items[i].tag;
        switch (t) {
            .@"<" => depth += 1,
            .@">" => {
                depth -= 1;
                if (depth == 0) return true;
            },
            .shift_right => {
                if (depth <= 2) return true;
                depth -= 2;
            },
            .@";", .@"{", .@"}", .eof => return false,
            // Operators that cannot appear in type args.
            .@"+",
            .@"-",
            .@"*",
            .@"/",
            .@"%",
            .eq_eq,
            .not_eq,
            .lte,
            .gte,
            .and_and,
            .or_or,
            => return false,
            else => {},
        }
        i += 1;
    }
    return false;
}

// ============================================================
// Type expressions
// ============================================================

pub fn parseTypeExpr(self: anytype) @TypeOf(self.*).Error!u32 {
    const tag = self.peekTag();
    switch (tag) {
        // Shorthand types.
        .kw_vec2f,
        .kw_vec3f,
        .kw_vec4f,
        .kw_vec2h,
        .kw_vec3h,
        .kw_vec4h,
        .kw_vec2i,
        .kw_vec3i,
        .kw_vec4i,
        .kw_vec2u,
        .kw_vec3u,
        .kw_vec4u,
        => {
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .type_vec_shorthand,
                .main_token = tok,
                .data = .{},
            });
        },
        .kw_mat2x2f,
        .kw_mat3x3f,
        .kw_mat4x4f,
        .kw_mat2x2h,
        .kw_mat3x3h,
        .kw_mat4x4h,
        => {
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .type_mat_shorthand,
                .main_token = tok,
                .data = .{},
            });
        },

        // Parameterized built-in types.
        .kw_vec2,
        .kw_vec3,
        .kw_vec4,
        .kw_mat2x2,
        .kw_mat3x3,
        .kw_mat4x4,
        .kw_mat2x3,
        .kw_mat2x4,
        .kw_mat3x2,
        .kw_mat3x4,
        .kw_mat4x2,
        .kw_mat4x3,
        .kw_array,
        .kw_atomic,
        .kw_ptr,
        .kw_sampler,
        .kw_texture_1d,
        .kw_texture_2d,
        .kw_texture_external,
        => return parseParameterizedType(self),

        // Scalar types.
        .kw_f32,
        .kw_f16,
        .kw_u32,
        .kw_i32,
        .kw_bool,
        => {
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .type_name,
                .main_token = tok,
                .data = .{},
            });
        },

        // User-defined type.
        .ident => {
            if (self.token_idx + 1 < self.tree.tokens.items.len and
                self.tree.tokens.items[self.token_idx + 1].tag == .@"<")
            {
                return parseParameterizedType(self);
            }
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .type_name,
                .main_token = tok,
                .data = .{},
            });
        },

        else => {
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .type_name,
                .main_token = tok,
                .data = .{},
            });
        },
    }
}

fn parseParameterizedType(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    const parses_array_length_expr = main_token < self.tree.tokens.items.len and
        self.tree.tokens.items[main_token].tag == .kw_array;
    self.advance();

    if (self.peekTag() != .@"<") {
        return self.tree.addNode(.{
            .tag = .type_name,
            .main_token = main_token,
            .data = .{},
        });
    }

    self.advance();

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    var param_index: u32 = 0;
    while (self.peekTag() != .@">" and self.peekTag() != .shift_right and self.peekTag() != .eof) {
        if (parses_array_length_expr and param_index == 1) {
            const param = try parseArrayLengthExpr(self);
            try self.scratch.append(self.allocator, param);
        } else if (self.peekTag() == .int_literal) {
            const tok = self.token_idx;
            self.advance();
            const node = try self.tree.addNode(.{
                .tag = .int_literal,
                .main_token = tok,
                .data = .{},
            });
            try self.scratch.append(self.allocator, node);
        } else {
            const param = try parseTypeExpr(self);
            try self.scratch.append(self.allocator, param);
        }
        if (self.peekTag() == .@",") self.advance();
        param_index += 1;
    }
    if (self.peekTag() == .shift_right) {
        self.tree.tokens.items[self.token_idx].tag = .@">";
    } else {
        _ = try self.expect(.@">");
    }

    const params = self.scratch.items[scratch_top..];
    const extra_start = try self.tree.addExtraSlice(params);
    const count: u32 = @intCast(params.len);

    return self.tree.addNode(.{
        .tag = .type_parameterized,
        .main_token = main_token,
        .data = .{ .lhs = extra_start, .rhs = count },
    });
}

fn parseArrayLengthExpr(self: anytype) @TypeOf(self.*).Error!u32 {
    return parseArrayLengthBitwiseOr(self);
}

fn parseArrayLengthBitwiseOr(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseArrayLengthBitwiseXor(self);
    while (self.peekTag() == .@"|") {
        const op_token = self.token_idx;
        self.advance();
        const rhs = try parseArrayLengthBitwiseXor(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op_token,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseArrayLengthBitwiseXor(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseArrayLengthBitwiseAnd(self);
    while (self.peekTag() == .@"^") {
        const op_token = self.token_idx;
        self.advance();
        const rhs = try parseArrayLengthBitwiseAnd(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op_token,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseArrayLengthBitwiseAnd(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseArrayLengthShift(self);
    while (self.peekTag() == .@"&") {
        const op_token = self.token_idx;
        self.advance();
        const rhs = try parseArrayLengthShift(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op_token,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseArrayLengthShift(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseArrayLengthAddSub(self);
    while (true) {
        const tag = self.peekTag();
        if (tag != .shift_left and tag != .shift_right) break;
        const op_token = self.token_idx;
        self.advance();
        const rhs = try parseArrayLengthAddSub(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op_token,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseArrayLengthAddSub(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseArrayLengthMulDiv(self);
    while (true) {
        const tag = self.peekTag();
        if (tag != .@"+" and tag != .@"-") break;
        const op_token = self.token_idx;
        self.advance();
        const rhs = try parseArrayLengthMulDiv(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op_token,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseArrayLengthMulDiv(self: anytype) @TypeOf(self.*).Error!u32 {
    var lhs = try parseArrayLengthPrimary(self);
    while (true) {
        const tag = self.peekTag();
        if (tag != .@"*" and tag != .@"/" and tag != .@"%") break;
        const op_token = self.token_idx;
        self.advance();
        const rhs = try parseArrayLengthPrimary(self);
        lhs = try self.tree.addNode(.{
            .tag = .binary_expr,
            .main_token = op_token,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }
    return lhs;
}

fn parseArrayLengthPrimary(self: anytype) @TypeOf(self.*).Error!u32 {
    switch (self.peekTag()) {
        .int_literal => {
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .int_literal,
                .main_token = tok,
                .data = .{},
            });
        },
        .ident => {
            const tok = self.token_idx;
            self.advance();
            return self.tree.addNode(.{
                .tag = .ident_expr,
                .main_token = tok,
                .data = .{},
            });
        },
        .@"(" => {
            self.advance();
            const expr = try parseArrayLengthExpr(self);
            _ = try self.expect(.@")");
            return expr;
        },
        else => return error.UnexpectedToken,
    }
}
