// emit_spirv_builtin_test.zig — SPIR-V builtin and texture emission tests.

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

// ============================================================
// HLSL type mapping tests (via IR construction)
// ============================================================

test "spirv builtin: any and all reduce bool vectors" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> out_data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let mask = (id.xyxy < vec4<u32>(2u)) & vec4<bool>(true, false, true, true);
        \\    let value = select(0u, 1u, any(mask.yw)) + select(0u, 2u, all(mask.xw));
        \\    out_data[0] = value;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.Any));
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.All));
}

test "spirv builtin: coarse derivatives emit native opcodes" {
    const source =
        \\struct FragIn {
        \\    @location(0) uv: vec2f,
        \\}
        \\
        \\@fragment
        \\fn main(in: FragIn) -> @location(0) vec4f {
        \\    let dx = dpdxCoarse(in.uv);
        \\    let dy = dpdyCoarse(in.uv);
        \\    let fw = fwidthCoarse(in.uv);
        \\    let v = dx + dy + fw;
        \\    return vec4f(v.x, v.y, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.DPdxCoarse));
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.DPdyCoarse));
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.FwidthCoarse));
}

test "spirv texture: textureNumLevels emits OpImageQueryLevels" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out_data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    out_data[0] = textureNumLevels(tex);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.ImageQueryLevels));
}

test "spirv texture: sampled textureDimensions uses OpImageQuerySizeLod" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out_data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let dims = textureDimensions(tex);
        \\    out_data[0] = dims.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.ImageQuerySizeLod));
}

test "spirv texture: textureSample produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureSample(tex, samp, uv).x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.ImageSampleImplicitLod));
}

test "spirv texture: textureSampleLevel produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureSampleLevel(tex, samp, uv, 0.0).x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.ImageSampleExplicitLod));
}

test "spirv texture: textureSampleBias emits implicit-lod sample" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureSampleBias(tex, samp, uv, 1.0).x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.ImageSampleImplicitLod));
}

test "spirv texture: textureSampleCompare produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var shadow_tex: texture_depth_2d;
        \\@group(0) @binding(1) var shadow_samp: sampler_comparison;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureSampleCompare(shadow_tex, shadow_samp, uv, 0.5);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.ImageSampleDrefImplicitLod));
}

test "spirv texture: textureSampleCompareLevel produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var shadow_tex: texture_depth_2d;
        \\@group(0) @binding(1) var shadow_samp: sampler_comparison;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureSampleCompareLevel(shadow_tex, shadow_samp, uv, 0.5);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
    try testing.expectEqual(@as(u32, 1), count_spirv_opcode(out[0..len], spirv.Opcode.ImageSampleDrefExplicitLod));
}

test "spirv texture: textureGather produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureGather(0, tex, samp, uv).x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv texture: textureGatherCompare produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var shadow_tex: texture_depth_2d;
        \\@group(0) @binding(1) var shadow_samp: sampler_comparison;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureGatherCompare(shadow_tex, shadow_samp, uv, 0.5).x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv texture: textureSampleGrad produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    let ddx = vec2f(0.01, 0.0);
        \\    let ddy = vec2f(0.0, 0.01);
        \\    out_data[id.x] = textureSampleGrad(tex, samp, uv, ddx, ddy).x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv texture: textureSampleOffset produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    let off = vec2i(1, 0);
        \\    out_data[id.x] = textureSampleOffset(tex, samp, uv, off).x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv texture: textureSampleLevelOffset produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    let off = vec2i(1, 0);
        \\    out_data[id.x] = textureSampleLevelOffset(tex, samp, uv, 0.0, off).x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: countOneBits produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = countOneBits(buf[id.x]);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: reverseBits produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = reverseBits(buf[id.x]);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: extractBits produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = extractBits(buf[id.x], 4u, 8u);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: insertBits produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = insertBits(buf[id.x], 0xFFu, 4u, 8u);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: countLeadingZeros produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = countLeadingZeros(buf[id.x]);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: countTrailingZeros produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = countTrailingZeros(buf[id.x]);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: firstLeadingBit produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = firstLeadingBit(buf[id.x]);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: firstTrailingBit produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = firstTrailingBit(buf[id.x]);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: saturate produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = saturate(buf[id.x]);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: reflect produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = vec3f(1.0, 0.0, 0.0);
        \\    let n = vec3f(0.0, 1.0, 0.0);
        \\    let r = reflect(a, n);
        \\    buf[id.x] = r.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: refract produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = vec3f(1.0, 0.0, 0.0);
        \\    let n = vec3f(0.0, 1.0, 0.0);
        \\    let r = refract(a, n, 1.0);
        \\    buf[id.x] = r.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: select produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = select(0.0, 1.0, buf[id.x] > 0.5);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: storage texture r32float format produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_storage_2d<r32float, write>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    textureStore(tex, vec2i(0, 0), vec4f(1.0, 0.0, 0.0, 1.0));
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: storage texture rgba32float format produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba32float, write>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    textureStore(tex, vec2i(0, 0), vec4f(1.0, 0.0, 0.0, 1.0));
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: storage texture rgba8uint format produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8uint, write>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    textureStore(tex, vec2i(0, 0), vec4u(255, 0, 0, 255));
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: storage texture rgba8sint format produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8sint, write>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    textureStore(tex, vec2i(0, 0), vec4i(127, 0, 0, 127));
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv texture: textureDimensions produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out_data: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let dims = textureDimensions(tex, 0);
        \\    out_data[id.x] = dims.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: subgroupBroadcast produces valid SPIR-V" {
    const source =
        \\enable subgroups;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = subgroupBroadcast(buf[id.x], 0u);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: subgroupShuffle produces valid SPIR-V" {
    const source =
        \\enable subgroups;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = subgroupShuffle(buf[id.x], id.x ^ 1u);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: workgroupBarrier produces valid SPIR-V" {
    const source =
        \\var<workgroup> shared: array<f32, 64>;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_index) lid: u32) {
        \\    shared[lid] = buf[lid];
        \\    workgroupBarrier();
        \\    buf[lid] = shared[63u - lid];
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: bitcast produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let f = bitcast<f32>(buf[id.x]);
        \\    buf[id.x] = bitcast<u32>(f + 1.0);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: pack2x16float and unpack2x16float produce valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v = unpack2x16float(buf[id.x]);
        \\    buf[id.x] = pack2x16float(v + vec2f(1.0, 1.0));
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: atomicAdd produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> counter: atomic<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    atomicAdd(&counter, 1u);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: multiple math builtins produce valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var v = buf[id.x];
        \\    v = sin(v);
        \\    v = cos(v);
        \\    v = exp(v);
        \\    v = log(v);
        \\    v = sqrt(v);
        \\    v = abs(v);
        \\    v = floor(v);
        \\    v = ceil(v);
        \\    v = round(v);
        \\    v = trunc(v);
        \\    v = fract(v);
        \\    v = pow(v, 2.0);
        \\    v = min(v, 1.0);
        \\    v = max(v, 0.0);
        \\    v = clamp(v, 0.0, 1.0);
        \\    buf[id.x] = v;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: transpose produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var m: mat2x2<f32> = mat2x2<f32>(vec2f(1.0, 0.0), vec2f(0.0, 1.0));
        \\    let t: mat2x2<f32> = transpose(m);
        \\    buf[id.x] = t[0].x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: determinant produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var m: mat2x2<f32> = mat2x2<f32>(vec2f(1.0, 0.0), vec2f(0.0, 1.0));
        \\    buf[id.x] = determinant(m);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: textureNumLevels produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out_data: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    out_data[id.x] = textureNumLevels(tex);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: textureNumLayers produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d_array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out_data: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    out_data[id.x] = textureNumLayers(tex);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: textureBarrier produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = 1.0;
        \\    textureBarrier();
        \\    buf[id.x] = 2.0;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: subgroupElect produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    if subgroupElect() {
        \\        buf[0u] = 1u;
        \\    }
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: subgroupBroadcastFirst produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = subgroupBroadcastFirst(buf[id.x]);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: subgroupShuffleDown produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = subgroupShuffleDown(buf[id.x], 1u);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: subgroupInclusiveAdd produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = subgroupInclusiveAdd(buf[id.x]);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: subgroupMul produces valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = subgroupMul(buf[id.x]);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}

test "spirv builtin: subgroup bitwise ops produce valid SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = subgroupAnd(buf[id.x]);
        \\    let o = subgroupOr(buf[id.x]);
        \\    let x = subgroupXor(buf[id.x]);
        \\    buf[id.x] = a + o + x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
}
