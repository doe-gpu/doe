const std = @import("std");
const mod = @import("../../src/doe_wgsl/mod.zig");
const lean_proof = @import("../../src/lean_proof.zig");
const runtime_compile = @import("../../src/doe_wgsl/runtime_compile.zig");

const analyzeToIrWithConfig = mod.analyzeToIrWithConfig;
const ir = mod.ir;
const MAX_OUTPUT = mod.MAX_OUTPUT;

fn has_call_named(function: *const ir.Function, name: []const u8) bool {
    for (function.exprs.items) |expr| {
        if (expr.data == .call and std.mem.eql(u8, expr.data.call.name, name)) return true;
    }
    return false;
}

fn expect_gid_component_precondition(
    precondition: ir.DispatchPrecondition,
    element_multiplier: u64,
    loop_limit: u64,
    loop_limit_multiplier: u64,
    element_offset: u64,
) !void {
    try std.testing.expectEqual(ir.DispatchPreconditionKind.gid_component, precondition.kind);
    try std.testing.expectEqual(@as(u8, 0), precondition.gid_axis);
    try std.testing.expectEqual(element_multiplier, precondition.element_multiplier);
    try std.testing.expectEqual(loop_limit, precondition.loop_limit);
    try std.testing.expectEqual(loop_limit_multiplier, precondition.loop_limit_multiplier);
    try std.testing.expectEqual(@as(u64, 4), precondition.element_stride_bytes);
    try std.testing.expectEqual(element_offset, precondition.element_offset);
}

test "analyzeToIrWithConfig records generalized for-loop gid preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    for (var i: u32 = 1u; i <= 4u; i = i + 2u) {
        \\        data[gid.x + i + 2u] = 1u;
        \\    }
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    try std.testing.expect(has_call_named(&baseline_ir.functions.items[0], "min"));

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_loop_offset)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        try std.testing.expect(has_call_named(&elided_ir.functions.items[0], "min"));
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    try expect_gid_component_precondition(elided_ir.dispatch_preconditions.items[0], 1, 5, 1, 2);
    try std.testing.expect(!has_call_named(&elided_ir.functions.items[0], "min"));
}

test "compute runtime translation drops _doe_sizes for dispatch-validated generalized for-loop bounds" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    for (var i: u32 = 1u; i <= 4u; i = i + 2u) {
        \\        data[gid.x + i + 2u] = 1u;
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

    try std.testing.expect(!translation.info.needs_sizes_buf);
    try std.testing.expect(translation.info.dispatch_preconditions.len > 0);
}

test "analyzeToIrWithConfig records generalized guarded loop gid preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    var i: u32 = 1u;
        \\    loop {
        \\        if (i > 3u) { break; }
        \\        data[gid.x + i + 2u] = 1u;
        \\        continuing {
        \\            i = i + 2u;
        \\        }
        \\    }
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    try std.testing.expect(has_call_named(&baseline_ir.functions.items[0], "min"));

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_loop_offset)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        try std.testing.expect(has_call_named(&elided_ir.functions.items[0], "min"));
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    try expect_gid_component_precondition(elided_ir.dispatch_preconditions.items[0], 1, 4, 1, 2);
    try std.testing.expect(!has_call_named(&elided_ir.functions.items[0], "min"));
}

test "compute runtime translation drops _doe_sizes for dispatch-validated generalized guarded loop bounds" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    var i: u32 = 1u;
        \\    loop {
        \\        if (i > 3u) { break; }
        \\        data[gid.x + i + 2u] = 1u;
        \\        continuing {
        \\            i = i + 2u;
        \\        }
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

    try std.testing.expect(!translation.info.needs_sizes_buf);
    try std.testing.expect(translation.info.dispatch_preconditions.len > 0);
}

test "analyzeToIrWithConfig records affine loop gid preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    for (var i: u32 = 1u; i <= 4u; i = i + 2u) {
        \\        data[gid.x * 2u + i * 3u + 1u] = 1u;
        \\    }
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    try std.testing.expect(has_call_named(&baseline_ir.functions.items[0], "min"));

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_loop_affine)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        try std.testing.expect(has_call_named(&elided_ir.functions.items[0], "min"));
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    try expect_gid_component_precondition(elided_ir.dispatch_preconditions.items[0], 2, 5, 3, 1);
    try std.testing.expect(!has_call_named(&elided_ir.functions.items[0], "min"));
}

test "analyzeToIrWithConfig records matvec-style guarded loop preconditions" {
    const source =
        \\const kPackedCols : u32 = 8u;
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let rowBy4 = gid.x;
        \\    var col: u32 = 0u;
        \\    loop {
        \\        if (col >= kPackedCols) {
        \\            break;
        \\        }
        \\        data[((4u * rowBy4 + 2u) * kPackedCols) + col] = 1u;
        \\        col = col + 1u;
        \\    }
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    try std.testing.expect(has_call_named(&baseline_ir.functions.items[0], "min"));

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_loop_affine)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        try std.testing.expect(has_call_named(&elided_ir.functions.items[0], "min"));
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    try expect_gid_component_precondition(elided_ir.dispatch_preconditions.items[0], 32, 8, 1, 16);
    try std.testing.expect(!has_call_named(&elided_ir.functions.items[0], "min"));
}

test "compute runtime translation drops _doe_sizes for dispatch-validated affine loop bounds" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    for (var i: u32 = 1u; i <= 4u; i = i + 2u) {
        \\        data[gid.x * 2u + i * 3u + 1u] = 1u;
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

    try std.testing.expect(!translation.info.needs_sizes_buf);
    try std.testing.expect(translation.info.dispatch_preconditions.len > 0);
}

test "analyzeToIrWithConfig records while-loop gid preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    var i: u32 = 1u;
        \\    while (i <= 4u) {
        \\        data[gid.x + i + 2u] = 1u;
        \\        i = i + 2u;
        \\    }
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    try std.testing.expect(has_call_named(&baseline_ir.functions.items[0], "min"));

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_loop_offset)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        try std.testing.expect(has_call_named(&elided_ir.functions.items[0], "min"));
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    try expect_gid_component_precondition(elided_ir.dispatch_preconditions.items[0], 1, 5, 1, 2);
    try std.testing.expect(!has_call_named(&elided_ir.functions.items[0], "min"));
}

test "compute runtime translation drops _doe_sizes for dispatch-validated while-loop bounds" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    var i: u32 = 1u;
        \\    while (i <= 4u) {
        \\        data[gid.x + i + 2u] = 1u;
        \\        i = i + 2u;
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

    try std.testing.expect(!translation.info.needs_sizes_buf);
    try std.testing.expect(translation.info.dispatch_preconditions.len > 0);
}

test "analyzeToIrWithConfig records descending for-loop gid preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    for (var i: u32 = 6u; i >= 2u; i = i - 2u) {
        \\        data[gid.x + i + 1u] = 1u;
        \\    }
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    try std.testing.expect(has_call_named(&baseline_ir.functions.items[0], "min"));

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_loop_offset)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        try std.testing.expect(has_call_named(&elided_ir.functions.items[0], "min"));
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    try expect_gid_component_precondition(elided_ir.dispatch_preconditions.items[0], 1, 7, 1, 1);
    try std.testing.expect(!has_call_named(&elided_ir.functions.items[0], "min"));
}

test "compute runtime translation drops _doe_sizes for dispatch-validated descending for-loop bounds" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    for (var i: u32 = 6u; i >= 2u; i = i - 2u) {
        \\        data[gid.x + i + 1u] = 1u;
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

    try std.testing.expect(!translation.info.needs_sizes_buf);
    try std.testing.expect(translation.info.dispatch_preconditions.len > 0);
}

test "analyzeToIrWithConfig records descending while-loop gid preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    var i: u32 = 7u;
        \\    while (i > 1u) {
        \\        data[gid.x + i + 2u] = 1u;
        \\        i -= 2u;
        \\    }
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    try std.testing.expect(has_call_named(&baseline_ir.functions.items[0], "min"));

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_loop_offset)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        try std.testing.expect(has_call_named(&elided_ir.functions.items[0], "min"));
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    try expect_gid_component_precondition(elided_ir.dispatch_preconditions.items[0], 1, 8, 1, 2);
    try std.testing.expect(!has_call_named(&elided_ir.functions.items[0], "min"));
}

test "analyzeToIrWithConfig records descending guarded affine loop preconditions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    var i: u32 = 6u;
        \\    loop {
        \\        if (i < 2u) { break; }
        \\        data[gid.x * 2u + i * 3u + 1u] = 1u;
        \\        continuing {
        \\            i -= 2u;
        \\        }
        \\    }
        \\}
    ;

    var baseline_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{});
    defer baseline_ir.deinit();
    try std.testing.expect(has_call_named(&baseline_ir.functions.items[0], "min"));

    var elided_ir = try analyzeToIrWithConfig(std.testing.allocator, source, .{
        .elide_proven_bounds = true,
    });
    defer elided_ir.deinit();

    if (!lean_proof.boundsProven(.gid_1d_storage_buffer_loop_affine)) {
        try std.testing.expectEqual(@as(usize, 0), elided_ir.dispatch_preconditions.items.len);
        try std.testing.expect(has_call_named(&elided_ir.functions.items[0], "min"));
        return;
    }

    try std.testing.expectEqual(@as(usize, 1), elided_ir.dispatch_preconditions.items.len);
    try expect_gid_component_precondition(elided_ir.dispatch_preconditions.items[0], 2, 7, 3, 1);
    try std.testing.expect(!has_call_named(&elided_ir.functions.items[0], "min"));
}
