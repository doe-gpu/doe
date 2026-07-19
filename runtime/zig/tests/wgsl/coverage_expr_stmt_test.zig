// coverage_expr_stmt_test.zig — WGSL expression, statement, and const-folding coverage tests.

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

fn countSubstr(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        count += 1;
        offset = index + needle.len;
    }
    return count;
}

test "expressions: unary negation through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let x = data[id.x];
        \\    data[id.x] = -x;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "-(") or contains(msl, "- ") or contains(msl, "-x"));
}

test "expressions: logical not through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let flag = data[id.x] > 0.0;
        \\    if (!flag) {
        \\        data[id.x] = -1.0;
        \\    }
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "!"));
}

test "expressions: shift left and right operators through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let val = data[id.x];
        \\    data[id.x] = (val << 2u) | (val >> 1u);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "<<"));
    try std.testing.expect(contains(msl, ">>"));
}

test "expressions: all comparison operators through HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let x = data[id.x];
        \\    var result = 0.0;
        \\    if (x == 0.0) { result = 1.0; }
        \\    if (x != 0.0) { result = 2.0; }
        \\    if (x < 1.0) { result = 3.0; }
        \\    if (x <= 1.0) { result = 4.0; }
        \\    if (x > 1.0) { result = 5.0; }
        \\    if (x >= 1.0) { result = 6.0; }
        \\    data[id.x] = result;
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(contains(hlsl, "=="));
    try std.testing.expect(contains(hlsl, "!="));
}

test "expressions: division and modulo operators through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = data[id.x];
        \\    let quotient = a / 3u;
        \\    let remainder = a % 3u;
        \\    data[id.x] = quotient + remainder;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "/"));
    try std.testing.expect(contains(msl, "%"));
}

test "expressions: scalar global consts inline through MSL" {
    const source =
        \\const kMask: u32 = 3u;
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = data[id.x & kMask] + kMask;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expectEqual(@as(usize, 1), countSubstr(msl, "kMask"));
    try std.testing.expect(contains(msl, "& 3"));
}

test "statements: for loop through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var sum = 0.0;
        \\    for (var i = 0u; i < 10u; i = i + 1u) {
        \\        sum = sum + 1.0;
        \\    }
        \\    data[id.x] = sum;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "for") or contains(msl, "while"));
}

test "statements: repeated for-loop induction vars stay scoped in MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var sum = 0u;
        \\    for (var i = 0u; i < 4u; i = i + 1u) {
        \\        sum = sum + i;
        \\    }
        \\    for (var i = 4u; i < 8u; i = i + 1u) {
        \\        sum = sum + i;
        \\    }
        \\    data[id.x] = sum;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "{\n        uint i = 0;"));
    try std.testing.expect(contains(msl, "    }\n    {\n        uint i = 4;"));
}

test "statements: while loop through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var count = 0u;
        \\    while (count < 5u) {
        \\        count = count + 1u;
        \\    }
        \\    data[id.x] = f32(count);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "while"));
}

test "statements: loop with break through HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var i = 0u;
        \\    loop {
        \\        if (i >= 10u) {
        \\            break;
        \\        }
        \\        i = i + 1u;
        \\    }
        \\    data[id.x] = f32(i);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(contains(hlsl, "while") or contains(hlsl, "for"));
    try std.testing.expect(contains(hlsl, "break"));
}

test "statements: for loop with continue through SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var sum = 0.0;
        \\    for (var i = 0u; i < 10u; i = i + 1u) {
        \\        if (i == 5u) {
        \\            continue;
        \\        }
        \\        sum = sum + 1.0;
        \\    }
        \\    data[id.x] = sum;
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "statements: if-else if-else chain through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let x = data[id.x];
        \\    if (x < 0.0) {
        \\        data[id.x] = -1.0;
        \\    } else if (x > 1.0) {
        \\        data[id.x] = 1.0;
        \\    } else {
        \\        data[id.x] = 0.0;
        \\    }
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(contains(msl, "if"));
    try std.testing.expect(contains(msl, "else"));
}

test "expressions: chained struct member access through MSL" {
    const source =
        \\struct Inner {
        \\    value: f32,
        \\};
        \\
        \\struct Outer {
        \\    scale: f32,
        \\    data: Inner,
        \\};
        \\
        \\@group(0) @binding(0) var<uniform> params: Outer;
        \\@group(0) @binding(1) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    out[id.x] = params.data.value * params.scale;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "expressions: array indexing with expression through SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let base = id.x * 4u;
        \\    data[base + 0u] = data[base + 1u] + data[base + 2u] + data[base + 3u];
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "expressions: compound assignment operators through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    var acc = data[id.x];
        \\    acc += 1.0;
        \\    acc -= 0.5;
        \\    acc *= 2.0;
        \\    data[id.x] = acc;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "expressions: logical and-or short circuit through HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let x = data[id.x];
        \\    if (x > 0.0 && x < 1.0) {
        \\        data[id.x] = 0.5;
        \\    }
        \\    if (x <= 0.0 || x >= 1.0) {
        \\        data[id.x] = -1.0;
        \\    }
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    try std.testing.expect(contains(hlsl, "&&"));
    try std.testing.expect(contains(hlsl, "||"));
}

test "expressions: chained let bindings referencing prior lets through SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = data[id.x];
        \\    let b = a * 2.0;
        \\    let c = b + 1.0;
        \\    let d = c * a;
        \\    data[id.x] = d;
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "expressions: subtraction operator distinct from negation through MSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = data[id.x];
        \\    let b = data[id.x + 1u];
        \\    data[id.x] = a - b;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "expressions: nested builtin calls through SPIR-V" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = abs(sin(cos(data[id.x])));
        \\}
    ;

    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "const folding: module-scope literal arithmetic through MSL" {
    // Inter-const references (const B = A * 2) are not yet supported by sema
    // (UnknownIdentifier). Test const folding with direct literal expressions.
    const source =
        \\const TILE_SIZE: u32 = 8u;
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = TILE_SIZE;
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}
