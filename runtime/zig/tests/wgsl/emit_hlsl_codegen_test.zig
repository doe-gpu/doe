// emit_hlsl_codegen_test.zig — HLSL compute, binding, and control-flow emission tests.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const dispatch_contract = @import("../../src/contracts/shader_abi/dispatch_info.zig");
const maps = @import("../../src/compiler/wgsl/emit/hlsl/emit_hlsl_maps.zig");

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

test "hlsl compute: simple shader emits numthreads and SV_DispatchThreadID" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32, 64>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = data[id.x] * 2.0;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "[numthreads(64, 1, 1)]"));
    try testing.expect(contains(hlsl, "SV_DispatchThreadID"));
    try testing.expect(contains(hlsl, "void main"));
}

test "hlsl compute: num_workgroups builtin lowers via dispatch info contract" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32, 1>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(num_workgroups) nwg: vec3u) {
        \\    data[0] = nwg.x;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    try testing.expect(len > 0);
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, dispatch_contract.DISPATCH_INFO_CBUFFER_NAME));
    try testing.expect(contains(hlsl, "register(b0, space7)"));
    try testing.expect(contains(hlsl, dispatch_contract.DISPATCH_INFO_FIELD_NAME));
    try testing.expect(contains(hlsl, "const uint3 nwg = doe_num_workgroups;"));
}

test "hlsl compute: multi-dimensional workgroup size" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32, 256>;
        \\
        \\@compute @workgroup_size(8, 8, 1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x + id.y * 16u] = id.x;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "[numthreads(8, 8, 1)]"));
}

test "hlsl binding: uniform buffer maps to cbuffer register(bN)" {
    const source =
        \\struct Params {
        \\    scale: f32,
        \\    offset: f32,
        \\}
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let s = params.scale;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "register(b0, space0)"));
    try testing.expect(contains(hlsl, "cbuffer"));
}

test "hlsl binding: storage buffer read_write maps to RWStructuredBuffer register(uN)" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32, 16>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[0] = 1.0;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "RWStructuredBuffer"));
    try testing.expect(contains(hlsl, "register(u0, space0)"));
}

test "hlsl binding: storage buffer read maps to StructuredBuffer register(tN)" {
    const source =
        \\@group(0) @binding(0) var<storage, read> data: array<f32, 16>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v = data[0];
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "StructuredBuffer"));
    try testing.expect(!contains(hlsl, "RWStructuredBuffer"));
    try testing.expect(contains(hlsl, "register(t0, space0)"));
}

test "hlsl binding: group 1 maps to space1" {
    const source =
        \\struct Data { value: f32 }
        \\@group(1) @binding(2) var<uniform> params: Data;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v = params.value;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "register(b2, space1)"));
}

test "hlsl: atomic helper functions are emitted in preamble" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32, 4>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[0] = 0.0;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "doe_atomicLoad"));
    try testing.expect(contains(hlsl, "doe_atomicStore"));
    try testing.expect(contains(hlsl, "doe_atomicAdd"));
    try testing.expect(contains(hlsl, "InterlockedExchange"));
}

test "hlsl operator: assign ops map correctly" {
    try testing.expectEqualStrings("=", maps.assign_op_text(.assign));
    try testing.expectEqualStrings("+=", maps.assign_op_text(.add));
    try testing.expectEqualStrings("-=", maps.assign_op_text(.sub));
    try testing.expectEqualStrings("*=", maps.assign_op_text(.mul));
    try testing.expectEqualStrings("/=", maps.assign_op_text(.div));
    try testing.expectEqualStrings("%=", maps.assign_op_text(.rem));
}

test "hlsl operator: binary ops map correctly" {
    try testing.expectEqualStrings("+", maps.binary_op_text(.add));
    try testing.expectEqualStrings("&&", maps.binary_op_text(.logical_and));
    try testing.expectEqualStrings("||", maps.binary_op_text(.logical_or));
    try testing.expectEqualStrings("<<", maps.binary_op_text(.shift_left));
    try testing.expectEqualStrings(">>", maps.binary_op_text(.shift_right));
}

test "hlsl operator: unary ops map correctly" {
    try testing.expectEqualStrings("-", maps.unary_op_text(.neg));
    try testing.expectEqualStrings("!", maps.unary_op_text(.not));
    try testing.expectEqualStrings("~", maps.unary_op_text(.bit_not));
}

test "hlsl struct: user-defined struct appears in output" {
    const source =
        \\struct Params {
        \\    a: f32,
        \\    b: u32,
        \\    c: vec4f,
        \\}
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v = params.a;
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "struct Params"));
    try testing.expect(contains(hlsl, "float a;"));
    try testing.expect(contains(hlsl, "uint b;"));
    try testing.expect(contains(hlsl, "float4 c;"));
}

test "hlsl control flow: if/else emits correctly" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32, 4>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    if (id.x == 0u) {
        \\        data[0] = 1.0;
        \\    } else {
        \\        data[0] = 2.0;
        \\    }
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "if ("));
    try testing.expect(contains(hlsl, "} else {"));
}

test "hlsl control flow: for loop emits while" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32, 16>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    for (var i: u32 = 0u; i < 16u; i = i + 1u) {
        \\        data[i] = f32(i);
        \\    }
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "while ("));
}

test "hlsl workgroup: var<workgroup> emits groupshared" {
    const source =
        \\var<workgroup> shared_data: array<f32, 256>;
        \\
        \\@compute @workgroup_size(256)
        \\fn main(@builtin(local_invocation_index) idx: u32) {
        \\    shared_data[idx] = f32(idx);
        \\}
    ;
    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(allocator, source, &out);
    const hlsl = out[0..len];

    try testing.expect(contains(hlsl, "groupshared"));
}
