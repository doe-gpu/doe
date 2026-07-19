// doe_wgsl/parser.zig — WGSL parser producing an AST.
//
// Parses the subset of WGSL used by AI workload compute shaders:
// - enable directives
// - struct declarations (with nested array fields)
// - global var/let/const/override declarations with attributes
// - fn declarations with attributes, multiple entry points, helper functions
// - block statements with if/else, for, while, loop, switch, break, continue, return
// - expressions: binary, unary, call, member access, index, literals
// - type expressions: scalar, vec, mat, array, atomic, user-defined
//
// Parsing logic is split across cohesive sub-modules:
// - parser_decl.zig: directives, struct/fn/global declarations
// - parser_stmt.zig: block and control-flow statements
// - parser_expr.zig: expressions and type expressions

const std = @import("std");
const ast_mod = @import("ast.zig");
const token_mod = @import("token.zig");
const lexer_mod = @import("lexer.zig");
const parser_attrs = @import("parser_attrs.zig");
const parser_decl = @import("parser_decl.zig");
const parser_stmt = @import("parser_stmt.zig");
const parser_expr = @import("parser_expr.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeTag = ast_mod.NodeTag;
const NULL_NODE = ast_mod.NULL_NODE;
const Token = token_mod.Token;
const Tag = token_mod.Tag;
const Lexer = lexer_mod.Lexer;

// ============================================================
// Parse-error location side-channel
// ============================================================

pub const FailureContext = struct {
    /// Token index in the Ast where parsing failed, or null if unknown.
    token_idx: ?u32 = null,
    /// Byte-offset span of the failing token, valid even after the Ast is freed.
    loc: ?Token.Loc = null,
};

var last_failure_context = FailureContext{};

pub fn resetLastFailureContext() void {
    last_failure_context = .{};
}

pub fn lastFailureContext() FailureContext {
    return last_failure_context;
}

pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
};

pub const AttrSpan = parser_attrs.AttrSpan;

pub const Parser = struct {
    tree: *Ast,
    token_idx: u32,
    /// Scratch buffer for collecting child indices before committing to extra_data.
    scratch: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,

    pub const Error = ParseError;

    pub fn init(tree: *Ast, allocator: std.mem.Allocator) Parser {
        return .{
            .tree = tree,
            .token_idx = 0,
            .scratch = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.scratch.deinit(self.allocator);
    }

    // ============================================================
    // Tokenization phase
    // ============================================================

    pub fn tokenize(tree: *Ast, source: []const u8) !void {
        tree.source = source;
        var lex = Lexer.init(source);
        while (true) {
            const tok = lex.next();
            try tree.tokens.append(tree.allocator, tok);
            if (tok.tag == .eof) break;
        }
    }

    // ============================================================
    // Top-level entry
    // ============================================================

    pub fn parse(self: *Parser) ParseError!u32 {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (self.peekTag() != .eof) {
            const decl = try self.parseTopLevelDecl();
            if (decl != NULL_NODE) {
                try self.scratch.append(self.allocator, decl);
            }
        }

        const decls = self.scratch.items[scratch_top..];
        const extra_start = try self.tree.addExtraSlice(decls);
        const count: u32 = @intCast(decls.len);

        // Overwrite node 0 (root).
        self.tree.nodes.items[0] = .{
            .tag = .root,
            .main_token = 0,
            .data = .{ .lhs = extra_start, .rhs = count },
        };
        return 0;
    }

    fn parseTopLevelDecl(self: *Parser) ParseError!u32 {
        // Collect leading attributes.
        const attrs = try parser_attrs.parseAttributes(self);

        return switch (self.peekTag()) {
            .kw_enable => parser_decl.parseEnableDirective(self),
            .kw_diagnostic => parser_decl.parseDiagnosticDirective(self),
            .kw_struct => parser_decl.parseStructDecl(self, attrs),
            .kw_fn => parser_decl.parseFnDecl(self, attrs),
            .kw_var => parser_decl.parseGlobalVar(self, attrs),
            .kw_override => parser_decl.parseOverrideDecl(self, attrs),
            .kw_const => parser_decl.parseConstDecl(self, attrs),
            .kw_let => parser_decl.parseConstDecl(self, attrs),
            .kw_alias => parser_decl.parseAliasDecl(self),
            // const_assert is recognised but not yet implemented; reject explicitly.
            .kw_const_assert => {
                last_failure_context = .{
                    .token_idx = self.token_idx,
                    .loc = if (self.token_idx < self.tree.tokens.items.len)
                        self.tree.tokens.items[self.token_idx].loc
                    else
                        null,
                };
                return ParseError.UnexpectedToken;
            },
            .@";" => {
                // Tolerate stray semicolons between declarations (e.g. `};` after struct).
                self.advance();
                return NULL_NODE;
            },
            else => {
                // Reject unexpected tokens at the top level; valid WGSL
                // top-level constructs always start with a keyword or attribute.
                last_failure_context = .{
                    .token_idx = self.token_idx,
                    .loc = if (self.token_idx < self.tree.tokens.items.len)
                        self.tree.tokens.items[self.token_idx].loc
                    else
                        null,
                };
                return ParseError.UnexpectedToken;
            },
        };
    }

    // ============================================================
    // Attributes
    // ============================================================

    // ============================================================
    // Token helpers
    // ============================================================

    pub fn peekTag(self: anytype) Tag {
        if (self.token_idx >= self.tree.tokens.items.len) return .eof;
        return self.tree.tokens.items[self.token_idx].tag;
    }

    pub fn advance(self: anytype) void {
        if (self.token_idx < self.tree.tokens.items.len) {
            self.token_idx += 1;
        }
    }

    pub fn expect(self: anytype, expected: Tag) @TypeOf(self.*).Error!u32 {
        if (self.peekTag() == expected) {
            const tok = self.token_idx;
            self.advance();
            return tok;
        }
        const fail_loc: ?Token.Loc = if (self.token_idx < self.tree.tokens.items.len)
            self.tree.tokens.items[self.token_idx].loc
        else
            null;
        last_failure_context = .{ .token_idx = self.token_idx, .loc = fail_loc };
        return ParseError.UnexpectedToken;
    }

    pub fn skipSemicolon(self: anytype) void {
        if (self.peekTag() == .@";") self.advance();
    }
};

// ============================================================
// Public API
// ============================================================

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) !Ast {
    resetLastFailureContext();
    var tree = Ast.init(allocator);
    errdefer tree.deinit();

    try Parser.tokenize(&tree, source);

    var parser = Parser.init(&tree, allocator);
    defer parser.deinit();

    _ = try parser.parse();
    return tree;
}

// ============================================================
// Tests
// ============================================================

test "parse simple compute shader" {
    const source =
        \\enable f16;
        \\
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = data[id.x] * 2.0;
        \\}
    ;

    var tree = try parseSource(std.testing.allocator, source);
    defer tree.deinit();

    // Root node should have declarations.
    const root = tree.nodes.items[0];
    try std.testing.expectEqual(NodeTag.root, root.tag);
    const decl_count = root.data.rhs;
    try std.testing.expect(decl_count >= 3); // enable + var + fn
}

test "parse struct" {
    const source =
        \\struct Params {
        \\    size: u32,
        \\    data: array<f32, 16>,
        \\}
    ;
    var tree = try parseSource(std.testing.allocator, source);
    defer tree.deinit();
    const root = tree.nodes.items[0];
    try std.testing.expect(root.data.rhs >= 1);
}

test "parse override" {
    const source =
        \\override BLOCK_SIZE: u32 = 64u;
        \\override USE_F16: bool = false;
    ;
    var tree = try parseSource(std.testing.allocator, source);
    defer tree.deinit();
    const root = tree.nodes.items[0];
    try std.testing.expectEqual(@as(u32, 2), root.data.rhs);
}

test "parse multiple entry points" {
    const source =
        \\fn helper(x: f32) -> f32 {
        \\    return x * 2.0;
        \\}
        \\
        \\@compute @workgroup_size(64)
        \\fn main_a(@builtin(global_invocation_id) id: vec3u) {
        \\    let x = helper(1.0);
        \\}
        \\
        \\@compute @workgroup_size(128)
        \\fn main_b(@builtin(global_invocation_id) id: vec3u) {
        \\    let y = helper(2.0);
        \\}
    ;
    var tree = try parseSource(std.testing.allocator, source);
    defer tree.deinit();
    const root = tree.nodes.items[0];
    try std.testing.expectEqual(@as(u32, 3), root.data.rhs);
}
