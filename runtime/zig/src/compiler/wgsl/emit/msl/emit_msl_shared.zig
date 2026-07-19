// doe_wgsl/emit_msl_shared.zig — MSL emitter helpers shared across shader stages.
//
// Provides type emission, expression emission, statement emission, and bound global
// parameter emission. All write operations work through a (buf, pos) pair so that
// callers manage their own output buffers without heap allocation.

const std = @import("std");
const ir = @import("../../ir/ir.zig");

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
};

// ──────────────────────────────────────────────────────────────────────────────
// Function name helpers
// ──────────────────────────────────────────────────────────────────────────────

pub fn vertex_function_name(name: []const u8) []const u8 {
    // "main" is reserved in C; rename to avoid link collision.
    if (std.mem.eql(u8, name, "main")) return "main_vertex";
    return name;
}

pub fn fragment_function_name(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "main")) return "main_fragment";
    return name;
}

// ──────────────────────────────────────────────────────────────────────────────
// Type emission
// ──────────────────────────────────────────────────────────────────────────────

pub fn write_type(module: *const ir.Module, ty: ir.TypeId, buf: []u8, pos: *usize) EmitError!void {
    switch (module.types.get(ty)) {
        .scalar => |scalar| try write_str(buf, pos, switch (scalar) {
            .void => "void",
            .bool => "bool",
            .i32, .abstract_int => "int",
            .u32 => "uint",
            .f32, .abstract_float => "float",
            .f16 => "half",
        }),
        .vector => |vec| {
            const elem_name = switch (module.types.get(vec.elem)) {
                .scalar => |scalar| switch (scalar) {
                    .bool => "bool",
                    .i32, .abstract_int => "int",
                    .u32 => "uint",
                    .f32, .abstract_float => "float",
                    .f16 => "half",
                    else => return error.InvalidIr,
                },
                else => return error.InvalidIr,
            };
            try write_str(buf, pos, elem_name);
            try write_u32(buf, pos, vec.len);
        },
        .matrix => |mat| {
            const elem_name = switch (module.types.get(mat.elem)) {
                .scalar => |scalar| switch (scalar) {
                    .f32, .abstract_float => "float",
                    .f16 => "half",
                    else => return error.InvalidIr,
                },
                else => return error.InvalidIr,
            };
            try write_str(buf, pos, elem_name);
            try write_u32(buf, pos, mat.columns);
            try write_str(buf, pos, "x");
            try write_u32(buf, pos, mat.rows);
        },
        .array => |arr| {
            if (arr.len == null) return error.InvalidIr;
            try write_str(buf, pos, "array<");
            try write_type(module, arr.elem, buf, pos);
            try write_str(buf, pos, ", ");
            try write_u32(buf, pos, arr.len.?);
            try write_str(buf, pos, ">");
        },
        .atomic => |inner| switch (module.types.get(inner)) {
            .scalar => |scalar| switch (scalar) {
                .u32 => try write_str(buf, pos, "atomic_uint"),
                .i32, .abstract_int => try write_str(buf, pos, "atomic_int"),
                else => return error.InvalidIr,
            },
            else => return error.InvalidIr,
        },
        .struct_ => |struct_id| try write_str(buf, pos, module.structs.items[struct_id].name),
        .sampler => try write_str(buf, pos, "sampler"),
        .sampler_comparison => try write_str(buf, pos, "sampler"),
        .texture_1d => |sample_ty| {
            try write_str(buf, pos, "texture1d<");
            try write_type(module, sample_ty, buf, pos);
            try write_str(buf, pos, ">");
        },
        .texture_2d => |sample_ty| {
            try write_str(buf, pos, "texture2d<");
            try write_type(module, sample_ty, buf, pos);
            try write_str(buf, pos, ">");
        },
        .texture_2d_array => |sample_ty| {
            try write_str(buf, pos, "texture2d_array<");
            try write_type(module, sample_ty, buf, pos);
            try write_str(buf, pos, ">");
        },
        .texture_cube => |sample_ty| {
            try write_str(buf, pos, "texturecube<");
            try write_type(module, sample_ty, buf, pos);
            try write_str(buf, pos, ">");
        },
        .texture_multisampled_2d => |sample_ty| {
            try write_str(buf, pos, "texture2d_ms<");
            try write_type(module, sample_ty, buf, pos);
            try write_str(buf, pos, ">");
        },
        .texture_depth_2d => try write_str(buf, pos, "depth2d<float>"),
        .texture_depth_cube => try write_str(buf, pos, "depthcube<float>"),
        .texture_3d => |sample_ty| {
            try write_str(buf, pos, "texture3d<");
            try write_type(module, sample_ty, buf, pos);
            try write_str(buf, pos, ">");
        },
        .storage_texture_2d => |storage| {
            const access_str: []const u8 = switch (storage.access) {
                .read => "access::read",
                .write => "access::write",
                .read_write => "access::read_write",
            };
            try write_str(buf, pos, "texture2d<");
            try write_str(buf, pos, storage_format_msl(storage.format));
            try write_str(buf, pos, ", ");
            try write_str(buf, pos, access_str);
            try write_str(buf, pos, ">");
        },
        .ref => |ref_ty| try write_type(module, ref_ty.elem, buf, pos),
    }
}

fn storage_format_msl(format: ir.TextureFormat) []const u8 {
    return switch (format) {
        .rgba8unorm, .rgba8snorm, .rgba16float, .r32float, .rg32float, .rgba32float => "float",
        .rgba8uint, .rgba16uint, .r32uint, .rg32uint, .rgba32uint => "uint",
        .rgba8sint, .rgba16sint, .r32sint, .rg32sint, .rgba32sint => "int",
    };
}

// ──────────────────────────────────────────────────────────────────────────────
// Bound global parameter emission (uniform buffers, textures, samplers)
// ──────────────────────────────────────────────────────────────────────────────

pub fn write_bound_global_param(module: *const ir.Module, global: ir.Global, buf: []u8, pos: *usize) EmitError!void {
    const binding = global.binding orelse return error.InvalidIr;
    if (global.addr_space) |addr_space| switch (addr_space) {
        .uniform => {
            try write_str(buf, pos, "constant ");
            try write_type(module, global.ty, buf, pos);
            try write_str(buf, pos, "& ");
            try write_str(buf, pos, global.name);
            try write_str(buf, pos, " [[buffer(");
            try write_u32(buf, pos, binding.binding);
            try write_str(buf, pos, ")]]");
            return;
        },
        .storage => {
            const access = global.access orelse .read_write;
            if (access == .read) {
                try write_str(buf, pos, "const device ");
            } else {
                try write_str(buf, pos, "device ");
            }
            switch (module.types.get(global.ty)) {
                .array => |arr| {
                    try write_type(module, arr.elem, buf, pos);
                    try write_str(buf, pos, "* ");
                },
                else => {
                    try write_type(module, global.ty, buf, pos);
                    try write_str(buf, pos, "& ");
                },
            }
            try write_str(buf, pos, global.name);
            try write_str(buf, pos, " [[buffer(");
            try write_u32(buf, pos, binding.binding);
            try write_str(buf, pos, ")]]");
            return;
        },
        else => {},
    };
    // Handle texture/sampler types.
    switch (module.types.get(global.ty)) {
        .sampler, .sampler_comparison => {
            try write_str(buf, pos, "sampler ");
            try write_str(buf, pos, global.name);
            try write_str(buf, pos, " [[sampler(");
            try write_u32(buf, pos, binding.binding);
            try write_str(buf, pos, ")]]");
        },
        .texture_1d, .texture_2d, .texture_2d_array, .texture_cube, .texture_multisampled_2d, .texture_depth_2d, .texture_depth_cube, .texture_3d => {
            try write_type(module, global.ty, buf, pos);
            try write_str(buf, pos, " ");
            try write_str(buf, pos, global.name);
            try write_str(buf, pos, " [[texture(");
            try write_u32(buf, pos, binding.binding);
            try write_str(buf, pos, ")]]");
        },
        .storage_texture_2d => {
            try write_type(module, global.ty, buf, pos);
            try write_str(buf, pos, " ");
            try write_str(buf, pos, global.name);
            try write_str(buf, pos, " [[texture(");
            try write_u32(buf, pos, binding.binding);
            try write_str(buf, pos, ")]]");
        },
        else => return error.InvalidIr,
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Statement emission
// ──────────────────────────────────────────────────────────────────────────────

pub fn write_stmt(module: *const ir.Module, function: ir.Function, stmt_id: ir.StmtId, buf: []u8, pos: *usize, indent: *usize) EmitError!void {
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                try write_stmt(module, function, function.stmt_children.items[range.start + i], buf, pos, indent);
            }
        },
        .local_decl => |decl| {
            const local = function.locals.items[decl.local];
            try write_indent(buf, pos, indent.*);
            if (decl.is_const) try write_str(buf, pos, "const ");
            try write_type(module, local.ty, buf, pos);
            try write_str(buf, pos, " ");
            try write_str(buf, pos, local.name);
            if (decl.initializer) |expr_id| {
                try write_str(buf, pos, " = ");
                try write_expr(module, function, expr_id, buf, pos);
            }
            try write_str(buf, pos, ";\n");
        },
        .expr => |expr_id| {
            try write_indent(buf, pos, indent.*);
            try write_expr(module, function, expr_id, buf, pos);
            try write_str(buf, pos, ";\n");
        },
        .assign => |assign| {
            try write_indent(buf, pos, indent.*);
            try write_expr(module, function, assign.lhs, buf, pos);
            try write_str(buf, pos, " ");
            try write_str(buf, pos, assign_op_text(assign.op));
            try write_str(buf, pos, " ");
            try write_expr(module, function, assign.rhs, buf, pos);
            try write_str(buf, pos, ";\n");
        },
        .return_ => |value| {
            try write_indent(buf, pos, indent.*);
            try write_str(buf, pos, "return");
            if (value) |expr_id| {
                try write_str(buf, pos, " ");
                try write_expr(module, function, expr_id, buf, pos);
            }
            try write_str(buf, pos, ";\n");
        },
        .if_ => |if_stmt| {
            try write_indent(buf, pos, indent.*);
            try write_str(buf, pos, "if (");
            try write_expr(module, function, if_stmt.cond, buf, pos);
            try write_str(buf, pos, ") {\n");
            indent.* += 4;
            try write_stmt(module, function, if_stmt.then_block, buf, pos, indent);
            indent.* -= 4;
            try write_indent(buf, pos, indent.*);
            try write_str(buf, pos, "}");
            if (if_stmt.else_block) |else_block| {
                try write_str(buf, pos, " else {\n");
                indent.* += 4;
                try write_stmt(module, function, else_block, buf, pos, indent);
                indent.* -= 4;
                try write_indent(buf, pos, indent.*);
                try write_str(buf, pos, "}\n");
            } else {
                try write_str(buf, pos, "\n");
            }
        },
        .loop_ => |loop_stmt| {
            if (loop_stmt.init) |init_stmt| try write_stmt(module, function, init_stmt, buf, pos, indent);
            try write_indent(buf, pos, indent.*);
            switch (loop_stmt.kind) {
                .while_loop, .for_loop => {
                    try write_str(buf, pos, "while (");
                    if (loop_stmt.cond) |cond| {
                        try write_expr(module, function, cond, buf, pos);
                    } else {
                        try write_str(buf, pos, "true");
                    }
                    try write_str(buf, pos, ") {\n");
                },
                .loop => try write_str(buf, pos, "while (true) {\n"),
            }
            indent.* += 4;
            try write_stmt(module, function, loop_stmt.body, buf, pos, indent);
            if (loop_stmt.continuing) |continuing| try write_stmt(module, function, continuing, buf, pos, indent);
            indent.* -= 4;
            try write_indent(buf, pos, indent.*);
            try write_str(buf, pos, "}\n");
        },
        .switch_ => |switch_stmt| {
            try write_indent(buf, pos, indent.*);
            try write_str(buf, pos, "switch (");
            try write_expr(module, function, switch_stmt.expr, buf, pos);
            try write_str(buf, pos, ") {\n");
            indent.* += 4;
            var case_index: u32 = 0;
            while (case_index < switch_stmt.cases.len) : (case_index += 1) {
                const case_node = function.switch_cases.items[switch_stmt.cases.start + case_index];
                if (case_node.is_default) {
                    try write_indent(buf, pos, indent.*);
                    try write_str(buf, pos, "default:\n");
                } else {
                    for (case_node.selectors.items) |sel_expr_id| {
                        try write_indent(buf, pos, indent.*);
                        try write_str(buf, pos, "case ");
                        try write_expr(module, function, sel_expr_id, buf, pos);
                        try write_str(buf, pos, ":\n");
                    }
                }
                indent.* += 4;
                try write_stmt(module, function, case_node.body, buf, pos, indent);
                try write_indent(buf, pos, indent.*);
                try write_str(buf, pos, "break;\n");
                indent.* -= 4;
            }
            indent.* -= 4;
            try write_indent(buf, pos, indent.*);
            try write_str(buf, pos, "}\n");
        },
        .break_ => {
            try write_indent(buf, pos, indent.*);
            try write_str(buf, pos, "break;\n");
        },
        .continue_ => {
            try write_indent(buf, pos, indent.*);
            try write_str(buf, pos, "continue;\n");
        },
        .discard_ => {
            try write_indent(buf, pos, indent.*);
            try write_str(buf, pos, "discard_fragment();\n");
        },
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Expression emission
// ──────────────────────────────────────────────────────────────────────────────

pub fn write_expr(module: *const ir.Module, function: ir.Function, expr_id: ir.ExprId, buf: []u8, pos: *usize) EmitError!void {
    const expr = function.exprs.items[expr_id];
    switch (expr.data) {
        .bool_lit => |value| try write_str(buf, pos, if (value) "true" else "false"),
        .int_lit => |value| try write_u64(buf, pos, value),
        .float_lit => |value| try write_float(buf, pos, value),
        .param_ref => |index| try write_str(buf, pos, function.params.items[index].name),
        .local_ref => |index| try write_str(buf, pos, function.locals.items[index].name),
        .global_ref => |index| try write_str(buf, pos, module.globals.items[index].name),
        .load => |inner| try write_expr(module, function, inner, buf, pos),
        .unary => |unary| {
            try write_str(buf, pos, "(");
            try write_str(buf, pos, unary_op_text(unary.op));
            try write_expr(module, function, unary.operand, buf, pos);
            try write_str(buf, pos, ")");
        },
        .binary => |binary| {
            try write_str(buf, pos, "(");
            try write_expr(module, function, binary.lhs, buf, pos);
            try write_str(buf, pos, " ");
            try write_str(buf, pos, binary_op_text(binary.op));
            try write_str(buf, pos, " ");
            try write_expr(module, function, binary.rhs, buf, pos);
            try write_str(buf, pos, ")");
        },
        .call => |call| try write_call(module, function, expr.ty, call, buf, pos),
        .construct => |construct| {
            try write_type(module, construct.ty, buf, pos);
            try write_str(buf, pos, "(");
            try write_expr_list(module, function, construct.args, buf, pos);
            try write_str(buf, pos, ")");
        },
        .member => |member| {
            try write_expr(module, function, member.base, buf, pos);
            try write_str(buf, pos, ".");
            try write_str(buf, pos, member.field_name);
        },
        .index => |index| {
            try write_expr(module, function, index.base, buf, pos);
            try write_str(buf, pos, "[");
            try write_expr(module, function, index.index, buf, pos);
            try write_str(buf, pos, "]");
        },
    }
}

// Emit an expression with an explicit cast to the target type when the
// expression type does not match. Prevents MSL overload ambiguity in
// builtins like min/max/clamp where mixed argument types are invalid.
fn write_expr_coerced(module: *const ir.Module, function: ir.Function, expr_id: ir.ExprId, target_ty: ir.TypeId, buf: []u8, pos: *usize) EmitError!void {
    const expr_ty = function.exprs.items[expr_id].ty;
    if (expr_ty != target_ty or should_force_literal_cast(module, function, expr_id, target_ty)) {
        try write_type(module, target_ty, buf, pos);
        try write_str(buf, pos, "(");
        try write_expr(module, function, expr_id, buf, pos);
        try write_str(buf, pos, ")");
        return;
    }
    try write_expr(module, function, expr_id, buf, pos);
}

fn should_force_literal_cast(module: *const ir.Module, function: ir.Function, expr_id: ir.ExprId, target_ty: ir.TypeId) bool {
    if (function.exprs.items[expr_id].data != .int_lit) return false;
    return switch (module.types.get(target_ty)) {
        .scalar => |scalar| scalar == .u32,
        else => false,
    };
}

fn write_call(module: *const ir.Module, function: ir.Function, result_ty: ir.TypeId, call: @FieldType(ir.Expr, "call"), buf: []u8, pos: *usize) EmitError!void {
    if (call.kind == .builtin) {
        if (try try_write_special_builtin(module, function, result_ty, call, buf, pos)) return;
    }
    try write_str(buf, pos, call.name);
    try write_str(buf, pos, "(");
    try write_expr_list(module, function, call.args, buf, pos);
    try write_str(buf, pos, ")");
}

// Returns true if the call was fully emitted as a special case.
fn try_write_special_builtin(module: *const ir.Module, function: ir.Function, result_ty: ir.TypeId, call: @FieldType(ir.Expr, "call"), buf: []u8, pos: *usize) EmitError!bool {
    if (std.mem.eql(u8, call.name, "workgroupBarrier")) {
        try write_str(buf, pos, "threadgroup_barrier(mem_flags::mem_threadgroup)");
        return true;
    }
    if (std.mem.eql(u8, call.name, "storageBarrier")) {
        try write_str(buf, pos, "threadgroup_barrier(mem_flags::mem_device)");
        return true;
    }
    if (std.mem.eql(u8, call.name, "textureBarrier")) {
        try write_str(buf, pos, "threadgroup_barrier(mem_flags::mem_texture)");
        return true;
    }
    // min/max/clamp: cast all arguments to the result type to avoid MSL
    // overload ambiguity when argument types differ (e.g. int vs uint,
    // abstract_int vs concrete, or mixed vector element types).
    if (std.mem.eql(u8, call.name, "min") or std.mem.eql(u8, call.name, "max") or std.mem.eql(u8, call.name, "clamp")) {
        try write_str(buf, pos, call.name);
        try write_str(buf, pos, "(");
        var i: u32 = 0;
        while (i < call.args.len) : (i += 1) {
            if (i > 0) try write_str(buf, pos, ", ");
            try write_expr_coerced(module, function, function.expr_args.items[call.args.start + i], result_ty, buf, pos);
        }
        try write_str(buf, pos, ")");
        return true;
    }
    // textureSample(t, s, coord) → t.sample(s, coord)
    if (std.mem.eql(u8, call.name, "textureSample")) {
        if (call.args.len < 3) return error.InvalidIr;
        try write_texture_arg(module, function, call.args, 0, buf, pos);
        try write_str(buf, pos, ".sample(");
        try write_expr(module, function, function.expr_args.items[call.args.start + 1], buf, pos);
        try write_str(buf, pos, ", ");
        try write_expr_range(module, function, call.args, 2, buf, pos);
        try write_str(buf, pos, ")");
        return true;
    }
    // textureSampleBias(t, s, coord, bias) → t.sample(s, coord, bias(bias))
    if (std.mem.eql(u8, call.name, "textureSampleBias")) {
        if (call.args.len < 4) return error.InvalidIr;
        try write_texture_arg(module, function, call.args, 0, buf, pos);
        try write_str(buf, pos, ".sample(");
        try write_expr(module, function, function.expr_args.items[call.args.start + 1], buf, pos);
        try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[call.args.start + 2], buf, pos);
        try write_str(buf, pos, ", bias(");
        try write_expr(module, function, function.expr_args.items[call.args.start + 3], buf, pos);
        try write_str(buf, pos, "))");
        return true;
    }
    // textureSampleLevel(t, s, coord, level) → t.sample(s, coord, level(level))
    if (std.mem.eql(u8, call.name, "textureSampleLevel")) {
        if (call.args.len < 4) return error.InvalidIr;
        try write_texture_arg(module, function, call.args, 0, buf, pos);
        try write_str(buf, pos, ".sample(");
        try write_expr(module, function, function.expr_args.items[call.args.start + 1], buf, pos);
        try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[call.args.start + 2], buf, pos);
        try write_str(buf, pos, ", level(");
        try write_expr(module, function, function.expr_args.items[call.args.start + 3], buf, pos);
        try write_str(buf, pos, "))");
        return true;
    }
    // textureSampleGrad(t, s, coord, ddx, ddy) → t.sample(s, coord, gradient2d(ddx, ddy))
    if (std.mem.eql(u8, call.name, "textureSampleGrad")) {
        if (call.args.len < 5) return error.InvalidIr;
        try write_texture_arg(module, function, call.args, 0, buf, pos);
        try write_str(buf, pos, ".sample(");
        try write_expr(module, function, function.expr_args.items[call.args.start + 1], buf, pos);
        try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[call.args.start + 2], buf, pos);
        try write_str(buf, pos, ", gradient2d(");
        try write_expr(module, function, function.expr_args.items[call.args.start + 3], buf, pos);
        try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[call.args.start + 4], buf, pos);
        try write_str(buf, pos, "))");
        return true;
    }
    // textureSampleCompare(t, s, coord, ref) → t.sample_compare(s, coord, ref)
    if (std.mem.eql(u8, call.name, "textureSampleCompare")) {
        if (call.args.len < 4) return error.InvalidIr;
        try write_texture_arg(module, function, call.args, 0, buf, pos);
        try write_str(buf, pos, ".sample_compare(");
        try write_expr(module, function, function.expr_args.items[call.args.start + 1], buf, pos);
        try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[call.args.start + 2], buf, pos);
        try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[call.args.start + 3], buf, pos);
        try write_str(buf, pos, ")");
        return true;
    }
    // textureSampleCompareLevel is identical but uses level(0) for LOD.
    if (std.mem.eql(u8, call.name, "textureSampleCompareLevel")) {
        if (call.args.len < 4) return error.InvalidIr;
        try write_texture_arg(module, function, call.args, 0, buf, pos);
        try write_str(buf, pos, ".sample_compare(");
        try write_expr(module, function, function.expr_args.items[call.args.start + 1], buf, pos);
        try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[call.args.start + 2], buf, pos);
        try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[call.args.start + 3], buf, pos);
        try write_str(buf, pos, ", level(0))");
        return true;
    }
    // textureLoad(t, coord, [level]) → t.read(coord, [level])
    if (std.mem.eql(u8, call.name, "textureLoad")) {
        if (call.args.len < 2) return error.InvalidIr;
        try write_texture_arg(module, function, call.args, 0, buf, pos);
        try write_str(buf, pos, ".read(");
        try write_expr_range(module, function, call.args, 1, buf, pos);
        try write_str(buf, pos, ")");
        return true;
    }
    // textureStore(t, coord, value) → t.write(value, coord)
    if (std.mem.eql(u8, call.name, "textureStore")) {
        if (call.args.len < 3) return error.InvalidIr;
        try write_texture_arg(module, function, call.args, 0, buf, pos);
        try write_str(buf, pos, ".write(");
        try write_expr(module, function, function.expr_args.items[call.args.start + 2], buf, pos);
        try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[call.args.start + 1], buf, pos);
        try write_str(buf, pos, ")");
        return true;
    }
    // textureDimensions(t) → uint2(t.get_width(), t.get_height())
    if (std.mem.eql(u8, call.name, "textureDimensions")) {
        if (call.args.len < 1) return error.InvalidIr;
        try write_str(buf, pos, "uint2(");
        try write_texture_arg(module, function, call.args, 0, buf, pos);
        try write_str(buf, pos, ".get_width(), ");
        try write_texture_arg(module, function, call.args, 0, buf, pos);
        try write_str(buf, pos, ".get_height())");
        return true;
    }
    return false;
}

// Emits the expression at args[offset] directly (no comma handling).
fn write_texture_arg(module: *const ir.Module, function: ir.Function, args: ir.Range, offset: u32, buf: []u8, pos: *usize) EmitError!void {
    try write_expr(module, function, function.expr_args.items[args.start + offset], buf, pos);
}

// Emits args[from..end] separated by commas.
fn write_expr_range(module: *const ir.Module, function: ir.Function, args: ir.Range, from: u32, buf: []u8, pos: *usize) EmitError!void {
    var i: u32 = from;
    while (i < args.len) : (i += 1) {
        if (i > from) try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[args.start + i], buf, pos);
    }
}

fn write_expr_list(module: *const ir.Module, function: ir.Function, range: ir.Range, buf: []u8, pos: *usize) EmitError!void {
    var i: u32 = 0;
    while (i < range.len) : (i += 1) {
        if (i > 0) try write_str(buf, pos, ", ");
        try write_expr(module, function, function.expr_args.items[range.start + i], buf, pos);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// Low-level write helpers
// ──────────────────────────────────────────────────────────────────────────────

pub fn write_str(buf: []u8, pos: *usize, text: []const u8) EmitError!void {
    if (pos.* + text.len > buf.len) return error.OutputTooLarge;
    @memcpy(buf[pos.* .. pos.* + text.len], text);
    pos.* += text.len;
}

pub fn write_indent(buf: []u8, pos: *usize, count: usize) EmitError!void {
    var i: usize = 0;
    while (i < count) : (i += 1) try write_str(buf, pos, " ");
}

pub fn write_u32(buf: []u8, pos: *usize, value: u32) EmitError!void {
    var tmp: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{}", .{value}) catch return error.OutputTooLarge;
    try write_str(buf, pos, text);
}

fn write_u64(buf: []u8, pos: *usize, value: u64) EmitError!void {
    var tmp: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{}", .{value}) catch return error.OutputTooLarge;
    try write_str(buf, pos, text);
}

fn write_float(buf: []u8, pos: *usize, value: f64) EmitError!void {
    var tmp: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return error.OutputTooLarge;
    try write_str(buf, pos, text);
}

// ──────────────────────────────────────────────────────────────────────────────
// Operator text tables
// ──────────────────────────────────────────────────────────────────────────────

fn unary_op_text(op: ir.UnaryOp) []const u8 {
    return switch (op) {
        .neg => "-",
        .not => "!",
        .bit_not => "~",
    };
}

fn binary_op_text(op: ir.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .rem => "%",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shift_left => "<<",
        .shift_right => ">>",
        .equal => "==",
        .not_equal => "!=",
        .less => "<",
        .less_equal => "<=",
        .greater => ">",
        .greater_equal => ">=",
        .logical_and => "&&",
        .logical_or => "||",
    };
}

fn assign_op_text(op: ir.AssignOp) []const u8 {
    return switch (op) {
        .assign => "=",
        .add => "+=",
        .sub => "-=",
        .mul => "*=",
        .div => "/=",
        .rem => "%=",
        .bit_and => "&=",
        .bit_or => "|=",
        .bit_xor => "^=",
    };
}
