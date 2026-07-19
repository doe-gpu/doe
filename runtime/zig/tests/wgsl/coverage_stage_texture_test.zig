// coverage_stage_texture_test.zig — WGSL stage-output and texture-surface coverage tests.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const translateToMsl = mod.translateToMsl;
const translateToHlsl = mod.translateToHlsl;
const translateToSpirv = mod.translateToSpirv;
const MAX_OUTPUT = mod.MAX_OUTPUT;
const MAX_HLSL_OUTPUT = mod.MAX_HLSL_OUTPUT;
const MAX_SPIRV_OUTPUT = mod.MAX_SPIRV_OUTPUT;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "vertex: multiple location outputs through SPIR-V" {
    const source =
        \\struct VertOut {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) color: vec4f,
        \\    @location(1) uv: vec2f,
        \\};
        \\
        \\@vertex
        \\fn main(@builtin(vertex_index) vi: u32) -> VertOut {
        \\    var out: VertOut;
        \\    out.pos = vec4f(0.0, 0.0, 0.0, 1.0);
        \\    out.color = vec4f(1.0, 0.0, 0.0, 1.0);
        \\    out.uv = vec2f(0.0, 0.0);
        \\    return out;
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "fragment: solid color output through MSL HLSL SPIR-V" {
    const source =
        \\@fragment
        \\fn main() -> @location(0) vec4f {
        \\    return vec4f(0.2, 0.4, 0.6, 1.0);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    // MSL uses "fragment" as a function qualifier, not [[fragment]].
    try std.testing.expect(contains(msl_out[0..msl_len], "main_fragment"));

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(contains(hlsl_out[0..hlsl_len], "SV_Target0"));

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "texture_1d textureLoad compiles across MSL HLSL SPIR-V" {
    const source =
        \\@group(0) @binding(0) var t: texture_1d<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let val = textureLoad(t, id.x, 0);
        \\    out[id.x] = val.x;
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(contains(msl_out[0..msl_len], "texture1d"));
    try std.testing.expect(contains(msl_out[0..msl_len], ".get_width("));
    try std.testing.expect(contains(msl_out[0..msl_len], ".read("));

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(contains(hlsl_out[0..hlsl_len], "Texture1D"));
    try std.testing.expect(contains(hlsl_out[0..hlsl_len], ".Load(int2("));

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "texture_cube compiles to MSL" {
    const source =
        \\@group(0) @binding(0) var t: texture_cube<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let dims = textureDimensions(t, 0);
        \\    out[id.x] = f32(dims.x);
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    try std.testing.expect(contains(out[0..len], "texturecube"));
}

test "texture_cube compiles to HLSL" {
    const source =
        \\@group(0) @binding(0) var t: texture_cube<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let dims = textureDimensions(t, 0);
        \\    out[id.x] = f32(dims.x);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    try std.testing.expect(contains(out[0..len], "TextureCube"));
}

test "texture_cube compiles to SPIR-V" {
    const source =
        \\@group(0) @binding(0) var t: texture_cube<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let dims = textureDimensions(t, 0);
        \\    out[id.x] = f32(dims.x);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "texture_depth_cube compiles to MSL" {
    const source =
        \\@group(0) @binding(0) var t: texture_depth_cube;
        \\@group(0) @binding(1) var s: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let dims = textureDimensions(t, 0);
        \\    out[id.x] = f32(dims.x);
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    try std.testing.expect(contains(out[0..len], "depthcube"));
}

test "texture_depth_2d textureDimensions compiles to MSL" {
    const source =
        \\@group(0) @binding(0) var t: texture_depth_2d;
        \\@group(0) @binding(1) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let dims = textureDimensions(t, 0);
        \\    out[id.x] = f32(dims.x);
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    try std.testing.expect(contains(out[0..len], "depth2d"));
    try std.testing.expect(contains(out[0..len], ".get_width("));
}

test "texture_2d_array compiles to MSL" {
    const source =
        \\@group(0) @binding(0) var t: texture_2d_array<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let dims = textureDimensions(t, 0);
        \\    out[id.x] = f32(dims.x);
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    try std.testing.expect(contains(out[0..len], "texture2d_array"));
}

test "texture_2d_array compiles to HLSL" {
    const source =
        \\@group(0) @binding(0) var t: texture_2d_array<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let dims = textureDimensions(t, 0);
        \\    out[id.x] = f32(dims.x);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    try std.testing.expect(contains(out[0..len], "Texture2DArray"));
}

test "texture_2d_array compiles to SPIR-V" {
    const source =
        \\@group(0) @binding(0) var t: texture_2d_array<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let dims = textureDimensions(t, 0);
        \\    out[id.x] = f32(dims.x);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}
