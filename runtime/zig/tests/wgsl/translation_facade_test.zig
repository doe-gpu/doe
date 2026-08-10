const std = @import("std");
const api = @import("../../src/compiler/wgsl/mod.zig");
const csl_tests = @import("translation_test_support.zig");
const lean_proof = @import("../../src/verification/lean_proof.zig");

const TranslateError = api.TranslateError;
const MAX_OUTPUT = api.MAX_OUTPUT;
const MAX_HLSL_OUTPUT = api.MAX_HLSL_OUTPUT;
const MAX_SPIRV_OUTPUT = api.MAX_SPIRV_OUTPUT;
const MAX_CSL_OUTPUT = api.MAX_CSL_OUTPUT;
const translateToMsl = api.translateToMsl;
const translateToHlsl = api.translateToHlsl;
const translateToSpirv = api.translateToSpirv;
const translateToCsl = api.translateToCsl;

test "translate vertex shader with struct I/O to MSL" {
    const source =
        \\struct VertIn {
        \\    @location(0) pos: vec4f,
        \\    @location(1) uv: vec2f,
        \\}
        \\struct VertOut {
        \\    @builtin(position) clip_pos: vec4f,
        \\    @location(0) uv: vec2f,
        \\}
        \\@vertex
        \\fn vs_main(in: VertIn) -> VertOut {
        \\    var out: VertOut;
        \\    out.clip_pos = in.pos;
        \\    out.uv = in.uv;
        \\    return out;
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "vertex ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[position]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[attribute(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[attribute(1)]]") != null);
}

test "translate fragment shader with MRT output to MSL" {
    const source =
        \\@group(0) @binding(0) var my_texture: texture_2d<f32>;
        \\@group(0) @binding(1) var my_sampler: sampler;
        \\struct FragOut {
        \\    @location(0) color0: vec4f,
        \\    @location(1) color1: vec4f,
        \\}
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> FragOut {
        \\    var out: FragOut;
        \\    out.color0 = textureSample(my_texture, my_sampler, uv);
        \\    out.color1 = vec4f(1.0, 0.0, 0.0, 1.0);
        \\    return out;
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "fragment ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[color(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[color(1)]]") != null);
}

test "translate fragment shader with builtin inputs and discard to MSL" {
    const source =
        \\@fragment
        \\fn fs_main(
        \\    @builtin(position) frag_coord: vec4f,
        \\    @builtin(front_facing) is_front: bool,
        \\) -> @location(0) vec4f {
        \\    if (!is_front) {
        \\        discard;
        \\    }
        \\    return vec4f(frag_coord.x, frag_coord.y, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "fragment ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[position]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[front_facing]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "discard_fragment()") != null);
}

test "translate vertex shader with builtin vertex_index and instance_index to MSL" {
    const source =
        \\@vertex
        \\fn vs_main(
        \\    @builtin(vertex_index) vid: u32,
        \\    @builtin(instance_index) iid: u32,
        \\) -> @builtin(position) vec4f {
        \\    return vec4f(f32(vid), f32(iid), 0.0, 1.0);
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "vertex ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[vertex_id]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[instance_id]]") != null);
}

test "robustness: sized array index emits min() in MSL output" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32, 16>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let idx = gid.x;
        \\    data[idx] = 1.0;
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    const msl = out[0..len];
    // The robustness pass should have injected min(idx, 15) for the array index.
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") != null);
}

test "robustness: guarded local stride workgroup index elides sized-array clamp" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> out: array<f32, 1>;
        \\var<workgroup> partial_sums: array<f32, 64>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_id) local_invocation_id: vec3u) {
        \\    let lane = local_invocation_id.x;
        \\    partial_sums[lane] = 1.0;
        \\    workgroupBarrier();
        \\    var stride = 32u;
        \\    loop {
        \\        if (stride == 0u) { break; }
        \\        if (lane < stride) {
        \\            partial_sums[lane] = partial_sums[lane] + partial_sums[lane + stride];
        \\        }
        \\        workgroupBarrier();
        \\        stride = stride >> 1u;
        \\    }
        \\    if (lane == 0u) {
        \\        out[0] = partial_sums[0];
        \\    }
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "partial_sums[min") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min((lane + stride)") == null);
}

test "robustness: runtime-sized array index emits arrayLength in MSL output" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let idx = gid.x;
        \\    buf[idx] = 42u;
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    const msl = out[0..len];
    const expect_elided = lean_proof.boundsProven(.gid_1d_storage_buffer);
    try std.testing.expectEqual(!expect_elided, std.mem.indexOf(u8, msl, "min(") != null);
    try std.testing.expectEqual(!expect_elided, std.mem.indexOf(u8, msl, "_doe_sizes") != null);
}

test "arrayLength(&buf) in comparison compiles" {
    try csl_tests.expectArrayLengthInComparisonCompiles(std.testing.allocator, translateToMsl, MAX_OUTPUT);
}
test "robustness: runtime-sized constant index coerces abstract int for MSL min()" {
    try csl_tests.expectRuntimeSizedConstantIndexCoercesAbstractIntForMslMin(std.testing.allocator, translateToMsl, MAX_OUTPUT);
}
test "robustness: vertex array clamp coerces u32 literal for MSL min()" {
    try csl_tests.expectVertexArrayClampCoercesU32LiteralForMslMin(std.testing.allocator, translateToMsl, MAX_OUTPUT);
}
test "arrayLength on struct member compiles to MSL" {
    try csl_tests.expectArrayLengthOnStructMemberCompilesToMsl(std.testing.allocator, translateToMsl, MAX_OUTPUT);
}
test "arrayLength on struct member compiles to HLSL" {
    try csl_tests.expectArrayLengthOnStructMemberCompilesToHlsl(std.testing.allocator, translateToHlsl, MAX_HLSL_OUTPUT);
}
test "arrayLength on struct member compiles to SPIR-V" {
    try csl_tests.expectArrayLengthOnStructMemberCompilesToSpirv(std.testing.allocator, translateToSpirv, MAX_SPIRV_OUTPUT);
}
test "translate element-wise compute shader to CSL" {
    try csl_tests.expectElementWiseComputeShaderCompilesToCsl(std.testing.allocator, translateToCsl, MAX_CSL_OUTPUT);
}
test "vertex shader rejected for CSL emission" {
    try csl_tests.expectVertexShaderRejectedForCsl(std.testing.allocator, translateToCsl, TranslateError.UnsupportedConstruct, MAX_CSL_OUTPUT);
}
