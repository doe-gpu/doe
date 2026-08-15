// coverage_type_decl_test.zig — WGSL type-system and declaration coverage tests.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const translateToMsl = mod.translateToMsl;
const translateToHlsl = mod.translateToHlsl;
const translateToSpirv = mod.translateToSpirv;
const analyzeToIr = mod.analyzeToIr;
const MAX_OUTPUT = mod.MAX_OUTPUT;
const MAX_HLSL_OUTPUT = mod.MAX_HLSL_OUTPUT;
const MAX_SPIRV_OUTPUT = mod.MAX_SPIRV_OUTPUT;
const ir = mod.ir;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "type system: i32 storage buffer round-trips through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<i32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = 42;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "int"));
}

test "type system: u32 bitwise operations through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = data[id.x];
        \\    let b = a & 0xFFu;
        \\    let c = b | 0x0Fu;
        \\    let d = c ^ 0x55u;
        \\    data[id.x] = d;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "type system: bool let binding with comparison through SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let flag: bool = data[id.x] > 0.0;
        \\    if (flag) {
        \\        data[id.x] = 1.0;
        \\    }
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "type system: vec2 and vec3 constructor emission through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v2 = vec2f(1.0, 2.0);
        \\    let v3 = vec3f(v2, 3.0);
        \\    data[id.x] = v3.z;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "float2("));
    try std.testing.expect(contains(msl, "float3("));
}

test "type system: integer vector shorthand types through HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let v2u = vec2u(1u, 2u);
        \\    let v2i = vec2i(3, 4);
        \\    data[id.x] = v2u.x + u32(v2i.x);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(contains(hlsl, "uint2("));
    try std.testing.expect(contains(hlsl, "int2("));
}

test "type system: fixed-size array field in struct through SPIR-V" {
    const source =
        \\struct Params {
        \\    weights: array<f32, 8>,
        \\};
        \\
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\@group(0) @binding(1) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = params.weights[0];
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "declarations: var with explicit f32 type annotation through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var acc: f32 = 0.0;
        \\    acc = acc + data[id.x];
        \\    data[id.x] = acc;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "declarations: module-scope const used in function body through MSL" {
    const source =
        \\const SCALE: f32 = 2.5;
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = data[id.x] * SCALE;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "declarations: override constant with default through IR" {
    const source =
        \\override BLOCK_SIZE: u32 = 64u;
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = f32(BLOCK_SIZE);
        \\}
    ;

    var module_ir = try analyzeToIr(std.testing.allocator, source);
    defer module_ir.deinit();

    var found_override = false;
    for (module_ir.globals.items) |global| {
        if (global.class == .override_) {
            found_override = true;
            try std.testing.expect(global.initializer != null);
        }
    }
    try std.testing.expect(found_override);
}

test "declarations: struct with mixed scalar and vector fields through IR" {
    const source =
        \\struct Config {
        \\    count: u32,
        \\    threshold: f32,
        \\    offset: vec2f,
        \\};
        \\
        \\@group(0) @binding(0) var<uniform> config: Config;
        \\@group(0) @binding(1) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = config.threshold + config.offset.x;
        \\}
    ;

    var module_ir = try analyzeToIr(std.testing.allocator, source);
    defer module_ir.deinit();

    try std.testing.expectEqual(@as(usize, 1), module_ir.structs.items.len);
    try std.testing.expectEqual(@as(usize, 3), module_ir.structs.items[0].fields.items.len);
}

test "declarations: fixed-size array parameter through MSL HLSL and SPIR-V" {
    const source =
        \\fn sum4(values: array<u32, 4>) -> u32 {
        \\    return values[0] + values[1] + values[2] + values[3];
        \\}
        \\
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var values: array<u32, 4>;
        \\    values[0] = 1u;
        \\    values[1] = 2u;
        \\    values[2] = 3u;
        \\    values[3] = 4u;
        \\    data[id.x] = sum4(values);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(contains(msl_out[0..msl_len], "sum4("));

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(contains(hlsl_out[0..hlsl_len], "sum4("));

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "declarations: array length const expression in workgroup array through MSL" {
    const source =
        \\const TILE: u32 = 16u;
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\var<workgroup> tile_a: array<f32, TILE * TILE>;
        \\
        \\@compute @workgroup_size(TILE, TILE, 1)
        \\fn main(@builtin(local_invocation_id) lid: vec3u, @builtin(workgroup_id) wid: vec3u) {
        \\    tile_a[lid.y * TILE + lid.x] = 0.0;
        \\    workgroupBarrier();
        \\    data[wid.x] = tile_a[lid.x];
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    try std.testing.expect(contains(out[0..len], "threadgroup float tile_a[256];"));
    try std.testing.expect(!contains(out[0..len], "threadgroup array<"));
}

test "declarations: scalar-wrapped array length through backends" {
    const source =
        \\struct Wrapped {
        \\    values: array<vec4<f32>, i32(4)>,
        \\}
        \\@group(0) @binding(0) var<storage, read_write> data: array<Wrapped>;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    data[0].values[0] = vec4<f32>(1.0);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    try std.testing.expect(try translateToMsl(std.testing.allocator, source, &msl_out) > 0);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    try std.testing.expect(try translateToHlsl(std.testing.allocator, source, &hlsl_out) > 0);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    try std.testing.expect(try translateToSpirv(std.testing.allocator, source, &spirv_out) > 0);
}

test "declarations: helper function call through MSL" {
    const source =
        \\fn square(x: f32) -> f32 {
        \\    return x * x;
        \\}
        \\
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = square(data[id.x]);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "square("));
}

test "declarations: helper function with multiple params through HLSL" {
    const source =
        \\fn add_scaled(a: f32, b: f32, scale: f32) -> f32 {
        \\    return a + b * scale;
        \\}
        \\
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = add_scaled(1.0, data[id.x], 0.5);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(contains(hlsl, "add_scaled("));
}

test "type system: f32 type constructor from u32 through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = f32(id.x);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "float("));
}

test "type system: u32 type constructor from f32 through HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var val: f32 = 3.14;
        \\    data[id.x] = u32(val);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(contains(hlsl, "uint("));
}

test "enable: f16 with half-precision vector through MSL" {
    const source =
        \\enable f16;
        \\
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let h: f16 = 1.5h;
        \\    let hv = vec2<f16>(h, 2.0h);
        \\    data[id.x] = f32(hv.x + hv.y);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "half"));
}

test "type system: atomic type with atomicLoad through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> counter: atomic<u32>;
        \\@group(0) @binding(1) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let val = atomicLoad(counter);
        \\    data[id.x] = val;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "atomic_load_explicit"));
}
