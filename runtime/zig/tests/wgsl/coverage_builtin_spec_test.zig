// coverage_builtin_spec_test.zig — WGSL spec conformance tests for builtins
// added in the builtins expansion: pack/unpack 2x16, atomicCompareExchangeWeak,
// derivative builtins, texture query builtins, math builtins with renamed MSL
// mappings, and quantizeToF16.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const translateToMsl = mod.translateToMsl;
const MAX_OUTPUT = mod.MAX_OUTPUT;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn expectMslContains(source: []const u8, needles: []const []const u8) !void {
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    for (needles) |needle| {
        try std.testing.expect(contains(msl, needle));
    }
}

// ============================================================
// Pack / unpack 2x16 builtins
// ============================================================

test "builtins: pack2x16snorm and pack2x16unorm through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> out: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v = vec2f(0.5, -0.5);
        \\    out[id.x] = pack2x16snorm(v) + pack2x16unorm(v);
        \\}
    ;
    const needles = [_][]const u8{ "pack_float_to_snorm2x16(", "pack_float_to_unorm2x16(" };
    try expectMslContains(source, &needles);
}

test "builtins: unpack2x16snorm and unpack2x16unorm through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@group(0) @binding(1) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let packed = data[id.x];
        \\    let a = unpack2x16snorm(packed);
        \\    let b = unpack2x16unorm(packed);
        \\    out[id.x] = a.x + b.x;
        \\}
    ;
    const needles = [_][]const u8{ "unpack_snorm2x16_to_float(", "unpack_unorm2x16_to_float(" };
    try expectMslContains(source, &needles);
}

// ============================================================
// Math builtins with renamed MSL mappings
// ============================================================

test "builtins: faceForward through MSL emits faceforward" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let n = vec3f(0.0, 1.0, 0.0);
        \\    let i = vec3f(0.0, -1.0, 0.0);
        \\    let r = vec3f(0.0, 0.5, 0.0);
        \\    let result = faceForward(n, i, r);
        \\    data[id.x] = result.y;
        \\}
    ;
    const needles = [_][]const u8{"faceforward("};
    try expectMslContains(source, &needles);
}

test "builtins: countOneBits through MSL emits popcount" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = countOneBits(data[id.x]);
        \\}
    ;
    const needles = [_][]const u8{"popcount("};
    try expectMslContains(source, &needles);
}

test "builtins: reverseBits through MSL emits reverse_bits" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = reverseBits(data[id.x]);
        \\}
    ;
    const needles = [_][]const u8{"reverse_bits("};
    try expectMslContains(source, &needles);
}

test "builtins: countLeadingZeros and countTrailingZeros through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = countLeadingZeros(data[id.x]) + countTrailingZeros(data[id.x]);
        \\}
    ;
    const needles = [_][]const u8{ "clz(", "ctz(" };
    try expectMslContains(source, &needles);
}

test "builtins: saturate through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = saturate(data[id.x]);
        \\}
    ;
    const needles = [_][]const u8{"saturate("};
    try expectMslContains(source, &needles);
}

test "builtins: reflect and refract through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let i = vec3f(1.0, 0.0, 0.0);
        \\    let n = vec3f(0.0, 1.0, 0.0);
        \\    let r = reflect(i, n);
        \\    let t = refract(i, n, 1.5);
        \\    data[id.x] = r.x + t.x;
        \\}
    ;
    const needles = [_][]const u8{ "reflect(", "refract(" };
    try expectMslContains(source, &needles);
}

test "builtins: transpose and determinant through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let m = mat2x2f(1.0, 2.0, 3.0, 4.0);
        \\    let t = transpose(m);
        \\    let d = determinant(m);
        \\    data[id.x] = t[0][0] + d;
        \\}
    ;
    const needles = [_][]const u8{ "transpose(", "determinant(" };
    try expectMslContains(source, &needles);
}

// ============================================================
// Bit manipulation builtins
// ============================================================

test "builtins: extractBits and insertBits through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v = data[id.x];
        \\    let extracted = extractBits(v, 4u, 8u);
        \\    let inserted = insertBits(v, extracted, 16u, 8u);
        \\    data[id.x] = inserted;
        \\}
    ;
    const needles = [_][]const u8{ "extract_bits(", "insert_bits(" };
    try expectMslContains(source, &needles);
}

test "builtins: firstLeadingBit and firstTrailingBit through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v = data[id.x];
        \\    let flb = firstLeadingBit(v);
        \\    let ftb = firstTrailingBit(v);
        \\    data[id.x] = flb + ftb;
        \\}
    ;
    // firstLeadingBit uses (31 - clz(...)), firstTrailingBit uses ctz(...)
    const needles = [_][]const u8{ "clz(", "ctz(" };
    try expectMslContains(source, &needles);
}

// ============================================================
// quantizeToF16
// ============================================================

test "builtins: quantizeToF16 through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = quantizeToF16(data[id.x]);
        \\}
    ;
    // MSL: float(half(x))
    const needles = [_][]const u8{"float(half("};
    try expectMslContains(source, &needles);
}

// ============================================================
// Texture query builtins
// ============================================================

test "builtins: textureNumLevels through MSL" {
    const source =
        \\@group(0) @binding(0) var my_tex: texture_2d<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    out[id.x] = textureNumLevels(my_tex);
        \\}
    ;
    const needles = [_][]const u8{"get_num_mip_levels()"};
    try expectMslContains(source, &needles);
}

test "builtins: textureNumLayers through MSL" {
    const source =
        \\@group(0) @binding(0) var my_tex: texture_2d_array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    out[id.x] = textureNumLayers(my_tex);
        \\}
    ;
    const needles = [_][]const u8{"get_array_size()"};
    try expectMslContains(source, &needles);
}

// ============================================================
// Derivative builtins (fragment stage)
// ============================================================

test "builtins: dpdx dpdy fwidth through MSL" {
    const source =
        \\@group(0) @binding(0) var my_tex: texture_2d<f32>;
        \\@group(0) @binding(1) var my_sampler: sampler;
        \\
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    let dx = dpdx(uv.x);
        \\    let dy = dpdy(uv.x);
        \\    let fw = fwidth(uv.x);
        \\    return vec4f(dx, dy, fw, 1.0);
        \\}
    ;
    const needles = [_][]const u8{ "dfdx(", "dfdy(", "fwidth(" };
    try expectMslContains(source, &needles);
}

test "builtins: dpdxCoarse dpdyCoarse fwidthCoarse through MSL" {
    const source =
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    let dx = dpdxCoarse(uv.x);
        \\    let dy = dpdyCoarse(uv.x);
        \\    let fw = fwidthCoarse(uv.x);
        \\    return vec4f(dx, dy, fw, 1.0);
        \\}
    ;
    const needles = [_][]const u8{ "dfdx(", "dfdy(", "fwidth(" };
    try expectMslContains(source, &needles);
}

test "builtins: dpdxFine dpdyFine fwidthFine through MSL" {
    const source =
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    let dx = dpdxFine(uv.x);
        \\    let dy = dpdyFine(uv.x);
        \\    let fw = fwidthFine(uv.x);
        \\    return vec4f(dx, dy, fw, 1.0);
        \\}
    ;
    const needles = [_][]const u8{ "dfdx(", "dfdy(", "fwidth(" };
    try expectMslContains(source, &needles);
}

// ============================================================
// MSL passthrough surface coverage
// ============================================================

test "builtins: passthrough surface coverage — every mapped name resolves" {
    // Verify the passthrough map handles all names it claims.
    const msl_maps = @import("../../src/compiler/wgsl/emit/msl/emit_msl_maps.zig");
    const names = [_][]const u8{
        "abs",         "acos",              "asin",               "atan",        "atan2",
        "ceil",        "cos",               "cosh",               "cross",       "determinant",
        "distance",    "dot",               "exp",                "exp2",        "fma",
        "floor",       "fract",             "ldexp",              "length",      "log",
        "log2",        "mix",               "normalize",          "pow",         "reflect",
        "refract",     "round",             "saturate",           "sign",        "sin",
        "sinh",        "smoothstep",        "sqrt",               "step",        "tan",
        "tanh",        "transpose",         "trunc",              "faceForward", "countOneBits",
        "reverseBits", "countLeadingZeros", "countTrailingZeros",
    };
    for (names) |name| {
        try std.testing.expect(msl_maps.msl_builtin_passthrough_name(name) != null);
    }
}
