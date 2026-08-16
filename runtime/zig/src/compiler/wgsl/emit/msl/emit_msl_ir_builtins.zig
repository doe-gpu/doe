// doe_wgsl/emit_msl_ir_builtins.zig — WGSL builtin-to-MSL call emission.
//
// Extracted from emit_msl_ir.zig. Handles translation of WGSL builtin function
// calls (atomics, packing, barriers, subgroups, arrayLength, select, etc.) to
// their MSL equivalents.

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const maps = @import("emit_msl_maps.zig");
const texture_builtins = @import("emit_msl_texture.zig");
const layout = @import("../../ir/layout_utils.zig");
const workgroup_policy = @import("emit_msl_workgroup_zero.zig");

const should_force_literal_cast = maps.shouldForceLiteralCast;

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
};

pub fn emit_call(self: anytype, function: ir.Function, result_ty: ir.TypeId, call: @FieldType(ir.Expr, "call")) EmitError!void {
    if (call.kind == .builtin) {
        if (std.mem.eql(u8, call.name, "workgroupBarrier")) {
            try self.write(if (workgroup_policy.singleInvocationWorkgroup(function))
                "(void)0"
            else
                "threadgroup_barrier(mem_flags::mem_threadgroup)");
            return;
        }
        if (std.mem.eql(u8, call.name, "storageBarrier")) {
            try self.write(if (workgroup_policy.singleInvocationWorkgroup(function))
                "(void)0"
            else
                "threadgroup_barrier(mem_flags::mem_device)");
            return;
        }
        if (std.mem.eql(u8, call.name, "textureBarrier")) {
            try self.write(if (workgroup_policy.singleInvocationWorkgroup(function))
                "(void)0"
            else
                "threadgroup_barrier(mem_flags::mem_texture)");
            return;
        }
        if (std.mem.eql(u8, call.name, "bitcast")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("as_type<");
            try self.emit_type(result_ty);
            try self.write(">(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "unpack2x16float")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("float2(as_type<half2>(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write("))");
            return;
        }
        if (std.mem.eql(u8, call.name, "pack2x16float")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("as_type<uint>(half2(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write("))");
            return;
        }
        if (std.mem.eql(u8, call.name, "unpack4x8unorm")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("(float4(as_type<uchar4>(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")) / 255.0)");
            return;
        }
        if (std.mem.eql(u8, call.name, "unpack4x8snorm")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("clamp(float4(as_type<char4>(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")) / 127.0, -1.0, 1.0)");
            return;
        }
        if (std.mem.eql(u8, call.name, "pack4x8unorm")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("as_type<uint>(uchar4(round(clamp(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(", 0.0, 1.0) * 255.0)))");
            return;
        }
        if (std.mem.eql(u8, call.name, "pack4x8snorm")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("as_type<uint>(char4(round(clamp(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(", -1.0, 1.0) * 127.0)))");
            return;
        }
        if (try texture_builtins.emit_builtin(self, function, call)) return;
        if (std.mem.eql(u8, call.name, "atomicLoad")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("atomic_load_explicit(&(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write("), memory_order_relaxed)");
            return;
        }
        if (std.mem.eql(u8, call.name, "atomicStore")) {
            if (call.args.len != 2) return error.InvalidIr;
            try self.write("atomic_store_explicit(&(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write("), ");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 1]);
            try self.write(", memory_order_relaxed)");
            return;
        }
        if (std.mem.eql(u8, call.name, "atomicAdd")) {
            try emit_atomic_fetch_explicit(self, function, call, "atomic_fetch_add_explicit");
            return;
        }
        if (std.mem.eql(u8, call.name, "atomicSub")) {
            try emit_atomic_fetch_explicit(self, function, call, "atomic_fetch_sub_explicit");
            return;
        }
        if (std.mem.eql(u8, call.name, "atomicMax")) {
            try emit_atomic_fetch_explicit(self, function, call, "atomic_fetch_max_explicit");
            return;
        }
        if (std.mem.eql(u8, call.name, "atomicMin")) {
            try emit_atomic_fetch_explicit(self, function, call, "atomic_fetch_min_explicit");
            return;
        }
        if (std.mem.eql(u8, call.name, "atomicAnd")) {
            try emit_atomic_fetch_explicit(self, function, call, "atomic_fetch_and_explicit");
            return;
        }
        if (std.mem.eql(u8, call.name, "atomicOr")) {
            try emit_atomic_fetch_explicit(self, function, call, "atomic_fetch_or_explicit");
            return;
        }
        if (std.mem.eql(u8, call.name, "atomicXor")) {
            try emit_atomic_fetch_explicit(self, function, call, "atomic_fetch_xor_explicit");
            return;
        }
        if (std.mem.eql(u8, call.name, "atomicExchange")) {
            try emit_atomic_fetch_explicit(self, function, call, "atomic_exchange_explicit");
            return;
        }
        if (std.mem.eql(u8, call.name, "atomicCompareExchangeWeak")) {
            try emit_atomic_compare_exchange_weak(self, function, result_ty, call);
            return;
        }
        if (std.mem.eql(u8, call.name, "subgroupAdd")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("simd_sum(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "subgroupExclusiveAdd")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("simd_prefix_exclusive_sum(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "subgroupMin")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("simd_min(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "subgroupMax")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("simd_max(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "subgroupBroadcast")) {
            if (call.args.len != 2) return error.InvalidIr;
            try self.write("simd_broadcast(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(", ");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 1]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "subgroupShuffle")) {
            if (call.args.len != 2) return error.InvalidIr;
            try self.write("simd_shuffle(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(", ");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 1]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "subgroupShuffleXor")) {
            if (call.args.len != 2) return error.InvalidIr;
            try self.write("simd_shuffle_xor(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(", ");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 1]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "pack2x16snorm")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("pack_float_to_snorm2x16(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "pack2x16unorm")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("pack_float_to_unorm2x16(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "unpack2x16snorm")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("unpack_snorm2x16_to_float(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "unpack2x16unorm")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("unpack_unorm2x16_to_float(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "inverseSqrt")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("rsqrt(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "degrees")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(" * 57.29577951308232)");
            return;
        }
        if (std.mem.eql(u8, call.name, "radians")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(" * 0.017453292519943295)");
            return;
        }
        if (std.mem.eql(u8, call.name, "quantizeToF16")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("float(half(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write("))");
            return;
        }
        if (std.mem.eql(u8, call.name, "modf")) {
            // WGSL modf(x) returns __modf_result{fract, whole}; MSL has no struct
            // equivalent — emit the fractional component via x - floor(x).
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(" - floor(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write("))");
            return;
        }
        if (std.mem.eql(u8, call.name, "frexp")) {
            // WGSL frexp(x) returns __frexp_result{fract, exp}; MSL has no struct
            // equivalent — emit the fractional mantissa via frexp(x, &dummy).
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("frexp(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(", (thread int*)nullptr)");
            return;
        }
        if (std.mem.eql(u8, call.name, "extractBits")) {
            if (call.args.len != 3) return error.InvalidIr;
            try self.write("extract_bits(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(", ");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 1]);
            try self.write(", ");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 2]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "insertBits")) {
            if (call.args.len != 4) return error.InvalidIr;
            try self.write("insert_bits(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(", ");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 1]);
            try self.write(", ");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 2]);
            try self.write(", ");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 3]);
            try self.write(")");
            return;
        }
        if (std.mem.eql(u8, call.name, "firstLeadingBit")) {
            // MSL clz returns count of leading zeros; WGSL firstLeadingBit returns
            // the bit position of the highest set bit (31 - clz for u32).
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("(31 - int(clz(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")))");
            return;
        }
        if (std.mem.eql(u8, call.name, "firstTrailingBit")) {
            // MSL ctz returns count of trailing zeros; WGSL firstTrailingBit
            // returns the same value (bit position of the lowest set bit).
            if (call.args.len != 1) return error.InvalidIr;
            try self.write("int(ctz(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write("))");
            return;
        }
        if (try emit_derivative_builtin(self, call, function)) return;
        if (std.mem.eql(u8, call.name, "arrayLength")) {
            if (call.args.len != 1) return error.InvalidIr;
            try emit_array_length(self, function, call);
            return;
        }
        if (std.mem.eql(u8, call.name, "select")) {
            if (call.args.len != 3) return error.InvalidIr;
            try self.write("((");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 2]);
            try self.write(") ? (");
            try self.emit_expr(function, function.expr_args.items[call.args.start + 1]);
            try self.write(") : (");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write("))");
            return;
        }
        if (std.mem.eql(u8, call.name, "min") or std.mem.eql(u8, call.name, "max") or std.mem.eql(u8, call.name, "clamp")) {
            try emit_concrete_numeric_builtin(self, function, result_ty, call);
            return;
        }
        if (std.mem.eql(u8, call.name, "any") or std.mem.eql(u8, call.name, "all")) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write(call.name);
            try self.write("(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return;
        }
        if (maps.msl_builtin_passthrough_name(call.name)) |mapped_name| {
            try self.write(mapped_name);
            try self.write("(");
            try self.emit_expr_list(function, call.args);
            try self.write(")");
            return;
        }
        return error.InvalidIr;
    }
    try self.write(call.name);
    try self.write("(");
    var need_comma = false;
    if (call.args.len > 0) {
        try self.emit_expr_list(function, call.args);
        need_comma = true;
    }
    try self.emit_helper_capture_args(&need_comma);
    try self.write(")");
}

fn emit_array_length(self: anytype, function: ir.Function, call: @FieldType(ir.Expr, "call")) EmitError!void {
    const target_expr = function.expr_args.items[call.args.start];
    if (try self.emit_array_length_local_if_available(function, target_expr)) return;
    switch (function.exprs.items[target_expr].data) {
        .global_ref => |index| {
            const global = self.module.globals.items[index];
            switch (self.module.types.get(global.ty)) {
                .array => |arr| {
                    if (arr.len != null) return error.InvalidIr;
                    const binding = global.binding orelse return error.InvalidIr;
                    try self.write("uint(_doe_sizes[");
                    try self.write_u32(self.msl_binding_slot(binding));
                    try self.write("] / sizeof(");
                    try self.emit_type(arr.elem);
                    try self.write("))");
                    return;
                },
                else => return error.InvalidIr,
            }
        },
        .member => |member| {
            // arrayLength(&buf.data) — struct field containing a runtime-sized array.
            // Walk up to find the containing global for binding + sizes lookup.
            const global_index = layout.resolve_member_global(function, member.base) orelse return error.InvalidIr;
            const global = self.module.globals.items[global_index];
            const binding = global.binding orelse return error.InvalidIr;
            const struct_id = switch (self.module.types.get(global.ty)) {
                .struct_ => |sid| sid,
                else => return error.InvalidIr,
            };
            const struct_def = self.module.structs.items[struct_id];
            // The target field must be a runtime-sized array.
            if (member.field_index >= struct_def.fields.items.len) return error.InvalidIr;
            const field = struct_def.fields.items[member.field_index];
            const arr = switch (self.module.types.get(field.ty)) {
                .array => |a| a,
                else => return error.InvalidIr,
            };
            if (arr.len != null) return error.InvalidIr;
            // Compute byte offset of the runtime-sized array field.
            const field_offset = layout.struct_field_offset(self.module, struct_def, member.field_index);
            // (_doe_sizes[slot] - field_offset) / sizeof(elem)
            try self.write("uint((_doe_sizes[");
            try self.write_u32(self.msl_binding_slot(binding));
            try self.write("] - ");
            try self.write_u32(field_offset);
            try self.write(") / sizeof(");
            try self.emit_type(arr.elem);
            try self.write("))");
            return;
        },
        else => return error.InvalidIr,
    }
}

fn emit_concrete_numeric_builtin(
    self: anytype,
    function: ir.Function,
    result_ty: ir.TypeId,
    call: @FieldType(ir.Expr, "call"),
) EmitError!void {
    try self.write(call.name);
    try self.write("(");
    var i: u32 = 0;
    while (i < call.args.len) : (i += 1) {
        if (i > 0) try self.write(", ");
        try emit_expr_coerced(self, function, function.expr_args.items[call.args.start + i], result_ty);
    }
    try self.write(")");
}

fn emit_atomic_fetch_explicit(self: anytype, function: ir.Function, call: @FieldType(ir.Expr, "call"), name: []const u8) EmitError!void {
    if (call.args.len != 2) return error.InvalidIr;
    try self.write(name);
    try self.write("(&(");
    try self.emit_expr(function, function.expr_args.items[call.args.start]);
    try self.write("), ");
    try self.emit_expr(function, function.expr_args.items[call.args.start + 1]);
    try self.write(", memory_order_relaxed)");
}

pub fn emit_expr_coerced(self: anytype, function: ir.Function, expr_id: ir.ExprId, target_ty: ir.TypeId) EmitError!void {
    const expr_ty = function.exprs.items[expr_id].ty;
    if (expr_ty != target_ty or should_force_literal_cast(self.module, function, expr_id, target_ty)) {
        try self.emit_type(target_ty);
        try self.write("(");
        try self.emit_expr(function, expr_id);
        try self.write(")");
        return;
    }
    try self.emit_expr(function, expr_id);
}

fn emit_atomic_compare_exchange_weak(self: anytype, function: ir.Function, result_ty: ir.TypeId, call: @FieldType(ir.Expr, "call")) EmitError!void {
    // WGSL atomicCompareExchangeWeak(ptr, expected, desired) returns
    // __atomic_compare_exchange_result{old_value, exchanged}. MSL has
    // atomic_compare_exchange_weak_explicit which writes the old value
    // through the expected pointer. Preserve both the original value and the
    // success bit in the WGSL result struct.
    if (call.args.len != 3) return error.InvalidIr;
    try self.write("({auto _doe_cew_e = ");
    try self.emit_expr(function, function.expr_args.items[call.args.start + 1]);
    try self.write("; bool _doe_cew_x = atomic_compare_exchange_weak_explicit(&(");
    try self.emit_expr(function, function.expr_args.items[call.args.start]);
    try self.write("), &_doe_cew_e, ");
    try self.emit_expr(function, function.expr_args.items[call.args.start + 2]);
    try self.write(", memory_order_relaxed, memory_order_relaxed); ");
    try self.emit_type(result_ty);
    try self.write("{_doe_cew_e, _doe_cew_x};})");
}

/// Derivative builtins (fragment-only). WGSL names map directly or with
/// fine/coarse suffixes to MSL dfdx/dfdy/fwidth.
fn emit_derivative_builtin(self: anytype, call: @FieldType(ir.Expr, "call"), function: ir.Function) EmitError!bool {
    const Mapping = struct { wgsl: []const u8, msl: []const u8 };
    const DERIVATIVE_MAP = [_]Mapping{
        .{ .wgsl = "dpdx", .msl = "dfdx" },
        .{ .wgsl = "dpdxCoarse", .msl = "dfdx" },
        .{ .wgsl = "dpdxFine", .msl = "dfdx" },
        .{ .wgsl = "dpdy", .msl = "dfdy" },
        .{ .wgsl = "dpdyCoarse", .msl = "dfdy" },
        .{ .wgsl = "dpdyFine", .msl = "dfdy" },
        .{ .wgsl = "fwidth", .msl = "fwidth" },
        .{ .wgsl = "fwidthCoarse", .msl = "fwidth" },
        .{ .wgsl = "fwidthFine", .msl = "fwidth" },
    };
    inline for (DERIVATIVE_MAP) |entry| {
        if (std.mem.eql(u8, call.name, entry.wgsl)) {
            if (call.args.len != 1) return error.InvalidIr;
            try self.write(entry.msl);
            try self.write("(");
            try self.emit_expr(function, function.expr_args.items[call.args.start]);
            try self.write(")");
            return true;
        }
    }
    return false;
}
