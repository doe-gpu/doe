const std = @import("std");
const ast_mod = @import("ast.zig");
const token_mod = @import("token.zig");
const ir = @import("../ir/ir.zig");
const sema_types = @import("sema_types.zig");
const sema_attrs = @import("sema_attrs.zig");
const sema_expr = @import("sema_expr.zig");
const sema_helpers = @import("sema_helpers.zig");
const sema_resolve = @import("sema_resolve.zig");
const sema_typeutils = @import("sema_typeutils.zig");

const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NodeTag = ast_mod.NodeTag;
const NULL_NODE = ast_mod.NULL_NODE;
const Tag = token_mod.Tag;

pub const AnalyzeError = sema_types.AnalyzeError;
pub const SymbolRef = sema_types.SymbolRef;
pub const NodeInfo = sema_types.NodeInfo;
pub const AliasInfo = sema_types.AliasInfo;
pub const StructFieldInfo = sema_types.StructFieldInfo;
pub const StructInfo = sema_types.StructInfo;
pub const GlobalInfo = sema_types.GlobalInfo;
pub const ParamInfo = sema_types.ParamInfo;
pub const LocalInfo = sema_types.LocalInfo;
pub const FunctionInfo = sema_types.FunctionInfo;
pub const SemanticModule = sema_types.SemanticModule;

pub const FailureContext = struct {
    node_idx: u32 = NULL_NODE,
    token_idx: ?u32 = null,
};

threadlocal var last_failure_context = FailureContext{};

pub fn resetLastFailureContext() void {
    last_failure_context = .{};
}
pub fn lastFailureContext() FailureContext {
    return last_failure_context;
}
pub fn analyze(allocator: std.mem.Allocator, tree: *const Ast) !SemanticModule {
    return analyzeWithOverrides(allocator, tree, &.{});
}

pub fn analyzeWithOverrides(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    overrides: []const ir.OverrideEntry,
) !SemanticModule {
    return analyzeWithContext(allocator, tree, overrides, &last_failure_context);
}

pub fn analyzeWithContext(allocator: std.mem.Allocator, tree: *const Ast, overrides: []const ir.OverrideEntry, failure: *FailureContext) !SemanticModule {
    failure.* = .{};
    var module = SemanticModule{
        .allocator = allocator,
        .tree = tree,
        .types = ir.TypeStore.init(allocator),
    };
    errdefer module.deinit();

    try init_builtin_types(&module);
    try module.node_info.resize(allocator, tree.nodes.items.len);
    @memset(module.node_info.items, NodeInfo{});

    var analyzer = Analyzer{ .module = &module, .overrides = overrides, .failure = failure };
    try analyzer.run();
    return module;
}
const Scope = struct {
    bindings: std.StringHashMapUnmanaged(SymbolRef) = .{},

    fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
    }
};

const BodyAnalyzer = struct {
    parent: *Analyzer,
    function_index: u32,
    scopes: std.ArrayListUnmanaged(Scope) = .{},
    loop_depth: u32 = 0,
    switch_depth: u32 = 0,

    fn deinit(self: *BodyAnalyzer) void {
        for (self.scopes.items) |*scope| scope.deinit(self.parent.module.allocator);
        self.scopes.deinit(self.parent.module.allocator);
    }
    fn function(self: *BodyAnalyzer) *FunctionInfo {
        return &self.parent.module.functions.items[self.function_index];
    }
    fn push_scope(self: *BodyAnalyzer) !void {
        try self.scopes.append(self.parent.module.allocator, .{});
    }
    fn pop_scope(self: *BodyAnalyzer) void {
        var scope = self.scopes.pop().?;
        scope.deinit(self.parent.module.allocator);
    }

    fn bind_name(self: *BodyAnalyzer, name: []const u8, symbol: SymbolRef) !void {
        var scope = &self.scopes.items[self.scopes.items.len - 1];
        if (scope.bindings.contains(name)) return error.DuplicateSymbol;
        try scope.bindings.put(self.parent.module.allocator, name, symbol);
    }

    fn resolve_name(self: *BodyAnalyzer, name: []const u8) ?SymbolRef {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].bindings.get(name)) |symbol| return symbol;
        }
        if (self.parent.module.global_map.get(name)) |global_index| return .{ .global = global_index };
        if (self.parent.module.function_map.get(name)) |fn_index| return .{ .function = fn_index };
        return null;
    }
};

const Analyzer = struct {
    failure: *FailureContext,
    module: *SemanticModule,
    overrides: []const ir.OverrideEntry = &.{},

    fn run(self: *Analyzer) !void {
        const root = self.module.tree.nodes.items[0];
        const decl_start = root.data.lhs;
        const decl_count = root.data.rhs;

        var i: u32 = 0;
        while (i < decl_count) : (i += 1) {
            const decl_idx = self.module.tree.extra_data.items[decl_start + i];
            try self.register_top_level(decl_idx);
        }

        i = 0;
        while (i < decl_count) : (i += 1) {
            const decl_idx = self.module.tree.extra_data.items[decl_start + i];
            try self.resolve_top_level(decl_idx);
        }

        i = 0;
        while (i < decl_count) : (i += 1) {
            const decl_idx = self.module.tree.extra_data.items[decl_start + i];
            const node = self.module.tree.nodes.items[decl_idx];
            if (node.tag == .fn_decl) {
                const name = self.module.tree.tokenSlice(self.module.tree.extra_data.items[node.data.lhs]);
                const fn_index = self.module.function_map.get(name) orelse return error.InvalidWgsl;
                try self.analyze_function_body(fn_index);
            }
        }
    }

    fn register_top_level(self: *Analyzer, node_idx: u32) !void {
        sema_typeutils.captureFailureNode(self.module.tree, node_idx, self.failure);
        const node = self.module.tree.nodes.items[node_idx];
        switch (node.tag) {
            .struct_decl => try self.register_struct(node),
            .alias_decl => try self.register_alias(node),
            .global_var, .const_decl, .override_decl => try self.register_global(node, node_idx),
            .fn_decl => try self.register_function(node, node_idx),
            else => {},
        }
    }

    fn resolve_top_level(self: *Analyzer, node_idx: u32) !void {
        sema_typeutils.captureFailureNode(self.module.tree, node_idx, self.failure);
        const node = self.module.tree.nodes.items[node_idx];
        switch (node.tag) {
            .struct_decl => try self.resolve_struct(node),
            .alias_decl => try self.resolve_alias(node),
            .global_var, .const_decl, .override_decl => try self.resolve_global(node, node_idx),
            .fn_decl => try self.resolve_function_signature(node, node_idx),
            else => {},
        }
    }

    fn register_struct(self: *Analyzer, node: Node) !void {
        const name = self.module.tree.tokenSlice(node.data.lhs);
        if (self.module.struct_map.contains(name)) return error.DuplicateSymbol;
        const struct_id: ir.StructId = @intCast(self.module.structs.items.len);
        const ty = try self.module.types.intern(.{ .struct_ = struct_id });
        try self.module.structs.ensureUnusedCapacity(self.module.allocator, 1);
        const name_copy = try ir.dup_string(self.module.allocator, name);
        self.module.structs.appendAssumeCapacity(.{
            .name = name_copy,
            .struct_id = struct_id,
            .ty = ty,
        });
        try self.module.struct_map.put(self.module.allocator, name_copy, struct_id);
    }

    fn register_alias(self: *Analyzer, node: Node) !void {
        const name = self.module.tree.tokenSlice(node.main_token + 1);
        if (self.module.alias_map.contains(name)) return error.DuplicateSymbol;
        try self.module.aliases.ensureUnusedCapacity(self.module.allocator, 1);
        const copy = try ir.dup_string(self.module.allocator, name);
        const idx: u32 = @intCast(self.module.aliases.items.len);
        self.module.aliases.appendAssumeCapacity(.{ .name = copy, .ty = ir.INVALID_TYPE });
        try self.module.alias_map.put(self.module.allocator, copy, idx);
    }

    fn register_global(self: *Analyzer, node: Node, node_idx: u32) !void {
        const name = switch (node.tag) {
            .global_var => self.module.tree.tokenSlice(self.module.tree.extra_data.items[node.data.rhs]),
            .const_decl => self.module.tree.tokenSlice(node.main_token + 1),
            .override_decl => self.module.tree.tokenSlice(self.module.tree.extra_data.items[node.data.lhs]),
            else => return error.InvalidWgsl,
        };
        if (self.module.global_map.contains(name)) return error.DuplicateSymbol;
        try self.module.globals.ensureUnusedCapacity(self.module.allocator, 1);
        const copy = try ir.dup_string(self.module.allocator, name);
        const idx: u32 = @intCast(self.module.globals.items.len);
        self.module.globals.appendAssumeCapacity(.{
            .name = copy,
            .node_idx = node_idx,
            .ty = ir.INVALID_TYPE,
            .class = switch (node.tag) {
                .global_var => .var_,
                .const_decl => .const_,
                .override_decl => .override_,
                else => .var_,
            },
        });
        try self.module.global_map.put(self.module.allocator, copy, idx);
    }

    fn register_function(self: *Analyzer, node: Node, node_idx: u32) !void {
        const name = self.module.tree.tokenSlice(self.module.tree.extra_data.items[node.data.lhs]);
        if (self.module.function_map.contains(name)) return error.DuplicateSymbol;
        try self.module.functions.ensureUnusedCapacity(self.module.allocator, 1);
        const copy = try ir.dup_string(self.module.allocator, name);
        const idx: u32 = @intCast(self.module.functions.items.len);
        self.module.functions.appendAssumeCapacity(.{
            .name = copy,
            .node_idx = node_idx,
            .return_type = self.module.void_type,
        });
        try self.module.function_map.put(self.module.allocator, copy, idx);
    }

    fn resolve_struct(self: *Analyzer, node: Node) !void {
        const member_range = node.data.rhs;
        const member_start = member_range & 0xFFFF;
        const member_count = member_range >> 16;
        const struct_id = self.module.struct_map.get(self.module.tree.tokenSlice(node.data.lhs)) orelse return error.InvalidWgsl;
        var struct_info = &self.module.structs.items[struct_id];

        var i: u32 = 0;
        while (i < member_count) : (i += 1) {
            const member_idx = self.module.tree.extra_data.items[member_start + i];
            const member = self.module.tree.nodes.items[member_idx];
            const field_ty = try self.resolve_type_node(member.data.lhs);
            const io = try sema_attrs.parse_io_attr(self, member.data.rhs & 0xFFFF, member.data.rhs >> 16);
            try struct_info.fields.ensureUnusedCapacity(self.module.allocator, 1);
            const field_name = try ir.dup_string(self.module.allocator, self.module.tree.tokenSlice(member.main_token));
            struct_info.fields.appendAssumeCapacity(.{
                .name = field_name,
                .ty = field_ty,
                .io = io,
            });
        }
    }

    fn resolve_alias(self: *Analyzer, node: Node) !void {
        const name = self.module.tree.tokenSlice(node.main_token + 1);
        const alias_index = self.module.alias_map.get(name) orelse return error.InvalidWgsl;
        self.module.aliases.items[alias_index].ty = try self.resolve_type_node(node.data.lhs);
    }

    fn resolve_global(self: *Analyzer, node: Node, _: u32) !void {
        const global_name = switch (node.tag) {
            .global_var => self.module.tree.tokenSlice(self.module.tree.extra_data.items[node.data.rhs]),
            .const_decl => self.module.tree.tokenSlice(node.main_token + 1),
            .override_decl => self.module.tree.tokenSlice(self.module.tree.extra_data.items[node.data.lhs]),
            else => return error.InvalidWgsl,
        };
        const global_index = self.module.global_map.get(global_name) orelse return error.InvalidWgsl;
        var global_info = &self.module.globals.items[global_index];

        switch (node.tag) {
            .global_var => {
                const extra = self.module.tree.extra_data.items;
                const base = node.data.rhs;
                global_info.ty = try self.resolve_type_node(node.data.lhs);
                if (extra[base + 1] != 0) global_info.addr_space = try parse_address_space(self.module.tree.tokenSlice(extra[base + 1]));
                if (extra[base + 2] != 0) global_info.access = try parse_access(self.module.tree.tokenSlice(extra[base + 2]));
                global_info.binding = try sema_attrs.parse_binding(self, extra[base + 4], extra[base + 5]);
                if (global_info.addr_space == null and is_handle_type(self.module.types.get(global_info.ty))) {
                    global_info.addr_space = .handle;
                }
            },
            .const_decl => {
                global_info.ty = if (node.data.lhs != NULL_NODE) try self.resolve_type_node(node.data.lhs) else ir.INVALID_TYPE;
                if (node.data.rhs != NULL_NODE) {
                    const init_ty = try self.analyze_expr(node.data.rhs, null);
                    if (global_info.ty == ir.INVALID_TYPE) {
                        global_info.ty = init_ty;
                    } else if (!self.type_compatible(global_info.ty, init_ty)) {
                        return error.TypeMismatch;
                    }
                }
                if (global_info.ty == ir.INVALID_TYPE) return error.InvalidType;
            },
            .override_decl => {
                const extra = self.module.tree.extra_data.items;
                const base = node.data.lhs;
                const type_node = extra[base + 1];
                const init_node = extra[base + 2];
                const attrs_start = extra[base + 3];
                const attrs_len = extra[base + 4];
                global_info.ty = if (type_node != NULL_NODE) try self.resolve_type_node(type_node) else ir.INVALID_TYPE;
                if (init_node != NULL_NODE) {
                    const init_ty = try self.analyze_expr(init_node, null);
                    if (global_info.ty == ir.INVALID_TYPE) {
                        global_info.ty = init_ty;
                    } else if (!self.type_compatible(global_info.ty, init_ty)) {
                        return error.TypeMismatch;
                    }
                }
                if (global_info.ty == ir.INVALID_TYPE) return error.InvalidType;
                global_info.override_id = try sema_attrs.parse_override_id(self, attrs_start, attrs_len);
            },
            else => return error.InvalidWgsl,
        }
    }

    fn resolve_function_signature(self: *Analyzer, node: Node, _: u32) !void {
        const extra = self.module.tree.extra_data.items;
        const extra_start = node.data.lhs;
        const name = self.module.tree.tokenSlice(extra[extra_start + 0]);
        const function_index = self.module.function_map.get(name) orelse return error.InvalidWgsl;
        var function_info = &self.module.functions.items[function_index];

        const params_start = extra[extra_start + 1];
        const params_len = extra[extra_start + 2];
        const return_type_node = extra[extra_start + 3];
        const return_attrs_start = extra[extra_start + 4];
        const return_attrs_len = extra[extra_start + 5];
        const attrs_start = extra[extra_start + 6];
        const attrs_len = extra[extra_start + 7];

        function_info.return_type = if (return_type_node != NULL_NODE) try self.resolve_type_node(return_type_node) else self.module.void_type;
        function_info.return_io = try sema_attrs.parse_io_attr(self, return_attrs_start, return_attrs_len);
        function_info.stage = try sema_attrs.parse_stage(self, attrs_start, attrs_len);
        function_info.workgroup_size = try sema_attrs.parse_workgroup_size(self, attrs_start, attrs_len);

        var i: u32 = 0;
        while (i < params_len) : (i += 1) {
            const param_extra_start = extra[params_start + i];
            const param_ty = try self.resolve_type_node(extra[param_extra_start + 1]);
            const param_io = try sema_attrs.parse_io_attr(self, extra[param_extra_start + 2], extra[param_extra_start + 3]);
            try function_info.params.ensureUnusedCapacity(self.module.allocator, 1);
            const param_name = try ir.dup_string(self.module.allocator, self.module.tree.tokenSlice(extra[param_extra_start + 0]));
            function_info.params.appendAssumeCapacity(.{
                .name = param_name,
                .ty = param_ty,
                .io = param_io,
            });
        }
    }

    fn analyze_function_body(self: *Analyzer, function_index: u32) !void {
        var body = BodyAnalyzer{ .parent = self, .function_index = function_index };
        defer body.deinit();
        try body.push_scope();
        for (body.function().params.items, 0..) |param, index| {
            try body.bind_name(param.name, .{ .param = @intCast(index) });
        }

        const fn_node = self.module.tree.nodes.items[body.function().node_idx];
        try self.analyze_stmt(fn_node.data.rhs, &body);
        body.pop_scope();
    }

    fn analyze_stmt(self: *Analyzer, node_idx: u32, body: *BodyAnalyzer) !void {
        sema_typeutils.captureFailureNode(self.module.tree, node_idx, self.failure);
        const node = self.module.tree.nodes.items[node_idx];
        switch (node.tag) {
            .block => {
                try body.push_scope();
                const stmt_start = node.data.lhs;
                const stmt_count = node.data.rhs;
                var i: u32 = 0;
                while (i < stmt_count) : (i += 1) {
                    try self.analyze_stmt(self.module.tree.extra_data.items[stmt_start + i], body);
                }
                body.pop_scope();
            },
            .var_stmt, .let_stmt, .const_stmt => try self.analyze_local_decl(node_idx, node, body),
            .return_stmt => {
                const expr_node = node.data.lhs;
                if (expr_node != NULL_NODE) {
                    const expr_ty = try self.analyze_expr(expr_node, body);
                    if (!self.type_compatible(body.function().return_type, expr_ty)) return error.TypeMismatch;
                }
            },
            .if_stmt => {
                const extra = self.module.tree.extra_data.items;
                const then_block = extra[node.data.rhs + 0];
                const else_block = extra[node.data.rhs + 1];
                _ = try self.analyze_expr(node.data.lhs, body);
                try self.analyze_stmt(then_block, body);
                if (else_block != NULL_NODE) try self.analyze_stmt(else_block, body);
            },
            .for_stmt => {
                const extra = self.module.tree.extra_data.items;
                const base = node.data.lhs;
                try body.push_scope();
                body.loop_depth += 1;
                defer body.loop_depth -= 1;
                if (extra[base + 0] != NULL_NODE) try self.analyze_stmt(extra[base + 0], body);
                if (extra[base + 1] != NULL_NODE) _ = try self.analyze_expr(extra[base + 1], body);
                if (extra[base + 2] != NULL_NODE) try self.analyze_stmt(extra[base + 2], body);
                try self.analyze_stmt(node.data.rhs, body);
                body.pop_scope();
            },
            .while_stmt => {
                body.loop_depth += 1;
                defer body.loop_depth -= 1;
                _ = try self.analyze_expr(node.data.lhs, body);
                try self.analyze_stmt(node.data.rhs, body);
            },
            .loop_stmt => {
                body.loop_depth += 1;
                defer body.loop_depth -= 1;
                try self.analyze_stmt(node.data.lhs, body);
            },
            .break_stmt => {
                if (body.loop_depth == 0 and body.switch_depth == 0) return error.InvalidWgsl;
                if (node.data.lhs != NULL_NODE) {
                    if (body.loop_depth == 0) return error.InvalidWgsl;
                    const cond_ty = try self.analyze_expr(node.data.lhs, body);
                    if (!self.type_compatible(self.module.bool_type, cond_ty)) return error.TypeMismatch;
                }
            },
            .continue_stmt => {
                if (body.loop_depth == 0) return error.InvalidWgsl;
            },
            .continuing_stmt => {
                if (body.loop_depth == 0) return error.InvalidWgsl;
                try self.analyze_stmt(node.data.lhs, body);
            },
            .switch_stmt => {
                const extra = self.module.tree.extra_data.items;
                const case_start = node.data.rhs & 0xFFFF;
                const case_count = node.data.rhs >> 16;
                _ = try self.analyze_expr(node.data.lhs, body);
                body.switch_depth += 1;
                defer body.switch_depth -= 1;
                var i: u32 = 0;
                while (i < case_count) : (i += 1) {
                    const case_node = self.module.tree.nodes.items[extra[case_start + i]];
                    const selector_start = case_node.data.rhs & 0xFFFF;
                    const selector_count = case_node.data.rhs >> 16;
                    var j: u32 = 0;
                    while (j < selector_count) : (j += 1) {
                        _ = try self.analyze_expr(extra[selector_start + j], body);
                    }
                    try self.analyze_stmt(case_node.data.lhs, body);
                }
            },
            .switch_case => try self.analyze_stmt(node.data.lhs, body),
            .discard_stmt => {},
            .expr_stmt => _ = try self.analyze_expr(node.data.lhs, body),
            .assign_stmt => {
                const lhs_node = self.module.tree.nodes.items[node.data.lhs];
                if (lhs_node.tag == .ident_expr and std.mem.eql(u8, self.module.tree.tokenSlice(lhs_node.main_token), "_")) {
                    _ = try self.analyze_expr(node.data.rhs, body);
                    self.module.node_info.items[node_idx].ty = self.module.void_type;
                    return;
                }
                const lhs_ty = try self.analyze_expr(node.data.lhs, body);
                const lhs_info = self.module.node_info.items[node.data.lhs];
                if (lhs_info.category != .ref) return error.InvalidWgsl;
                const rhs_ty = try self.analyze_expr(node.data.rhs, body);
                const value_ty = try sema_expr.analyze_assignment_value_type(
                    self,
                    lhs_ty,
                    rhs_ty,
                    self.module.tree.tokens.items[node.main_token].tag,
                );
                if (!self.type_compatible(lhs_ty, value_ty)) return error.TypeMismatch;
                self.module.node_info.items[node_idx].ty = lhs_ty;
            },
            .inc_stmt, .dec_stmt => {
                const lhs_ty = try self.analyze_expr(node.data.lhs, body);
                const lhs_info = self.module.node_info.items[node.data.lhs];
                if (lhs_info.category != .ref) return error.InvalidWgsl;
                self.module.node_info.items[node_idx].ty = lhs_ty;
            },
            else => {},
        }
    }

    fn analyze_local_decl(self: *Analyzer, node_idx: u32, node: Node, body: *BodyAnalyzer) !void {
        sema_typeutils.captureFailureNode(self.module.tree, node_idx, self.failure);
        const name = self.module.tree.tokenSlice(node.main_token + 1);
        const explicit_type = if (node.data.lhs != NULL_NODE) try self.resolve_type_node(node.data.lhs) else ir.INVALID_TYPE;
        const init_ty = if (node.data.rhs != NULL_NODE) try self.analyze_expr(node.data.rhs, body) else ir.INVALID_TYPE;
        const resolved_type = blk: {
            if (explicit_type != ir.INVALID_TYPE) break :blk explicit_type;
            if (init_ty != ir.INVALID_TYPE) break :blk materialize_inferred_local_type(self.module, init_ty);
            return error.InvalidType;
        };
        if (explicit_type != ir.INVALID_TYPE and init_ty != ir.INVALID_TYPE and !self.type_compatible(explicit_type, init_ty)) {
            return error.TypeMismatch;
        }
        const local_index: u32 = @intCast(body.function().locals.items.len);
        try body.function().locals.ensureUnusedCapacity(self.module.allocator, 1);
        body.function().locals.appendAssumeCapacity(.{
            .name = try ir.dup_string(self.module.allocator, name),
            .ty = resolved_type,
            .mutable = node.tag == .var_stmt,
        });
        try body.bind_name(body.function().locals.items[local_index].name, .{ .local = local_index });
    }

    fn analyze_expr(self: *Analyzer, node_idx: u32, body: ?*BodyAnalyzer) AnalyzeError!ir.TypeId {
        sema_typeutils.captureFailureNode(self.module.tree, node_idx, self.failure);
        const existing = self.module.node_info.items[node_idx];
        if (existing.ty != ir.INVALID_TYPE) return existing.ty;

        const node = self.module.tree.nodes.items[node_idx];
        var info = NodeInfo{};
        info.ty = switch (node.tag) {
            .int_literal => try sema_typeutils.analyze_int_literal(self.module, node),
            .float_literal => try sema_typeutils.analyze_float_literal(self.module, node),
            .bool_literal => self.module.bool_type,
            .ident_expr => try self.resolve_ident_expr(node, body, &info),
            .unary_expr => try self.analyze_unary(node, body),
            .binary_expr => try self.analyze_binary(node, body),
            .call_expr => try self.analyze_call(node, body),
            .generic_call_expr => try self.analyze_generic_call(node, body),
            .construct_expr => try self.analyze_construct(node, body),
            .member_expr => try self.analyze_member(node, body, &info),
            .index_expr => try self.analyze_index(node, body, &info),
            else => return error.UnsupportedConstruct,
        };
        if (node.tag == .unary_expr and self.module.tree.tokens.items[node.main_token].tag == .@"*") {
            info.category = .ref;
        } else if (node.tag != .ident_expr and node.tag != .member_expr and node.tag != .index_expr) {
            info.category = .value;
        }
        self.module.node_info.items[node_idx] = info;
        return info.ty;
    }

    fn resolve_ident_expr(self: *Analyzer, node: Node, body: ?*BodyAnalyzer, out: *NodeInfo) !ir.TypeId {
        const name = self.module.tree.tokenSlice(node.main_token);
        const symbol = if (body) |ctx|
            ctx.resolve_name(name)
        else if (self.module.global_map.get(name)) |global_index|
            SymbolRef{ .global = global_index }
        else if (self.module.function_map.get(name)) |fn_index|
            SymbolRef{ .function = fn_index }
        else
            null;
        if (symbol == null) return error.UnknownIdentifier;
        out.symbol = symbol.?;
        return switch (symbol.?) {
            .global => |index| blk: {
                out.category = if (is_handle_type(self.module.types.get(self.module.globals.items[index].ty))) .value else .ref;
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

    fn analyze_unary(self: *Analyzer, node: Node, body: ?*BodyAnalyzer) AnalyzeError!ir.TypeId {
        const operand_ty = try self.analyze_expr(node.data.lhs, body);
        return try sema_expr.analyze_unary_type(self, node, body, operand_ty);
    }

    fn analyze_binary(self: *Analyzer, node: Node, body: ?*BodyAnalyzer) AnalyzeError!ir.TypeId {
        const lhs_ty = try self.analyze_expr(node.data.lhs, body);
        const rhs_ty = try self.analyze_expr(node.data.rhs, body);
        return try sema_expr.analyze_binary_type(self, lhs_ty, rhs_ty, self.module.tree.tokens.items[node.main_token].tag);
    }

    fn analyze_call(self: *Analyzer, node: Node, body: ?*BodyAnalyzer) AnalyzeError!ir.TypeId {
        const name = self.module.tree.tokenSlice(node.main_token);
        const args_start = node.data.lhs;
        const args_len = node.data.rhs;

        var arg_types_buf: [16]ir.TypeId = undefined;
        if (args_len > arg_types_buf.len) return error.UnsupportedConstruct;
        var i: u32 = 0;
        while (i < args_len) : (i += 1) {
            arg_types_buf[i] = try self.analyze_expr(self.module.tree.extra_data.items[args_start + i], body);
        }

        if (self.try_resolve_named_type(name)) |ty| {
            try sema_expr.validate_construct(self, ty, arg_types_buf[0..args_len]);
            return ty;
        }
        if (try sema_expr.infer_constructor_call(self, name, arg_types_buf[0..args_len])) |ty| {
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
        return try sema_attrs.infer_builtin_call(self, name, arg_types_buf[0..args_len]);
    }

    fn analyze_generic_call(self: *Analyzer, node: Node, body: ?*BodyAnalyzer) AnalyzeError!ir.TypeId {
        const name = self.module.tree.tokenSlice(node.main_token);
        const target_ty = try self.resolve_type_node(node.data.lhs);
        const span = decode_packed_span(node.data.rhs);

        var arg_types_buf: [16]ir.TypeId = undefined;
        if (span.len > arg_types_buf.len) return error.UnsupportedConstruct;
        var i: u32 = 0;
        while (i < span.len) : (i += 1) {
            arg_types_buf[i] = try self.analyze_expr(self.module.tree.extra_data.items[span.start + i], body);
        }

        if (std.mem.eql(u8, name, "bitcast")) {
            if (span.len != 1) return error.TypeMismatch;
            if (!bitcast_types_compatible(self.module, target_ty, arg_types_buf[0])) return error.TypeMismatch;
            return target_ty;
        }
        return error.UnsupportedBuiltin;
    }

    fn analyze_construct(self: *Analyzer, node: Node, body: ?*BodyAnalyzer) AnalyzeError!ir.TypeId {
        const span = decode_packed_span(node.data.rhs);

        var arg_types_buf: [16]ir.TypeId = undefined;
        const heap_arg_types = if (span.len > arg_types_buf.len)
            try self.module.allocator.alloc(ir.TypeId, span.len)
        else
            null;
        defer if (heap_arg_types) |allocated| self.module.allocator.free(allocated);
        const arg_types = heap_arg_types orelse arg_types_buf[0..span.len];
        var i: u32 = 0;
        while (i < span.len) : (i += 1) {
            arg_types[i] = try self.analyze_expr(self.module.tree.extra_data.items[span.start + i], body);
        }

        const target_ty = blk: {
            const type_node = self.module.tree.nodes.items[node.data.lhs];
            switch (type_node.tag) {
                .type_name, .type_vec_shorthand, .type_mat_shorthand => {
                    const name = self.module.tree.tokenSlice(type_node.main_token);
                    if (try sema_expr.infer_constructor_call(self, name, arg_types)) |ty| break :blk ty;
                },
                else => {},
            }
            break :blk try self.resolve_type_node(node.data.lhs);
        };
        try sema_expr.validate_construct(self, target_ty, arg_types);
        return target_ty;
    }
    fn analyze_member(self: *Analyzer, node: Node, body: ?*BodyAnalyzer, out: *NodeInfo) AnalyzeError!ir.TypeId {
        const base_ty = try self.analyze_expr(node.data.lhs, body);
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
                const swizzle = parse_vector_swizzle(field_name, vec.len) catch return error.InvalidWgsl;
                if (swizzle.len == 1) {
                    out.category = self.module.node_info.items[node.data.lhs].category;
                    return vec.elem;
                }
                out.category = .value;
                return try self.module.types.intern(.{ .vector = .{ .elem = vec.elem, .len = swizzle.len } });
            },
            else => return error.InvalidWgsl,
        }
    }

    fn analyze_index(self: *Analyzer, node: Node, body: ?*BodyAnalyzer, out: *NodeInfo) AnalyzeError!ir.TypeId {
        const base_ty = try self.analyze_expr(node.data.lhs, body);
        _ = try self.analyze_expr(node.data.rhs, body);
        out.category = self.module.node_info.items[node.data.lhs].category;
        const inner_ty = switch (self.module.types.get(base_ty)) {
            .ref => |ref_ty| ref_ty.elem,
            else => base_ty,
        };
        return switch (self.module.types.get(inner_ty)) {
            .array => |arr| arr.elem,
            .vector => |vec| vec.elem,
            .matrix => |mat| try self.module.types.intern(.{ .vector = .{ .elem = mat.elem, .len = mat.rows } }),
            else => error.InvalidWgsl,
        };
    }

    pub fn resolve_type_node(self: *Analyzer, node_idx: u32) AnalyzeError!ir.TypeId {
        sema_typeutils.captureFailureNode(self.module.tree, node_idx, self.failure);
        const node = self.module.tree.nodes.items[node_idx];
        return switch (node.tag) {
            .type_name => try self.resolve_type_name(self.module.tree.tokenSlice(node.main_token)),
            .type_vec_shorthand => try self.resolve_type_name(self.module.tree.tokenSlice(node.main_token)),
            .type_mat_shorthand => try self.resolve_type_name(self.module.tree.tokenSlice(node.main_token)),
            .type_parameterized => try self.resolve_type_parameterized(node),
            else => error.InvalidType,
        };
    }

    fn resolve_type_name(self: *Analyzer, name: []const u8) AnalyzeError!ir.TypeId {
        if (std.mem.eql(u8, name, "void")) return self.module.void_type;
        if (std.mem.eql(u8, name, "bool")) return self.module.bool_type;
        if (std.mem.eql(u8, name, "i32")) return self.module.i32_type;
        if (std.mem.eql(u8, name, "u32")) return self.module.u32_type;
        if (std.mem.eql(u8, name, "f32")) return self.module.f32_type;
        if (std.mem.eql(u8, name, "f16")) return self.module.f16_type;
        if (std.mem.eql(u8, name, "sampler")) return self.module.sampler_type;
        if (std.mem.eql(u8, name, "sampler_comparison")) return self.module.sampler_comparison_type;
        if (std.mem.eql(u8, name, "texture_1d")) return try self.module.types.intern(.{ .texture_1d = self.module.f32_type });
        if (std.mem.eql(u8, name, "texture_2d")) return try self.module.types.intern(.{ .texture_2d = self.module.f32_type });
        if (std.mem.eql(u8, name, "texture_external")) return try self.module.types.intern(.{ .texture_2d = self.module.f32_type });
        if (std.mem.eql(u8, name, "texture_3d")) return try self.module.types.intern(.{ .texture_3d = self.module.f32_type });
        if (std.mem.eql(u8, name, "texture_depth_2d")) return try self.module.types.intern(.{ .texture_depth_2d = {} });
        if (std.mem.eql(u8, name, "texture_depth_cube")) return try self.module.types.intern(.{ .texture_depth_cube = {} });
        if (std.mem.eql(u8, name, "texture_cube")) return try self.module.types.intern(.{ .texture_cube = self.module.f32_type });
        if (std.mem.eql(u8, name, "texture_2d_array")) return try self.module.types.intern(.{ .texture_2d_array = self.module.f32_type });
        if (self.try_resolve_named_type(name)) |ty| return ty;
        return error.UnknownType;
    }

    pub fn try_resolve_named_type(self: *Analyzer, name: []const u8) ?ir.TypeId {
        if (self.module.struct_map.get(name)) |struct_id| return self.module.structs.items[struct_id].ty;
        if (self.module.alias_map.get(name)) |alias_index| {
            const ty = self.module.aliases.items[alias_index].ty;
            if (ty != ir.INVALID_TYPE) return ty;
        }
        return switch (token_mod.lookupIdent(name)) {
            .kw_vec2f => self.module.types.intern(.{ .vector = .{ .elem = self.module.f32_type, .len = 2 } }) catch null,
            .kw_vec3f => self.module.types.intern(.{ .vector = .{ .elem = self.module.f32_type, .len = 3 } }) catch null,
            .kw_vec4f => self.module.types.intern(.{ .vector = .{ .elem = self.module.f32_type, .len = 4 } }) catch null,
            .kw_vec2u => self.module.types.intern(.{ .vector = .{ .elem = self.module.u32_type, .len = 2 } }) catch null,
            .kw_vec3u => self.module.types.intern(.{ .vector = .{ .elem = self.module.u32_type, .len = 3 } }) catch null,
            .kw_vec4u => self.module.types.intern(.{ .vector = .{ .elem = self.module.u32_type, .len = 4 } }) catch null,
            .kw_vec2i => self.module.types.intern(.{ .vector = .{ .elem = self.module.i32_type, .len = 2 } }) catch null,
            .kw_vec3i => self.module.types.intern(.{ .vector = .{ .elem = self.module.i32_type, .len = 3 } }) catch null,
            .kw_vec4i => self.module.types.intern(.{ .vector = .{ .elem = self.module.i32_type, .len = 4 } }) catch null,
            .kw_vec2h => self.module.types.intern(.{ .vector = .{ .elem = self.module.f16_type, .len = 2 } }) catch null,
            .kw_vec3h => self.module.types.intern(.{ .vector = .{ .elem = self.module.f16_type, .len = 3 } }) catch null,
            .kw_vec4h => self.module.types.intern(.{ .vector = .{ .elem = self.module.f16_type, .len = 4 } }) catch null,
            .kw_mat2x2f => self.module.types.intern(.{ .matrix = .{ .elem = self.module.f32_type, .columns = 2, .rows = 2 } }) catch null,
            .kw_mat3x3f => self.module.types.intern(.{ .matrix = .{ .elem = self.module.f32_type, .columns = 3, .rows = 3 } }) catch null,
            .kw_mat4x4f => self.module.types.intern(.{ .matrix = .{ .elem = self.module.f32_type, .columns = 4, .rows = 4 } }) catch null,
            .kw_mat2x2h => self.module.types.intern(.{ .matrix = .{ .elem = self.module.f16_type, .columns = 2, .rows = 2 } }) catch null,
            .kw_mat3x3h => self.module.types.intern(.{ .matrix = .{ .elem = self.module.f16_type, .columns = 3, .rows = 3 } }) catch null,
            .kw_mat4x4h => self.module.types.intern(.{ .matrix = .{ .elem = self.module.f16_type, .columns = 4, .rows = 4 } }) catch null,
            else => null,
        };
    }

    fn resolve_type_parameterized(self: *Analyzer, node: Node) AnalyzeError!ir.TypeId {
        return sema_resolve.resolve_type_parameterized(self, node);
    }

    pub fn type_compatible(self: *Analyzer, expected: ir.TypeId, actual: ir.TypeId) bool {
        if (expected == actual) return true;
        if (expected == ir.INVALID_TYPE or actual == ir.INVALID_TYPE) return false;
        return switch (self.module.types.get(expected)) {
            .scalar => |expected_scalar| switch (self.module.types.get(actual)) {
                .scalar => |actual_scalar| switch (expected_scalar) {
                    .abstract_int => actual_scalar == .i32 or actual_scalar == .u32 or actual_scalar == .abstract_int,
                    .abstract_float => actual_scalar == .f32 or actual_scalar == .f16 or actual_scalar == .abstract_float,
                    .i32, .u32 => actual_scalar == .abstract_int,
                    .f32, .f16 => actual_scalar == .abstract_float,
                    else => false,
                },
                else => false,
            },
            .ref => |ref_ty| ref_ty.elem == actual or self.type_compatible(ref_ty.elem, actual),
            else => false,
        };
    }
};

const bitcast_types_compatible = sema_typeutils.bitcast_types_compatible;
const is_handle_type = sema_typeutils.is_handle_type;
const materialize_inferred_local_type = sema_typeutils.materialize_inferred_local_type;
const init_builtin_types = sema_helpers.init_builtin_types;
const decode_packed_span = sema_helpers.decode_packed_span;
const parse_address_space = sema_helpers.parse_address_space;
const parse_access = sema_helpers.parse_access;
const parse_vector_swizzle = sema_helpers.parse_vector_swizzle;
