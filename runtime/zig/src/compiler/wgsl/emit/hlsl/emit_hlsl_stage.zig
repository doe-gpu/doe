const ir = @import("../../ir/ir.zig");
const maps = @import("emit_hlsl_maps.zig");

const CLIP_DISTANCE_RESULT_NAME = "_doe_clip_distance";

pub fn emit_stage_function(self: anytype, function_index: ir.FunctionId) !void {
    const function = self.module.functions.items[function_index];
    const stage = function.stage orelse return error.InvalidIr;
    if (stage == .compute) return error.InvalidIr;
    // Need either scalar return with IO attr, or struct return with IO fields.
    if (function.return_io == null and !is_io_struct(self, function.return_type)) return error.InvalidIr;

    if (function.return_io != null and function.return_io.?.builtin == .clip_distances) {
        try emit_clip_distance_impl_function(self, function_index);
    } else {
        try emit_impl_function(self, function_index);
    }
    try emit_output_struct(self, function, stage);
    try emit_wrapper_function(self, function_index, stage);
}

fn is_io_struct(self: anytype, ty: ir.TypeId) bool {
    return switch (self.module.types.get(ty)) {
        .struct_ => |struct_id| {
            const struct_def = self.module.structs.items[struct_id];
            for (struct_def.fields.items) |field| {
                if (field.io != null) return true;
            }
            return false;
        },
        else => false,
    };
}

fn get_struct_def(self: anytype, ty: ir.TypeId) ?ir.StructDef {
    return switch (self.module.types.get(ty)) {
        .struct_ => |struct_id| self.module.structs.items[struct_id],
        else => null,
    };
}

fn emit_impl_function(self: anytype, function_index: ir.FunctionId) !void {
    const function = self.module.functions.items[function_index];
    try self.write("\n");
    try self.emit_type_only(function.return_type);
    try self.write(" ");
    try self.write(function.name);
    try self.write("_impl(");
    for (function.params.items, 0..) |param, index| {
        if (index > 0) try self.write(", ");
        try self.emit_typed_name(param.ty, param.name);
    }
    try self.write(") {\n");
    self.indent += 4;
    try self.emit_stmt(function, function.root_stmt);
    self.indent -= 4;
    try self.write("}\n");
}

fn emit_output_struct(self: anytype, function: ir.Function, stage: ir.ShaderStage) !void {
    try self.write("\nstruct ");
    try self.write(function.name);
    try self.write("_stage_out {\n");
    self.indent += 4;
    if (function.return_io) |io| {
        // Non-struct return: single output with semantic.
        try self.write_indent();
        if (io.builtin == .clip_distances) {
            const arr_len = switch (self.module.types.get(function.return_type)) {
                .array => |arr| arr.len orelse 8,
                else => 8,
            };
            try self.write("float value [");
            try self.write_u32(arr_len);
            try self.write("] : SV_ClipDistance;\n");
        } else {
            try self.emit_typed_name(function.return_type, "value");
            try self.write(" : ");
            try write_output_semantic(self, stage, io);
            try self.write(";\n");
        }
    } else if (get_struct_def(self, function.return_type)) |struct_def| {
        // Struct return: each field gets its own semantic.
        for (struct_def.fields.items) |field| {
            const io = field.io orelse continue;
            try self.write_indent();
            try emit_hlsl_interp_modifier(self, io);
            try self.emit_typed_name(field.ty, field.name);
            try self.write(" : ");
            try write_output_semantic(self, stage, io);
            try self.write(";\n");
        }
    }
    self.indent -= 4;
    try self.write("};\n");
}

fn emit_wrapper_function(self: anytype, function_index: ir.FunctionId, stage: ir.ShaderStage) !void {
    _ = stage;
    const function = self.module.functions.items[function_index];
    const is_struct_return = function.return_io == null and get_struct_def(self, function.return_type) != null;

    try self.write("\n");
    try self.write(function.name);
    try self.write("_stage_out ");
    try self.write(function.name);
    try self.write("(");
    var first_param = true;
    for (function.params.items) |param| {
        if (param.io) |io_attr| {
            if (maps.hlsl_intrinsic_builtin(io_attr.builtin) != null) continue;
        }
        if (get_struct_def(self, param.ty)) |struct_def| {
            // Struct-typed input: flatten fields into individual semantic parameters.
            for (struct_def.fields.items) |field| {
                const io = field.io orelse continue;
                if (maps.hlsl_intrinsic_builtin(io.builtin) != null) continue;
                if (!first_param) try self.write(", ");
                try emit_hlsl_interp_modifier(self, io);
                try self.emit_typed_name(field.ty, field.name);
                try self.write(" : ");
                try write_input_semantic(self, io);
                first_param = false;
            }
        } else {
            if (!first_param) try self.write(", ");
            if (param.io) |io_attr| {
                try emit_hlsl_interp_modifier(self, io_attr);
            }
            try self.emit_typed_name(param.ty, param.name);
            try self.write(" : ");
            try write_input_semantic(self, param.io.?);
            first_param = false;
        }
    }
    try self.write(") {\n");
    self.indent += 4;

    // Reconstruct struct parameters from flattened fields.
    for (function.params.items) |param| {
        if (get_struct_def(self, param.ty)) |struct_def| {
            try self.write_indent();
            try self.emit_type_only(param.ty);
            try self.write(" ");
            try self.write(param.name);
            try self.write(";\n");
            for (struct_def.fields.items) |field| {
                if (field.io == null) continue;
                try self.write_indent();
                try self.write(param.name);
                try self.write(".");
                try self.write(field.name);
                try self.write(" = ");
                if (maps.hlsl_intrinsic_builtin(field.io.?.builtin)) |intrinsic| {
                    try self.write(intrinsic);
                } else {
                    try self.write(field.name);
                }
                try self.write(";\n");
            }
        }
    }

    try self.write_indent();
    try self.write(function.name);
    try self.write("_stage_out out;\n");

    if (function.return_io != null and function.return_io.?.builtin == .clip_distances) {
        try self.write_indent();
        try self.write(function.name);
        try self.write("_impl(out.value, ");
        try emit_wrapper_args(self, function);
        try self.write(");\n");
    } else if (is_struct_return) {
        // Call impl, store result, then decompose struct fields to output.
        try self.write_indent();
        try self.emit_type_only(function.return_type);
        try self.write(" _result = ");
        try self.write(function.name);
        try self.write("_impl(");
        try emit_wrapper_args(self, function);
        try self.write(");\n");
        if (get_struct_def(self, function.return_type)) |struct_def| {
            for (struct_def.fields.items) |field| {
                if (field.io == null) continue;
                try self.write_indent();
                try self.write("out.");
                try self.write(field.name);
                try self.write(" = _result.");
                try self.write(field.name);
                try self.write(";\n");
            }
        }
    } else {
        try self.write_indent();
        try self.write("out.value = ");
        try self.write(function.name);
        try self.write("_impl(");
        try emit_wrapper_args(self, function);
        try self.write(");\n");
    }

    try self.write_indent();
    try self.write("return out;\n");
    self.indent -= 4;
    try self.write("}\n");
}

fn emit_wrapper_args(self: anytype, function: ir.Function) !void {
    var first_arg = true;
    for (function.params.items) |param| {
        if (!first_arg) try self.write(", ");
        if (param.io) |io_attr| {
            if (maps.hlsl_intrinsic_builtin(io_attr.builtin)) |intrinsic| {
                try self.write(intrinsic);
                first_arg = false;
                continue;
            }
        }
        try self.write(param.name);
        first_arg = false;
    }
}

fn emit_clip_distance_impl_function(self: anytype, function_index: ir.FunctionId) !void {
    const function = self.module.functions.items[function_index];
    const return_array = switch (self.module.types.get(function.return_type)) {
        .array => |arr| arr,
        else => return error.InvalidIr,
    };
    if (return_array.len == null) return error.InvalidIr;

    try self.write("\nvoid ");
    try self.write(function.name);
    try self.write("_impl(out ");
    try self.emit_typed_name(function.return_type, CLIP_DISTANCE_RESULT_NAME);
    for (function.params.items) |param| {
        try self.write(", ");
        try self.emit_typed_name(param.ty, param.name);
    }
    try self.write(") {\n");
    self.indent += 4;
    try emit_clip_distance_stmt(self, function, function.root_stmt, CLIP_DISTANCE_RESULT_NAME, return_array.len.?);
    self.indent -= 4;
    try self.write("}\n");
}

fn emit_clip_distance_stmt(self: anytype, function: ir.Function, stmt_id: ir.StmtId, result_name: []const u8, result_len: u32) !void {
    const stmt = function.stmts.items[stmt_id];
    switch (stmt) {
        .block => |range| {
            var i: u32 = 0;
            while (i < range.len) : (i += 1) {
                try emit_clip_distance_stmt(self, function, function.stmt_children.items[range.start + i], result_name, result_len);
            }
        },
        .local_decl => |decl| {
            const local = function.locals.items[decl.local];
            try self.write_indent();
            if (decl.is_const) try self.write("const ");
            try self.emit_typed_name(local.ty, local.name);
            if (decl.initializer) |expr_id| {
                try self.write(" = ");
                try self.emit_expr(function, expr_id);
            }
            try self.write(";\n");
        },
        .expr => |expr_id| {
            try self.write_indent();
            try self.emit_expr(function, expr_id);
            try self.write(";\n");
        },
        .assign => |assign| {
            try self.write_indent();
            try self.emit_expr(function, assign.lhs);
            try self.write(" ");
            try self.write(maps.assign_op_text(assign.op));
            try self.write(" ");
            try self.emit_expr(function, assign.rhs);
            try self.write(";\n");
        },
        .return_ => |value| {
            if (value) |expr_id| {
                var index: u32 = 0;
                while (index < result_len) : (index += 1) {
                    try self.write_indent();
                    try self.write(result_name);
                    try self.write("[");
                    try self.write_u32(index);
                    try self.write("] = ");
                    try emit_clip_distance_element_expr(self, function, expr_id, index);
                    try self.write(";\n");
                }
            }
            try self.write_indent();
            try self.write("return;\n");
        },
        .if_ => |if_stmt| {
            try self.write_indent();
            try self.write("if (");
            try self.emit_expr(function, if_stmt.cond);
            try self.write(") {\n");
            self.indent += 4;
            try emit_clip_distance_stmt(self, function, if_stmt.then_block, result_name, result_len);
            self.indent -= 4;
            try self.write_indent();
            try self.write("}");
            if (if_stmt.else_block) |else_block| {
                try self.write(" else {\n");
                self.indent += 4;
                try emit_clip_distance_stmt(self, function, else_block, result_name, result_len);
                self.indent -= 4;
                try self.write_indent();
                try self.write("}\n");
            } else {
                try self.write("\n");
            }
        },
        .loop_ => |loop_stmt| {
            if (loop_stmt.init) |init_stmt| try emit_clip_distance_stmt(self, function, init_stmt, result_name, result_len);
            try self.write_indent();
            try self.write("while (");
            if (loop_stmt.cond) |cond| {
                try self.emit_expr(function, cond);
            } else {
                try self.write("true");
            }
            try self.write(") {\n");
            self.indent += 4;
            try emit_clip_distance_stmt(self, function, loop_stmt.body, result_name, result_len);
            if (loop_stmt.continuing) |continuing| try emit_clip_distance_stmt(self, function, continuing, result_name, result_len);
            self.indent -= 4;
            try self.write_indent();
            try self.write("}\n");
        },
        .switch_ => |switch_stmt| {
            try self.write_indent();
            try self.write("switch (");
            try self.emit_expr(function, switch_stmt.expr);
            try self.write(") {\n");
            self.indent += 4;
            var case_index: u32 = 0;
            while (case_index < switch_stmt.cases.len) : (case_index += 1) {
                const case_node = function.switch_cases.items[switch_stmt.cases.start + case_index];
                if (case_node.is_default) {
                    try self.write_indent();
                    try self.write("default:\n");
                } else {
                    var selector_index: usize = 0;
                    while (selector_index < case_node.selectors.items.len) : (selector_index += 1) {
                        try self.write_indent();
                        try self.write("case ");
                        try self.emit_expr(function, case_node.selectors.items[selector_index]);
                        try self.write(":\n");
                    }
                }
                self.indent += 4;
                try emit_clip_distance_stmt(self, function, case_node.body, result_name, result_len);
                try self.write_indent();
                try self.write("break;\n");
                self.indent -= 4;
            }
            self.indent -= 4;
            try self.write_indent();
            try self.write("}\n");
        },
        .break_ => {
            try self.write_indent();
            try self.write("break;\n");
        },
        .continue_ => {
            try self.write_indent();
            try self.write("continue;\n");
        },
        .discard_ => {
            try self.write_indent();
            try self.write("discard;\n");
        },
    }
}

fn emit_clip_distance_element_expr(self: anytype, function: ir.Function, expr_id: ir.ExprId, index: u32) !void {
    const expr = function.exprs.items[expr_id];
    switch (expr.data) {
        .construct => |construct| {
            if (construct.args.len <= index) return error.InvalidIr;
            try self.emit_expr(function, function.expr_args.items[construct.args.start + index]);
        },
        else => {
            try self.emit_expr(function, expr_id);
            try self.write("[");
            try self.write_u32(index);
            try self.write("]");
        },
    }
}

/// Emit HLSL interpolation modifier prefix for an IO field. Emits nothing for
/// the default (perspective, center). Builtins skip interpolation modifiers.
fn emit_hlsl_interp_modifier(self: anytype, io: ir.IoAttr) !void {
    if (io.builtin != .none) return;
    const interp = io.interpolation orelse return;
    switch (interp) {
        .flat => try self.write("nointerpolation "),
        .linear => {
            const sampling = io.sampling orelse .center;
            switch (sampling) {
                .center => try self.write("noperspective "),
                .centroid => try self.write("noperspective centroid "),
                .sample => try self.write("noperspective sample "),
            }
        },
        .perspective => {
            const sampling = io.sampling orelse .center;
            switch (sampling) {
                .center => {},
                .centroid => try self.write("centroid "),
                .sample => try self.write("sample "),
            }
        },
    }
}

fn write_input_semantic(self: anytype, io: ir.IoAttr) !void {
    if (io.location) |loc| {
        try self.write("TEXCOORD");
        try self.write_u32(loc);
        return;
    }
    if (!maps.hlsl_builtin_has_semantic(io.builtin)) return error.UnsupportedBuiltin;
    try self.write(maps.hlsl_builtin_name(io.builtin));
}

fn write_output_semantic(self: anytype, stage: ir.ShaderStage, io: ir.IoAttr) !void {
    if (io.blend_src) |src_index| {
        // Dual-source blending: both sources target SV_Target0
        _ = src_index;
        try self.write("SV_Target0");
        return;
    }
    if (io.location) |loc| {
        try self.write(if (stage == .fragment) "SV_Target" else "TEXCOORD");
        try self.write_u32(loc);
        return;
    }
    if (!maps.hlsl_builtin_has_semantic(io.builtin)) return error.UnsupportedBuiltin;
    try self.write(maps.hlsl_builtin_name(io.builtin));
}
