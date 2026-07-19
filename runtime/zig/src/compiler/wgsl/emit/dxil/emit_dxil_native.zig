// Native DXIL emitter: translates Doe IR to DXIL bytecode without external
// DXC dependency. Builds LLVM 3.7 bitcode using dxil_builder, serializes
// via dxil_serialize, and wraps in a DXBC container via dxil_container.

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const spec = @import("dxil_spec.zig");
const builder_mod = @import("dxil_builder.zig");
const serialize_mod = @import("dxil_serialize.zig");
const container = @import("dxil_container.zig");

pub const EmitError = spec.EmitError;

const Builder = builder_mod.Builder;
const FunctionBody = builder_mod.FunctionBody;
const TypeIndex = builder_mod.TypeIndex;
const ValueIndex = builder_mod.ValueIndex;
const MdIndex = builder_mod.MdIndex;

pub const MAX_OUTPUT: usize = 256 * 1024;

const MAX_BITCODE_SIZE: usize = 192 * 1024;
const MAX_DXIL_PART_SIZE: usize = 200 * 1024;
const MAX_GLOBALS: usize = 64;

pub fn emit(module: *const ir.Module, out: []u8) EmitError!usize {
    var emitter = Emitter.init(module);
    return emitter.emit_module(out);
}

const ResourceBinding = struct {
    class: u32,
    kind: u32,
    group: u32,
    binding: u32,
    global_index: u32,
    handle_value: ValueIndex,
};

const Emitter = struct {
    module: *const ir.Module,
    b: Builder,
    resources: [MAX_GLOBALS]ResourceBinding = undefined,
    resource_count: u32 = 0,
    dx_op_fn: u32 = 0,
    i32_ty: TypeIndex = builder_mod.INVALID_TYPE,
    f32_ty: TypeIndex = builder_mod.INVALID_TYPE,
    void_ty: TypeIndex = builder_mod.INVALID_TYPE,
    i1_ty: TypeIndex = builder_mod.INVALID_TYPE,

    fn init(module: *const ir.Module) Emitter {
        return .{
            .module = module,
            .b = Builder.init(),
        };
    }

    fn emit_module(self: *Emitter, out: []u8) EmitError!usize {
        if (self.module.entry_points.items.len == 0) return error.InvalidIr;
        const entry = self.module.entry_points.items[0];
        const function = &self.module.functions.items[entry.function];

        // Setup base types
        self.void_ty = try self.b.type_void();
        self.i1_ty = try self.b.type_i1();
        self.i32_ty = try self.b.type_i32();
        self.f32_ty = try self.b.type_f32();

        // Declare dx.op overloaded intrinsic
        try self.declare_dx_op();

        // Declare entry point function
        const entry_fn_ty = try self.build_entry_function_type(function, entry.stage);
        const entry_fn_idx = try self.b.add_function(.{
            .name = function.name,
            .type_index = entry_fn_ty,
            .linkage = spec.Linkage.EXTERNAL,
            .is_definition = true,
        });

        // Analyze and register resource bindings
        try self.collect_resources();

        // Build function body
        var body = self.b.create_function_body(entry_fn_idx);
        try self.emit_entry_body(&body, function, entry);

        // Add symbol table entries
        try self.b.add_symtab_entry(self.b.functions[entry_fn_idx].value_index, function.name);

        // Build DXIL metadata
        try self.emit_dxil_metadata(function, entry);

        // Serialize LLVM bitcode
        var bitcode_buf: [MAX_BITCODE_SIZE]u8 = .{0} ** MAX_BITCODE_SIZE;
        const bodies = [_]FunctionBody{body};
        const bitcode_size = try serialize_mod.serialize(&self.b, &bodies, &bitcode_buf);

        // Build DXIL program part
        var dxil_part_buf: [MAX_DXIL_PART_SIZE]u8 = undefined;
        const shader_kind = switch (entry.stage) {
            .compute => spec.ShaderKind.COMPUTE,
            .vertex => spec.ShaderKind.VERTEX,
            .fragment => spec.ShaderKind.PIXEL,
        };
        const dxil_part_size = try container.write_dxil_program_part(.{
            .shader_kind = shader_kind,
            .bitcode = bitcode_buf[0..bitcode_size],
        }, &dxil_part_buf);

        // Build signature parts
        var isgn_buf: [64]u8 = undefined;
        const isgn_size = try container.write_empty_signature(&isgn_buf);
        var osgn_buf: [64]u8 = undefined;
        const osgn_size = try container.write_empty_signature(&osgn_buf);

        // Build feature flags part
        var sfi0_buf: [16]u8 = undefined;
        const sfi0_size = try container.write_feature_flags(&sfi0_buf);

        // Assemble DXBC container
        const parts = [_]container.Part{
            .{ .fourcc = spec.PartFourCC.SFI0, .data = sfi0_buf[0..sfi0_size] },
            .{ .fourcc = spec.PartFourCC.ISGN, .data = isgn_buf[0..isgn_size] },
            .{ .fourcc = spec.PartFourCC.OSGN, .data = osgn_buf[0..osgn_size] },
            .{ .fourcc = spec.PartFourCC.DXIL, .data = dxil_part_buf[0..dxil_part_size] },
        };
        return container.write_container(&parts, out);
    }

    fn declare_dx_op(self: *Emitter) EmitError!void {
        // dx.op.* functions are overloaded; declare a generic i32-returning
        // variant that we call for all DXIL intrinsics. The actual overloads
        // are resolved by the DXIL validator based on the opcode argument.
        const i32_ty = self.i32_ty;
        const dx_op_ty = try self.b.type_function(i32_ty, &.{i32_ty}, true);
        self.dx_op_fn = try self.b.add_function(.{
            .name = "dx.op.i32",
            .type_index = dx_op_ty,
            .linkage = spec.Linkage.EXTERNAL,
            .is_definition = false,
        });
    }

    fn build_entry_function_type(self: *Emitter, function: *const ir.Function, stage: ir.ShaderStage) EmitError!TypeIndex {
        _ = function;
        _ = stage;
        // DXIL entry points take no parameters; inputs come from dx.op intrinsics
        return self.b.type_function(self.void_ty, &.{}, false);
    }

    fn collect_resources(self: *Emitter) EmitError!void {
        for (self.module.globals.items, 0..) |global, idx| {
            const binding = global.binding orelse continue;
            const resource = classify_resource(self.module, global) orelse continue;
            if (self.resource_count >= MAX_GLOBALS) return error.OutputTooLarge;
            self.resources[self.resource_count] = .{
                .class = resource.class,
                .kind = resource.kind,
                .group = binding.group,
                .binding = binding.binding,
                .global_index = @intCast(idx),
                .handle_value = 0,
            };
            self.resource_count += 1;
        }
    }

    fn emit_entry_body(self: *Emitter, body: *FunctionBody, function: *const ir.Function, entry: ir.EntryPoint) EmitError!void {
        // For compute shaders, emit thread ID loads and body statements.
        // For vertex/fragment, emit load_input/store_output patterns.
        switch (entry.stage) {
            .compute => try self.emit_compute_body(body, function),
            .vertex => try self.emit_vs_body(body, function),
            .fragment => try self.emit_ps_body(body, function),
        }
    }

    fn emit_compute_body(self: *Emitter, body: *FunctionBody, function: *const ir.Function) EmitError!void {
        // Load thread IDs for parameters that use compute builtins
        for (function.params.items) |param| {
            const io = param.io orelse continue;
            const opcode: ?u32 = switch (io.builtin) {
                .global_invocation_id => spec.DxilOpcode.THREAD_ID,
                .local_invocation_id => spec.DxilOpcode.THREAD_ID_IN_GROUP,
                .workgroup_id => spec.DxilOpcode.GROUP_ID,
                .local_invocation_index => spec.DxilOpcode.FLATTENED_THREAD_ID_IN_GROUP,
                else => null,
            };
            if (opcode) |dxil_op| {
                // Emit dx.op call to load each component (x, y, z)
                if (io.builtin == .local_invocation_index) {
                    _ = try self.emit_dx_op_call(body, dxil_op, &.{});
                } else {
                    // vec3u: load x, y, z components
                    for (0..3) |component| {
                        const comp_const = try self.b.add_const_u32(@intCast(component));
                        _ = try self.emit_dx_op_call(body, dxil_op, &.{comp_const});
                    }
                }
            }
        }

        // Emit the function body statements via recursive walk
        try self.emit_function_stmts(body, function, function.root_stmt);

        // Ensure function ends with ret void
        try body.add_void_op(.{ .ret_void = {} });
    }

    fn emit_vs_body(self: *Emitter, body: *FunctionBody, function: *const ir.Function) EmitError!void {
        // Vertex shader: load inputs via LoadInput, run body, store outputs
        for (function.params.items) |param| {
            const io = param.io orelse continue;
            if (io.builtin == .vertex_index or io.builtin == .instance_index) {
                const semantic = switch (io.builtin) {
                    .vertex_index => spec.DxilOpcode.LOAD_INPUT,
                    .instance_index => spec.DxilOpcode.LOAD_INPUT,
                    else => continue,
                };
                _ = try self.emit_dx_op_call(body, semantic, &.{});
            }
        }
        try self.emit_function_stmts(body, function, function.root_stmt);
        try body.add_void_op(.{ .ret_void = {} });
    }

    fn emit_ps_body(self: *Emitter, body: *FunctionBody, function: *const ir.Function) EmitError!void {
        // Pixel shader: load interpolated inputs, run body, store outputs
        for (function.params.items) |param| {
            const io = param.io orelse continue;
            if (io.location != null or io.builtin == .position or io.builtin == .front_facing) {
                _ = try self.emit_dx_op_call(body, spec.DxilOpcode.LOAD_INPUT, &.{});
            }
        }
        try self.emit_function_stmts(body, function, function.root_stmt);
        try body.add_void_op(.{ .ret_void = {} });
    }

    fn emit_function_stmts(self: *Emitter, body: *FunctionBody, function: *const ir.Function, stmt_id: ir.StmtId) EmitError!void {
        const stmt = function.stmts.items[stmt_id];
        switch (stmt) {
            .block => |range| {
                var i: u32 = 0;
                while (i < range.len) : (i += 1) {
                    try self.emit_function_stmts(body, function, function.stmt_children.items[range.start + i]);
                }
            },
            .local_decl => |decl| {
                if (decl.initializer) |expr_id| {
                    _ = try self.emit_expr_value(body, function, expr_id);
                }
            },
            .expr => |expr_id| {
                _ = try self.emit_expr_value(body, function, expr_id);
            },
            .assign => |assign| {
                const rhs = try self.emit_expr_value(body, function, assign.rhs);
                _ = rhs;
                // Store operations would go through dx.op.bufferStore or
                // storeOutput depending on the LHS target
            },
            .return_ => |value| {
                if (value) |expr_id| {
                    _ = try self.emit_expr_value(body, function, expr_id);
                }
            },
            .if_ => |if_stmt| {
                _ = try self.emit_expr_value(body, function, if_stmt.cond);
                try self.emit_function_stmts(body, function, if_stmt.then_block);
                if (if_stmt.else_block) |else_block| {
                    try self.emit_function_stmts(body, function, else_block);
                }
            },
            .loop_ => |loop_stmt| {
                if (loop_stmt.init) |init_stmt| try self.emit_function_stmts(body, function, init_stmt);
                if (loop_stmt.cond) |cond| {
                    _ = try self.emit_expr_value(body, function, cond);
                }
                try self.emit_function_stmts(body, function, loop_stmt.body);
                if (loop_stmt.continuing) |continuing| try self.emit_function_stmts(body, function, continuing);
            },
            .switch_ => |switch_stmt| {
                _ = try self.emit_expr_value(body, function, switch_stmt.expr);
                var case_index: u32 = 0;
                while (case_index < switch_stmt.cases.len) : (case_index += 1) {
                    const case_node = function.switch_cases.items[switch_stmt.cases.start + case_index];
                    try self.emit_function_stmts(body, function, case_node.body);
                }
            },
            .break_, .continue_, .discard_ => {},
        }
    }

    fn emit_expr_value(self: *Emitter, body: *FunctionBody, function: *const ir.Function, expr_id: ir.ExprId) EmitError!ValueIndex {
        const expr = function.exprs.items[expr_id];
        switch (expr.data) {
            .bool_lit => |val| return self.b.add_constant(self.i1_ty, .{ .uint_val = @intFromBool(val) }),
            .int_lit => |val| return self.b.add_constant(self.i32_ty, .{ .uint_val = @intCast(val) }),
            .float_lit => |val| return self.b.add_const_f32(@floatCast(val)),
            .param_ref => |_| return self.b.add_const_i32(0),
            .local_ref => |_| return self.b.add_const_i32(0),
            .global_ref => |_| return self.b.add_const_i32(0),
            .load => |inner| return self.emit_expr_value(body, function, inner),
            .unary => |unary| {
                const operand = try self.emit_expr_value(body, function, unary.operand);
                return self.emit_unary_op(body, unary.op, operand, expr.ty);
            },
            .binary => |binary| {
                const lhs = try self.emit_expr_value(body, function, binary.lhs);
                const rhs = try self.emit_expr_value(body, function, binary.rhs);
                return self.emit_binary_op(body, binary.op, lhs, rhs, expr.ty);
            },
            .call => |call| {
                if (call.kind == .builtin) {
                    return self.emit_builtin_call(body, function, call.name, call.args, expr.ty);
                }
                return self.b.add_const_i32(0);
            },
            .construct => |construct| {
                _ = construct;
                return self.b.add_const_i32(0);
            },
            .member => |member| {
                _ = try self.emit_expr_value(body, function, member.base);
                return self.b.add_const_i32(0);
            },
            .index => |index| {
                _ = try self.emit_expr_value(body, function, index.base);
                _ = try self.emit_expr_value(body, function, index.index);
                return self.b.add_const_i32(0);
            },
        }
    }

    fn emit_unary_op(self: *Emitter, body: *FunctionBody, op: ir.UnaryOp, operand: ValueIndex, result_ty: ir.TypeId) EmitError!ValueIndex {
        const is_float = is_float_type(self.module, result_ty);
        const llvm_op: u32 = switch (op) {
            .neg => if (is_float) spec.BinOp.FSUB else spec.BinOp.SUB,
            .not => spec.BinOp.XOR,
            .bit_not => spec.BinOp.XOR,
        };
        // For negation: 0 - operand
        const zero = if (is_float) try self.b.add_const_f32(0.0) else try self.b.add_const_i32(0);
        if (op == .neg) {
            return body.add_op(.{ .binop = .{ .lhs = zero, .rhs = operand, .opcode = llvm_op } }, self.i32_ty);
        }
        // For not/bit_not: operand ^ -1
        const all_ones = try self.b.add_const_i32(-1);
        return body.add_op(.{ .binop = .{ .lhs = operand, .rhs = all_ones, .opcode = llvm_op } }, self.i32_ty);
    }

    fn emit_binary_op(self: *Emitter, body: *FunctionBody, op: ir.BinaryOp, lhs: ValueIndex, rhs: ValueIndex, result_ty: ir.TypeId) EmitError!ValueIndex {
        const is_float = is_float_type(self.module, result_ty);
        const is_signed = is_signed_type(self.module, result_ty);
        const llvm_op: u32 = switch (op) {
            .add => if (is_float) spec.BinOp.FADD else spec.BinOp.ADD,
            .sub => if (is_float) spec.BinOp.FSUB else spec.BinOp.SUB,
            .mul => if (is_float) spec.BinOp.FMUL else spec.BinOp.MUL,
            .div => if (is_float) spec.BinOp.FDIV else if (is_signed) spec.BinOp.SDIV else spec.BinOp.UDIV,
            .rem => if (is_float) spec.BinOp.FREM else if (is_signed) spec.BinOp.SREM else spec.BinOp.UREM,
            .bit_and => spec.BinOp.AND,
            .bit_or => spec.BinOp.OR,
            .bit_xor => spec.BinOp.XOR,
            .shift_left => spec.BinOp.SHL,
            .shift_right => if (is_signed) spec.BinOp.ASHR else spec.BinOp.LSHR,
            .equal => return body.add_op(.{ .cmp = .{ .lhs = lhs, .rhs = rhs, .predicate = if (is_float) spec.CmpPred.FCMP_OEQ else spec.CmpPred.ICMP_EQ } }, self.i1_ty),
            .not_equal => return body.add_op(.{ .cmp = .{ .lhs = lhs, .rhs = rhs, .predicate = if (is_float) spec.CmpPred.FCMP_ONE else spec.CmpPred.ICMP_NE } }, self.i1_ty),
            .less => return body.add_op(.{ .cmp = .{ .lhs = lhs, .rhs = rhs, .predicate = if (is_float) spec.CmpPred.FCMP_OLT else if (is_signed) spec.CmpPred.ICMP_SLT else spec.CmpPred.ICMP_ULT } }, self.i1_ty),
            .less_equal => return body.add_op(.{ .cmp = .{ .lhs = lhs, .rhs = rhs, .predicate = if (is_float) spec.CmpPred.FCMP_OLE else if (is_signed) spec.CmpPred.ICMP_SLE else spec.CmpPred.ICMP_ULE } }, self.i1_ty),
            .greater => return body.add_op(.{ .cmp = .{ .lhs = lhs, .rhs = rhs, .predicate = if (is_float) spec.CmpPred.FCMP_OGT else if (is_signed) spec.CmpPred.ICMP_SGT else spec.CmpPred.ICMP_UGT } }, self.i1_ty),
            .greater_equal => return body.add_op(.{ .cmp = .{ .lhs = lhs, .rhs = rhs, .predicate = if (is_float) spec.CmpPred.FCMP_OGE else if (is_signed) spec.CmpPred.ICMP_SGE else spec.CmpPred.ICMP_UGE } }, self.i1_ty),
            .logical_and => spec.BinOp.AND,
            .logical_or => spec.BinOp.OR,
        };
        return body.add_op(.{ .binop = .{ .lhs = lhs, .rhs = rhs, .opcode = llvm_op } }, self.i32_ty);
    }

    fn emit_builtin_call(self: *Emitter, body: *FunctionBody, function: *const ir.Function, name: []const u8, args: ir.Range, result_ty: ir.TypeId) EmitError!ValueIndex {
        _ = result_ty;
        // Map WGSL builtins to DXIL opcodes
        if (std.mem.eql(u8, name, "workgroupBarrier")) {
            const mode = try self.b.add_const_u32(spec.BarrierMode.SYNC_THREAD_GROUP | spec.BarrierMode.TGSM_FENCE);
            return self.emit_dx_op_call(body, spec.DxilOpcode.BARRIER, &.{mode});
        }
        if (std.mem.eql(u8, name, "storageBarrier")) {
            const mode = try self.b.add_const_u32(spec.BarrierMode.SYNC_THREAD_GROUP | spec.BarrierMode.UAV_FENCE_GLOBAL);
            return self.emit_dx_op_call(body, spec.DxilOpcode.BARRIER, &.{mode});
        }
        if (std.mem.eql(u8, name, "textureBarrier")) {
            const mode = try self.b.add_const_u32(spec.BarrierMode.SYNC_THREAD_GROUP | spec.BarrierMode.UAV_FENCE_GLOBAL);
            return self.emit_dx_op_call(body, spec.DxilOpcode.BARRIER, &.{mode});
        }
        if (std.mem.eql(u8, name, "subgroupElect")) {
            return self.emit_dx_op_call(body, spec.DxilOpcode.WAVE_IS_FIRST_LANE, &.{});
        }
        if (std.mem.eql(u8, name, "subgroupAll")) {
            if (args.len >= 1) {
                const arg = try self.emit_expr_value(body, function, function.expr_args.items[args.start]);
                return self.emit_dx_op_call(body, spec.DxilOpcode.WAVE_ALL_TRUE, &.{arg});
            }
            return self.emit_dx_op_call(body, spec.DxilOpcode.WAVE_ALL_TRUE, &.{});
        }
        if (std.mem.eql(u8, name, "subgroupAny")) {
            if (args.len >= 1) {
                const arg = try self.emit_expr_value(body, function, function.expr_args.items[args.start]);
                return self.emit_dx_op_call(body, spec.DxilOpcode.WAVE_ANY_TRUE, &.{arg});
            }
            return self.emit_dx_op_call(body, spec.DxilOpcode.WAVE_ANY_TRUE, &.{});
        }
        if (std.mem.eql(u8, name, "subgroupBallot")) {
            if (args.len >= 1) {
                const arg = try self.emit_expr_value(body, function, function.expr_args.items[args.start]);
                return self.emit_dx_op_call(body, spec.DxilOpcode.WAVE_ACTIVE_BALLOT, &.{arg});
            }
            return self.emit_dx_op_call(body, spec.DxilOpcode.WAVE_ACTIVE_BALLOT, &.{});
        }
        if (std.mem.eql(u8, name, "subgroupAdd")) {
            if (args.len >= 1) {
                const arg = try self.emit_expr_value(body, function, function.expr_args.items[args.start]);
                const wave_op = try self.b.add_const_u32(spec.WaveOp.SUM);
                return self.emit_dx_op_call(body, spec.DxilOpcode.WAVE_ACTIVE_OP, &.{ arg, wave_op });
            }
            return self.b.add_const_i32(0);
        }

        // For other builtins, evaluate args and return a placeholder value
        var i: u32 = 0;
        while (i < args.len) : (i += 1) {
            _ = try self.emit_expr_value(body, function, function.expr_args.items[args.start + i]);
        }
        return self.b.add_const_i32(0);
    }

    fn emit_dx_op_call(self: *Emitter, body: *FunctionBody, opcode: u32, extra_args: []const ValueIndex) EmitError!ValueIndex {
        const opcode_const = try self.b.add_const_u32(opcode);
        var call_op = builder_mod.FunctionBodyOp{ .call = .{
            .result_type = self.i32_ty,
            .callee = self.b.functions[self.dx_op_fn].value_index,
            .args = undefined,
            .arg_count = @intCast(1 + extra_args.len),
        } };
        call_op.call.args[0] = opcode_const;
        for (extra_args, 0..) |arg, i| {
            call_op.call.args[1 + i] = arg;
        }
        return body.add_op(call_op, self.i32_ty);
    }

    fn emit_dxil_metadata(self: *Emitter, function: *const ir.Function, entry: ir.EntryPoint) EmitError!void {
        // dx.version metadata: !{i32 1, i32 0}
        const ver_major = try self.b.add_metadata_value(self.i32_ty, try self.b.add_const_u32(1));
        const ver_minor = try self.b.add_metadata_value(self.i32_ty, try self.b.add_const_u32(0));
        const dx_version = try self.b.add_metadata_node(&.{ ver_major, ver_minor });
        try self.b.add_named_metadata("dx.version", &.{dx_version});

        // dx.valver metadata: !{i32 1, i32 7}
        const val_major = try self.b.add_metadata_value(self.i32_ty, try self.b.add_const_u32(1));
        const val_minor = try self.b.add_metadata_value(self.i32_ty, try self.b.add_const_u32(7));
        const val_version = try self.b.add_metadata_node(&.{ val_major, val_minor });
        try self.b.add_named_metadata("dx.valver", &.{val_version});

        // dx.shaderModel metadata
        const sm_kind_str = try self.b.add_metadata_string(switch (entry.stage) {
            .compute => "cs",
            .vertex => "vs",
            .fragment => "ps",
        });
        const sm_major = try self.b.add_metadata_value(self.i32_ty, try self.b.add_const_u32(6));
        const sm_minor = try self.b.add_metadata_value(self.i32_ty, try self.b.add_const_u32(0));
        const shader_model = try self.b.add_metadata_node(&.{ sm_kind_str, sm_major, sm_minor });
        try self.b.add_named_metadata("dx.shaderModel", &.{shader_model});

        // dx.entryPoints metadata
        const entry_name_str = try self.b.add_metadata_string(function.name);
        // For compute shaders, emit numthreads
        if (entry.stage == .compute) {
            const x = try self.b.add_metadata_value(self.i32_ty, try self.b.add_const_u32(entry.workgroup_size[0]));
            const y = try self.b.add_metadata_value(self.i32_ty, try self.b.add_const_u32(entry.workgroup_size[1]));
            const z = try self.b.add_metadata_value(self.i32_ty, try self.b.add_const_u32(entry.workgroup_size[2]));
            const num_threads = try self.b.add_metadata_node(&.{ x, y, z });
            const tag_numthreads = try self.b.add_metadata_value(self.i32_ty, try self.b.add_const_u32(spec.DxilMdTag.NUM_THREADS));
            const props = try self.b.add_metadata_node(&.{ tag_numthreads, num_threads });
            const entry_point = try self.b.add_metadata_node(&.{ entry_name_str, null, null, props });
            try self.b.add_named_metadata("dx.entryPoints", &.{entry_point});
        } else {
            const entry_point = try self.b.add_metadata_node(&.{ entry_name_str, null, null, null });
            try self.b.add_named_metadata("dx.entryPoints", &.{entry_point});
        }
    }
};

fn classify_resource(module: *const ir.Module, global: ir.Global) ?struct { class: u32, kind: u32 } {
    const addr_space = global.addr_space orelse return null;
    return switch (addr_space) {
        .uniform => .{ .class = spec.ResourceClass.CBV, .kind = spec.ResourceKind.CBUFFER },
        .storage => blk: {
            const access = global.access orelse .read_write;
            break :blk switch (access) {
                .read => .{ .class = spec.ResourceClass.SRV, .kind = classify_storage_kind(module, global.ty) },
                else => .{ .class = spec.ResourceClass.UAV, .kind = classify_storage_kind(module, global.ty) },
            };
        },
        .handle => switch (module.types.get(global.ty)) {
            .sampler, .sampler_comparison => .{ .class = spec.ResourceClass.SAMPLER, .kind = spec.ResourceKind.SAMPLER },
            .texture_1d => .{ .class = spec.ResourceClass.SRV, .kind = spec.ResourceKind.TEXTURE_1D },
            .texture_2d, .texture_2d_array, .texture_depth_2d => .{ .class = spec.ResourceClass.SRV, .kind = spec.ResourceKind.TEXTURE_2D },
            .texture_3d => .{ .class = spec.ResourceClass.SRV, .kind = spec.ResourceKind.TEXTURE_3D },
            .texture_cube, .texture_depth_cube => .{ .class = spec.ResourceClass.SRV, .kind = spec.ResourceKind.TEXTURE_CUBE },
            .texture_multisampled_2d => .{ .class = spec.ResourceClass.SRV, .kind = spec.ResourceKind.TEXTURE_2D_MS },
            .storage_texture_2d => |st| .{
                .class = if (st.access == .read) spec.ResourceClass.SRV else spec.ResourceClass.UAV,
                .kind = spec.ResourceKind.TEXTURE_2D,
            },
            else => null,
        },
        else => null,
    };
}

fn classify_storage_kind(module: *const ir.Module, ty: ir.TypeId) u32 {
    return switch (module.types.get(ty)) {
        .array => spec.ResourceKind.STRUCTURED_BUFFER,
        .struct_ => spec.ResourceKind.STRUCTURED_BUFFER,
        else => spec.ResourceKind.RAW_BUFFER,
    };
}

fn is_float_type(module: *const ir.Module, ty: ir.TypeId) bool {
    return switch (module.types.get(ty)) {
        .scalar => |s| s == .f32 or s == .f16 or s == .abstract_float,
        .vector => |v| is_float_type(module, v.elem),
        else => false,
    };
}

fn is_signed_type(module: *const ir.Module, ty: ir.TypeId) bool {
    return switch (module.types.get(ty)) {
        .scalar => |s| s == .i32 or s == .abstract_int,
        .vector => |v| is_signed_type(module, v.elem),
        else => false,
    };
}

test "native dxil emit produces container with DXBC magic" {
    const testing_alloc = std.testing.allocator;
    var module = ir.Module.init(testing_alloc);
    defer module.deinit();

    const void_ty = try module.types.intern(.{ .scalar = .void });
    const u32_ty = try module.types.intern(.{ .scalar = .u32 });
    const vec3u_ty = try module.types.intern(.{ .vector = .{ .elem = u32_ty, .len = 3 } });

    var func = ir.Function{
        .name = try ir.dup_string(testing_alloc, "main"),
        .return_type = void_ty,
        .stage = .compute,
        .workgroup_size = .{ 64, 1, 1 },
    };
    try func.params.append(testing_alloc, .{
        .name = try ir.dup_string(testing_alloc, "gid"),
        .ty = vec3u_ty,
        .io = .{ .builtin = .global_invocation_id },
    });

    const root_stmt = try func.append_stmt(testing_alloc, .{ .block = .{ .start = 0, .len = 0 } });
    func.root_stmt = root_stmt;

    try module.functions.append(testing_alloc, func);
    try module.entry_points.append(testing_alloc, .{
        .function = 0,
        .stage = .compute,
        .workgroup_size = .{ 64, 1, 1 },
    });

    var out: [MAX_OUTPUT]u8 = undefined;
    const size = try emit(&module, &out);
    try std.testing.expect(size > 32);
    // Verify DXBC container magic
    try std.testing.expectEqualSlices(u8, &spec.DXBC_FOURCC, out[0..4]);
}
