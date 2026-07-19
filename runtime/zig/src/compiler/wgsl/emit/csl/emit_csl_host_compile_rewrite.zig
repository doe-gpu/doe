const std = @import("std");

pub const RewriteError = error{OutputTooLarge};

pub fn rewriteF16CompileSourceInPlace(buf: []u8, pos: *usize) RewriteError!void {
    rewriteScalarTokenInPlace(buf[0..pos.*], "f32", "f16");
    try replaceAllInPlace(buf, pos, "-3.4028235e+38", "-65504.0");
    try replaceAllInPlace(buf, pos, "-1.0e30", "-65504.0");
    try replaceAllInPlace(buf, pos, "@bitcast(f16, u[1])", "@as(f16, 0.000001)");
    try replaceAllInPlace(buf, pos, "var scratch_in: [2]f16 = @zeros([2]f16);", "var scratch_in: [2]u32 = @zeros([2]u32);");
    try replaceAllInPlace(buf, pos, "var scratch_out: [2]f16 = @zeros([2]f16);", "var scratch_out: [2]u32 = @zeros([2]u32);");
    try replaceAllInPlace(buf, pos, "scratch_out[0] = local_max_val;", "scratch_out[0] = @as(u32, @bitcast(u16, local_max_val));");
    try replaceAllInPlace(buf, pos, "scratch_out[0] = best_val;", "scratch_out[0] = @as(u32, @bitcast(u16, best_val));");
    try replaceAllInPlace(buf, pos, "scratch_out[1] = @bitcast(f16, local_max_idx);", "scratch_out[1] = local_max_idx;");
    try replaceAllInPlace(buf, pos, "scratch_out[1] = @bitcast(f16, best_idx);", "scratch_out[1] = best_idx;");
    try replaceAllInPlace(buf, pos, "const incoming_val = scratch_in[0];", "const incoming_val: f16 = @bitcast(f16, @as(u16, scratch_in[0]));");
    try replaceAllInPlace(buf, pos, "const incoming_idx = @bitcast(u32, scratch_in[1]);", "const incoming_idx = scratch_in[1];");
    try replaceAllInPlace(
        buf,
        pos,
        "@fmacs(C_dsd, C_dsd, A_dsd, b_val);",
        "for (@range(i16, Mt)) |ii| {\n                const c_idx = @as(u32, j) * @as(u32, Mt) + @as(u32, ii);\n                const a_idx = @as(u32, k) * @as(u32, Mt) + @as(u32, ii);\n                C_tile[c_idx] += Ap.*[a_idx] * b_val;\n            }",
    );
}

pub fn restoreFusedGemvF32ReductionInPlace(buf: []u8, pos: *usize) RewriteError!void {
    try replaceAllInPlace(buf, pos, "@export_name(\"output\", [*]f16, true);\n    @export_name(\"compute\", fn()void);", "@export_name(\"output\", [*]f16, true);\n    @export_name(\"partial\", [*]f32, true);\n    @export_name(\"reduced\", [*]f32, true);\n    @export_name(\"compute\", fn()void);");
    try replaceAllInPlace(buf, pos, "reduce_fadds accumulates f16 partials", "reduce_fadds accumulates f32 partials");
    try replaceAllInPlace(buf, pos, "var partial: [out_dim_per_pe]f16 = @zeros([out_dim_per_pe]f16);", "var partial: [out_dim_per_pe]f32 = @zeros([out_dim_per_pe]f32);");
    try replaceAllInPlace(buf, pos, "var reduced: [out_dim_per_pe]f16 = @zeros([out_dim_per_pe]f16);", "var reduced: [out_dim_per_pe]f32 = @zeros([out_dim_per_pe]f32);");
    try replaceAllInPlace(buf, pos, "var weight_col: [out_dim_per_pe]f16 = @zeros([out_dim_per_pe]f16);", "var weight_col: [out_dim_per_pe]f32 = @zeros([out_dim_per_pe]f32);");
    try replaceAllInPlace(buf, pos, "var partial_ptr: [*]f16 = &partial;", "var partial_ptr: [*]f32 = &partial;");
    try replaceAllInPlace(buf, pos, "var reduced_ptr: [*]f16 = &reduced;", "var reduced_ptr: [*]f32 = &reduced;");
    try replaceAllInPlace(buf, pos, "var sum: f16 = 0.0;", "var sum: f32 = 0.0;");
    try replaceAllInPlace(buf, pos, "const d = @as(f16, @bitcast(f16, d_bits));", "const d = @as(f32, @bitcast(f16, d_bits));");
    try replaceAllInPlace(buf, pos, "weight_col[@as(u32, row)] = @as(f16, byte & 0x0F) * d;", "weight_col[@as(u32, row)] = @as(f32, byte & 0x0F) * d;");
    try replaceAllInPlace(buf, pos, "weight_col[@as(u32, row)] = @as(f16, byte >> 4) * d;", "weight_col[@as(u32, row)] = @as(f32, byte >> 4) * d;");
    try replaceAllInPlace(buf, pos, "const lo = @as(f16, byte & 0x0F) * d;", "const lo = @as(f32, byte & 0x0F) * d;");
    try replaceAllInPlace(buf, pos, "const hi = @as(f16, byte >> 4) * d;", "const hi = @as(f32, byte >> 4) * d;");
    try replaceAllInPlace(buf, pos, "const x_lo = @as(f16, ", "const x_lo = @as(f32, ");
    try replaceAllInPlace(buf, pos, "const x_hi = @as(f16, ", "const x_hi = @as(f32, ");
    try replaceAllInPlace(buf, pos, "sum += lo * @as(f16, ", "sum += lo * @as(f32, ");
    try replaceAllInPlace(buf, pos, "sum += hi * @as(f16, ", "sum += hi * @as(f32, ");
    try replaceAllInPlace(buf, pos, "@ptrcast([*]f16, &partial)", "@ptrcast([*]f32, &partial)");
    try replaceAllInPlace(buf, pos, "@ptrcast([*]f16, &reduced)", "@ptrcast([*]f32, &reduced)");
}

fn rewriteScalarTokenInPlace(bytes: []u8, from: []const u8, to: []const u8) void {
    std.debug.assert(from.len == to.len);
    var idx: usize = 0;
    while (idx + from.len <= bytes.len) : (idx += 1) {
        if (!std.mem.eql(u8, bytes[idx..][0..from.len], from)) continue;
        const before_ident = idx > 0 and isIdentifierByte(bytes[idx - 1]);
        const after_idx = idx + from.len;
        const after_ident = after_idx < bytes.len and isIdentifierByte(bytes[after_idx]);
        if (before_ident or after_ident) continue;
        @memcpy(bytes[idx..][0..to.len], to);
        idx += from.len - 1;
    }
}

fn replaceAllInPlace(buf: []u8, pos: *usize, from: []const u8, to: []const u8) RewriteError!void {
    var idx: usize = 0;
    while (idx + from.len <= pos.*) {
        if (!std.mem.eql(u8, buf[idx..][0..from.len], from)) {
            idx += 1;
            continue;
        }
        if (to.len > from.len) {
            const growth = to.len - from.len;
            if (pos.* + growth > buf.len) return error.OutputTooLarge;
            std.mem.copyBackwards(u8, buf[idx + to.len .. pos.* + growth], buf[idx + from.len .. pos.*]);
            pos.* += growth;
        } else if (to.len < from.len) {
            const shrink = from.len - to.len;
            std.mem.copyForwards(u8, buf[idx + to.len .. pos.* - shrink], buf[idx + from.len .. pos.*]);
            pos.* -= shrink;
        }
        @memcpy(buf[idx..][0..to.len], to);
        idx += to.len;
    }
}

fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
