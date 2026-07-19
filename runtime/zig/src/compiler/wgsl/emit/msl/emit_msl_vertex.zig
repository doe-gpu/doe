// doe_wgsl/emit_msl_vertex.zig — MSL vertex stage emitter.
//
// Vertex shaders in Metal require:
// - [[vertex]] qualifier on the function
// - Vertex inputs as function parameters with [[attribute(N)]] or [[vertex_id]]/[[instance_id]]
// - A return struct containing [[position]] and inter-stage varyings with [[user(locN)]]
// - Bound globals (uniforms, textures, samplers) injected as parameters
//
// Structs used as vertex input or output already have IoAttr on their fields; we emit
// the correct Metal attribute for each field when generating parameter and return types.

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const emit_msl_shared = @import("emit_msl_shared.zig");

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    UnsupportedBuiltin,
};

pub fn emit_vertex_function(
    module: *const ir.Module,
    function: ir.Function,
    buf: []u8,
    pos: *usize,
    indent: *usize,
) EmitError!void {
    var ctx = VertexEmitter{
        .module = module,
        .function = function,
        .buf = buf,
        .pos = pos,
        .indent = indent,
    };
    try ctx.emit();
}

const VertexEmitter = struct {
    module: *const ir.Module,
    function: ir.Function,
    buf: []u8,
    pos: *usize,
    indent: *usize,

    fn emit(self: *VertexEmitter) EmitError!void {
        try self.emit_output_struct_if_needed();
        try self.write("\n[[vertex]]\n");
        try self.emit_return_type();
        try self.write(" ");
        try self.write(emit_msl_shared.vertex_function_name(self.function.name));
        try self.write("(");
        try self.emit_params();
        try self.write(") {\n");
        self.indent.* += 4;
        try self.emit_stmt(self.function.root_stmt);
        self.indent.* -= 4;
        try self.write("}\n");
    }

    // When the return type is a struct containing location-decorated fields, we need to
    // verify it already has [[position]] and [[user(locN)]] attributes. Metal accepts
    // the struct as-is if the struct definition was already emitted with those attributes.
    // We re-emit the struct with Metal vertex output attributes here, prefixed with
    // the function name to avoid collision.
    fn emit_output_struct_if_needed(self: *VertexEmitter) EmitError!void {
        const ret_ty = self.module.types.get(self.function.return_type);
        switch (ret_ty) {
            .struct_ => |struct_id| {
                const struct_def = self.module.structs.items[struct_id];
                // Emit a Metal-annotated output struct for vertex stage.
                try self.write("\nstruct ");
                try self.write(struct_def.name);
                try self.write("_vertex_out {\n");
                self.indent.* += 4;
                for (struct_def.fields.items) |field| {
                    try self.write_indent();
                    try self.emit_field_type(field.ty);
                    try self.write(" ");
                    try self.write(field.name);
                    if (field.io) |io| {
                        try self.write(" ");
                        try self.emit_vertex_out_attr(io);
                    }
                    try self.write(";\n");
                }
                self.indent.* -= 4;
                try self.write("};\n");
            },
            .scalar => |scalar| {
                // void return is only valid for non-entry-point functions; a vertex entry
                // point must output at least [[position]].
                if (scalar == .void) return error.InvalidIr;
            },
            else => {},
        }
    }

    fn emit_return_type(self: *VertexEmitter) EmitError!void {
        const ret_ty = self.module.types.get(self.function.return_type);
        switch (ret_ty) {
            .struct_ => |struct_id| {
                const struct_def = self.module.structs.items[struct_id];
                try self.write(struct_def.name);
                try self.write("_vertex_out");
            },
            else => try emit_msl_shared.write_type(self.module, self.function.return_type, self.buf, self.pos),
        }
    }

    fn emit_params(self: *VertexEmitter) EmitError!void {
        var need_comma = false;
        // Inject bound globals (uniforms, textures, samplers) first.
        for (self.module.globals.items) |global| {
            if (global.binding == null) continue;
            if (need_comma) try self.write(", ");
            try emit_msl_shared.write_bound_global_param(self.module, global, self.buf, self.pos);
            need_comma = true;
        }
        // Vertex input parameters.
        for (self.function.params.items) |param| {
            if (need_comma) try self.write(", ");
            try self.emit_vertex_param(param);
            need_comma = true;
        }
    }

    fn emit_vertex_param(self: *VertexEmitter, param: ir.Param) EmitError!void {
        const ty = self.module.types.get(param.ty);
        switch (ty) {
            .struct_ => |struct_id| {
                // Struct vertex input: emit the struct directly; each field carries [[attribute(N)]].
                const struct_def = self.module.structs.items[struct_id];
                try self.write(struct_def.name);
                try self.write(" ");
                try self.write(param.name);
                try self.write(" [[stage_in]]");
            },
            else => {
                // Scalar/vector vertex input with explicit io attribute.
                try emit_msl_shared.write_type(self.module, param.ty, self.buf, self.pos);
                try self.write(" ");
                try self.write(param.name);
                if (param.io) |io| {
                    try self.write(" ");
                    try self.emit_vertex_in_attr(io);
                }
            },
        }
    }

    fn emit_vertex_in_attr(self: *VertexEmitter, io: ir.IoAttr) EmitError!void {
        if (io.builtin != .none) {
            try self.write("[[");
            try self.write(try vertex_input_builtin_attr(io.builtin));
            try self.write("]]");
        } else if (io.location) |loc| {
            try self.write("[[attribute(");
            try self.write_u32(loc);
            try self.write(")]]");
        }
    }

    fn emit_vertex_out_attr(self: *VertexEmitter, io: ir.IoAttr) EmitError!void {
        if (io.builtin == .position) {
            if (io.invariant) {
                try self.write("[[position, invariant]]");
            } else {
                try self.write("[[position]]");
            }
        } else if (io.location) |loc| {
            try self.write("[[user(loc");
            try self.write_u32(loc);
            try self.write(")]]");
            if (io.interpolation) |interp| {
                switch (interp) {
                    .flat => try self.write(" [[flat]]"),
                    .linear => {
                        const sampling = io.sampling orelse .center;
                        try self.write(switch (sampling) {
                            .center => " [[center_no_perspective]]",
                            .centroid => " [[centroid_no_perspective]]",
                            .sample => " [[sample_no_perspective]]",
                        });
                    },
                    .perspective => {
                        const sampling = io.sampling orelse .center;
                        switch (sampling) {
                            .center => {},
                            .centroid => try self.write(" [[centroid_perspective]]"),
                            .sample => try self.write(" [[sample_perspective]]"),
                        }
                    },
                }
            }
        }
    }

    fn emit_field_type(self: *VertexEmitter, ty: ir.TypeId) EmitError!void {
        try emit_msl_shared.write_type(self.module, ty, self.buf, self.pos);
    }

    // Statement emission delegates to shared helpers.
    fn emit_stmt(self: *VertexEmitter, stmt_id: ir.StmtId) EmitError!void {
        try emit_msl_shared.write_stmt(self.module, self.function, stmt_id, self.buf, self.pos, self.indent);
    }

    fn write(self: *VertexEmitter, text: []const u8) EmitError!void {
        if (self.pos.* + text.len > self.buf.len) return error.OutputTooLarge;
        @memcpy(self.buf[self.pos.* .. self.pos.* + text.len], text);
        self.pos.* += text.len;
    }

    fn write_indent(self: *VertexEmitter) EmitError!void {
        var i: usize = 0;
        while (i < self.indent.*) : (i += 1) try self.write(" ");
    }

    fn write_u32(self: *VertexEmitter, value: u32) EmitError!void {
        var tmp: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, "{}", .{value}) catch return error.OutputTooLarge;
        try self.write(text);
    }
};

fn vertex_input_builtin_attr(builtin: ir.Builtin) EmitError![]const u8 {
    return switch (builtin) {
        .vertex_index => "vertex_id",
        .instance_index => "instance_id",
        else => error.UnsupportedBuiltin,
    };
}
