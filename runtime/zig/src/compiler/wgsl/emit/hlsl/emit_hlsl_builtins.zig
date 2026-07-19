const std = @import("std");
const ir = @import("../../ir/ir.zig");
const maps = @import("emit_hlsl_maps.zig");
const texture = @import("emit_hlsl_texture.zig");
const layout = @import("../../ir/layout_utils.zig");

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    UnsupportedBuiltin,
};

/// Attempt to emit a builtin call.  Returns true if the call was handled,
/// false if it fell through to the renamed/passthrough maps and was emitted
/// there, or returns InvalidIr when nothing matched.
///
/// `self` is the parent Emitter (duck-typed via anytype).
pub fn emit_builtin_call(
    self: anytype,
    function: ir.Function,
    result_ty: ir.TypeId,
    call_name: []const u8,
    call_args: ir.Range,
) EmitError!void {
    // Barriers
    if (std.mem.eql(u8, call_name, "workgroupBarrier")) {
        try self.write("GroupMemoryBarrierWithGroupSync()");
        return;
    }
    if (std.mem.eql(u8, call_name, "storageBarrier")) {
        try self.write("AllMemoryBarrierWithGroupSync()");
        return;
    }
    if (std.mem.eql(u8, call_name, "textureBarrier")) {
        try self.write("DeviceMemoryBarrierWithGroupSync()");
        return;
    }

    // bitcast
    if (std.mem.eql(u8, call_name, "bitcast")) {
        if (call_args.len != 1) return error.InvalidIr;
        try self.write(maps.hlsl_bitcast_fn(self.module, result_ty));
        try self.write("(");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write(")");
        return;
    }

    // arrayLength
    if (std.mem.eql(u8, call_name, "arrayLength")) {
        try emit_array_length(self, function, call_args);
        return;
    }

    // select — ternary rewrite
    if (std.mem.eql(u8, call_name, "select")) {
        if (call_args.len != 3) return error.InvalidIr;
        try self.write("((");
        try self.emit_expr(function, function.expr_args.items[call_args.start + 2]);
        try self.write(") ? (");
        try self.emit_expr(function, function.expr_args.items[call_args.start + 1]);
        try self.write(") : (");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write("))");
        return;
    }

    // Subgroup operations
    if (std.mem.eql(u8, call_name, "subgroupShuffleXor")) {
        if (call_args.len != 2) return error.InvalidIr;
        try self.write("WaveReadLaneAt(");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write(", WaveGetLaneIndex() ^ ");
        try self.emit_expr(function, function.expr_args.items[call_args.start + 1]);
        try self.write(")");
        return;
    }
    if (std.mem.eql(u8, call_name, "subgroupBallot")) {
        if (call_args.len != 1) return error.InvalidIr;
        try self.write("WaveActiveBallot(");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write(")");
        return;
    }
    if (std.mem.eql(u8, call_name, "subgroupElect")) {
        try self.write("WaveIsFirstLane()");
        return;
    }

    // Bit manipulation
    if (std.mem.eql(u8, call_name, "countLeadingZeros")) {
        if (call_args.len != 1) return error.InvalidIr;
        // CLZ(x) = (x == 0) ? 32 : (31 - firstbithigh(x))
        try self.write("((");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write(" == 0u) ? 32u : (31u - firstbithigh(");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write(")))");
        return;
    }
    if (std.mem.eql(u8, call_name, "countTrailingZeros")) {
        if (call_args.len != 1) return error.InvalidIr;
        // CTZ(x) = (x == 0) ? 32 : firstbitlow(x)
        try self.write("((");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write(" == 0u) ? 32u : firstbitlow(");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write("))");
        return;
    }
    if (std.mem.eql(u8, call_name, "extractBits")) {
        if (call_args.len != 3) return error.InvalidIr;
        // extractBits(e, offset, count) = (e >> offset) & ((1u << count) - 1u)
        try self.write("((");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write(" >> ");
        try self.emit_expr(function, function.expr_args.items[call_args.start + 1]);
        try self.write(") & ((1u << ");
        try self.emit_expr(function, function.expr_args.items[call_args.start + 2]);
        try self.write(") - 1u))");
        return;
    }
    if (std.mem.eql(u8, call_name, "insertBits")) {
        if (call_args.len != 4) return error.InvalidIr;
        // insertBits(e, newbits, offset, count):
        //   mask = (1u << count) - 1u
        //   (e & ~(mask << offset)) | ((newbits & mask) << offset)
        try self.write("((");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write(" & ~(((1u << ");
        try self.emit_expr(function, function.expr_args.items[call_args.start + 3]);
        try self.write(") - 1u) << ");
        try self.emit_expr(function, function.expr_args.items[call_args.start + 2]);
        try self.write(")) | ((");
        try self.emit_expr(function, function.expr_args.items[call_args.start + 1]);
        try self.write(" & ((1u << ");
        try self.emit_expr(function, function.expr_args.items[call_args.start + 3]);
        try self.write(") - 1u)) << ");
        try self.emit_expr(function, function.expr_args.items[call_args.start + 2]);
        try self.write("))");
        return;
    }

    // Texture builtins (delegated to texture module)
    if (try texture.emit_texture_builtin(self.module, self.buf, &self.pos, function, call_name, call_args)) return;

    // Angle conversions
    if (std.mem.eql(u8, call_name, "degrees")) {
        if (call_args.len != 1) return error.InvalidIr;
        try self.write("(");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write(" * 57.29577951308232)");
        return;
    }
    if (std.mem.eql(u8, call_name, "radians")) {
        if (call_args.len != 1) return error.InvalidIr;
        try self.write("(");
        try self.emit_expr(function, function.expr_args.items[call_args.start]);
        try self.write(" * 0.017453292519943295)");
        return;
    }

    // Renamed builtins (WGSL name → HLSL name, same args)
    if (maps.hlsl_renamed_builtin(call_name)) |mapped| {
        try self.write(mapped);
        try self.write("(");
        try self.emit_expr_list(function, call_args);
        try self.write(")");
        return;
    }

    // Passthrough builtins (same name in HLSL)
    if (maps.hlsl_builtin_passthrough(call_name)) {
        try self.write(call_name);
        try self.write("(");
        try self.emit_expr_list(function, call_args);
        try self.write(")");
        return;
    }

    return error.InvalidIr;
}

/// Emit arrayLength() — handles both bare global arrays and struct-field
/// runtime-sized arrays.
fn emit_array_length(self: anytype, function: ir.Function, call_args: ir.Range) EmitError!void {
    if (call_args.len != 1) return error.InvalidIr;
    const target_expr = function.expr_args.items[call_args.start];
    switch (function.exprs.items[target_expr].data) {
        .global_ref => |index| {
            const global = self.module.globals.items[index];
            switch (self.module.types.get(global.ty)) {
                .array => |arr| {
                    if (arr.len != null) return error.InvalidIr;
                    try self.write("doe_arrayLength_");
                    try self.write(global.name);
                    try self.write("()");
                    return;
                },
                else => return error.InvalidIr,
            }
        },
        .member => |member| {
            // arrayLength(&buf.data) — struct field runtime-sized array.
            const global_index = layout.resolve_member_global(function, member.base) orelse return error.InvalidIr;
            const global = self.module.globals.items[global_index];
            const struct_id = switch (self.module.types.get(global.ty)) {
                .struct_ => |sid| sid,
                else => return error.InvalidIr,
            };
            const struct_def = self.module.structs.items[struct_id];
            if (member.field_index >= struct_def.fields.items.len) return error.InvalidIr;
            const field = struct_def.fields.items[member.field_index];
            try self.write("doe_arrayLength_");
            try self.write(global.name);
            try self.write("_");
            try self.write(field.name);
            try self.write("()");
            return;
        },
        else => return error.InvalidIr,
    }
}
