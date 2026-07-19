// doe_wgsl/parser_stmt.zig — Statement parsing.
//
// Block statements, control flow (if/else, for, while, loop, switch),
// local variable declarations, return, break, continue, discard,
// and expression/assignment statements.
// All functions take an `anytype` self matching the Parser interface.

const std = @import("std");
const ast_mod = @import("ast.zig");
const token_mod = @import("token.zig");
const parser_expr = @import("parser_expr.zig");
const NULL_NODE = ast_mod.NULL_NODE;
const Tag = token_mod.Tag;

// ============================================================
// Statements
// ============================================================

pub fn parseBlock(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    _ = try self.expect(.@"{");

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (self.peekTag() != .@"}" and self.peekTag() != .eof) {
        const stmt = try parseStatement(self);
        if (stmt != NULL_NODE) {
            try self.scratch.append(self.allocator, stmt);
        }
    }
    _ = try self.expect(.@"}");

    const stmts = self.scratch.items[scratch_top..];
    const extra_start = try self.tree.addExtraSlice(stmts);
    const count: u32 = @intCast(stmts.len);

    return self.tree.addNode(.{
        .tag = .block,
        .main_token = main_token,
        .data = .{ .lhs = extra_start, .rhs = count },
    });
}

pub fn parseStatement(self: anytype) @TypeOf(self.*).Error!u32 {
    return switch (self.peekTag()) {
        .@"{" => parseBlock(self),
        .kw_var => parseLocalVarStmt(self),
        .kw_let => parseLocalLetStmt(self),
        .kw_const => parseLocalConstStmt(self),
        .kw_return => parseReturnStmt(self),
        .kw_if => parseIfStmt(self),
        .kw_for => parseForStmt(self),
        .kw_while => parseWhileStmt(self),
        .kw_loop => parseLoopStmt(self),
        .kw_break => parseBreakStmt(self),
        .kw_continue => parseContinueStmt(self),
        .kw_continuing => parseContinuingStmt(self),
        .kw_switch => parseSwitchStmt(self),
        .kw_discard => parseDiscardStmt(self),
        .@";" => blk: {
            self.advance();
            break :blk NULL_NODE;
        },
        else => parseExprOrAssignStmt(self),
    };
}

fn parseLocalVarStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `var`

    // Optional address space.
    if (self.peekTag() == .@"<") {
        self.advance();
        self.advance(); // address space
        if (self.peekTag() == .@",") {
            self.advance();
            self.advance(); // access mode
        }
        _ = try self.expect(.@">");
    }

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
    return self.tree.addNode(.{
        .tag = .var_stmt,
        .main_token = main_token,
        .data = .{ .lhs = type_node, .rhs = init_node },
    });
}

fn parseLocalLetStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `let`
    self.advance(); // consume name

    var type_node: u32 = NULL_NODE;
    if (self.peekTag() == .@":") {
        self.advance();
        type_node = try parser_expr.parseTypeExpr(self);
    }

    _ = try self.expect(.@"=");
    const init_node = try parser_expr.parseExpr(self);
    self.skipSemicolon();

    return self.tree.addNode(.{
        .tag = .let_stmt,
        .main_token = main_token,
        .data = .{ .lhs = type_node, .rhs = init_node },
    });
}

fn parseLocalConstStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `const`
    self.advance(); // consume name

    var type_node: u32 = NULL_NODE;
    if (self.peekTag() == .@":") {
        self.advance();
        type_node = try parser_expr.parseTypeExpr(self);
    }

    _ = try self.expect(.@"=");
    const init_node = try parser_expr.parseExpr(self);
    self.skipSemicolon();

    return self.tree.addNode(.{
        .tag = .const_stmt,
        .main_token = main_token,
        .data = .{ .lhs = type_node, .rhs = init_node },
    });
}

fn parseReturnStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `return`

    var expr: u32 = NULL_NODE;
    if (self.peekTag() != .@";" and self.peekTag() != .eof) {
        expr = try parser_expr.parseExpr(self);
    }
    self.skipSemicolon();

    return self.tree.addNode(.{
        .tag = .return_stmt,
        .main_token = main_token,
        .data = .{ .lhs = expr },
    });
}

fn parseIfStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `if`

    // Condition — may or may not have parens.
    var skip_close = false;
    if (self.peekTag() == .@"(") {
        self.advance();
        skip_close = true;
    }
    const cond = try parser_expr.parseExpr(self);
    if (skip_close and self.peekTag() == .@")") {
        self.advance();
    }

    const then_block = try parseBlock(self);

    var else_node: u32 = NULL_NODE;
    if (self.peekTag() == .kw_else) {
        self.advance(); // consume `else`
        if (self.peekTag() == .kw_if) {
            else_node = try parseIfStmt(self);
        } else {
            else_node = try parseBlock(self);
        }
    }

    const extra_start = try self.tree.addExtraSlice(&.{ then_block, else_node });

    return self.tree.addNode(.{
        .tag = .if_stmt,
        .main_token = main_token,
        .data = .{ .lhs = cond, .rhs = extra_start },
    });
}

fn parseForStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `for`
    _ = try self.expect(.@"(");

    // Init.
    var init_stmt: u32 = NULL_NODE;
    if (self.peekTag() != .@";") {
        init_stmt = try parseStatement(self);
    } else {
        self.advance();
    }

    // Condition.
    var cond: u32 = NULL_NODE;
    if (self.peekTag() != .@";") {
        cond = try parser_expr.parseExpr(self);
    }
    self.skipSemicolon();

    // Update.
    var update: u32 = NULL_NODE;
    if (self.peekTag() != .@")") {
        update = try parseExprOrAssignStmt(self);
    }
    _ = try self.expect(.@")");

    const body = try parseBlock(self);

    const extra_start = try self.tree.addExtraSlice(&.{ init_stmt, cond, update });

    return self.tree.addNode(.{
        .tag = .for_stmt,
        .main_token = main_token,
        .data = .{ .lhs = extra_start, .rhs = body },
    });
}

fn parseWhileStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `while`

    var skip_close = false;
    if (self.peekTag() == .@"(") {
        self.advance();
        skip_close = true;
    }
    const cond = try parser_expr.parseExpr(self);
    if (skip_close and self.peekTag() == .@")") {
        self.advance();
    }

    const body = try parseBlock(self);

    return self.tree.addNode(.{
        .tag = .while_stmt,
        .main_token = main_token,
        .data = .{ .lhs = cond, .rhs = body },
    });
}

fn parseLoopStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `loop`
    const body = try parseBlock(self);
    return self.tree.addNode(.{
        .tag = .loop_stmt,
        .main_token = main_token,
        .data = .{ .lhs = body },
    });
}

fn parseBreakStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `break`
    // `break if expr;` (WGSL loop break-if).
    var cond: u32 = NULL_NODE;
    if (self.peekTag() == .kw_if) {
        self.advance();
        cond = try parser_expr.parseExpr(self);
    }
    self.skipSemicolon();
    return self.tree.addNode(.{
        .tag = .break_stmt,
        .main_token = main_token,
        .data = .{ .lhs = cond },
    });
}

fn parseContinueStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance();
    self.skipSemicolon();
    return self.tree.addNode(.{
        .tag = .continue_stmt,
        .main_token = main_token,
        .data = .{},
    });
}

fn parseContinuingStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `continuing`
    const body = try parseBlock(self);
    return self.tree.addNode(.{
        .tag = .continuing_stmt,
        .main_token = main_token,
        .data = .{ .lhs = body },
    });
}

fn parseSwitchStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance(); // consume `switch`

    var skip_close = false;
    if (self.peekTag() == .@"(") {
        self.advance();
        skip_close = true;
    }
    const expr = try parser_expr.parseExpr(self);
    if (skip_close and self.peekTag() == .@")") {
        self.advance();
    }

    _ = try self.expect(.@"{");

    const scratch_top = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(scratch_top);

    while (self.peekTag() != .@"}" and self.peekTag() != .eof) {
        const case_node = try parseSwitchCase(self);
        try self.scratch.append(self.allocator, case_node);
    }
    _ = try self.expect(.@"}");

    const cases = self.scratch.items[scratch_top..];
    const extra_start = try self.tree.addExtraSlice(cases);
    const count: u32 = @intCast(cases.len);

    return self.tree.addNode(.{
        .tag = .switch_stmt,
        .main_token = main_token,
        .data = .{ .lhs = expr, .rhs = extra_start | (count << 16) },
    });
}

fn parseSwitchCase(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    var selectors = std.ArrayListUnmanaged(u32){};
    defer selectors.deinit(self.allocator);
    if (self.peekTag() == .kw_case) {
        self.advance(); // consume `case`
        while (true) {
            try selectors.append(self.allocator, try parser_expr.parseExpr(self));
            if (self.peekTag() != .@",") break;
            self.advance();
        }
    } else if (self.peekTag() == .kw_default) {
        self.advance(); // consume `default`
    }
    if (self.peekTag() == .@":") self.advance();
    const body = try parseBlock(self);
    const selectors_start = try self.tree.addExtraSlice(selectors.items);
    const selectors_len: u32 = @intCast(selectors.items.len);
    return self.tree.addNode(.{
        .tag = .switch_case,
        .main_token = main_token,
        .data = .{ .lhs = body, .rhs = selectors_start | (selectors_len << 16) },
    });
}

fn parseDiscardStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const main_token = self.token_idx;
    self.advance();
    self.skipSemicolon();
    return self.tree.addNode(.{
        .tag = .discard_stmt,
        .main_token = main_token,
        .data = .{},
    });
}

pub fn parseExprOrAssignStmt(self: anytype) @TypeOf(self.*).Error!u32 {
    const lhs = try parser_expr.parseExpr(self);

    const tag = self.peekTag();
    if (isAssignOp(tag)) {
        const op_token = self.token_idx;
        self.advance();
        const rhs = try parser_expr.parseExpr(self);
        self.skipSemicolon();
        return self.tree.addNode(.{
            .tag = .assign_stmt,
            .main_token = op_token,
            .data = .{ .lhs = lhs, .rhs = rhs },
        });
    }

    if (tag == .plus_plus or tag == .minus_minus) {
        const op_token = self.token_idx;
        self.advance();
        self.skipSemicolon();
        return self.tree.addNode(.{
            .tag = if (tag == .plus_plus) .inc_stmt else .dec_stmt,
            .main_token = op_token,
            .data = .{ .lhs = lhs },
        });
    }

    // Bare expression statement (e.g., function call).
    self.skipSemicolon();
    return self.tree.addNode(.{
        .tag = .expr_stmt,
        .main_token = self.tree.nodes.items[lhs].main_token,
        .data = .{ .lhs = lhs },
    });
}

fn isAssignOp(tag: Tag) bool {
    return switch (tag) {
        .@"=",
        .plus_eq,
        .minus_eq,
        .star_eq,
        .slash_eq,
        .percent_eq,
        .amp_eq,
        .pipe_eq,
        .caret_eq,
        => true,
        else => false,
    };
}
