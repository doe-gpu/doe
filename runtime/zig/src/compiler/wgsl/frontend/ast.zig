// doe_wgsl/ast.zig — WGSL abstract syntax tree node types.
//
// Node indices are u32 into a flat ArrayList. Null is represented by NULL_NODE.
// Slices of children (e.g., struct fields, function params) are stored in a
// separate extra_data array; the node stores a span {start, len} into it.

const std = @import("std");
const Token = @import("token.zig").Token;

pub const NULL_NODE: u32 = 0;

pub const Node = struct {
    tag: NodeTag,
    /// Primary token for this node (e.g., the `fn` keyword, the identifier, the operator).
    main_token: u32,
    /// Two general-purpose data fields; interpretation depends on tag.
    data: Data,

    pub const Data = struct {
        lhs: u32 = 0,
        rhs: u32 = 0,
    };
};

pub const NodeTag = enum(u8) {
    /// Root node. data.lhs = extra start of top-level declaration indices, data.rhs = count.
    root,

    // ============================================================
    // Top-level declarations
    // ============================================================

    /// `enable <ident>;`  main_token = `enable`, data.lhs = ident token index.
    enable_directive,

    /// `diagnostic(off, ...);`  main_token = `diagnostic`.
    diagnostic_directive,

    /// `struct <name> { ... }` main_token = `struct`.
    /// data.lhs = name token, data.rhs = extra span start for members.
    struct_decl,

    /// Struct member: `name: type` with optional @attributes.
    /// main_token = name ident. data.lhs = type node, data.rhs = extra span for attributes.
    struct_member,

    /// `fn <name>(...) -> <ret> { ... }`
    /// main_token = `fn`. data.lhs = extra span for params+attrs, data.rhs = body block node.
    fn_decl,

    /// `@group(N) @binding(M) var<...> name: type;`
    /// main_token = `var`. data.lhs = type node, data.rhs = extra span for attributes.
    global_var,

    /// `override name: type = expr;`
    /// main_token = `override`. data.lhs = extra start (OverrideExtra), data.rhs = unused.
    override_decl,

    /// `const name: type = expr;` (module scope)
    /// main_token = `const`. data.lhs = type node (or 0), data.rhs = initializer node.
    const_decl,

    /// `alias name = type;`
    alias_decl,

    // ============================================================
    // Statements
    // ============================================================

    /// `{ stmt* }` — compound statement.
    /// main_token = `{`. data.lhs = extra start, data.rhs = count.
    block,

    /// `var name: type = init;` (local)
    var_stmt,

    /// `let name: type = init;`
    let_stmt,

    /// `const name: type = init;` (local)
    const_stmt,

    /// `return expr;`
    return_stmt,

    /// `if (cond) { ... } else { ... }`
    /// data.lhs = condition, data.rhs = extra start for [then_block, else_node].
    if_stmt,

    /// `else if` or `else` clause linked from if_stmt extra.
    else_clause,

    /// `for (init; cond; update) { body }`
    for_stmt,

    /// `while (cond) { body }`
    while_stmt,

    /// `loop { body }`
    loop_stmt,

    /// `break;`
    break_stmt,

    /// `continue;`
    continue_stmt,

    /// `continuing { ... }`
    continuing_stmt,

    /// `switch (expr) { ... }`
    switch_stmt,

    /// `case expr: { ... }` or `default: { ... }`
    /// data.lhs = body block, data.rhs = packed selector span (start | len << 16).
    switch_case,

    /// `discard;`
    discard_stmt,

    /// Expression statement (fn call, assignment).
    expr_stmt,

    /// Assignment: `lhs = rhs;` or `lhs += rhs;` etc.
    /// main_token = the assignment operator token.
    assign_stmt,

    /// Postfix increment statement: `lhs++;`.
    /// main_token = the `++` token. data.lhs = lhs expression node.
    inc_stmt,

    /// Postfix decrement statement: `lhs--;`.
    /// main_token = the `--` token. data.lhs = lhs expression node.
    dec_stmt,

    // ============================================================
    // Expressions
    // ============================================================

    /// Identifier reference. main_token = the ident token.
    ident_expr,

    /// Integer literal.
    int_literal,

    /// Float literal.
    float_literal,

    /// Boolean literal (true/false).
    bool_literal,

    /// Binary op: `lhs op rhs`. main_token = operator. data.lhs/rhs = operand nodes.
    binary_expr,

    /// Unary op: `op expr`. main_token = operator. data.lhs = operand.
    unary_expr,

    /// Function/constructor call: `name(args...)`.
    /// main_token = name token. data.lhs = extra start of arg nodes, data.rhs = arg count.
    call_expr,

    /// Generic builtin call: `name<T>(args...)`.
    /// main_token = name token. data.lhs = target type node, data.rhs = packed arg span.
    generic_call_expr,

    /// Type constructor call: `vec4<f32>(...)`, `vec4f(...)`, `f32(...)`.
    /// main_token = constructor token. data.lhs = type node, data.rhs = packed arg span.
    construct_expr,

    /// Member access: `expr.field`. main_token = `.`. data.lhs = expr, data.rhs = field token.
    member_expr,

    /// Index access: `expr[index]`. main_token = `[`. data.lhs = expr, data.rhs = index expr.
    index_expr,

    // ============================================================
    // Type expressions
    // ============================================================

    /// Simple type name (f32, u32, MyStruct, etc). main_token = type token.
    type_name,

    /// Parameterized type: `vec4<f32>`, `array<T, N>`.
    /// main_token = type token. data.lhs = extra start of param type nodes, data.rhs = count.
    type_parameterized,

    /// Shorthand vector type: vec4f, vec3u, etc. main_token = the shorthand token.
    type_vec_shorthand,

    /// Shorthand matrix type: mat4x4f, etc.
    type_mat_shorthand,

    // ============================================================
    // Attributes
    // ============================================================

    /// `@attribute` or `@attribute(args...)`.
    /// main_token = `@`. data.lhs = attr name token, data.rhs = extra span for args (or 0).
    attribute,
};

/// Spans into the extra_data array.
pub const Span = struct {
    start: u32,
    len: u32,
};

/// Data stored per fn_decl in extra_data.
pub const FnExtra = struct {
    name_token: u32,
    params_start: u32,
    params_len: u32,
    return_type: u32, // node index, or NULL_NODE
    attrs_start: u32,
    attrs_len: u32,
};

/// Data stored per global_var in extra_data.
pub const GlobalVarExtra = struct {
    name_token: u32,
    addr_space: u32, // token index for address space keyword, or 0
    access_mode: u32, // token index for access mode keyword, or 0
    initializer: u32, // node index, or NULL_NODE
    attrs_start: u32,
    attrs_len: u32,
};

/// Data stored per override_decl in extra_data.
pub const OverrideExtra = struct {
    name_token: u32,
    type_node: u32,
    init_node: u32,
    attrs_start: u32,
    attrs_len: u32,
};

/// Data stored per fn param in extra_data.
pub const ParamExtra = struct {
    name_token: u32,
    type_node: u32,
    attrs_start: u32,
    attrs_len: u32,
};

pub const Ast = struct {
    source: []const u8,
    allocator: std.mem.Allocator,
    tokens: std.ArrayListUnmanaged(Token),
    nodes: std.ArrayListUnmanaged(Node),
    extra_data: std.ArrayListUnmanaged(u32),

    pub fn init(allocator: std.mem.Allocator) Ast {
        var ast = Ast{
            .source = &.{},
            .allocator = allocator,
            .tokens = .{},
            .nodes = .{},
            .extra_data = .{},
        };
        // Reserve index 0 as NULL_NODE.
        ast.nodes.append(allocator, .{
            .tag = .root,
            .main_token = 0,
            .data = .{},
        }) catch {};
        return ast;
    }

    pub fn deinit(self: *Ast) void {
        self.tokens.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.extra_data.deinit(self.allocator);
    }

    pub fn addNode(self: *Ast, node: Node) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return idx;
    }

    pub fn addExtra(self: *Ast, value: u32) !u32 {
        const idx: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(self.allocator, value);
        return idx;
    }

    pub fn addExtraSlice(self: *Ast, values: []const u32) !u32 {
        const start: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.appendSlice(self.allocator, values);
        return start;
    }

    pub fn tokenSlice(self: *const Ast, token_idx: u32) []const u8 {
        const tok = self.tokens.items[token_idx];
        return self.source[tok.loc.start..tok.loc.end];
    }
};
