// mod_backend_translation_test.zig — Backend-specific WGSL translation contract tests.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const translateToMsl = mod.translateToMsl;
const translateToHlsl = mod.translateToHlsl;
const translateToSpirv = mod.translateToSpirv;
const MAX_OUTPUT = mod.MAX_OUTPUT;
const MAX_HLSL_OUTPUT = mod.MAX_HLSL_OUTPUT;
const MAX_SPIRV_OUTPUT = mod.MAX_SPIRV_OUTPUT;

test "hlsl emit num_workgroups lowers through dispatch info contract" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32, 1>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(num_workgroups) nwg: vec3u) {
        \\    data[0] = nwg.x;
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "cbuffer DoeDispatchInfo") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "const uint3 nwg = doe_num_workgroups;") != null);
}

test "translate bitcast to HLSL uses asuint and asfloat" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let as_uint = bitcast<u32>(1.0f);
        \\    let as_float = bitcast<f32>(as_uint);
        \\    data[id.x] = bitcast<u32>(as_float);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "asuint(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "asfloat(") != null);
}

test "translate subgroup builtins to HLSL Wave intrinsics" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(32)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let base = data[id.x];
        \\    let reduced = subgroupAdd(base);
        \\    let prefix = subgroupExclusiveAdd(base);
        \\    let lane = subgroupBroadcast(base, 0u);
        \\    let shuffled = subgroupShuffle(base, 1u);
        \\    let mixed = subgroupShuffleXor(base, 1u);
        \\    data[id.x] = reduced + prefix + lane + shuffled + mixed;
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "WaveActiveSum(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "WavePrefixSum(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "WaveReadLaneAt(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "WaveGetLaneIndex()") != null);
}

test "translate atomic builtins to HLSL helpers" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> value: atomic<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let old = atomicAdd(value, 1u);
        \\    atomicStore(value, old);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_atomicAdd(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_atomicStore(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "InterlockedAdd(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "InterlockedExchange(") != null);
}

test "translate signed atomic builtins to HLSL helpers" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> value: atomic<i32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let old = atomicAdd(value, 1);
        \\    atomicStore(value, old);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "int doe_atomicAdd(inout int v, int a)") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "void doe_atomicStore(inout int value, int next)") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_atomicAdd(value, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_atomicStore(value, old)") != null);
}

test "translate pack and unpack builtins to HLSL helpers" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let packed = pack2x16float(vec2f(1.0, 2.0));
        \\    let unpacked = unpack2x16float(packed);
        \\    if (unpacked.x > 0.0) {
        \\        data[id.x] = packed;
        \\    }
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_pack2x16float(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_unpack2x16float(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "f16tof32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "f32tof16(") != null);
}

test "translate HLSL math name remapping fract mix inverseSqrt" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = fract(1.5) + inverseSqrt(4.0) + mix(0.0, 1.0, 0.5);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "frac(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "rsqrt(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "lerp(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "fract") == null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "inverseSqrt") == null);
}

test "translate degrees radians to HLSL inline multiply" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = degrees(1.0) + radians(180.0);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "57.29577951308232") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "0.017453292519943295") != null);
}

test "translate compound assignment with inferred f32 local to MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read> lhs: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var acc = 0.0;
        \\    acc += lhs[id.x];
        \\    out[id.x] = acc;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "translate select builtin to HLSL ternary" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = select(0.0, 1.0, data[id.x] > 0.5);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "?") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, ":") != null);
}

test "translate select builtin to MSL ternary" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = select(0.0, 1.0, data[id.x] > 0.5);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "?") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, ":") != null);
}

test "translate select builtin to SPIR-V OpSelect" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = select(0.0, 1.0, data[id.x] > 0.5);
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "translate pack and unpack 4x8 normalized builtins to HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let packed_u = pack4x8unorm(vec4f(0.0, 0.5, 1.0, 0.25));
        \\    let packed_s = pack4x8snorm(vec4f(-1.0, -0.5, 0.5, 1.0));
        \\    let unpacked_u = unpack4x8unorm(packed_u);
        \\    let unpacked_s = unpack4x8snorm(packed_s);
        \\    if (unpacked_u.y >= 0.0 && unpacked_s.z >= -1.0) {
        \\        data[id.x] = packed_u ^ packed_s;
        \\    }
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_pack4x8unorm(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_pack4x8snorm(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_unpack4x8unorm(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_unpack4x8snorm(") != null);
}

test "translate texture builtins to HLSL" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var out_tex: texture_storage_2d<rgba8unorm, write>;
        \\@group(0) @binding(2) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let sample = textureLoad(tex, vec2u(id.xy), 0);
        \\    textureStore(out_tex, vec2u(id.xy), sample);
        \\    data[id.x] = sample.x;
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, ".Load(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "RWTexture2D<float4>") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "?") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_textureDimensions_tex(uint(0))") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_textureDimensions_out_tex()") != null);
}

test "translate newly accepted math builtins end-to-end to HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = tan(1.0) + acos(0.5) + asin(0.5) + atan(1.0) + cosh(1.0) + sinh(1.0) + sign(1.0);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "tan(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "acos(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "sign(") != null);
}

test "translate newly accepted math builtins end-to-end to SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = tan(1.0) + acos(0.5) + asin(0.5) + atan(1.0) + cosh(1.0) + sinh(1.0) + sign(1.0);
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "translate atan2 and ldexp to SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = atan2(1.0, 2.0) + ldexp(1.0, 2);
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "translate arrayLength to HLSL helper" {
    const source =
        \\@group(0) @binding(0) var<storage, read> data: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out_data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    out_data[id.x] = arrayLength(data);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "uint doe_arrayLength_data()") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "data.GetDimensions(count, stride);") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "doe_arrayLength_data()") != null);
}

test "translate arrayLength to MSL runtime sizes helper" {
    const source =
        \\@group(0) @binding(0) var<storage, read> data: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    out[id.x] = arrayLength(data);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "constant uint* _doe_sizes [[buffer(30)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "uint(_doe_sizes[0] / sizeof(float))") != null);
}

test "translate arrayLength to SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read> data: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out_data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    out_data[id.x] = arrayLength(data);
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}
