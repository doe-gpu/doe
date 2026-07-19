const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const runtime_compile = @import("../../src/compiler/wgsl/runtime/runtime_compile.zig");

const analyzeToIrWithConfig = mod.analyzeToIrWithConfig;
const ir = mod.ir;
const MAX_OUTPUT = mod.MAX_OUTPUT;

fn has_call_named(function: *const ir.Function, name: []const u8) bool {
    for (function.exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, name)) return true;
    }
    return false;
}

test "analyzeToIrWithConfig elides provable workgroup tile clamps" {
    const source =
        \\const TILE_K: u32 = 16u;
        \\const THREAD_M: u32 = 4u;
        \\const WG_N: u32 = 16u;
        \\var<workgroup> shared_tile: array<f32, 1024>;
        \\@compute @workgroup_size(16, 16, 1)
        \\fn main(@builtin(local_invocation_id) lid: vec3u) {
        \\    let tx = lid.x;
        \\    let ty = lid.y;
        \\    let tid = ty * WG_N + tx;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        let elem_idx = tid * 4u + i;
        \\        shared_tile[elem_idx] = 1.0;
        \\    }
        \\    workgroupBarrier();
        \\    for (var k: u32 = 0u; k < TILE_K; k = k + 1u) {
        \\        let a = shared_tile[((ty * THREAD_M + 3u) * TILE_K) + k];
        \\        shared_tile[0u] = a;
        \\    }
        \\}
    ;

    var module_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer module_ir.deinit();

    try std.testing.expect(!has_call_named(&module_ir.functions.items[0], "min"));
}

test "compute runtime translation drops workgroup tile min clamps" {
    const source =
        \\const TILE_K: u32 = 16u;
        \\const THREAD_M: u32 = 4u;
        \\const WG_N: u32 = 16u;
        \\var<workgroup> shared_tile: array<f32, 1024>;
        \\@compute @workgroup_size(16, 16, 1)
        \\fn main(@builtin(local_invocation_id) lid: vec3u) {
        \\    let tx = lid.x;
        \\    let ty = lid.y;
        \\    let tid = ty * WG_N + tx;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        let elem_idx = tid * 4u + i;
        \\        shared_tile[elem_idx] = 1.0;
        \\    }
        \\    workgroupBarrier();
        \\    for (var k: u32 = 0u; k < TILE_K; k = k + 1u) {
        \\        let a = shared_tile[((ty * THREAD_M + 3u) * TILE_K) + k];
        \\        shared_tile[0u] = a;
        \\    }
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    var translation = try runtime_compile.translateToMslForComputeRuntime(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer translation.info.deinit(std.testing.allocator);

    const msl = out[0..translation.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "shared_tile[min(") == null);
}

test "compute runtime translation keeps unknown workgroup indices clamped" {
    const source =
        \\@group(0) @binding(0) var<storage, read> idxs: array<u32, 1>;
        \\var<workgroup> shared_tile: array<f32, 64>;
        \\@compute @workgroup_size(8, 1, 1)
        \\fn main(@builtin(local_invocation_id) lid: vec3u) {
        \\    let idx = idxs[0u];
        \\    shared_tile[idx] = f32(lid.x);
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    var translation = try runtime_compile.translateToMslForComputeRuntime(
        std.testing.allocator,
        source,
        &out,
        null,
        0,
    );
    defer translation.info.deinit(std.testing.allocator);

    const msl = out[0..translation.len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "shared_tile[min(") != null);
}
