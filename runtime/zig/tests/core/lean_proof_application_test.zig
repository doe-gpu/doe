const std = @import("std");
const ir = @import("../../src/compiler/wgsl/ir/ir.zig");
const wgsl = @import("../../src/compiler/wgsl/mod.zig");

fn functionHasBuiltinCall(function: *const ir.Function, name: []const u8) bool {
    for (function.exprs.items) |expr| {
        if (expr.data != .call) continue;
        if (std.mem.eql(u8, expr.data.call.name, name)) return true;
    }
    return false;
}

test "proof-backed storage elision rejects num_workgroups near miss" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(
        \\    @builtin(global_invocation_id) gid: vec3u,
        \\    @builtin(num_workgroups) num_wg: vec3u,
        \\) {
        \\    data[num_wg.x] = 1u;
        \\}
    ;

    var module_ir = try wgsl.analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer module_ir.deinit();

    try std.testing.expectEqual(@as(usize, 0), module_ir.dispatch_preconditions.items.len);
    try std.testing.expect(functionHasBuiltinCall(&module_ir.functions.items[0], "min"));
}

test "proof-backed storage elision rejects subtraction near miss" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    data[gid.x - 1u] = 1u;
        \\}
    ;

    var module_ir = try wgsl.analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer module_ir.deinit();

    try std.testing.expectEqual(@as(usize, 0), module_ir.dispatch_preconditions.items.len);
    try std.testing.expect(functionHasBuiltinCall(&module_ir.functions.items[0], "min"));
}

test "proof-backed texture elision rejects mixed builtin coords" {
    const source =
        \\@group(0) @binding(0) var src_tex: texture_2d<f32>;
        \\@group(0) @binding(1) var dst_tex: texture_storage_2d<rgba8unorm, write>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn main(
        \\    @builtin(global_invocation_id) gid: vec3u,
        \\    @builtin(num_workgroups) num_wg: vec3u,
        \\) {
        \\    let sample = textureLoad(src_tex, vec2u(num_wg.x, gid.y), 0);
        \\    textureStore(dst_tex, vec2u(num_wg.x, gid.y), sample);
        \\}
    ;

    var module_ir = try wgsl.analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_texture_bounds = true,
    });
    defer module_ir.deinit();

    try std.testing.expectEqual(@as(usize, 0), module_ir.texture_dispatch_preconditions.items.len);
    try std.testing.expect(functionHasBuiltinCall(&module_ir.functions.items[0], "clamp"));
}
