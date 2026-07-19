// doe_wgsl/emit_msl_fragment.zig — MSL fragment stage emitter.
//
// Fragment shaders in Metal require:
// - [[fragment]] qualifier on the function
// - Fragment inputs as function parameters annotated with [[stage_in]] (for varyings)
//   or individual builtins: [[position]], [[front_facing]], [[sample_id]], [[sample_mask]]
// - Return type annotated for MRT: single color target uses [[color(0)]]; struct fields
//   use [[color(N)]] per location. [[depth(any)]] for frag_depth output.
//
// Output struct: when the return type is a struct, we emit a Metal-annotated variant with
// [[color(N)]] on each @location(N) field and [[depth(any)]] on @builtin(frag_depth).

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const emit_msl_shared = @import("emit_msl_shared.zig");

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    UnsupportedBuiltin,
};

pub fn emit_fragment_function(
    module: *const ir.Module,
    function: ir.Function,
    buf: []u8,
    pos: *usize,
    indent: *usize,
) EmitError!void {
    var ctx = FragmentEmitter{
        .module = module,
        .function = function,
        .buf = buf,
        .pos = pos,
        .indent = indent,
    };
    try ctx.emit();
}

const FragmentEmitter = struct {
    module: *const ir.Module,
    function: ir.Function,
    buf: []u8,
    pos: *usize,
    indent: *usize,

    fn emit(self: *FragmentEmitter) EmitError!void {
        try self.emit_output_struct_if_needed();
        try self.write("\n[[fragment]]\n");
        try self.emit_return_type();
        try self.write(" ");
        try self.write(emit_msl_shared.fragment_function_name(self.function.name));
        try self.write("(");
        try self.emit_params();
        try self.write(") {\n");
        self.indent.* += 4;
        try self.emit_stmt(self.function.root_stmt);
        self.indent.* -= 4;
        try self.write("}\n");
    }

    fn emit_output_struct_if_needed(self: *FragmentEmitter) EmitError!void {
        const ret_ty = self.module.types.get(self.function.return_type);
        switch (ret_ty) {
            .struct_ => |struct_id| {
                const struct_def = self.module.structs.items[struct_id];
                try self.write("\nstruct ");
                try self.write(struct_def.name);
                try self.write("_fragment_out {\n");
                self.indent.* += 4;
                for (struct_def.fields.items) |field| {
                    try self.write_indent();
                    try self.emit_field_type(field.ty);
                    try self.write(" ");
                    try self.write(field.name);
                    if (field.io) |io| {
                        try self.write(" ");
                        try self.emit_fragment_out_attr(io);
                    }
                    try self.write(";\n");
                }
                self.indent.* -= 4;
                try self.write("};\n");
            },
            .scalar => |scalar| {
                // void return only valid for discard-only shaders; Metal requires a return type.
                if (scalar == .void) return error.InvalidIr;
            },
            else => {},
        }
    }

    fn emit_return_type(self: *FragmentEmitter) EmitError!void {
        const ret_ty = self.module.types.get(self.function.return_type);
        switch (ret_ty) {
            .struct_ => |struct_id| {
                const struct_def = self.module.structs.items[struct_id];
                try self.write(struct_def.name);
                try self.write("_fragment_out");
            },
            else => {
                // Single-target fragment: annotate the scalar/vector return.
                try emit_msl_shared.write_type(self.module, self.function.return_type, self.buf, self.pos);
            },
        }
    }

    fn emit_params(self: *FragmentEmitter) EmitError!void {
        var need_comma = false;
        // Inject bound globals.
        for (self.module.globals.items) |global| {
            if (global.binding == null) continue;
            if (need_comma) try self.write(", ");
            try emit_msl_shared.write_bound_global_param(self.module, global, self.buf, self.pos);
            need_comma = true;
        }
        // Fragment stage input parameters.
        for (self.function.params.items) |param| {
            if (need_comma) try self.write(", ");
            try self.emit_fragment_param(param);
            need_comma = true;
        }
    }

    fn emit_fragment_param(self: *FragmentEmitter, param: ir.Param) EmitError!void {
        const ty = self.module.types.get(param.ty);
        switch (ty) {
            .struct_ => |struct_id| {
                // Struct fragment input: [[stage_in]] carries varyings from vertex stage.
                const struct_def = self.module.structs.items[struct_id];
                try self.write(struct_def.name);
                try self.write("_vertex_out ");
                try self.write(param.name);
                try self.write(" [[stage_in]]");
            },
            else => {
                // Scalar/vector input with builtin or location attribute.
                try emit_msl_shared.write_type(self.module, param.ty, self.buf, self.pos);
                try self.write(" ");
                try self.write(param.name);
                if (param.io) |io| {
                    try self.write(" ");
                    try self.emit_fragment_in_attr(io);
                }
            },
        }
    }

    fn emit_fragment_in_attr(self: *FragmentEmitter, io: ir.IoAttr) EmitError!void {
        if (io.builtin != .none) {
            try self.write("[[");
            try self.write(try fragment_input_builtin_attr(io.builtin));
            try self.write("]]");
        } else if (io.location) |loc| {
            // Location-decorated scalar fragment inputs (uncommon but valid).
            try self.write("[[user(loc");
            try self.write_u32(loc);
            try self.write(")]]");
        }
    }

    fn emit_fragment_out_attr(self: *FragmentEmitter, io: ir.IoAttr) EmitError!void {
        if (io.builtin == .frag_depth) {
            try self.write("[[depth(any)]]");
        } else if (io.builtin == .sample_mask) {
            try self.write("[[sample_mask]]");
        } else if (io.location) |loc| {
            try self.write("[[color(");
            try self.write_u32(loc);
            try self.write(")]]");
        }
    }

    fn emit_field_type(self: *FragmentEmitter, ty: ir.TypeId) EmitError!void {
        try emit_msl_shared.write_type(self.module, ty, self.buf, self.pos);
    }

    fn emit_stmt(self: *FragmentEmitter, stmt_id: ir.StmtId) EmitError!void {
        try emit_msl_shared.write_stmt(self.module, self.function, stmt_id, self.buf, self.pos, self.indent);
    }

    fn write(self: *FragmentEmitter, text: []const u8) EmitError!void {
        if (self.pos.* + text.len > self.buf.len) return error.OutputTooLarge;
        @memcpy(self.buf[self.pos.* .. self.pos.* + text.len], text);
        self.pos.* += text.len;
    }

    fn write_indent(self: *FragmentEmitter) EmitError!void {
        var i: usize = 0;
        while (i < self.indent.*) : (i += 1) try self.write(" ");
    }

    fn write_u32(self: *FragmentEmitter, value: u32) EmitError!void {
        var tmp: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, "{}", .{value}) catch return error.OutputTooLarge;
        try self.write(text);
    }
};

fn fragment_input_builtin_attr(builtin: ir.Builtin) EmitError![]const u8 {
    return switch (builtin) {
        .position => "position",
        .front_facing => "front_facing",
        .sample_index => "sample_id",
        .sample_mask => "sample_mask",
        else => error.UnsupportedBuiltin,
    };
}
