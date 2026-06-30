const std = @import("std");
const ir = @import("ir.zig");
const sema_helpers = @import("sema_helpers.zig");
const spirv = @import("spirv_builder.zig");
const emit_spirv_shared = @import("emit_spirv_shared.zig");
const emit_spirv_builtins = @import("emit_spirv_builtins.zig");
const emit_spirv_fn_helpers = @import("emit_spirv_fn_helpers.zig");
const emit_spirv_matrix = @import("emit_spirv_matrix.zig");

const EmitError = emit_spirv_shared.EmitError;
const AccessChainEntry = emit_spirv_fn_helpers.AccessChainEntry;
const LoadCacheEntry = emit_spirv_fn_helpers.LoadCacheEntry;
const ResultInstEntry = emit_spirv_fn_helpers.ResultInstEntry;
const ScalarKind = emit_spirv_fn_helpers.ScalarKind;
const appendResultInstEntry = emit_spirv_fn_helpers.appendResultInstEntry;
const cacheableResultOpcode = emit_spirv_fn_helpers.cacheableResultOpcode;
const clearResultInstEntries = emit_spirv_fn_helpers.clearResultInstEntries;
const findResultInstEntry = emit_spirv_fn_helpers.findResultInstEntry;
const scalar_construct_kind = emit_spirv_fn_helpers.scalar_construct_kind;
const assign_op_to_binary = emit_spirv_fn_helpers.assign_op_to_binary;
const param_is_assigned = emit_spirv_fn_helpers.param_is_assigned;
const ref_chain_roots_at_local = emit_spirv_fn_helpers.ref_chain_roots_at_local;
const removeLoadCacheEntry = emit_spirv_fn_helpers.removeLoadCacheEntry;

pub fn FunctionState(comptime EmitterT: type) type {
    return struct {
        emitter: *EmitterT,
        function: *const ir.Function,
        param_ptr_ids: []u32,
        param_value_ids: []u32,
        local_ptr_ids: []u32,
        local_value_ids: []u32,
        access_chain_cache: std.ArrayListUnmanaged(AccessChainEntry) = .{},
        load_cache: std.ArrayListUnmanaged(LoadCacheEntry) = .{},
        result_inst_cache: std.ArrayListUnmanaged(ResultInstEntry) = .{},
        break_targets: std.ArrayListUnmanaged(u32) = .{},
        continue_targets: std.ArrayListUnmanaged(u32) = .{},

        pub fn init(emitter: *EmitterT, function_index: ir.FunctionId) EmitError!@This() {
            const function = &emitter.module.functions.items[function_index];
            const param_ptr_ids = try emitter.alloc.alloc(u32, function.params.items.len);
            errdefer emitter.alloc.free(param_ptr_ids);
            @memset(param_ptr_ids, 0);
            const param_value_ids = try emitter.alloc.alloc(u32, function.params.items.len);
            errdefer emitter.alloc.free(param_value_ids);
            @memset(param_value_ids, 0);
            const local_ptr_ids = try emitter.alloc.alloc(u32, function.locals.items.len);
            errdefer emitter.alloc.free(local_ptr_ids);
            @memset(local_ptr_ids, 0);
            const local_value_ids = try emitter.alloc.alloc(u32, function.locals.items.len);
            errdefer emitter.alloc.free(local_value_ids);
            @memset(local_value_ids, 0);
            return .{
                .emitter = emitter,
                .function = function,
                .param_ptr_ids = param_ptr_ids,
                .param_value_ids = param_value_ids,
                .local_ptr_ids = local_ptr_ids,
                .local_value_ids = local_value_ids,
            };
        }

        pub fn deinit(self: *@This()) void {
            for (self.access_chain_cache.items) |entry| self.emitter.alloc.free(entry.indices);
            self.access_chain_cache.deinit(self.emitter.alloc);
            self.load_cache.deinit(self.emitter.alloc);
            clearResultInstEntries(self.emitter.alloc, &self.result_inst_cache);
            self.result_inst_cache.deinit(self.emitter.alloc);
            self.break_targets.deinit(self.emitter.alloc);
            self.continue_targets.deinit(self.emitter.alloc);
            self.emitter.alloc.free(self.local_value_ids);
            self.emitter.alloc.free(self.local_ptr_ids);
            self.emitter.alloc.free(self.param_value_ids);
            self.emitter.alloc.free(self.param_ptr_ids);
        }

        pub fn is_ssa_promotable_local(self: *@This(), local_index: u32) bool {
            const local = self.function.locals.items[local_index];
            if (local.mutable) return false;
            return switch (self.emitter.module.types.get(local.ty)) {
                .scalar => |s| s != .void,
                .vector => true,
                else => false,
            };
        }

        pub fn is_ssa_promotable_param(self: *@This(), param_index: u32) bool {
            const param = self.function.params.items[param_index];
            const type_ok = switch (self.emitter.module.types.get(param.ty)) {
                .scalar => |s| s != .void,
                .vector => true,
                else => false,
            };
            if (!type_ok) return false;
            return !param_is_assigned(self.function, param_index);
        }

        pub fn emit_stmt(self: *@This(), stmt_id: ir.StmtId) EmitError!bool {
            const stmt = self.function.stmts.items[stmt_id];
            switch (stmt) {
                .block => |range| {
                    var i: u32 = 0;
                    while (i < range.len) : (i += 1) {
                        if (try self.emit_stmt(self.function.stmt_children.items[range.start + i])) return true;
                    }
                    return false;
                },
                .local_decl => |decl| {
                    if (decl.initializer) |expr_id| {
                        const value_id = try self.emit_value_expr(expr_id);
                        if (self.local_ptr_ids[decl.local] != 0) {
                            try self.emitter.emit_store(self.local_ptr_ids[decl.local], value_id);
                            removeLoadCacheEntry(&self.load_cache, .local, decl.local);
                        } else {
                            self.local_value_ids[decl.local] = value_id;
                        }
                    }
                    return false;
                },
                .expr => |expr_id| {
                    const data = self.function.exprs.items[expr_id].data;
                    if (data == .global_ref or data == .local_ref or data == .param_ref) return false;
                    _ = try self.emit_value_expr(expr_id);
                    return false;
                },
                .assign => |assign| {
                    const ptr_id = try self.emit_ref_expr(assign.lhs);
                    var value_id = try self.emit_value_expr(assign.rhs);
                    if (assign.op != .assign) {
                        const current = try self.emit_load_from_ref(assign.lhs);
                        value_id = try self.emit_binary(
                            assign_op_to_binary(assign.op),
                            current,
                            value_id,
                            self.function.exprs.items[assign.lhs].ty,
                            self.function.exprs.items[assign.rhs].ty,
                            self.function.exprs.items[assign.lhs].ty,
                            self.function.exprs.items[assign.lhs].ty,
                        );
                    }
                    try self.emitter.emit_store(ptr_id, value_id);
                    if (ref_chain_roots_at_local(self.function, assign.lhs)) |local_index| {
                        removeLoadCacheEntry(&self.load_cache, .local, local_index);
                    }
                    return false;
                },
                .return_ => |value| {
                    if (value) |expr_id| {
                        try self.emitter.builder.append_function_inst(spirv.Opcode.ReturnValue, &.{try self.emit_value_expr(expr_id)});
                    } else {
                        try self.emitter.builder.append_function_inst(spirv.Opcode.Return, &.{});
                    }
                    return true;
                },
                .if_ => |if_stmt| {
                    const cond_id = try self.emit_value_expr(if_stmt.cond);
                    const then_label = self.emitter.builder.reserve_id();
                    const else_label = if (if_stmt.else_block != null) self.emitter.builder.reserve_id() else 0;
                    const merge_label = self.emitter.builder.reserve_id();
                    try self.emitter.builder.append_function_inst(spirv.Opcode.SelectionMerge, &.{ merge_label, spirv.SelectionControl.None });
                    try self.emitter.builder.append_function_inst(
                        spirv.Opcode.BranchConditional,
                        &.{ cond_id, then_label, if (else_label != 0) else_label else merge_label },
                    );

                    try self.emit_label(then_label);
                    const then_terminated = try self.emit_stmt(if_stmt.then_block);
                    if (!then_terminated) try self.emitter.builder.append_function_inst(spirv.Opcode.Branch, &.{merge_label});

                    var both_branches_terminated = false;
                    if (if_stmt.else_block) |else_block| {
                        try self.emit_label(else_label);
                        const else_terminated = try self.emit_stmt(else_block);
                        if (!else_terminated) try self.emitter.builder.append_function_inst(spirv.Opcode.Branch, &.{merge_label});
                        both_branches_terminated = then_terminated and else_terminated;
                    }

                    try self.emit_label(merge_label);
                    if (both_branches_terminated) {
                        // Both arms ended with a terminator (return/break/
                        // continue) so no control-flow edge reaches
                        // merge_label. SPIR-V requires every labeled block
                        // to have a terminator; emit OpUnreachable as the
                        // no-predecessor block's terminator and signal the
                        // caller that the enclosing statement is terminated
                        // (the .block handler then stops emitting subsequent
                        // statements, which are dead code).
                        try self.emitter.builder.append_function_inst(spirv.Opcode.Unreachable, &.{});
                        return true;
                    }
                    return false;
                },
                .loop_ => |loop_stmt| {
                    if (loop_stmt.init) |init_stmt| _ = try self.emit_stmt(init_stmt);

                    const header_label = self.emitter.builder.reserve_id();
                    const body_label = self.emitter.builder.reserve_id();
                    const continue_label = self.emitter.builder.reserve_id();
                    const merge_label = self.emitter.builder.reserve_id();

                    try self.emitter.builder.append_function_inst(spirv.Opcode.Branch, &.{header_label});
                    try self.emit_label(header_label);
                    if (loop_stmt.cond) |cond| {
                        const cond_id = try self.emit_value_expr(cond);
                        try self.emitter.builder.append_function_inst(spirv.Opcode.LoopMerge, &.{ merge_label, continue_label, spirv.LoopControl.None });
                        try self.emitter.builder.append_function_inst(
                            spirv.Opcode.BranchConditional,
                            &.{ cond_id, body_label, merge_label },
                        );
                    } else {
                        try self.emitter.builder.append_function_inst(spirv.Opcode.LoopMerge, &.{ merge_label, continue_label, spirv.LoopControl.None });
                        try self.emitter.builder.append_function_inst(spirv.Opcode.Branch, &.{body_label});
                    }

                    try self.break_targets.append(self.emitter.alloc, merge_label);
                    try self.continue_targets.append(self.emitter.alloc, continue_label);

                    try self.emit_label(body_label);
                    const body_terminated = try self.emit_stmt(loop_stmt.body);
                    if (!body_terminated) try self.emitter.builder.append_function_inst(spirv.Opcode.Branch, &.{continue_label});

                    try self.emit_label(continue_label);
                    const continuing_terminated = if (loop_stmt.continuing) |cont| try self.emit_stmt(cont) else false;
                    if (!continuing_terminated) try self.emitter.builder.append_function_inst(spirv.Opcode.Branch, &.{header_label});

                    _ = self.break_targets.pop();
                    _ = self.continue_targets.pop();

                    try self.emit_label(merge_label);
                    return false;
                },
                .switch_ => |switch_stmt| {
                    const selector_id = try self.emit_value_expr(switch_stmt.expr);
                    const merge_label = self.emitter.builder.reserve_id();
                    var labels = try self.emitter.alloc.alloc(u32, switch_stmt.cases.len);
                    defer self.emitter.alloc.free(labels);
                    @memset(labels, 0);

                    var default_label = merge_label;
                    var case_index: u32 = 0;
                    while (case_index < switch_stmt.cases.len) : (case_index += 1) {
                        const case_node = self.function.switch_cases.items[switch_stmt.cases.start + case_index];
                        labels[case_index] = self.emitter.builder.reserve_id();
                        if (case_node.is_default) default_label = labels[case_index];
                    }

                    var operands = std.ArrayListUnmanaged(u32){};
                    defer operands.deinit(self.emitter.alloc);
                    try operands.append(self.emitter.alloc, selector_id);
                    try operands.append(self.emitter.alloc, default_label);
                    case_index = 0;
                    while (case_index < switch_stmt.cases.len) : (case_index += 1) {
                        const case_node = self.function.switch_cases.items[switch_stmt.cases.start + case_index];
                        if (case_node.is_default) continue;
                        for (case_node.selectors.items) |selector_expr| {
                            try operands.append(self.emitter.alloc, try self.switch_selector_literal(selector_expr));
                            try operands.append(self.emitter.alloc, labels[case_index]);
                        }
                    }

                    try self.emitter.builder.append_function_inst(spirv.Opcode.SelectionMerge, &.{ merge_label, spirv.SelectionControl.None });
                    try self.emitter.builder.append_function_inst(spirv.Opcode.Switch, operands.items);

                    try self.break_targets.append(self.emitter.alloc, merge_label);
                    case_index = 0;
                    while (case_index < switch_stmt.cases.len) : (case_index += 1) {
                        const case_node = self.function.switch_cases.items[switch_stmt.cases.start + case_index];
                        try self.emit_label(labels[case_index]);
                        const terminated = try self.emit_stmt(case_node.body);
                        if (!terminated) try self.emitter.builder.append_function_inst(spirv.Opcode.Branch, &.{merge_label});
                    }
                    _ = self.break_targets.pop();

                    try self.emit_label(merge_label);
                    return false;
                },
                .break_ => {
                    if (self.break_targets.items.len == 0) return error.InvalidIr;
                    try self.emitter.builder.append_function_inst(spirv.Opcode.Branch, &.{self.break_targets.items[self.break_targets.items.len - 1]});
                    return true;
                },
                .continue_ => {
                    if (self.continue_targets.items.len == 0) return error.InvalidIr;
                    try self.emitter.builder.append_function_inst(spirv.Opcode.Branch, &.{self.continue_targets.items[self.continue_targets.items.len - 1]});
                    return true;
                },
                .discard_ => {
                    try self.emitter.builder.append_function_inst(spirv.Opcode.Kill, &.{});
                    return true;
                },
            }
        }

        fn emit_label(self: *@This(), label_id: u32) EmitError!void {
            try self.emitter.builder.append_function_inst(spirv.Opcode.Label, &.{label_id});
            // Cached ids may not dominate a new block; keep CSE straight-line.
            self.clearStraightLineCaches();
        }

        fn clearStraightLineCaches(self: *@This()) void {
            for (self.access_chain_cache.items) |entry| self.emitter.alloc.free(entry.indices);
            self.access_chain_cache.clearRetainingCapacity();
            self.load_cache.clearRetainingCapacity();
            clearResultInstEntries(self.emitter.alloc, &self.result_inst_cache);
        }

        pub fn emit_value_expr(self: *@This(), expr_id: ir.ExprId) EmitError!u32 {
            const expr = self.function.exprs.items[expr_id];
            return switch (expr.data) {
                .bool_lit => |value| try self.emitter.builder.const_bool(value),
                .int_lit => |value| switch (self.emitter.module.types.get(expr.ty)) {
                    .scalar => |scalar| switch (scalar) {
                        .u32 => try self.emitter.builder.const_u32(@truncate(value)),
                        .i32, .abstract_int => try self.emitter.builder.const_i32_bits(@truncate(value)),
                        else => return error.InvalidIr,
                    },
                    else => return error.InvalidIr,
                },
                .float_lit => |value| switch (self.emitter.module.types.get(expr.ty)) {
                    .scalar => |scalar| switch (scalar) {
                        .f16 => try self.emitter.builder.const_f16_bits(@as(u16, @bitCast(@as(f16, @floatCast(value))))),
                        else => try self.emitter.builder.const_f32_bits(@bitCast(@as(f32, @floatCast(value)))),
                    },
                    else => try self.emitter.builder.const_f32_bits(@bitCast(@as(f32, @floatCast(value)))),
                },
                .param_ref, .local_ref => return error.InvalidIr,
                .global_ref => |index| blk: {
                    const constant_id = self.emitter.global_constant_ids[index];
                    if (constant_id != 0) break :blk constant_id;
                    const global = self.emitter.module.globals.items[index];
                    switch (self.emitter.module.types.get(global.ty)) {
                        .sampler, .sampler_comparison, .texture_1d, .texture_2d, .texture_2d_array, .texture_cube, .texture_multisampled_2d, .texture_depth_2d, .texture_depth_cube, .texture_3d, .storage_texture_2d => {
                            break :blk try self.emitter.emit_function_load(
                                try self.emitter.lower_type(expr.ty),
                                self.emitter.global_ids[index],
                            );
                        },
                        else => if (global.class == .var_ and (global.addr_space orelse .private) == .private)
                            break :blk try self.emit_load_from_ref(expr_id)
                        else
                            return error.InvalidIr,
                    }
                },
                .load => |inner| try self.emit_load_from_ref(inner),
                .unary => |unary| try self.emit_unary(unary.op, try self.emit_value_expr(unary.operand), expr.ty),
                .binary => |binary| blk: {
                    const lhs_ty = self.function.exprs.items[binary.lhs].ty;
                    const rhs_ty = self.function.exprs.items[binary.rhs].ty;
                    break :blk try self.emit_binary(
                        binary.op,
                        try self.emit_value_expr(binary.lhs),
                        try self.emit_value_expr(binary.rhs),
                        lhs_ty,
                        rhs_ty,
                        self.binary_operand_type(lhs_ty, rhs_ty),
                        expr.ty,
                    );
                },
                .call => |call| try self.emit_call(call, expr.ty),
                .construct => |construct| try self.emit_construct(construct.ty, construct.args),
                .member => |member| if (expr.category == .ref)
                    return error.InvalidIr
                else
                    try self.emit_member_value(member, expr.ty),
                .index => |index| if (expr.category == .ref)
                    return error.InvalidIr
                else
                    try self.emit_composite_extract(try self.emit_value_expr(index.base), expr.ty, try self.literal_index(index.index)),
            };
        }

        pub fn emit_ref_expr(self: *@This(), expr_id: ir.ExprId) EmitError!u32 {
            // Walk leaf-to-root collecting member/index operands, then emit a
            // single OpAccessChain with all indices. Matches Tint's shape and
            // avoids the two-chain pattern that forced driver CSE for wrapped
            // storage-buffer access like `dye_in[i]`.
            var indices = std.ArrayListUnmanaged(u32){};
            defer indices.deinit(self.emitter.alloc);
            var current = expr_id;
            while (true) {
                const node = self.function.exprs.items[current];
                switch (node.data) {
                    .member => |m| {
                        try indices.append(self.emitter.alloc, try self.emitter.builder.const_u32(m.field_index));
                        current = m.base;
                    },
                    .index => |idx| {
                        try indices.append(self.emitter.alloc, try self.emit_value_expr(idx.index));
                        current = idx.base;
                    },
                    .param_ref, .local_ref, .global_ref => break,
                    else => return error.InvalidIr,
                }
            }
            const root_node = self.function.exprs.items[current];
            const root_id: u32 = switch (root_node.data) {
                .param_ref => |index| self.param_ptr_ids[index],
                .local_ref => |index| self.local_ptr_ids[index],
                .global_ref => |index| blk: {
                    if (self.emitter.global_buffer_wrapped[index]) {
                        try indices.append(self.emitter.alloc, try self.emitter.builder.const_u32(0));
                    }
                    break :blk self.emitter.global_ids[index];
                },
                else => return error.InvalidIr,
            };
            if (indices.items.len == 0) return root_id;
            // Reverse indices into root-first order.
            std.mem.reverse(u32, indices.items);
            const leaf_expr = self.function.exprs.items[expr_id];
            const ptr_type = try self.emitter.builder.type_pointer(
                try self.ref_storage_class(expr_id),
                try self.emitter.lower_type(leaf_expr.ty),
            );
            for (self.access_chain_cache.items) |entry| {
                if (entry.root_id != root_id) continue;
                if (entry.ptr_type != ptr_type) continue;
                if (entry.indices.len != indices.items.len) continue;
                if (std.mem.eql(u32, entry.indices, indices.items)) return entry.result_id;
            }
            const result_id = self.emitter.builder.reserve_id();
            var operands = std.ArrayListUnmanaged(u32){};
            defer operands.deinit(self.emitter.alloc);
            try operands.append(self.emitter.alloc, ptr_type);
            try operands.append(self.emitter.alloc, result_id);
            try operands.append(self.emitter.alloc, root_id);
            try operands.appendSlice(self.emitter.alloc, indices.items);
            try self.emitter.builder.append_function_inst(spirv.Opcode.AccessChain, operands.items);
            const cached_indices = try self.emitter.alloc.dupe(u32, indices.items);
            errdefer self.emitter.alloc.free(cached_indices);
            try self.access_chain_cache.append(self.emitter.alloc, .{
                .root_id = root_id,
                .ptr_type = ptr_type,
                .result_id = result_id,
                .indices = cached_indices,
            });
            return result_id;
        }

        fn emit_load_from_ref(self: *@This(), ref_expr_id: ir.ExprId) EmitError!u32 {
            const ref_expr = self.function.exprs.items[ref_expr_id];
            // WGSL const globals are emitted as constants, not storage.
            if (ref_expr.data == .global_ref) {
                const index = ref_expr.data.global_ref;
                const constant_id = self.emitter.global_constant_ids[index];
                if (constant_id != 0) return constant_id;
            }
            if (ref_expr.data == .local_ref) {
                const index = ref_expr.data.local_ref;
                const value_id = self.local_value_ids[index];
                if (value_id != 0) return value_id;
            }
            if (ref_expr.data == .param_ref) {
                const index = ref_expr.data.param_ref;
                const value_id = self.param_value_ids[index];
                if (value_id != 0) return value_id;
            }
            // Promoted vector swizzles extract from cached SSA composites.
            if (ref_expr.data == .member) {
                const member = ref_expr.data.member;
                const base = self.function.exprs.items[member.base];
                if (self.try_ssa_composite_id(base)) |composite_id| {
                    return try self.emit_swizzle_from_ssa(composite_id, base.ty, member, ref_expr.ty);
                }
            }
            // Promoted vector dynamic indexes extract from cached SSA composites.
            if (ref_expr.data == .index) {
                const index_node = ref_expr.data.index;
                const base = self.function.exprs.items[index_node.base];
                if (self.try_ssa_composite_id(base)) |composite_id| {
                    const index_id = try self.emit_value_expr(index_node.index);
                    return try self.emit_result_inst(
                        spirv.Opcode.VectorExtractDynamic,
                        try self.emitter.lower_type(ref_expr.ty),
                        &.{ composite_id, index_id },
                    );
                }
            }
            if (ref_expr.data == .local_ref) {
                const index = ref_expr.data.local_ref;
                if (self.local_ptr_ids[index] != 0) {
                    for (self.load_cache.items) |entry| {
                        if (entry.root == .local and entry.index == index) return entry.value_id;
                    }
                    const value_id = try self.emitter.emit_function_load(try self.emitter.lower_type(ref_expr.ty), self.local_ptr_ids[index]);
                    try self.load_cache.append(self.emitter.alloc, .{
                        .root = .local,
                        .index = index,
                        .value_id = value_id,
                    });
                    return value_id;
                }
            }
            return try self.emitter.emit_function_load(try self.emitter.lower_type(ref_expr.ty), try self.emit_ref_expr(ref_expr_id));
        }

        fn try_ssa_composite_id(self: *@This(), base: ir.ExprNode) ?u32 {
            switch (base.data) {
                .local_ref => |index| {
                    const id = self.local_value_ids[index];
                    return if (id != 0) id else null;
                },
                .param_ref => |index| {
                    const id = self.param_value_ids[index];
                    return if (id != 0) id else null;
                },
                else => return null,
            }
        }

        fn emit_swizzle_from_ssa(
            self: *@This(),
            composite_id: u32,
            base_ty: ir.TypeId,
            member: @FieldType(ir.Expr, "member"),
            result_ty: ir.TypeId,
        ) EmitError!u32 {
            if (member.field_name.len == 1) {
                return try self.emit_composite_extract(composite_id, result_ty, member.field_index);
            }
            const vec = switch (self.emitter.module.types.get(base_ty)) {
                .vector => |v| v,
                else => return error.InvalidIr,
            };
            const swizzle = sema_helpers.parse_vector_swizzle(member.field_name, vec.len) catch return error.InvalidIr;
            var operands = std.ArrayListUnmanaged(u32){};
            defer operands.deinit(self.emitter.alloc);
            var i: usize = 0;
            while (i < swizzle.len) : (i += 1) {
                try operands.append(self.emitter.alloc, try self.emit_composite_extract(composite_id, vec.elem, swizzle.indices[i]));
            }
            return try self.emit_construct_from_operands(result_ty, operands.items);
        }

        fn emit_member_value(self: *@This(), member: @FieldType(ir.Expr, "member"), result_ty: ir.TypeId) EmitError!u32 {
            const base_ty = self.function.exprs.items[member.base].ty;
            const vec = switch (self.emitter.module.types.get(base_ty)) {
                .vector => |vector| vector,
                else => return try self.emit_composite_extract(try self.emit_value_expr(member.base), result_ty, member.field_index),
            };
            if (member.field_name.len == 1) {
                return try self.emit_composite_extract(try self.emit_value_expr(member.base), result_ty, member.field_index);
            }
            const base_id = try self.emit_value_expr(member.base);
            const swizzle = sema_helpers.parse_vector_swizzle(member.field_name, vec.len) catch return error.InvalidIr;

            var operands = std.ArrayListUnmanaged(u32){};
            defer operands.deinit(self.emitter.alloc);
            var i: usize = 0;
            while (i < swizzle.len) : (i += 1) {
                try operands.append(self.emitter.alloc, try self.emit_composite_extract(base_id, vec.elem, swizzle.indices[i]));
            }
            return try self.emit_construct_from_operands(result_ty, operands.items);
        }

        fn emit_unary(self: *@This(), op: ir.UnaryOp, operand_id: u32, result_ty: ir.TypeId) EmitError!u32 {
            const opcode: u16 = switch (op) {
                .neg => switch (self.scalar_kind(result_ty)) {
                    .signed => spirv.Opcode.SNegate,
                    .float => spirv.Opcode.FNegate,
                    else => return error.UnsupportedConstruct,
                },
                .not => spirv.Opcode.LogicalNot,
                .bit_not => spirv.Opcode.Not,
            };
            return try self.emit_result_inst(opcode, try self.emitter.lower_type(result_ty), &.{operand_id});
        }

        /// Pick the common operand type for scalar/vector binary coercion.
        fn binary_operand_type(self: *@This(), lhs_ty: ir.TypeId, rhs_ty: ir.TypeId) ir.TypeId {
            const lhs_type = self.emitter.module.types.get(lhs_ty);
            const rhs_type = self.emitter.module.types.get(rhs_ty);
            const lhs_is_vector = switch (lhs_type) {
                .vector => true,
                else => false,
            };
            const rhs_is_vector = switch (rhs_type) {
                .vector => true,
                else => false,
            };
            if (!lhs_is_vector and rhs_is_vector) return rhs_ty;
            return lhs_ty;
        }

        fn emit_binary(
            self: *@This(),
            op: ir.BinaryOp,
            lhs_id: u32,
            rhs_id: u32,
            lhs_ty: ir.TypeId,
            rhs_ty: ir.TypeId,
            operand_ty: ir.TypeId,
            result_ty: ir.TypeId,
        ) EmitError!u32 {
            if (op == .mul) {
                if (try self.emit_matrix_multiply(lhs_id, rhs_id, lhs_ty, rhs_ty, result_ty)) |result_id| return result_id;
            }
            if (try emit_spirv_matrix.emit_matrix_elementwise(self, op, lhs_id, rhs_id, lhs_ty, rhs_ty, result_ty)) |result_id| return result_id;
            const coerced_lhs = try self.coerce_binary_operand(lhs_id, lhs_ty, operand_ty);
            const coerced_rhs = try self.coerce_binary_operand(rhs_id, rhs_ty, operand_ty);
            const opcode: u16 = switch (op) {
                .add => switch (self.scalar_kind(operand_ty)) {
                    .float => spirv.Opcode.FAdd,
                    else => spirv.Opcode.IAdd,
                },
                .sub => switch (self.scalar_kind(operand_ty)) {
                    .float => spirv.Opcode.FSub,
                    else => spirv.Opcode.ISub,
                },
                .mul => switch (self.scalar_kind(operand_ty)) {
                    .float => spirv.Opcode.FMul,
                    else => spirv.Opcode.IMul,
                },
                .div => switch (self.scalar_kind(operand_ty)) {
                    .float => spirv.Opcode.FDiv,
                    .unsigned => spirv.Opcode.UDiv,
                    .signed => spirv.Opcode.SDiv,
                    else => return error.UnsupportedConstruct,
                },
                .rem => switch (self.scalar_kind(operand_ty)) {
                    .float => spirv.Opcode.FRem,
                    .unsigned => spirv.Opcode.UMod,
                    .signed => spirv.Opcode.SRem,
                    else => return error.UnsupportedConstruct,
                },
                .bit_and => switch (self.scalar_kind(operand_ty)) {
                    .bool => spirv.Opcode.LogicalAnd,
                    else => spirv.Opcode.BitwiseAnd,
                },
                .bit_or => switch (self.scalar_kind(operand_ty)) {
                    .bool => spirv.Opcode.LogicalOr,
                    else => spirv.Opcode.BitwiseOr,
                },
                .bit_xor => switch (self.scalar_kind(operand_ty)) {
                    .bool => spirv.Opcode.LogicalNotEqual,
                    else => spirv.Opcode.BitwiseXor,
                },
                .shift_left => spirv.Opcode.ShiftLeftLogical,
                .shift_right => switch (self.scalar_kind(operand_ty)) {
                    .unsigned => spirv.Opcode.ShiftRightLogical,
                    else => spirv.Opcode.ShiftRightArithmetic,
                },
                .equal => return try self.emit_compare(op, coerced_lhs, coerced_rhs, operand_ty, result_ty),
                .not_equal => return try self.emit_compare(op, coerced_lhs, coerced_rhs, operand_ty, result_ty),
                .less => return try self.emit_compare(op, coerced_lhs, coerced_rhs, operand_ty, result_ty),
                .less_equal => return try self.emit_compare(op, coerced_lhs, coerced_rhs, operand_ty, result_ty),
                .greater => return try self.emit_compare(op, coerced_lhs, coerced_rhs, operand_ty, result_ty),
                .greater_equal => return try self.emit_compare(op, coerced_lhs, coerced_rhs, operand_ty, result_ty),
                .logical_and => spirv.Opcode.LogicalAnd,
                .logical_or => spirv.Opcode.LogicalOr,
            };
            return try self.emit_result_inst(opcode, try self.emitter.lower_type(result_ty), &.{ coerced_lhs, coerced_rhs });
        }

        fn emit_matrix_multiply(
            self: *@This(),
            lhs_id: u32,
            rhs_id: u32,
            lhs_ty: ir.TypeId,
            rhs_ty: ir.TypeId,
            result_ty: ir.TypeId,
        ) EmitError!?u32 {
            const lhs_type = self.emitter.module.types.get(lhs_ty);
            const rhs_type = self.emitter.module.types.get(rhs_ty);
            const result_type = try self.emitter.lower_type(result_ty);

            switch (lhs_type) {
                .scalar => switch (rhs_type) {
                    .matrix => |rhs_mat| {
                        const scalar_id = try self.emit_scalar_construct_from_type(rhs_mat.elem, lhs_ty, lhs_id);
                        return try self.emit_result_inst(spirv.Opcode.MatrixTimesScalar, result_type, &.{ rhs_id, scalar_id });
                    },
                    else => {},
                },
                .vector => switch (rhs_type) {
                    .matrix => return try self.emit_result_inst(spirv.Opcode.VectorTimesMatrix, result_type, &.{ lhs_id, rhs_id }),
                    else => {},
                },
                .matrix => |lhs_mat| switch (rhs_type) {
                    .scalar => {
                        const scalar_id = try self.emit_scalar_construct_from_type(lhs_mat.elem, rhs_ty, rhs_id);
                        return try self.emit_result_inst(spirv.Opcode.MatrixTimesScalar, result_type, &.{ lhs_id, scalar_id });
                    },
                    .vector => return try self.emit_result_inst(spirv.Opcode.MatrixTimesVector, result_type, &.{ lhs_id, rhs_id }),
                    .matrix => return try self.emit_result_inst(spirv.Opcode.MatrixTimesMatrix, result_type, &.{ lhs_id, rhs_id }),
                    else => {},
                },
                else => {},
            }

            return null;
        }

        fn emit_compare(self: *@This(), op: ir.BinaryOp, lhs_id: u32, rhs_id: u32, operand_ty: ir.TypeId, result_ty: ir.TypeId) EmitError!u32 {
            const opcode: u16 = switch (self.scalar_kind(operand_ty)) {
                .bool => switch (op) {
                    .equal => spirv.Opcode.LogicalEqual,
                    .not_equal => spirv.Opcode.LogicalNotEqual,
                    else => return error.UnsupportedConstruct,
                },
                .unsigned => switch (op) {
                    .equal => spirv.Opcode.IEqual,
                    .not_equal => spirv.Opcode.INotEqual,
                    .less => spirv.Opcode.ULessThan,
                    .less_equal => spirv.Opcode.ULessThanEqual,
                    .greater => spirv.Opcode.UGreaterThan,
                    .greater_equal => spirv.Opcode.UGreaterThanEqual,
                    else => return error.UnsupportedConstruct,
                },
                .signed => switch (op) {
                    .equal => spirv.Opcode.IEqual,
                    .not_equal => spirv.Opcode.INotEqual,
                    .less => spirv.Opcode.SLessThan,
                    .less_equal => spirv.Opcode.SLessThanEqual,
                    .greater => spirv.Opcode.SGreaterThan,
                    .greater_equal => spirv.Opcode.SGreaterThanEqual,
                    else => return error.UnsupportedConstruct,
                },
                .float => switch (op) {
                    .equal => spirv.Opcode.FOrdEqual,
                    .not_equal => spirv.Opcode.FOrdNotEqual,
                    .less => spirv.Opcode.FOrdLessThan,
                    .less_equal => spirv.Opcode.FOrdLessThanEqual,
                    .greater => spirv.Opcode.FOrdGreaterThan,
                    .greater_equal => spirv.Opcode.FOrdGreaterThanEqual,
                    else => return error.UnsupportedConstruct,
                },
            };
            return try self.emit_result_inst(opcode, try self.emitter.lower_type(result_ty), &.{ lhs_id, rhs_id });
        }

        fn emit_call(self: *@This(), call: anytype, result_ty: ir.TypeId) EmitError!u32 {
            if (call.kind == .builtin) return try self.emit_builtin_call(call, result_ty);
            const fn_id = self.emitter.function_id_by_name(call.name) orelse return error.InvalidIr;
            var args = std.ArrayListUnmanaged(u32){};
            defer args.deinit(self.emitter.alloc);
            var i: u32 = 0;
            while (i < call.args.len) : (i += 1) {
                const arg_expr_id = self.function.expr_args.items[call.args.start + i];
                const arg_expr = self.function.exprs.items[arg_expr_id];
                if (arg_expr.category == .ref) {
                    // Pointer arg: pass the pointer, not the loaded value.
                    try args.append(self.emitter.alloc, try self.emit_ref_expr(arg_expr_id));
                } else {
                    try args.append(self.emitter.alloc, try self.emit_value_expr(arg_expr_id));
                }
            }
            const result_id = try self.emitter.emit_function_call(try self.emitter.lower_type(result_ty), fn_id, args.items);
            self.load_cache.clearRetainingCapacity();
            return result_id;
        }

        fn emit_builtin_call(self: *@This(), call: anytype, result_ty: ir.TypeId) EmitError!u32 {
            return (try emit_spirv_builtins.emit_builtin(self, call, result_ty)) orelse return error.UnsupportedConstruct;
        }

        fn emit_construct(self: *@This(), ty: ir.TypeId, range: ir.Range) EmitError!u32 {
            if (range.len == 0) return try emit_spirv_fn_helpers.emitZeroValue(self, ty);
            switch (self.emitter.module.types.get(ty)) {
                .scalar => {
                    if (range.len != 1) return error.UnsupportedConstruct;
                    const expr_id = self.function.expr_args.items[range.start];
                    return try self.emit_scalar_construct(ty, expr_id, try self.emit_value_expr(expr_id));
                },
                .vector => return try self.emit_vector_construct(ty, range),
                else => {},
            }

            var operands = std.ArrayListUnmanaged(u32){};
            defer operands.deinit(self.emitter.alloc);
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                try operands.append(self.emitter.alloc, try self.emit_value_expr(self.function.expr_args.items[range.start + i]));
            }
            return try self.emit_construct_from_operands(ty, operands.items);
        }

        pub fn emit_construct_from_operands(self: *@This(), ty: ir.TypeId, operands: []const u32) EmitError!u32 {
            var full = std.ArrayListUnmanaged(u32){};
            defer full.deinit(self.emitter.alloc);
            const result_ty = try self.emitter.lower_type(ty);
            const result_id = self.emitter.builder.reserve_id();
            try full.append(self.emitter.alloc, result_ty);
            try full.append(self.emitter.alloc, result_id);
            try full.appendSlice(self.emitter.alloc, operands);
            try self.emitter.builder.append_function_inst(spirv.Opcode.CompositeConstruct, full.items);
            return result_id;
        }

        fn emit_scalar_construct(self: *@This(), target_ty: ir.TypeId, source_expr_id: ir.ExprId, source_id: u32) EmitError!u32 {
            return try self.emit_scalar_construct_from_type(target_ty, self.function.exprs.items[source_expr_id].ty, source_id);
        }

        fn coerce_binary_operand(self: *@This(), value_id: u32, source_ty: ir.TypeId, target_ty: ir.TypeId) EmitError!u32 {
            if (source_ty == target_ty or try self.emitter.lower_type(source_ty) == try self.emitter.lower_type(target_ty)) {
                return value_id;
            }

            switch (self.emitter.module.types.get(target_ty)) {
                .scalar => return try self.emit_scalar_construct_from_type(target_ty, source_ty, value_id),
                .vector => |target_vec| switch (self.emitter.module.types.get(source_ty)) {
                    .scalar => {
                        const scalar_id = try self.emit_scalar_construct_from_type(target_vec.elem, source_ty, value_id);
                        var components = std.ArrayListUnmanaged(u32){};
                        defer components.deinit(self.emitter.alloc);
                        var component_index: u32 = 0;
                        while (component_index < target_vec.len) : (component_index += 1) {
                            try components.append(self.emitter.alloc, scalar_id);
                        }
                        return try self.emit_construct_from_operands(target_ty, components.items);
                    },
                    .vector => |source_vec| {
                        if (source_vec.len != target_vec.len) return error.UnsupportedConstruct;
                        var components = std.ArrayListUnmanaged(u32){};
                        defer components.deinit(self.emitter.alloc);
                        var component_index: u32 = 0;
                        while (component_index < source_vec.len) : (component_index += 1) {
                            const component_id = try self.emit_composite_extract(value_id, source_vec.elem, component_index);
                            try components.append(
                                self.emitter.alloc,
                                try self.emit_scalar_construct_from_type(target_vec.elem, source_vec.elem, component_id),
                            );
                        }
                        return try self.emit_construct_from_operands(target_ty, components.items);
                    },
                    else => return error.UnsupportedConstruct,
                },
                else => return error.UnsupportedConstruct,
            }
        }

        fn emit_scalar_construct_from_type(self: *@This(), target_ty: ir.TypeId, source_ty: ir.TypeId, source_id: u32) EmitError!u32 {
            const target_type = self.emitter.module.types.get(target_ty);
            const source_type = self.emitter.module.types.get(source_ty);
            if (target_ty == source_ty or try self.emitter.lower_type(target_ty) == try self.emitter.lower_type(source_ty)) {
                return source_id;
            }

            const target_scalar = switch (target_type) {
                .scalar => |scalar| scalar,
                else => return error.UnsupportedConstruct,
            };
            const source_scalar = switch (source_type) {
                .scalar => |scalar| scalar,
                else => return error.UnsupportedConstruct,
            };

            const opcode: u16 = switch (scalar_construct_kind(target_scalar)) {
                .bool => return error.UnsupportedConstruct,
                .signed => switch (scalar_construct_kind(source_scalar)) {
                    .signed => return source_id,
                    .unsigned => spirv.Opcode.Bitcast,
                    .float => spirv.Opcode.ConvertFToS,
                    .bool => return error.UnsupportedConstruct,
                },
                .unsigned => switch (scalar_construct_kind(source_scalar)) {
                    .signed => spirv.Opcode.Bitcast,
                    .unsigned => return source_id,
                    .float => spirv.Opcode.ConvertFToU,
                    .bool => return error.UnsupportedConstruct,
                },
                .float => switch (scalar_construct_kind(source_scalar)) {
                    .signed => spirv.Opcode.ConvertSToF,
                    .unsigned => spirv.Opcode.ConvertUToF,
                    .float => spirv.Opcode.FConvert,
                    .bool => return error.UnsupportedConstruct,
                },
            };
            return try self.emit_result_inst(opcode, try self.emitter.lower_type(target_ty), &.{source_id});
        }

        fn emit_vector_construct(self: *@This(), target_ty: ir.TypeId, range: ir.Range) EmitError!u32 {
            const target_vec = switch (self.emitter.module.types.get(target_ty)) {
                .vector => |vec| vec,
                else => return error.UnsupportedConstruct,
            };
            if (range.len == 1) {
                const only_expr_id = self.function.expr_args.items[range.start];
                if (self.function.exprs.items[only_expr_id].ty == target_ty) {
                    return try self.emit_value_expr(only_expr_id);
                }
            }

            var components = std.ArrayListUnmanaged(u32){};
            defer components.deinit(self.emitter.alloc);

            var arg_index: u32 = 0;
            while (arg_index < range.len) : (arg_index += 1) {
                const expr_id = self.function.expr_args.items[range.start + arg_index];
                const expr_ty = self.function.exprs.items[expr_id].ty;
                switch (self.emitter.module.types.get(expr_ty)) {
                    .scalar => {
                        const scalar_id = try self.emit_scalar_construct(target_vec.elem, expr_id, try self.emit_value_expr(expr_id));
                        try components.append(self.emitter.alloc, scalar_id);
                    },
                    .vector => |source_vec| {
                        const vector_id = try self.emit_value_expr(expr_id);
                        var component_index: u32 = 0;
                        while (component_index < source_vec.len) : (component_index += 1) {
                            const component_id = try self.emit_composite_extract(vector_id, source_vec.elem, component_index);
                            try components.append(self.emitter.alloc, try self.emit_scalar_construct_from_type(target_vec.elem, source_vec.elem, component_id));
                        }
                    },
                    else => return error.UnsupportedConstruct,
                }
            }

            if (components.items.len == 1 and target_vec.len > 1) {
                const splat_id = components.items[0];
                while (components.items.len < target_vec.len) {
                    try components.append(self.emitter.alloc, splat_id);
                }
            }
            if (components.items.len != target_vec.len) return error.UnsupportedConstruct;
            return try self.emit_construct_from_operands(target_ty, components.items);
        }

        pub fn emit_composite_extract(self: *@This(), composite_id: u32, result_ty: ir.TypeId, index: u32) EmitError!u32 {
            return try self.emit_result_inst(spirv.Opcode.CompositeExtract, try self.emitter.lower_type(result_ty), &.{ composite_id, index });
        }

        pub fn emit_result_inst(self: *@This(), opcode: u16, result_type: u32, operands: []const u32) EmitError!u32 {
            const cacheable = cacheableResultOpcode(opcode);
            if (cacheable) {
                if (findResultInstEntry(self.result_inst_cache.items, opcode, result_type, operands)) |cached| return cached;
            }
            var full = std.ArrayListUnmanaged(u32){};
            defer full.deinit(self.emitter.alloc);
            const result_id = self.emitter.builder.reserve_id();
            try full.append(self.emitter.alloc, result_type);
            try full.append(self.emitter.alloc, result_id);
            try full.appendSlice(self.emitter.alloc, operands);
            try self.emitter.builder.append_function_inst(opcode, full.items);
            if (cacheable) try appendResultInstEntry(self.emitter.alloc, &self.result_inst_cache, opcode, result_type, result_id, operands);
            return result_id;
        }

        pub fn ref_storage_class(self: *@This(), expr_id: ir.ExprId) EmitError!u32 {
            const expr = self.function.exprs.items[expr_id];
            return switch (expr.data) {
                .param_ref => |index| switch (self.emitter.module.types.get(self.function.params.items[index].ty)) {
                    .ref => |ref_ty| emit_spirv_shared.addr_space_to_storage_class(ref_ty.addr_space),
                    else => spirv.StorageClass.Function,
                },
                .local_ref => spirv.StorageClass.Function,
                .global_ref => |index| try self.emitter.global_storage_class(self.emitter.module.globals.items[index]),
                .member => |member| try self.ref_storage_class(member.base),
                .index => |index| try self.ref_storage_class(index.base),
                else => error.InvalidIr,
            };
        }

        fn literal_index(self: *@This(), expr_id: ir.ExprId) EmitError!u32 {
            const expr = self.function.exprs.items[expr_id];
            return switch (expr.data) {
                .int_lit => |value| @truncate(value),
                else => error.UnsupportedConstruct,
            };
        }

        fn switch_selector_literal(self: *@This(), expr_id: ir.ExprId) EmitError!u32 {
            const expr = self.function.exprs.items[expr_id];
            return switch (expr.data) {
                .int_lit => |value| @truncate(value),
                .bool_lit => |value| if (value) 1 else 0,
                .unary => |unary| if (unary.op == .neg) blk: {
                    const inner = self.function.exprs.items[unary.operand];
                    switch (inner.data) {
                        .int_lit => |value| break :blk @as(u32, @bitCast(-@as(i32, @intCast(value)))),
                        else => return error.UnsupportedConstruct,
                    }
                } else error.UnsupportedConstruct,
                else => error.UnsupportedConstruct,
            };
        }

        pub fn scalar_kind(self: *@This(), ty: ir.TypeId) ScalarKind {
            return switch (self.emitter.module.types.get(ty)) {
                .scalar => |scalar| switch (scalar) {
                    .bool => .bool,
                    .u32 => .unsigned,
                    .f16, .f32, .abstract_float => .float,
                    else => .signed,
                },
                .vector => |vec| switch (self.emitter.module.types.get(vec.elem)) {
                    .scalar => |scalar| switch (scalar) {
                        .bool => .bool,
                        .u32 => .unsigned,
                        .f16, .f32, .abstract_float => .float,
                        else => .signed,
                    },
                    else => .signed,
                },
                else => .signed,
            };
        }
    };
}
