const std = @import("std");
const ir = @import("../../ir/ir.zig");
const ir_query = @import("../../ir/ir_query.zig");
const maps = @import("emit_hlsl_maps.zig");

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
};

/// Try to emit an HLSL texture builtin call. Returns true if the call was
/// handled, false if it is not a texture builtin and the caller should
/// continue matching other builtins.
pub fn emit_texture_builtin(
    module: *const ir.Module,
    buf: []u8,
    pos: *usize,
    function: ir.Function,
    call_name: []const u8,
    args: ir.Range,
) EmitError!bool {
    var ctx = WriteCtx{ .module = module, .buf = buf, .pos = pos };

    if (std.mem.eql(u8, call_name, "textureLoad")) {
        if (args.len < 2 or args.len > 3) return error.InvalidIr;
        const texture_expr = function.expr_args.items[args.start];
        const coord_expr = function.expr_args.items[args.start + 1];
        const is_storage_texture = switch (module.types.get(function.exprs.items[texture_expr].ty)) {
            .storage_texture_2d => true,
            else => false,
        };
        if (is_storage_texture) {
            if (args.len != 2) return error.InvalidIr;
            if (texture_global_name(module, function, texture_expr)) |global_name| {
                try ctx.write("((all(int2(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write(") >= int2(0, 0)) && all(uint2(int2(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write(")) < doe_textureDimensions_");
                try ctx.write(global_name);
                try ctx.write("())) ? ");
                try ctx.emit_expr(function, texture_expr);
                try ctx.write(".Load(int3(int2(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write("), 0)) : float4(0.0, 0.0, 0.0, 0.0))");
            } else {
                try ctx.emit_expr(function, texture_expr);
                try ctx.write(".Load(int3(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write(", 0))");
            }
            return true;
        }
        if (args.len != 3) return error.InvalidIr;
        const level_expr = function.expr_args.items[args.start + 2];
        if (texture_global_name(module, function, texture_expr)) |global_name| {
            if (ir_query.exprIsTexture1D(module, &function, texture_expr)) {
                // 1D texture: scalar coord, Load takes int2(coord, level)
                try ctx.write("((int(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write(") >= 0 && uint(int(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write(")) < doe_textureDimensions_");
                try ctx.write(global_name);
                try ctx.write("(uint(");
                try ctx.emit_expr(function, level_expr);
                try ctx.write("))) ? ");
                try ctx.emit_expr(function, texture_expr);
                try ctx.write(".Load(int2(int(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write("), int(");
                try ctx.emit_expr(function, level_expr);
                try ctx.write("))) : float4(0.0, 0.0, 0.0, 0.0))");
            } else {
                try ctx.write("((all(int2(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write(") >= int2(0, 0)) && all(uint2(int2(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write(")) < doe_textureDimensions_");
                try ctx.write(global_name);
                try ctx.write("(uint(");
                try ctx.emit_expr(function, level_expr);
                try ctx.write(")))) ? ");
                try ctx.emit_expr(function, texture_expr);
                try ctx.write(".Load(int3(int2(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write("), int(");
                try ctx.emit_expr(function, level_expr);
                try ctx.write("))) : float4(0.0, 0.0, 0.0, 0.0))");
            }
        } else {
            if (ir_query.exprIsTexture1D(module, &function, texture_expr)) {
                try ctx.emit_expr(function, texture_expr);
                try ctx.write(".Load(int2(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write(", ");
                try ctx.emit_expr(function, level_expr);
                try ctx.write("))");
            } else {
                try ctx.emit_expr(function, texture_expr);
                try ctx.write(".Load(int3(");
                try ctx.emit_expr(function, coord_expr);
                try ctx.write(", ");
                try ctx.emit_expr(function, level_expr);
                try ctx.write("))");
            }
        }
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureSample")) {
        if (args.len != 3) return error.InvalidIr;
        try ctx.emit_expr(function, function.expr_args.items[args.start]);
        try ctx.write(".Sample(");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 1]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 2]);
        try ctx.write(")");
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureSampleLevel")) {
        if (args.len != 4) return error.InvalidIr;
        try ctx.emit_expr(function, function.expr_args.items[args.start]);
        try ctx.write(".SampleLevel(");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 1]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 2]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 3]);
        try ctx.write(")");
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureSampleCompare")) {
        if (args.len != 4) return error.InvalidIr;
        try ctx.emit_expr(function, function.expr_args.items[args.start]);
        try ctx.write(".SampleCmp(");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 1]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 2]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 3]);
        try ctx.write(")");
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureSampleCompareLevel")) {
        if (args.len != 4) return error.InvalidIr;
        try ctx.emit_expr(function, function.expr_args.items[args.start]);
        try ctx.write(".SampleCmpLevelZero(");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 1]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 2]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 3]);
        try ctx.write(")");
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureGather")) {
        if (args.len != 4) return error.InvalidIr;
        try ctx.emit_expr(function, function.expr_args.items[args.start + 1]);
        try ctx.write(".GatherRed(");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 2]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 3]);
        try ctx.write(")");
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureGatherCompare")) {
        if (args.len != 4) return error.InvalidIr;
        try ctx.emit_expr(function, function.expr_args.items[args.start]);
        try ctx.write(".GatherCmp(");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 1]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 2]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 3]);
        try ctx.write(")");
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureSampleGrad")) {
        if (args.len != 5) return error.InvalidIr;
        try ctx.emit_expr(function, function.expr_args.items[args.start]);
        try ctx.write(".SampleGrad(");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 1]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 2]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 3]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 4]);
        try ctx.write(")");
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureSampleOffset")) {
        if (args.len != 4) return error.InvalidIr;
        try ctx.emit_expr(function, function.expr_args.items[args.start]);
        try ctx.write(".Sample(");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 1]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 2]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 3]);
        try ctx.write(")");
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureSampleLevelOffset")) {
        if (args.len != 5) return error.InvalidIr;
        try ctx.emit_expr(function, function.expr_args.items[args.start]);
        try ctx.write(".SampleLevel(");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 1]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 2]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 3]);
        try ctx.write(", ");
        try ctx.emit_expr(function, function.expr_args.items[args.start + 4]);
        try ctx.write(")");
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureStore")) {
        if (args.len != 3) return error.InvalidIr;
        const texture_expr = function.expr_args.items[args.start];
        const coord_expr = function.expr_args.items[args.start + 1];
        const value_expr = function.expr_args.items[args.start + 2];
        if (texture_global_name(module, function, texture_expr)) |global_name| {
            try ctx.write("((all(int2(");
            try ctx.emit_expr(function, coord_expr);
            try ctx.write(") >= int2(0, 0)) && all(uint2(int2(");
            try ctx.emit_expr(function, coord_expr);
            try ctx.write(")) < doe_textureDimensions_");
            try ctx.write(global_name);
            try ctx.write("())) ? (");
            try ctx.emit_expr(function, texture_expr);
            try ctx.write("[uint2(int2(");
            try ctx.emit_expr(function, coord_expr);
            try ctx.write("))] = ");
            try ctx.emit_expr(function, value_expr);
            try ctx.write(", 0) : 0)");
        } else {
            try ctx.emit_expr(function, texture_expr);
            try ctx.write("[");
            try ctx.emit_expr(function, coord_expr);
            try ctx.write("] = ");
            try ctx.emit_expr(function, value_expr);
        }
        return true;
    }
    if (std.mem.eql(u8, call_name, "textureDimensions")) {
        if (args.len < 1 or args.len > 2) return error.InvalidIr;
        const target_expr = function.expr_args.items[args.start];
        switch (function.exprs.items[target_expr].data) {
            .global_ref => |index| {
                const global = module.globals.items[index];
                try ctx.write("doe_textureDimensions_");
                try ctx.write(global.name);
                switch (module.types.get(global.ty)) {
                    .texture_1d, .texture_2d, .texture_cube, .texture_depth_cube, .texture_2d_array, .texture_3d => {
                        if (args.len != 2) return error.InvalidIr;
                        try ctx.write("(uint(");
                        try ctx.emit_expr(function, function.expr_args.items[args.start + 1]);
                        try ctx.write("))");
                        return true;
                    },
                    .storage_texture_2d => {
                        if (args.len != 1) return error.InvalidIr;
                        try ctx.write("()");
                        return true;
                    },
                    else => return error.InvalidIr,
                }
            },
            else => return error.InvalidIr,
        }
    }
    if (std.mem.eql(u8, call_name, "textureNumLevels")) {
        if (args.len != 1) return error.InvalidIr;
        const target_expr = function.expr_args.items[args.start];
        switch (function.exprs.items[target_expr].data) {
            .global_ref => |index| {
                const global = module.globals.items[index];
                try ctx.write("doe_textureNumLevels_");
                try ctx.write(global.name);
                try ctx.write("()");
                return true;
            },
            else => return error.InvalidIr,
        }
    }
    if (std.mem.eql(u8, call_name, "textureNumLayers")) {
        if (args.len != 1) return error.InvalidIr;
        const target_expr = function.expr_args.items[args.start];
        switch (function.exprs.items[target_expr].data) {
            .global_ref => |index| {
                const global = module.globals.items[index];
                try ctx.write("doe_textureNumLayers_");
                try ctx.write(global.name);
                try ctx.write("()");
                return true;
            },
            else => return error.InvalidIr,
        }
    }
    return false;
}

/// Lightweight write context that shares the Emitter's buffer and position.
const WriteCtx = struct {
    module: *const ir.Module,
    buf: []u8,
    pos: *usize,

    fn write(self: *WriteCtx, text: []const u8) EmitError!void {
        if (self.pos.* + text.len > self.buf.len) return error.OutputTooLarge;
        @memcpy(self.buf[self.pos.* .. self.pos.* + text.len], text);
        self.pos.* += text.len;
    }

    fn emit_expr(self: *WriteCtx, function: ir.Function, expr_id: ir.ExprId) EmitError!void {
        const expr = function.exprs.items[expr_id];
        switch (expr.data) {
            .int_lit => |value| {
                var buf_local: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&buf_local, "{}", .{value}) catch return error.OutputTooLarge;
                try self.write(text);
            },
            .float_lit => |value| {
                var buf_local: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf_local, "{d}", .{value}) catch return error.OutputTooLarge;
                try self.write(text);
                if (std.mem.indexOfScalar(u8, text, '.') == null and std.mem.indexOfAny(u8, text, "eE") == null) {
                    try self.write(".0");
                }
            },
            .param_ref => |index| {
                const param = function.params.items[index];
                if (param.io) |io_attr| {
                    if (maps.hlsl_intrinsic_builtin(io_attr.builtin)) |intrinsic| {
                        try self.write(intrinsic);
                        return;
                    }
                }
                try self.write(param.name);
            },
            .global_ref => |index| try self.write(self.module.globals.items[index].name),
            .local_ref => |index| try self.write(function.locals.items[index].name),
            .load => |inner| try self.emit_expr(function, inner),
            .call => |call| {
                try self.write(call.name);
                try self.write("(");
                var i: u32 = 0;
                while (i < call.args.len) : (i += 1) {
                    if (i > 0) try self.write(", ");
                    try self.emit_expr(function, function.expr_args.items[call.args.start + i]);
                }
                try self.write(")");
            },
            .member => |member| {
                try self.emit_expr(function, member.base);
                try self.write(".");
                try self.write(member.field_name);
            },
            .binary => |binary| {
                try self.write("(");
                try self.emit_expr(function, binary.lhs);
                try self.write(" ");
                try self.write(maps.binary_op_text(binary.op));
                try self.write(" ");
                try self.emit_expr(function, binary.rhs);
                try self.write(")");
            },
            .construct => |construct| {
                const module = self.module;
                switch (module.types.get(construct.ty)) {
                    .vector => |vec| {
                        const prefix = switch (module.types.get(vec.elem)) {
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
                        try self.write(prefix);
                        var buf_local: [32]u8 = undefined;
                        const len_text = std.fmt.bufPrint(&buf_local, "{}", .{vec.len}) catch return error.OutputTooLarge;
                        try self.write(len_text);
                    },
                    else => return error.InvalidIr,
                }
                try self.write("(");
                var i: u32 = 0;
                while (i < construct.args.len) : (i += 1) {
                    if (i > 0) try self.write(", ");
                    try self.emit_expr(function, function.expr_args.items[construct.args.start + i]);
                }
                try self.write(")");
            },
            .index => |index| {
                try self.emit_expr(function, index.base);
                try self.write("[");
                try self.emit_expr(function, index.index);
                try self.write("]");
            },
            else => return error.InvalidIr,
        }
    }
};

fn texture_global_name(module: *const ir.Module, function: ir.Function, expr_id: ir.ExprId) ?[]const u8 {
    return switch (function.exprs.items[expr_id].data) {
        .global_ref => |index| module.globals.items[index].name,
        else => null,
    };
}

/// Emit HLSL helper functions for texture metadata intrinsics (GetDimensions,
/// numLevels, numLayers) for all bound texture globals.
pub fn emit_texture_global_helpers(
    module: *const ir.Module,
    buf: []u8,
    pos: *usize,
) EmitError!void {
    var ctx = HelperCtx{ .buf = buf, .pos = pos };
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        switch (module.types.get(global.ty)) {
            .texture_1d => {
                try ctx.emit_dims_1d(global.name);
                try ctx.emit_num_levels(global.name, false, false, true);
            },
            .texture_2d, .texture_cube, .texture_depth_cube => {
                try ctx.emit_dims_2d(global.name);
                try ctx.emit_num_levels(global.name, false, false, false);
            },
            .texture_2d_array => {
                try ctx.emit_dims_2d_array(global.name);
                try ctx.emit_num_levels(global.name, true, false, false);
                try ctx.emit_num_layers(global.name);
            },
            .texture_3d => {
                try ctx.emit_dims_3d(global.name);
                try ctx.emit_num_levels(global.name, false, true, false);
            },
            .storage_texture_2d => {
                try ctx.emit_dims_storage(global.name);
            },
            else => {},
        }
    }
}

const HelperCtx = struct {
    buf: []u8,
    pos: *usize,

    fn w(self: *HelperCtx, text: []const u8) EmitError!void {
        if (self.pos.* + text.len > self.buf.len) return error.OutputTooLarge;
        @memcpy(self.buf[self.pos.* .. self.pos.* + text.len], text);
        self.pos.* += text.len;
    }

    fn emit_dims_1d(self: *HelperCtx, name: []const u8) EmitError!void {
        try self.w("\nuint doe_textureDimensions_");
        try self.w(name);
        try self.w("(uint level) {\n    uint w = 0u; uint lvls = 0u;\n    ");
        try self.w(name);
        try self.w(".GetDimensions(level, w, lvls);\n    return w;\n}\n");
    }

    fn emit_dims_2d(self: *HelperCtx, name: []const u8) EmitError!void {
        try self.w("\nuint2 doe_textureDimensions_");
        try self.w(name);
        try self.w("(uint level) {\n    uint w = 0u; uint h = 0u; uint lvls = 0u;\n    ");
        try self.w(name);
        try self.w(".GetDimensions(level, w, h, lvls);\n    return uint2(w, h);\n}\n");
    }

    fn emit_dims_2d_array(self: *HelperCtx, name: []const u8) EmitError!void {
        try self.w("\nuint2 doe_textureDimensions_");
        try self.w(name);
        try self.w("(uint level) {\n    uint w = 0u; uint h = 0u; uint elems = 0u; uint lvls = 0u;\n    ");
        try self.w(name);
        try self.w(".GetDimensions(level, w, h, elems, lvls);\n    return uint2(w, h);\n}\n");
    }

    fn emit_dims_3d(self: *HelperCtx, name: []const u8) EmitError!void {
        try self.w("\nuint3 doe_textureDimensions_");
        try self.w(name);
        try self.w("(uint level) {\n    uint w = 0u; uint h = 0u; uint d = 0u; uint lvls = 0u;\n    ");
        try self.w(name);
        try self.w(".GetDimensions(level, w, h, d, lvls);\n    return uint3(w, h, d);\n}\n");
    }

    fn emit_dims_storage(self: *HelperCtx, name: []const u8) EmitError!void {
        try self.w("\nuint2 doe_textureDimensions_");
        try self.w(name);
        try self.w("() {\n    uint w = 0u; uint h = 0u;\n    ");
        try self.w(name);
        try self.w(".GetDimensions(w, h);\n    return uint2(w, h);\n}\n");
    }

    fn emit_num_levels(self: *HelperCtx, name: []const u8, is_array: bool, is_3d: bool, is_1d: bool) EmitError!void {
        try self.w("\nuint doe_textureNumLevels_");
        try self.w(name);
        if (is_3d) {
            try self.w("() {\n    uint w = 0u; uint h = 0u; uint d = 0u; uint lvls = 0u;\n    ");
            try self.w(name);
            try self.w(".GetDimensions(0, w, h, d, lvls);\n");
        } else if (is_array) {
            try self.w("() {\n    uint w = 0u; uint h = 0u; uint elems = 0u; uint lvls = 0u;\n    ");
            try self.w(name);
            try self.w(".GetDimensions(0, w, h, elems, lvls);\n");
        } else if (is_1d) {
            try self.w("() {\n    uint w = 0u; uint lvls = 0u;\n    ");
            try self.w(name);
            try self.w(".GetDimensions(0, w, lvls);\n");
        } else {
            try self.w("() {\n    uint w = 0u; uint h = 0u; uint lvls = 0u;\n    ");
            try self.w(name);
            try self.w(".GetDimensions(0, w, h, lvls);\n");
        }
        try self.w("    return lvls;\n}\n");
    }

    fn emit_num_layers(self: *HelperCtx, name: []const u8) EmitError!void {
        try self.w("\nuint doe_textureNumLayers_");
        try self.w(name);
        try self.w("() {\n    uint w = 0u; uint h = 0u; uint elems = 0u; uint lvls = 0u;\n    ");
        try self.w(name);
        try self.w(".GetDimensions(0, w, h, elems, lvls);\n    return elems;\n}\n");
    }
};
