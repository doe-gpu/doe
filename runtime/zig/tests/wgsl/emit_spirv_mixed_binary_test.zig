// emit_spirv_mixed_binary_test.zig — regression tests for the
// scalar-op-vector binary coercion fix in
// `runtime/zig/src/doe_wgsl/emit_spirv_fn.zig`.
//
// Before the fix, the `.binary` value-expr dispatch (around line 358)
// unconditionally passed `binary.lhs.ty` as the operand_ty to
// `emit_binary`. For WGSL-legal `scalar op vector` expressions
// (e.g. `p * vec4<f32>(...)`), operand_ty was the scalar, which made
// `coerce_binary_operand` try to demote the RHS vector to a scalar
// and hit the unreachable arm at emit_spirv_fn.zig:772 with
// UnsupportedConstruct. The fix introduces `binary_operand_type`
// which picks the vector as operand_ty when one side is scalar and
// the other is vector, so the scalar gets broadcast and both sides
// emit at the vector width.
//
// Commuting the operands (`vector * scalar`) already worked before
// the fix because the lhs was already the vector. Both directions
// are covered here so the fix is locked against regression in either
// direction.

const std = @import("std");
const spirv = @import("../../src/doe_wgsl/spirv_builder.zig");
const mod = @import("../../src/doe_wgsl/mod.zig");

const testing = std.testing;
const allocator = testing.allocator;

const MAX_SPIRV_OUTPUT = mod.MAX_SPIRV_OUTPUT;
const translateToSpirv = mod.translateToSpirv;

fn read_u32_le(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(bytes[offset .. offset + 4].ptr)), .little);
}

fn expect_spirv_magic(binary: []const u8) !void {
    try testing.expect(binary.len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));
}

fn count_spirv_opcode(binary: []const u8, opcode: u16) u32 {
    const word_count = binary.len / 4;
    var i: usize = 5;
    var count: u32 = 0;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = @as(u16, @truncate(w));
        const wc = w >> 16;
        if (op == opcode) count += 1;
        i += wc;
    }
    return count;
}

fn count_member_decoration(binary: []const u8, decoration: u32) u32 {
    const word_count = binary.len / 4;
    var i: usize = 5;
    var count: u32 = 0;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = @as(u16, @truncate(w));
        const wc = w >> 16;
        if (op == spirv.Opcode.MemberDecorate and wc >= 4 and read_u32_le(binary, (i + 3) * 4) == decoration) count += 1;
        i += wc;
    }
    return count;
}

test "scalar * vector lowers via broadcast operand coercion" {
    // Minimum repro extracted from attention_head256_f16kv.wgsl's
    // inner accumulation. Pre-fix this failed
    // `UnsupportedConstruct` at emit_scalar_construct_from_type
    // because operand_ty was the f32 lhs and the vec4<f32> rhs could
    // not coerce down to a scalar.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    let p: f32 = 1.0;
        \\    let h: vec4<f32> = vec4<f32>(2.0);
        \\    let v: vec4<f32> = p * h;
        \\    output[0] = v.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
}

test "matrix * vector lowers with OpMatrixTimesVector" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    let m = mat4x4<f32>(
        \\        vec4<f32>(1.0, 0.0, 0.0, 0.0),
        \\        vec4<f32>(0.0, 1.0, 0.0, 0.0),
        \\        vec4<f32>(0.0, 0.0, 1.0, 0.0),
        \\        vec4<f32>(0.0, 0.0, 0.0, 1.0),
        \\    );
        \\    let v = m * vec4<f32>(1.0, 2.0, 3.0, 1.0);
        \\    output[0] = v.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.MatrixTimesVector));
}

test "vector * matrix lowers with OpVectorTimesMatrix" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    let m = mat4x4<f32>(
        \\        vec4<f32>(1.0, 0.0, 0.0, 0.0),
        \\        vec4<f32>(0.0, 1.0, 0.0, 0.0),
        \\        vec4<f32>(0.0, 0.0, 1.0, 0.0),
        \\        vec4<f32>(0.0, 0.0, 0.0, 1.0),
        \\    );
        \\    let v = vec4<f32>(1.0, 2.0, 3.0, 1.0) * m;
        \\    output[0] = v.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.VectorTimesMatrix));
}

test "matrix * scalar lowers with OpMatrixTimesScalar" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    let m = mat2x2<f32>(
        \\        vec2<f32>(1.0, 0.0),
        \\        vec2<f32>(0.0, 1.0),
        \\    );
        \\    let scaled = 2.0 * m;
        \\    output[0] = scaled[0].x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.MatrixTimesScalar));
}

test "matrix + matrix lowers column-wise with OpFAdd" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let a = mat2x2f(vec2f(1.0, 2.0), vec2f(3.0, 4.0));
        \\    let b = mat2x2f(vec2f(5.0, 6.0), vec2f(7.0, 8.0));
        \\    let c = a + b;
        \\    out_data[0] = c[0][0];
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
    try testing.expectEqual(@as(u32, 2), count_spirv_opcode(out[0..len], spirv.Opcode.FAdd));
    try testing.expectEqual(@as(u32, 0), count_spirv_opcode(out[0..len], spirv.Opcode.IAdd));
}

test "storage runtime array of matrices carries matrix layout decorations" {
    const source =
        \\struct Joints {
        \\    matrices: array<mat4x4<f32>>,
        \\}
        \\@group(0) @binding(0) var<storage, read> joints: Joints;
        \\@group(0) @binding(1) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let m = joints.matrices[0u];
        \\    out_data[0] = m[0][0];
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
    try testing.expect(count_member_decoration(out[0..len], spirv.Decoration.ColMajor) >= 1);
    try testing.expect(count_member_decoration(out[0..len], spirv.Decoration.MatrixStride) >= 1);
}

test "zero-argument vector constructors lower to zero composites" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let z = vec4<f32>();
        \\    let u = vec2<u32>();
        \\    out_data[0] = z.x + f32(u.x);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
}

test "vector * scalar still lowers (non-regression)" {
    // This direction worked before the fix because the lhs was
    // already the vector and operand_ty=lhs.ty was correct. Test
    // locks that the fix does not regress it.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    let p: f32 = 1.0;
        \\    let h: vec4<f32> = vec4<f32>(2.0);
        \\    let v: vec4<f32> = h * p;
        \\    output[0] = v.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
}

test "scalar + vector and scalar - vector via broadcast" {
    // Exercises the same path for `+` and `-` operators. Both route
    // through coerce_binary_operand with the same operand_ty choice,
    // so if any of `+`, `-`, `*` regressed the test would trip.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    let a: f32 = 3.0;
        \\    let b: vec4<f32> = vec4<f32>(4.0);
        \\    let sum: vec4<f32> = a + b;
        \\    let diff: vec4<f32> = a - b;
        \\    output[0] = sum.x + diff.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
}

test "scalar * vector chained with vector accumulate lowers" {
    // Closer to the original attention pattern:
    //   acc[d4] = acc[d4] + p * vec4<f32>(shared_block[i]);
    // Exercises nested binary ops where the inner `p * vec` is the
    // scalar-op-vector case and the outer `vec + vec` is same-width.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    let p: f32 = 1.5;
        \\    let v: vec4<f32> = vec4<f32>(2.0);
        \\    var acc: vec4<f32> = vec4<f32>(0.0);
        \\    acc = acc + p * v;
        \\    output[0] = acc.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
}
