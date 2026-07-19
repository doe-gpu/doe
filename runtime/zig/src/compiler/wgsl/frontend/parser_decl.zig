// doe_wgsl/parser_decl.zig — Declaration parsing.
//
// Directives (enable, diagnostic), struct declarations, function declarations
// with parameters, global var/override/const/alias declarations.
// All functions take an `anytype` self matching the Parser interface.

const ast_mod = @import("ast.zig");
const parser_attrs = @import("parser_attrs.zig");
const parser_expr = @import("parser_expr.zig");
const parser_stmt = @import("parser_stmt.zig");
const NULL_NODE = ast_mod.NULL_NODE;
const AttrSpan = parser_attrs.AttrSpan;
const parseAttributes = parser_attrs.parseAttributes;

// ============================================================
// Directives
// ============================================================

pub fn parseEnableDirective(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `enable`
    const name_token = self.token_idx;
    self.advance(); // consume extension name
    self.skipSemicolon();
    return self.tree.addNode(.{
        .tag = .enable_directive,
        .main_token = main_token,
        .data = .{ .lhs = name_token },
    });
}

pub fn parseDiagnosticDirective(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `diagnostic`
    // Skip to semicolon.
    while (self.peekTag() != .@";" and self.peekTag() != .eof) {
        self.advance();
    }
    self.skipSemicolon();
    return self.tree.addNode(.{
        .tag = .diagnostic_directive,
        .main_token = main_token,
        .data = .{},
    });
}

// ============================================================
// Struct
// ============================================================

pub fn parseStructDecl(self: anytype, attrs: AttrSpan) @TypeOf(self.*).Error!u32 {
    _ = attrs;
    const main_token = self.token_idx;
    self.advance(); // consume `struct`
    const name_token = self.token_idx;
    self.advance(); // consume name
    _ = try self.expect(.@"{");

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (self.peekTag() != .@"}" and self.peekTag() != .eof) {
        const member = try parseStructMember(self);
        try self.scratch.append(self.allocator, member);
    }
    _ = try self.expect(.@"}");

    const members = self.scratch.items[scratch_top..];
    const extra_start = try self.tree.addExtraSlice(members);
    const count: u32 = @intCast(members.len);

    return self.tree.addNode(.{
        .tag = .struct_decl,
        .main_token = main_token,
        .data = .{ .lhs = name_token, .rhs = extra_start | (count << 16) },
    });
}

fn parseStructMember(self: anytype) @TypeOf(self.*).Error!u32 {
    const member_attrs = try parseAttributes(self);
    const name_token = self.token_idx;
    self.advance(); // consume member name
    _ = try self.expect(.@":");
    const type_node = try parser_expr.parseTypeExpr(self);
    // Optional trailing comma.
    if (self.peekTag() == .@",") self.advance();

    return self.tree.addNode(.{
        .tag = .struct_member,
        .main_token = name_token,
        .data = .{ .lhs = type_node, .rhs = member_attrs.start | (member_attrs.len << 16) },
    });
}

// ============================================================
// Functions
// ============================================================

pub fn parseFnDecl(self: anytype, attrs: AttrSpan) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `fn`
    const name_token = self.token_idx;
    self.advance(); // consume function name
    _ = try self.expect(.@"(");

    // Parse parameters.
    const scratch_top = self.scratch.items.len;

    while (self.peekTag() != .@")" and self.peekTag() != .eof) {
        const param = try parseFnParam(self);
        try self.scratch.append(self.allocator, param);
        if (self.peekTag() == .@",") self.advance();
    }
    _ = try self.expect(.@")");

    // Return type.
    var return_type: u32 = NULL_NODE;
    var ret_attrs: AttrSpan = .{ .start = 0, .len = 0 };
    if (self.peekTag() == .arrow) {
        self.advance(); // consume `->`
        ret_attrs = try parseAttributes(self);
        return_type = try parser_expr.parseTypeExpr(self);
    }

    const params = self.scratch.items[scratch_top..];
    const params_start = try self.tree.addExtraSlice(params);
    const params_len: u32 = @intCast(params.len);
    self.scratch.shrinkRetainingCapacity(scratch_top);

    // Store fn extra data.
    const extra_start = try self.tree.addExtraSlice(&.{
        name_token,
        params_start,
        params_len,
        return_type,
        ret_attrs.start,
        ret_attrs.len,
        attrs.start,
        attrs.len,
    });

    // Parse body.
    const body = try parser_stmt.parseBlock(self);

    return self.tree.addNode(.{
        .tag = .fn_decl,
        .main_token = main_token,
        .data = .{ .lhs = extra_start, .rhs = body },
    });
}

fn parseFnParam(self: anytype) @TypeOf(self.*).Error!u32 {
    const param_attrs = try parseAttributes(self);
    const name_token = self.token_idx;
    self.advance(); // consume param name
    _ = try self.expect(.@":");
    const type_node = try parser_expr.parseTypeExpr(self);

    const extra_start = try self.tree.addExtraSlice(&.{
        name_token,
        type_node,
        param_attrs.start,
        param_attrs.len,
    });
    return extra_start;
}

// ============================================================
// Global declarations
// ============================================================

pub fn parseGlobalVar(self: anytype, attrs: AttrSpan) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `var`

    var addr_space: u32 = 0;
    var access_mode: u32 = 0;
    if (self.peekTag() == .@"<") {
        self.advance(); // consume `<`
        addr_space = self.token_idx;
        self.advance(); // consume address space
        if (self.peekTag() == .@",") {
            self.advance(); // consume `,`
            access_mode = self.token_idx;
            self.advance(); // consume access mode
        }
        _ = try self.expect(.@">");
    }

    const name_token = self.token_idx;
    self.advance(); // consume name

    var type_node: u32 = NULL_NODE;
    if (self.peekTag() == .@":") {
        self.advance(); // consume `:`
        type_node = try parser_expr.parseTypeExpr(self);
    }

    var init_node: u32 = NULL_NODE;
    if (self.peekTag() == .@"=") {
        self.advance(); // consume `=`
        init_node = try parser_expr.parseExpr(self);
    }

    self.skipSemicolon();

    const extra_start = try self.tree.addExtraSlice(&.{
        name_token,
        addr_space,
        access_mode,
        init_node,
        attrs.start,
        attrs.len,
    });

    return self.tree.addNode(.{
        .tag = .global_var,
        .main_token = main_token,
        .data = .{ .lhs = type_node, .rhs = extra_start },
    });
}

pub fn parseOverrideDecl(self: anytype, attrs: AttrSpan) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `override`

    const name_token = self.token_idx;
    self.advance(); // consume name

    var type_node: u32 = NULL_NODE;
    if (self.peekTag() == .@":") {
        self.advance();
        type_node = try parser_expr.parseTypeExpr(self);
    }

    var init_node: u32 = NULL_NODE;
    if (self.peekTag() == .@"=") {
        self.advance();
        init_node = try parser_expr.parseExpr(self);
    }

    self.skipSemicolon();

    const extra_start = try self.tree.addExtraSlice(&.{
        name_token,
        type_node,
        init_node,
        attrs.start,
        attrs.len,
    });

    return self.tree.addNode(.{
        .tag = .override_decl,
        .main_token = main_token,
        .data = .{ .lhs = extra_start, .rhs = 0 },
    });
}

pub fn parseConstDecl(self: anytype, attrs: AttrSpan) @TypeOf(self.*).Error!u32 {
    _ = attrs;
    const main_token = self.token_idx;
    self.advance(); // consume `const` or `let`

    // skip name
    self.advance();

    var type_node: u32 = NULL_NODE;
    if (self.peekTag() == .@":") {
        self.advance();
        type_node = try parser_expr.parseTypeExpr(self);
    }

    var init_node: u32 = NULL_NODE;
    if (self.peekTag() == .@"=") {
        self.advance();
        init_node = try parser_expr.parseExpr(self);
    }

    self.skipSemicolon();

    return self.tree.addNode(.{
        .tag = .const_decl,
        .main_token = main_token,
        .data = .{ .lhs = type_node, .rhs = init_node },
    });
}

pub fn parseAliasDecl(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `alias`
    self.advance(); // consume name
    _ = try self.expect(.@"=");
    const type_node = try parser_expr.parseTypeExpr(self);
    self.skipSemicolon();
    return self.tree.addNode(.{
        .tag = .alias_decl,
        .main_token = main_token,
        .data = .{ .lhs = type_node },
    });
}
