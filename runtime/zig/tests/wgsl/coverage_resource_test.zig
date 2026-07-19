// coverage_resource_test.zig — WGSL attribute, storage-class, and pointer coverage tests.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const translateToMsl = mod.translateToMsl;
const translateToHlsl = mod.translateToHlsl;
const translateToSpirv = mod.translateToSpirv;
const analyzeToIr = mod.analyzeToIr;
const MAX_OUTPUT = mod.MAX_OUTPUT;
const MAX_HLSL_OUTPUT = mod.MAX_HLSL_OUTPUT;
const MAX_SPIRV_OUTPUT = mod.MAX_SPIRV_OUTPUT;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "attributes: workgroup_size 3D through IR" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(4, 4, 2)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = 1.0;
        \\}
    ;

    var module_ir = try analyzeToIr(std.testing.allocator, source);
    defer module_ir.deinit();

    try std.testing.expect(module_ir.entry_points.items.len >= 1);
    try std.testing.expectEqual(@as(u32, 4), module_ir.entry_points.items[0].workgroup_size[0]);
    try std.testing.expectEqual(@as(u32, 4), module_ir.entry_points.items[0].workgroup_size[1]);
    try std.testing.expectEqual(@as(u32, 2), module_ir.entry_points.items[0].workgroup_size[2]);
}

test "attributes: multiple bind groups through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\@group(1) @binding(0) var<uniform> scale: f32;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    output[id.x] = input[id.x] * scale;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "buffer("));
}

test "storage classes: uniform struct through HLSL" {
    const source =
        \\struct Uniforms {
        \\    width: u32,
        \\    height: u32,
        \\};
        \\
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\@group(0) @binding(1) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = uniforms.width * uniforms.height;
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(contains(hlsl, "cbuffer") or contains(hlsl, "ConstantBuffer"));
}

test "storage classes: read-only storage buffer through SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read> src: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> dst: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    dst[id.x] = src[id.x];
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "pointer param: helper with ptr<storage, f32> MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> val: f32;
        \\
        \\fn add_one(p: ptr<storage, f32, read_write>) {
        \\    *p = *p + 1.0;
        \\}
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    add_one(&val);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    // MSL pointer param must use device address space, not bare element type.
    try std.testing.expect(contains(msl, "device"));
}

test "helper function: bound globals are threaded through MSL calls" {
    const source =
        \\struct Uniforms {
        \\    scale: f32,
        \\};
        \\
        \\@group(0) @binding(0) var<uniform> u: Uniforms;
        \\@group(0) @binding(1) var<storage, read> src: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> dst: array<f32>;
        \\
        \\fn helper(idx: u32) {
        \\    dst[idx] = src[idx] * u.scale;
        \\}
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    helper(id.x);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "void helper(uint idx, constant Uniforms& u [[buffer(0)]], const device float* src [[buffer(1)]], device float* dst [[buffer(2)]], constant uint* _doe_sizes [[buffer(30)]])"));
    try std.testing.expect(contains(msl, "helper(id.x, u, src, dst, _doe_sizes)"));
}

test "pointer param: helper with ptr<storage, f32> HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> val: f32;
        \\
        \\fn add_one(p: ptr<storage, f32, read_write>) {
        \\    *p = *p + 1.0;
        \\}
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    add_one(&val);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    // HLSL pointer param must use inout qualifier.
    try std.testing.expect(contains(hlsl, "inout"));
}

test "pointer param: helper with ptr<storage, f32> SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> val: f32;
        \\
        \\fn add_one(p: ptr<storage, f32, read_write>) {
        \\    *p = *p + 1.0;
        \\}
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    add_one(&val);
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}
