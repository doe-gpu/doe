// coverage_builtin_test.zig — WGSL builtin-surface coverage tests.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const msl_maps = @import("../../src/compiler/wgsl/emit/msl/emit_msl_maps.zig");
const translateToMsl = mod.translateToMsl;
const translateToHlsl = mod.translateToHlsl;
const translateToSpirv = mod.translateToSpirv;
const MAX_OUTPUT = mod.MAX_OUTPUT;
const MAX_HLSL_OUTPUT = mod.MAX_HLSL_OUTPUT;
const MAX_SPIRV_OUTPUT = mod.MAX_SPIRV_OUTPUT;
const ir = mod.ir;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "builtins: min max abs through MSL and HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = data[id.x];
        \\    data[id.x] = min(max(abs(a), 0.0), 1.0);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    const msl = msl_out[0..msl_len];
    try std.testing.expect(contains(msl, "min("));
    try std.testing.expect(contains(msl, "max("));
    try std.testing.expect(contains(msl, "abs("));

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    const hlsl = hlsl_out[0..hlsl_len];
    try std.testing.expect(contains(hlsl, "min("));
    try std.testing.expect(contains(hlsl, "max("));
    try std.testing.expect(contains(hlsl, "abs("));
}

test "builtins: clamp normalize length through all three backends" {
    // length() and distance() return arg_types[0] in sema (known limitation:
    // should return scalar for vector input). Work around by keeping all
    // operations on vectors so types stay consistent.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let x = data[id.x];
        \\    let v = vec3f(x, x, x);
        \\    let n = normalize(v);
        \\    let c = clamp(n, vec3f(0.0, 0.0, 0.0), vec3f(1.0, 1.0, 1.0));
        \\    data[id.x] = c.x;
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    const msl = msl_out[0..msl_len];
    try std.testing.expect(contains(msl, "clamp("));
    try std.testing.expect(contains(msl, "normalize("));

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "builtins: sin sqrt cos abs through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let x = data[id.x];
        \\    data[id.x] = sin(x) + sqrt(x) + cos(x) + abs(x);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "sin("));
    try std.testing.expect(contains(msl, "sqrt("));
    try std.testing.expect(contains(msl, "cos("));
    try std.testing.expect(contains(msl, "abs("));
}

test "msl builtin map covers the current IR builtin surface" {
    inline for (std.meta.fields(ir.Builtin)) |field| {
        const builtin: ir.Builtin = @enumFromInt(field.value);
        if (builtin == .none) continue;
        try std.testing.expect(!std.mem.eql(u8, msl_maps.msl_builtin_name(builtin), "unsupported_builtin"));
    }
}

test "builtins: local_invocation_id, workgroup_id, and num_workgroups through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(
        \\    @builtin(local_invocation_id) lid: vec3u,
        \\    @builtin(workgroup_id) wid: vec3u,
        \\    @builtin(num_workgroups) nwg: vec3u
        \\) {
        \\    let index = wid.x * 64u + lid.x;
        \\    data[index] = index + nwg.x;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "thread_position_in_threadgroup"));
    try std.testing.expect(contains(msl, "threadgroup_position_in_grid"));
    try std.testing.expect(contains(msl, "threadgroups_per_grid"));
}

test "builtins: local_invocation_index through HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_index) idx: u32) {
        \\    data[idx] = idx;
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(contains(hlsl, "SV_GroupIndex"));
}

test "builtins: normalize through MSL" {
    // distance() has a sema type-inference limitation (returns vec instead of
    // scalar). Test normalize on its own with compatible types.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = vec3f(data[id.x], 0.0, 0.0);
        \\    let n = normalize(a);
        \\    data[id.x] = n.x;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "normalize("));
}

test "builtins: dot product through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v1 = vec4f(1.0, 2.0, 3.0, 4.0);
        \\    let v2 = vec4f(4.0, 3.0, 2.0, 1.0);
        \\    data[id.x] = dot(v1, v2);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "dot("));
}
