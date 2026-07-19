const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const lean_proof = @import("../../src/verification/lean_proof.zig");
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

test "analyzeToIrWithConfig records tiled gid preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let idx = (gid.x / 4u) * 8u + (gid.x % 4u) + 3u;
        \\    data[idx] = 1u;
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    try std.testing.expect(has_call_named(&baseline_ir.functions.items[0], "min"));

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_tiled)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        try std.testing.expect(has_call_named(&elided_ir.functions.items[0], "min"));
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    const precondition = elided_ir.dispatch_preconditions.items[0];
    try std.testing.expectEqual(ir.DispatchPreconditionKind.gid_component_tiled, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    try std.testing.expectEqual(@as(u64, 8), precondition.element_multiplier);
    try std.testing.expectEqual(@as(u64, 4), precondition.tile_width);
    try std.testing.expectEqual(@as(u64, 4), precondition.element_stride_bytes);
    try std.testing.expectEqual(@as(u64, 3), precondition.element_offset);
    try std.testing.expect(!has_call_named(&elided_ir.functions.items[0], "min"));
}

test "compute runtime translation drops _doe_sizes for proof-covered tiled bounds only" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let idx = (gid.x / 4u) * 8u + (gid.x % 4u) + 3u;
        \\    data[idx] = 1u;
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

    if (lean_proof.boundsProven(.gid_1d_storage_buffer_tiled)) {
        try std.testing.expect(!translation.info.needs_sizes_buf);
    } else {
        try std.testing.expect(translation.info.needs_sizes_buf);
    }
}
