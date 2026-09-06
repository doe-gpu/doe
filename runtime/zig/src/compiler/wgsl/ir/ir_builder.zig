const std = @import("std");
const ast_mod = @import("../frontend/ast.zig");
const ir = @import("ir.zig");
const ir_const_eval = @import("ir_const_eval.zig");
const sema = @import("../frontend/sema.zig");
const sema_helpers = @import("../frontend/sema_helpers.zig");
const token_mod = @import("../frontend/token.zig");

const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const NULL_NODE = ast_mod.NULL_NODE;
const Tag = token_mod.Tag;

pub const BuildError = error{
    OutOfMemory,
    InvalidIr,
    UnsupportedConstruct,
};

pub const FailureContext = struct {
    node_idx: u32 = NULL_NODE,
    token_idx: ?u32 = null,
};

var last_failure_context = FailureContext{};

pub fn resetLastFailureContext() void {
    last_failure_context = .{};
}

pub fn lastFailureContext() FailureContext {
    return last_failure_context;
}

pub fn build(allocator: std.mem.Allocator, tree: *const Ast, semantic: *const sema.SemanticModule) BuildError!ir.Module {
    resetLastFailureContext();
    var module = ir.Module.init(allocator);
    errdefer module.deinit();

    try module.types.items.appendSlice(allocator, semantic.types.items.items);
    try copy_structs(allocator, &module, semantic);
    try copy_globals(allocator, tree, &module, semantic);
    try copy_functions(allocator, tree, &module, semantic);
    return module;
}

fn copy_structs(allocator: std.mem.Allocator, module: *ir.Module, semantic: *const sema.SemanticModule) BuildError!void {
    for (semantic.structs.items) |struct_info| {
        var struct_def = ir.StructDef{ .name = try ir.dup_string(allocator, struct_info.name) };
        errdefer struct_def.deinit(allocator);
        for (struct_info.fields.items) |field| {
            try struct_def.fields.ensureUnusedCapacity(allocator, 1);
            struct_def.fields.appendAssumeCapacity(.{
                .name = try ir.dup_string(allocator, field.name),
                .ty = field.ty,
                .io = field.io,
            });
        }
        try module.structs.append(allocator, struct_def);
    }
}

fn copy_globals(allocator: std.mem.Allocator, tree: *const Ast, module: *ir.Module, semantic: *const sema.SemanticModule) BuildError!void {
    for (semantic.globals.items) |global_info| {
        captureFailureNode(tree, global_info.node_idx);
        const node = tree.nodes.items[global_info.node_idx];
        var initializer: ?ir.ConstantValue = null;
        switch (node.tag) {
            .global_var => {
                const init_node = tree.extra_data.items[node.data.rhs + 3];
                if (init_node != NULL_NODE) initializer = try constant_from_node(allocator, tree, semantic, init_node, 0);
            },
            .const_decl => {
                if (node.data.rhs != NULL_NODE) initializer = try constant_from_node(allocator, tree, semantic, node.data.rhs, 0);
            },
            .override_decl => {
                const init_node = tree.extra_data.items[node.data.lhs + 2];
                if (init_node != NULL_NODE) initializer = try constant_from_node(allocator, tree, semantic, init_node, 0);
            },
            else => {},
        }
        var initializer_owned = true;
        errdefer if (initializer_owned) {
            if (initializer) |*value| value.deinit(allocator);
        };
        try module.globals.ensureUnusedCapacity(allocator, 1);
        module.globals.appendAssumeCapacity(.{
            .name = try ir.dup_string(allocator, global_info.name),
            .ty = global_info.ty,
            .class = global_info.class,
            .addr_space = global_info.addr_space,
            .access = global_info.access,
            .binding = global_info.binding,
            .io = global_info.io,
            .initializer = initializer,
            .override_id = global_info.override_id,
        });
        initializer_owned = false;
    }
}

fn copy_functions(allocator: std.mem.Allocator, tree: *const Ast, module: *ir.Module, semantic: *const sema.SemanticModule) BuildError!void {
    for (semantic.functions.items, 0..) |function_info, function_index| {
        captureFailureNode(tree, function_info.node_idx);
        var function = ir.Function{
            .name = try ir.dup_string(allocator, function_info.name),
            .return_type = function_info.return_type,
            .return_io = function_info.return_io,
            .stage = function_info.stage,
            .workgroup_size = function_info.workgroup_size,
        };
        errdefer function.deinit(allocator);

        for (function_info.params.items) |param| {
            try function.params.ensureUnusedCapacity(allocator, 1);
            function.params.appendAssumeCapacity(.{
                .name = try ir.dup_string(allocator, param.name),
                .ty = param.ty,
                .io = param.io,
            });
        }
        for (function_info.locals.items) |local| {
            try function.locals.ensureUnusedCapacity(allocator, 1);
            function.locals.appendAssumeCapacity(.{
                .name = try ir.dup_string(allocator, local.name),
                .ty = local.ty,
                .mutable = local.mutable,
            });
        }

        var builder = FunctionBuilder{
            .allocator = allocator,
            .tree = tree,
            .semantic = semantic,
            .function = &function,
        };
        const fn_node = tree.nodes.items[function_info.node_idx];
        function.root_stmt = try builder.lower_stmt(fn_node.data.rhs);

        const new_index: ir.FunctionId = @intCast(module.functions.items.len);
        try module.functions.ensureUnusedCapacity(allocator, 1);
        if (function_info.stage) |stage| {
            try module.entry_points.append(allocator, .{
                .function = new_index,
                .stage = stage,
                .workgroup_size = function_info.workgroup_size,
            });
        }
        module.functions.appendAssumeCapacity(function);
        _ = function_index;
    }
}

const FunctionBuilder = struct {
    allocator: std.mem.Allocator,
    tree: *const Ast,
    semantic: *const sema.SemanticModule,
    function: *ir.Function,
    next_local_index: u32 = 0,

    fn lower_stmt(self: *FunctionBuilder, node_idx: u32) BuildError!ir.StmtId {
        captureFailureNode(self.tree, node_idx);
        const node = self.tree.nodes.items[node_idx];
        return switch (node.tag) {
            .block => try self.lower_block(node),
            .var_stmt, .let_stmt, .const_stmt => try self.lower_local_decl(node),
            .return_stmt => try self.function.append_stmt(self.allocator, .{ .return_ = if (node.data.lhs != NULL_NODE) try self.lower_value_expr(node.data.lhs) else null }),
            .if_stmt => try self.lower_if_stmt(node),
            .for_stmt => try self.lower_for_stmt(node),
            .while_stmt => try self.function.append_stmt(self.allocator, .{ .loop_ = .{
                .kind = .while_loop,
                .init = null,
                .cond = try self.lower_value_expr(node.data.lhs),
                .continuing = null,
                .body = try self.lower_stmt(node.data.rhs),
            } }),
            .loop_stmt => try self.lower_loop_stmt(node),
            .break_stmt => try self.lower_break_stmt(node),
            .continue_stmt => try self.function.append_stmt(self.allocator, .continue_),
            .continuing_stmt => try self.lower_stmt(node.data.lhs),
            .discard_stmt => try self.function.append_stmt(self.allocator, .discard_),
            .expr_stmt => try self.function.append_stmt(self.allocator, .{ .expr = try self.lower_value_expr(node.data.lhs) }),
            .assign_stmt => blk: {
                const lhs_node = self.tree.nodes.items[node.data.lhs];
                if (lhs_node.tag == .ident_expr and std.mem.eql(u8, self.tree.tokenSlice(lhs_node.main_token), "_")) {
                    break :blk try self.function.append_stmt(self.allocator, .{ .expr = try self.lower_value_expr(node.data.rhs) });
                }
                break :blk try self.function.append_stmt(self.allocator, .{ .assign = .{
                    .op = map_assign_op(self.tree.tokens.items[node.main_token].tag),
                    .lhs = try self.lower_ref_expr(node.data.lhs),
                    .rhs = try self.lower_value_expr(node.data.rhs),
                } });
            },
            .inc_stmt, .dec_stmt => blk: {
                const lhs_ref = try self.lower_ref_expr(node.data.lhs);
                const one_id = try self.function.append_expr(self.allocator, .{
                    .ty = self.semantic.abstract_int_type,
                    .category = .value,
                    .data = .{ .int_lit = 1 },
                });
                break :blk try self.function.append_stmt(self.allocator, .{ .assign = .{
                    .op = if (node.tag == .inc_stmt) .add else .sub,
                    .lhs = lhs_ref,
                    .rhs = one_id,
                } });
            },
            .switch_stmt => try self.lower_switch_stmt(node),
            .switch_case, .else_clause => error.UnsupportedConstruct,
            else => error.UnsupportedConstruct,
        };
    }

    fn lower_if_stmt(self: *FunctionBuilder, node: Node) !ir.StmtId {
        const extra = self.tree.extra_data.items;
        const then_block = extra[node.data.rhs + 0];
        const else_block = extra[node.data.rhs + 1];
        return try self.function.append_stmt(self.allocator, .{ .if_ = .{
            .cond = try self.lower_value_expr(node.data.lhs),
            .then_block = try self.lower_stmt(then_block),
            .else_block = if (else_block != NULL_NODE) try self.lower_stmt(else_block) else null,
        } });
    }

    fn lower_block(self: *FunctionBuilder, node: Node) !ir.StmtId {
        var children = std.ArrayListUnmanaged(ir.StmtId){};
        defer children.deinit(self.allocator);
        var i: u32 = 0;
        while (i < node.data.rhs) : (i += 1) {
            try children.append(self.allocator, try self.lower_stmt(self.tree.extra_data.items[node.data.lhs + i]));
        }
        const range = try self.function.append_stmt_children(self.allocator, children.items);
        return try self.function.append_stmt(self.allocator, .{ .block = range });
    }

    fn lower_local_decl(self: *FunctionBuilder, node: Node) !ir.StmtId {
        const local_index = self.next_local_index;
        self.next_local_index += 1;
        const local_ty = self.function.locals.items[local_index].ty;
        const initializer = if (node.data.rhs != NULL_NODE) blk: {
            break :blk switch (self.semantic.types.get(local_ty)) {
                .ref => try self.lower_expr(node.data.rhs),
                else => try self.lower_value_expr(node.data.rhs),
            };
        } else null;
        return try self.function.append_stmt(self.allocator, .{ .local_decl = .{
            .local = local_index,
            .initializer = initializer,
            .is_const = node.tag != .var_stmt,
        } });
    }

    fn lower_for_stmt(self: *FunctionBuilder, node: Node) !ir.StmtId {
        const extra = self.tree.extra_data.items;
        const base = node.data.lhs;
        return try self.function.append_stmt(self.allocator, .{ .loop_ = .{
            .kind = .for_loop,
            .init = if (extra[base + 0] != NULL_NODE) try self.lower_stmt(extra[base + 0]) else null,
            .cond = if (extra[base + 1] != NULL_NODE) try self.lower_value_expr(extra[base + 1]) else null,
            .continuing = if (extra[base + 2] != NULL_NODE) try self.lower_stmt(extra[base + 2]) else null,
            .body = try self.lower_stmt(node.data.rhs),
        } });
    }

    fn lower_loop_stmt(self: *FunctionBuilder, node: Node) !ir.StmtId {
        const parts = try self.lower_loop_body_parts(node.data.lhs);
        return try self.function.append_stmt(self.allocator, .{ .loop_ = .{
            .kind = .loop,
            .init = null,
            .cond = null,
            .continuing = parts.continuing,
            .body = parts.body,
        } });
    }

    fn lower_loop_body_parts(self: *FunctionBuilder, block_idx: u32) !struct { body: ir.StmtId, continuing: ?ir.StmtId } {
        const block = self.tree.nodes.items[block_idx];
        if (block.tag != .block or block.data.rhs == 0) {
            return .{ .body = try self.lower_stmt(block_idx), .continuing = null };
        }

        const last_stmt_idx = self.tree.extra_data.items[block.data.lhs + block.data.rhs - 1];
        const last_stmt = self.tree.nodes.items[last_stmt_idx];
        if (last_stmt.tag != .continuing_stmt) {
            return .{ .body = try self.lower_stmt(block_idx), .continuing = null };
        }

        var children = std.ArrayListUnmanaged(ir.StmtId){};
        defer children.deinit(self.allocator);
        var i: u32 = 0;
        while (i + 1 < block.data.rhs) : (i += 1) {
            try children.append(self.allocator, try self.lower_stmt(self.tree.extra_data.items[block.data.lhs + i]));
        }

        const range = try self.function.append_stmt_children(self.allocator, children.items);
        return .{
            .body = try self.function.append_stmt(self.allocator, .{ .block = range }),
            .continuing = try self.lower_stmt(last_stmt.data.lhs),
        };
    }

    fn lower_break_stmt(self: *FunctionBuilder, node: Node) !ir.StmtId {
        if (node.data.lhs == NULL_NODE) return try self.function.append_stmt(self.allocator, .break_);

        const break_stmt = try self.function.append_stmt(self.allocator, .break_);
        const range = try self.function.append_stmt_children(self.allocator, &.{break_stmt});
        const then_block = try self.function.append_stmt(self.allocator, .{ .block = range });
        return try self.function.append_stmt(self.allocator, .{ .if_ = .{
            .cond = try self.lower_value_expr(node.data.lhs),
            .then_block = then_block,
            .else_block = null,
        } });
    }

    fn lower_switch_stmt(self: *FunctionBuilder, node: Node) !ir.StmtId {
        const extra = self.tree.extra_data.items;
        const case_start = node.data.rhs & 0xFFFF;
        const case_count = node.data.rhs >> 16;
        const cases_range = ir.Range{
            .start = @intCast(self.function.switch_cases.items.len),
            .len = case_count,
        };

        var i: u32 = 0;
        while (i < case_count) : (i += 1) {
            const case_node = self.tree.nodes.items[extra[case_start + i]];
            const selector_start = case_node.data.rhs & 0xFFFF;
            const selector_count = case_node.data.rhs >> 16;
            var case_ir = ir.SwitchCase{
                .body = try self.lower_stmt(case_node.data.lhs),
                .is_default = self.tree.tokens.items[case_node.main_token].tag == .kw_default,
            };
            errdefer case_ir.deinit(self.allocator);

            var j: u32 = 0;
            while (j < selector_count) : (j += 1) {
                try case_ir.selectors.append(self.allocator, try self.lower_value_expr(extra[selector_start + j]));
            }
            try self.function.switch_cases.append(self.allocator, case_ir);
        }

        return try self.function.append_stmt(self.allocator, .{ .switch_ = .{
            .expr = try self.lower_value_expr(node.data.lhs),
            .cases = cases_range,
        } });
    }

    fn lower_expr(self: *FunctionBuilder, node_idx: u32) BuildError!ir.ExprId {
        captureFailureNode(self.tree, node_idx);
        const node = self.tree.nodes.items[node_idx];
        const ty = self.semantic.nodeType(node_idx);
        const category = self.semantic.nodeCategory(node_idx);
        const expr = switch (node.tag) {
            .bool_literal => ir.Expr{ .bool_lit = std.mem.eql(u8, self.tree.tokenSlice(node.main_token), "true") },
            .int_literal => ir.Expr{ .int_lit = sema_helpers.parse_wgsl_int_literal(u64, self.tree.tokenSlice(node.main_token)) catch return error.InvalidIr },
            .float_literal => ir.Expr{ .float_lit = sema_helpers.parse_wgsl_float_literal(self.tree.tokenSlice(node.main_token)) catch return error.InvalidIr },
            .ident_expr => try self.lower_ident(node_idx),
            .unary_expr => blk: {
                const op_tag = self.tree.tokens.items[node.main_token].tag;
                if (op_tag == .@"&") break :blk try self.lower_address_of(node.data.lhs);
                if (op_tag == .@"*") return try self.lower_value_expr(node.data.lhs);
                break :blk ir.Expr{ .unary = .{
                    .op = map_unary_op(op_tag),
                    .operand = try self.lower_value_expr(node.data.lhs),
                } };
            },
            .binary_expr => ir.Expr{ .binary = .{
                .op = map_binary_op(self.tree.tokens.items[node.main_token].tag),
                .lhs = try self.lower_value_expr(node.data.lhs),
                .rhs = try self.lower_value_expr(node.data.rhs),
            } },
            .call_expr => try self.lower_call(node_idx, node),
            .generic_call_expr => try self.lower_generic_call(node_idx, node),
            .construct_expr => try self.lower_construct(node_idx, node),
            .member_expr => ir.Expr{ .member = .{
                .base = if (category == .ref) try self.lower_ref_expr(node.data.lhs) else try self.lower_value_expr(node.data.lhs),
                .field_index = try self.resolve_member_index(node.data.lhs, node.data.rhs),
                .field_name = try ir.dup_string(self.allocator, self.tree.tokenSlice(node.data.rhs)),
            } },
            .index_expr => ir.Expr{ .index = .{
                .base = if (category == .ref) try self.lower_ref_expr(node.data.lhs) else try self.lower_value_expr(node.data.lhs),
                .index = try self.lower_value_expr(node.data.rhs),
            } },
            else => return error.UnsupportedConstruct,
        };
        errdefer switch (expr) {
            .call => |call| self.allocator.free(call.name),
            .member => |member| self.allocator.free(member.field_name),
            else => {},
        };
        return try self.function.append_expr(self.allocator, .{
            .ty = ty,
            .category = category,
            .data = expr,
        });
    }

    fn lower_address_of(self: *FunctionBuilder, node_idx: u32) !ir.Expr {
        const ref_id = try self.lower_ref_expr(node_idx);
        const ref_expr = self.function.exprs.items[ref_id];
        return switch (ref_expr.data) {
            .param_ref => |index| .{ .param_ref = index },
            .local_ref => |index| .{ .local_ref = index },
            .global_ref => |index| .{ .global_ref = index },
            .member => |member| .{ .member = .{
                .base = member.base,
                .field_name = try ir.dup_string(self.allocator, member.field_name),
                .field_index = member.field_index,
            } },
            .index => |index| .{ .index = index },
            else => error.InvalidIr,
        };
    }

    fn lower_ident(self: *FunctionBuilder, node_idx: u32) !ir.Expr {
        return switch (self.semantic.nodeSymbol(node_idx)) {
            .global => |index| .{ .global_ref = index },
            .param => |index| .{ .param_ref = index },
            .local => |index| .{ .local_ref = index },
            else => return error.InvalidIr,
        };
    }

    fn lower_call(self: *FunctionBuilder, node_idx: u32, node: Node) !ir.Expr {
        const name = self.tree.tokenSlice(node.main_token);
        var args = std.ArrayListUnmanaged(ir.ExprId){};
        defer args.deinit(self.allocator);

        const kind: ir.CallKind = if (self.semantic.function_map.get(name) != null) .user else .builtin;
        const is_constructor = self.semantic.tryResolveNamedType(name) != null;
        const callee_fn = if (kind == .user) blk: {
            const fn_index = self.semantic.function_map.get(name) orelse break :blk null;
            break :blk &self.semantic.functions.items[fn_index];
        } else null;

        var i: u32 = 0;
        while (i < node.data.rhs) : (i += 1) {
            const arg_node = self.tree.extra_data.items[node.data.lhs + i];
            const param_is_ref = callee_fn != null and i < callee_fn.?.params.items.len and
                switch (self.semantic.types.get(callee_fn.?.params.items[i].ty)) {
                    .ref => true,
                    else => false,
                };
            if (!is_constructor and kind == .builtin and i == 0 and (std.mem.startsWith(u8, name, "atomic") or std.mem.eql(u8, name, "arrayLength"))) {
                // arrayLength(&buf) and atomic builtins may write &ref — unwrap & to get the ref.
                const ref_node = blk: {
                    const an = self.tree.nodes.items[arg_node];
                    if (an.tag == .unary_expr and self.tree.tokens.items[an.main_token].tag == .@"&") break :blk an.data.lhs;
                    break :blk arg_node;
                };
                try args.append(self.allocator, try self.lower_ref_expr(ref_node));
            } else if (param_is_ref) {
                // Pointer params: unwrap & and pass the ref directly.
                const ref_node = blk: {
                    const an = self.tree.nodes.items[arg_node];
                    if (an.tag == .unary_expr and self.tree.tokens.items[an.main_token].tag == .@"&") break :blk an.data.lhs;
                    break :blk arg_node;
                };
                try args.append(self.allocator, try self.lower_ref_expr(ref_node));
            } else {
                try args.append(self.allocator, try self.lower_value_expr(arg_node));
            }
        }
        const range = try self.function.append_expr_args(self.allocator, args.items);
        if (is_constructor) {
            return .{ .construct = .{ .ty = self.semantic.nodeType(node_idx), .args = range } };
        }
        return .{ .call = .{ .name = try ir.dup_string(self.allocator, name), .kind = kind, .args = range } };
    }

    fn lower_generic_call(self: *FunctionBuilder, _: u32, node: Node) !ir.Expr {
        const name = self.tree.tokenSlice(node.main_token);
        const span = sema_helpers.decode_packed_span(node.data.rhs);
        var args = std.ArrayListUnmanaged(ir.ExprId){};
        defer args.deinit(self.allocator);

        var i: u32 = 0;
        while (i < span.len) : (i += 1) {
            try args.append(self.allocator, try self.lower_value_expr(self.tree.extra_data.items[span.start + i]));
        }

        return .{ .call = .{
            .name = try ir.dup_string(self.allocator, name),
            .kind = .builtin,
            .args = try self.function.append_expr_args(self.allocator, args.items),
        } };
    }

    fn lower_construct(self: *FunctionBuilder, node_idx: u32, node: Node) !ir.Expr {
        var args = std.ArrayListUnmanaged(ir.ExprId){};
        defer args.deinit(self.allocator);

        const span = sema_helpers.decode_packed_span(node.data.rhs);
        var i: u32 = 0;
        while (i < span.len) : (i += 1) {
            try args.append(self.allocator, try self.lower_value_expr(self.tree.extra_data.items[span.start + i]));
        }

        return .{
            .construct = .{
                .ty = self.semantic.nodeType(node_idx),
                .args = try self.function.append_expr_args(self.allocator, args.items),
            },
        };
    }

    fn resolve_member_index(self: *FunctionBuilder, base_node_idx: u32, field_token: u32) !u32 {
        const field_name = self.tree.tokenSlice(field_token);
        var ty = self.semantic.nodeType(base_node_idx);
        while (true) {
            switch (self.semantic.types.get(ty)) {
                .ref => |ref_ty| ty = ref_ty.elem,
                .vector => |vec| {
                    return (sema_helpers.parse_vector_swizzle(field_name, vec.len) catch return error.InvalidIr).indices[0];
                },
                .struct_ => |struct_id| {
                    const struct_info = self.semantic.structs.items[struct_id];
                    for (struct_info.fields.items, 0..) |field, index| {
                        if (std.mem.eql(u8, field.name, field_name)) return @intCast(index);
                    }
                    return error.InvalidIr;
                },
                else => return error.InvalidIr,
            }
        }
    }

    fn lower_value_expr(self: *FunctionBuilder, node_idx: u32) !ir.ExprId {
        const expr_id = try self.lower_expr(node_idx);
        if (self.function.exprs.items[expr_id].category == .value) return expr_id;
        const value_ty = switch (self.semantic.types.get(self.function.exprs.items[expr_id].ty)) {
            .ref => |ref_ty| ref_ty.elem,
            else => self.function.exprs.items[expr_id].ty,
        };
        return try self.function.append_expr(self.allocator, .{
            .ty = value_ty,
            .category = .value,
            .data = .{ .load = expr_id },
        });
    }

    fn lower_ref_expr(self: *FunctionBuilder, node_idx: u32) !ir.ExprId {
        const node = self.tree.nodes.items[node_idx];
        if (node.tag == .unary_expr and self.tree.tokens.items[node.main_token].tag == .@"*") {
            return try self.lower_ref_expr(node.data.lhs);
        }
        const expr_id = try self.lower_expr(node_idx);
        if (self.function.exprs.items[expr_id].category != .ref) return error.InvalidIr;
        return expr_id;
    }
};

fn map_unary_op(tag: Tag) ir.UnaryOp {
    return switch (tag) {
        .@"-" => .neg,
        .@"!" => .not,
        .@"~" => .bit_not,
        else => .neg,
    };
}

fn map_binary_op(tag: Tag) ir.BinaryOp {
    return switch (tag) {
        .@"+" => .add,
        .@"-" => .sub,
        .@"*" => .mul,
        .@"/" => .div,
        .@"%" => .rem,
        .@"&" => .bit_and,
        .@"|" => .bit_or,
        .@"^" => .bit_xor,
        .shift_left => .shift_left,
        .shift_right => .shift_right,
        .eq_eq => .equal,
        .not_eq => .not_equal,
        .@"<" => .less,
        .lte => .less_equal,
        .@">" => .greater,
        .gte => .greater_equal,
        .and_and => .logical_and,
        .or_or => .logical_or,
        else => .add,
    };
}

fn map_assign_op(tag: Tag) ir.AssignOp {
    return switch (tag) {
        .@"=" => .assign,
        .plus_eq => .add,
        .minus_eq => .sub,
        .star_eq => .mul,
        .slash_eq => .div,
        .percent_eq => .rem,
        .amp_eq => .bit_and,
        .pipe_eq => .bit_or,
        .caret_eq => .bit_xor,
        .shift_left_eq => .shift_left,
        .shift_right_eq => .shift_right,
        else => .assign,
    };
}

fn constant_from_node(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    semantic: *const sema.SemanticModule,
    node_idx: u32,
    depth: u8,
) BuildError!?ir.ConstantValue {
    captureFailureNode(tree, node_idx);
    if (depth >= 16) return error.UnsupportedConstruct;
    const node = tree.nodes.items[node_idx];
    return switch (node.tag) {
        .bool_literal => ir.ConstantValue{ .bool = std.mem.eql(u8, tree.tokenSlice(node.main_token), "true") },
        .int_literal => ir.ConstantValue{ .int = sema_helpers.parse_wgsl_int_literal(u64, tree.tokenSlice(node.main_token)) catch return error.InvalidIr },
        .float_literal => ir.ConstantValue{ .float = sema_helpers.parse_wgsl_float_literal(tree.tokenSlice(node.main_token)) catch return error.InvalidIr },
        .ident_expr => blk: {
            const name = tree.tokenSlice(node.main_token);
            const global_index = semantic.global_map.get(name) orelse break :blk null;
            const global_info = semantic.globals.items[global_index];
            const global_node = tree.nodes.items[global_info.node_idx];
            const init_node = switch (global_node.tag) {
                .const_decl => global_node.data.rhs,
                .override_decl => tree.extra_data.items[global_node.data.lhs + 2],
                .global_var => tree.extra_data.items[global_node.data.rhs + 3],
                else => NULL_NODE,
            };
            if (init_node == NULL_NODE) break :blk null;
            break :blk try constant_from_node(allocator, tree, semantic, init_node, depth + 1);
        },
        .unary_expr => switch (tree.tokens.items[node.main_token].tag) {
            .@"-" => blk: {
                const inner = try constant_from_node(allocator, tree, semantic, node.data.lhs, depth + 1) orelse return error.UnsupportedConstruct;
                switch (inner) {
                    .int => |value| break :blk ir.ConstantValue{ .int = (~value) +% 1 },
                    .float => |value| break :blk ir.ConstantValue{ .float = -value },
                    else => return error.UnsupportedConstruct,
                }
            },
            else => error.UnsupportedConstruct,
        },
        .binary_expr => blk: {
            const lhs = try constant_from_node(allocator, tree, semantic, node.data.lhs, depth + 1) orelse return error.UnsupportedConstruct;
            const rhs = try constant_from_node(allocator, tree, semantic, node.data.rhs, depth + 1) orelse return error.UnsupportedConstruct;
            break :blk try fold_scalar_binary(map_binary_op(tree.tokens.items[node.main_token].tag), lhs, rhs);
        },
        .construct_expr => blk: {
            const span = sema_helpers.decode_packed_span(node.data.rhs);
            if (span.len == 1) {
                switch (semantic.types.get(semantic.nodeType(node_idx))) {
                    .scalar => {
                        const arg_node = tree.extra_data.items[span.start];
                        break :blk try constant_from_node(allocator, tree, semantic, arg_node, depth + 1);
                    },
                    else => {},
                }
            }
            var values = try allocator.alloc(ir.ConstantValue, span.len);
            var initialized: usize = 0;
            errdefer {
                for (values[0..initialized]) |*value| value.deinit(allocator);
                allocator.free(values);
            }
            while (initialized < span.len) : (initialized += 1) {
                const arg_node = tree.extra_data.items[span.start + initialized];
                values[initialized] = try constant_from_node(allocator, tree, semantic, arg_node, depth + 1) orelse return error.UnsupportedConstruct;
            }
            break :blk ir.ConstantValue{ .composite = values };
        },
        else => null,
    };
}

fn fold_scalar_binary(op: ir.BinaryOp, lhs: ir.ConstantValue, rhs: ir.ConstantValue) BuildError!ir.ConstantValue {
    return ir_const_eval.fold_scalar_binary(op, lhs, rhs) catch error.UnsupportedConstruct;
}

fn captureFailureNode(tree: *const Ast, node_idx: u32) void {
    if (node_idx == NULL_NODE or node_idx >= tree.nodes.items.len) return;
    const node = tree.nodes.items[node_idx];
    last_failure_context = .{
        .node_idx = node_idx,
        .token_idx = if (node.main_token < tree.tokens.items.len) node.main_token else null,
    };
}
