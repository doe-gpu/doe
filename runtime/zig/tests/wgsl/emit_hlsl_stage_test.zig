// emit_hlsl_stage_test.zig — HLSL stage I/O, subgroup, barrier, bit, and texture emission tests.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");

const testing = std.testing;
const allocator = testing.allocator;

const MAX_HLSL_OUTPUT = mod.MAX_HLSL_OUTPUT;
const translateToHlsl = mod.translateToHlsl;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ============================================================
// HLSL type mapping tests (via IR construction)
// ============================================================

test "hlsl vertex: struct return with position and location" {
    const source =
        \\struct VsOut {
        \\    @builtin(position) clip_pos: vec4f,
        \\    @location(0) uv: vec2f,
        \\}
        \\
        \\@vertex
        \\fn vs_main(@builtin(vertex_index) vid: u32) -> VsOut {
        \\    var out: VsOut;
        \\    return out;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "SV_Position"));
    try testing.expect(contains(hlsl, "TEXCOORD0"));
    try testing.expect(contains(hlsl, "vs_main_stage_out"));
    try testing.expect(contains(hlsl, "clip_pos"));
    try testing.expect(contains(hlsl, "uv"));
    // The impl function must exist
    try testing.expect(contains(hlsl, "vs_main_impl"));
}

test "hlsl vertex: struct input parameter flattened to semantics" {
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
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    // Input semantics from flattened struct
    try testing.expect(contains(hlsl, "TEXCOORD0"));
    try testing.expect(contains(hlsl, "TEXCOORD1"));
    // Output semantics
    try testing.expect(contains(hlsl, "SV_Position"));
    // Struct reconstruction in wrapper body
    try testing.expect(contains(hlsl, "VertIn in;"));
}

test "hlsl fragment: scalar return with location" {
    const source =
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    return vec4f(uv, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "SV_Target0"));
    try testing.expect(contains(hlsl, "TEXCOORD0"));
    try testing.expect(contains(hlsl, "fs_main_stage_out"));
}

test "hlsl fragment: struct return with MRT outputs" {
    const source =
        \\struct FragOut {
        \\    @location(0) color0: vec4f,
        \\    @location(1) color1: vec4f,
        \\}
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> FragOut {
        \\    var out: FragOut;
        \\    out.color0 = vec4f(uv, 0.0, 1.0);
        \\    out.color1 = vec4f(1.0, 0.0, 0.0, 1.0);
        \\    return out;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "SV_Target0"));
    try testing.expect(contains(hlsl, "SV_Target1"));
    try testing.expect(contains(hlsl, "fs_main_stage_out"));
    try testing.expect(contains(hlsl, "_result.color0"));
    try testing.expect(contains(hlsl, "_result.color1"));
}

test "hlsl vertex: builtin vertex_index and instance_index" {
    const source =
        \\@vertex
        \\fn vs_main(
        \\    @builtin(vertex_index) vid: u32,
        \\    @builtin(instance_index) iid: u32,
        \\) -> @builtin(position) vec4f {
        \\    return vec4f(f32(vid), f32(iid), 0.0, 1.0);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "SV_VertexID"));
    try testing.expect(contains(hlsl, "SV_InstanceID"));
    try testing.expect(contains(hlsl, "SV_Position"));
}

test "hlsl fragment: builtin front_facing and position inputs" {
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
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "SV_Position"));
    try testing.expect(contains(hlsl, "SV_IsFrontFace"));
    try testing.expect(contains(hlsl, "discard"));
}

test "hlsl fragment: struct return with frag_depth" {
    const source =
        \\struct FragOut {
        \\    @location(0) color: vec4f,
        \\    @builtin(frag_depth) depth: f32,
        \\}
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> FragOut {
        \\    var out: FragOut;
        \\    out.color = vec4f(uv, 0.0, 1.0);
        \\    out.depth = 0.5;
        \\    return out;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "SV_Target0"));
    try testing.expect(contains(hlsl, "SV_Depth"));
    try testing.expect(contains(hlsl, "fs_main_stage_out"));
}

test "hlsl subgroup: subgroupAdd emits WaveActiveSum in HLSL" {
    const source =
        \\enable subgroups;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = subgroupAdd(buf[id.x]);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "WaveActiveSum"));
}

test "hlsl subgroup: subgroupAll emits WaveActiveAllTrue in HLSL" {
    const source =
        \\enable subgroups;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let val = buf[id.x] > 0u;
        \\    if (subgroupAll(val)) {
        \\        buf[id.x] = 1u;
        \\    }
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "WaveActiveAllTrue"));
}

test "hlsl subgroup: subgroupAny emits WaveActiveAnyTrue in HLSL" {
    const source =
        \\enable subgroups;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let val = buf[id.x] > 0u;
        \\    if (subgroupAny(val)) {
        \\        buf[id.x] = 1u;
        \\    }
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "WaveActiveAnyTrue"));
}

test "hlsl subgroup: subgroupBallot emits WaveActiveBallot in HLSL" {
    const source =
        \\enable subgroups;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<vec4u>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = subgroupBallot(id.x < 32u);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "WaveActiveBallot"));
}

test "hlsl subgroup: subgroupElect emits WaveIsFirstLane in HLSL" {
    const source =
        \\enable subgroups;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    if (subgroupElect()) {
        \\        buf[0] = 1u;
        \\    }
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "WaveIsFirstLane()"));
}

test "hlsl subgroup: subgroupShuffleXor emits WaveReadLaneAt with XOR in HLSL" {
    const source =
        \\enable subgroups;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = subgroupShuffleXor(buf[id.x], 1u);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "WaveReadLaneAt("));
    try testing.expect(contains(hlsl, "WaveGetLaneIndex() ^ "));
}

test "hlsl subgroup: subgroupAnd emits WaveActiveBitAnd in HLSL" {
    const source =
        \\enable subgroups;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = subgroupAnd(buf[id.x]);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "WaveActiveBitAnd"));
}

test "hlsl barrier: workgroupBarrier emits GroupMemoryBarrierWithGroupSync" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\var<workgroup> shared_data: array<f32, 64>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_index) idx: u32) {
        \\    shared_data[idx] = buf[idx];
        \\    workgroupBarrier();
        \\    buf[idx] = shared_data[63u - idx];
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "GroupMemoryBarrierWithGroupSync()"));
}

test "hlsl barrier: storageBarrier emits AllMemoryBarrierWithGroupSync" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = buf[id.x] + 1.0;
        \\    storageBarrier();
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "AllMemoryBarrierWithGroupSync()"));
}

test "hlsl barrier: textureBarrier emits DeviceMemoryBarrierWithGroupSync" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = buf[id.x] + 1.0;
        \\    textureBarrier();
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "DeviceMemoryBarrierWithGroupSync()"));
}

test "hlsl bit: countOneBits maps to countbits" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = countOneBits(buf[id.x]);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "countbits("));
}

test "hlsl bit: reverseBits maps to reversebits" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = reverseBits(buf[id.x]);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "reversebits("));
}

test "hlsl bit: firstLeadingBit maps to firstbithigh" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = firstLeadingBit(buf[id.x]);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "firstbithigh("));
}

test "hlsl bit: firstTrailingBit maps to firstbitlow" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = firstTrailingBit(buf[id.x]);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "firstbitlow("));
}

test "hlsl bit: countLeadingZeros emits ternary with firstbithigh" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = countLeadingZeros(buf[id.x]);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "== 0u) ? 32u : (31u - firstbithigh("));
}

test "hlsl bit: countTrailingZeros emits ternary with firstbitlow" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = countTrailingZeros(buf[id.x]);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "== 0u) ? 32u : firstbitlow("));
}

test "hlsl bit: extractBits emits shift-and-mask expression" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = extractBits(buf[id.x], 4u, 8u);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, ">> "));
    try testing.expect(contains(hlsl, "(1u << "));
}

test "hlsl bit: insertBits emits mask-and-or expression" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = insertBits(buf[id.x], 255u, 8u, 8u);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "& ~("));
    try testing.expect(contains(hlsl, "(1u << "));
}

test "hlsl texture: textureNumLevels emits helper call" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[0] = textureNumLevels(tex);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "doe_textureNumLevels_tex()"));
    try testing.expect(contains(hlsl, "uint doe_textureNumLevels_tex()"));
    try testing.expect(contains(hlsl, "GetDimensions(0, w, h, lvls)"));
    try testing.expect(contains(hlsl, "return lvls;"));
}

test "hlsl texture: textureNumLayers emits helper call for 2d array" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d_array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[0] = textureNumLayers(tex);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "doe_textureNumLayers_tex()"));
    try testing.expect(contains(hlsl, "uint doe_textureNumLayers_tex()"));
    try testing.expect(contains(hlsl, "return elems;"));
}

test "hlsl vertex: interpolation modifiers on output struct" {
    const source =
        \\struct VsOut {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) @interpolate(flat) flat_val: f32,
        \\    @location(1) @interpolate(linear) linear_val: vec2f,
        \\    @location(2) @interpolate(perspective, centroid) centroid_val: vec2f,
        \\}
        \\@vertex
        \\fn vs_main(@builtin(vertex_index) vid: u32) -> VsOut {
        \\    var out: VsOut;
        \\    return out;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "nointerpolation float flat_val"));
    try testing.expect(contains(hlsl, "noperspective float2 linear_val"));
    try testing.expect(contains(hlsl, "centroid float2 centroid_val"));
}

test "hlsl fragment: interpolation modifiers on input params" {
    const source =
        \\struct FsIn {
        \\    @location(0) @interpolate(flat) flat_val: f32,
        \\    @location(1) @interpolate(linear, centroid) linear_centroid_val: vec2f,
        \\}
        \\@fragment
        \\fn fs_main(input: FsIn) -> @location(0) vec4f {
        \\    return vec4f(input.flat_val, input.linear_centroid_val, 1.0);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "nointerpolation float flat_val"));
    try testing.expect(contains(hlsl, "noperspective centroid float2 linear_centroid_val"));
}

test "hlsl fragment: MRT output with three render targets" {
    const source =
        \\struct MrtOut {
        \\    @location(0) albedo: vec4f,
        \\    @location(1) normal: vec4f,
        \\    @location(2) emission: vec4f,
        \\}
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> MrtOut {
        \\    var out: MrtOut;
        \\    out.albedo = vec4f(uv, 0.0, 1.0);
        \\    out.normal = vec4f(0.0, 0.0, 1.0, 0.0);
        \\    out.emission = vec4f(0.0);
        \\    return out;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "SV_Target0"));
    try testing.expect(contains(hlsl, "SV_Target1"));
    try testing.expect(contains(hlsl, "SV_Target2"));
    try testing.expect(contains(hlsl, "fs_main_stage_out"));
}
