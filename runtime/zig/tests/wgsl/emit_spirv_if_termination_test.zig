// emit_spirv_if_termination_test.zig — regression tests for the
// if/else termination-propagation fix in
// `runtime/zig/src/compiler/wgsl/emit/spirv/emit_spirv_fn.zig`.
//
// Before the fix, the .if_ handler unconditionally returned `false`
// (not-terminated) from emit_stmt, even when both branches ended in a
// terminator. That caused emit_function at emit_spirv.zig:299–304 to
// see a non-void function as unterminated and error InvalidIr. The
// fix reports terminated=true when both branches terminate and emits
// OpUnreachable at the orphan merge-label so SPIR-V structured
// control flow stays valid.
//
// These tests lock the contract by compiling each representative
// shape and asserting (a) SPIR-V emits without error, and (b) the
// binary has the SPIR-V magic header.

const std = @import("std");
const spirv = @import("../../src/compiler/wgsl/emit/spirv/spirv_builder.zig");
const mod = @import("../../src/compiler/wgsl/mod.zig");

const testing = std.testing;
const allocator = testing.allocator;

const MAX_SPIRV_OUTPUT = mod.MAX_SPIRV_OUTPUT;
const translateToSpirv = mod.translateToSpirv;

fn read_u32_le(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(bytes[offset .. offset + 4].ptr)), .little);
}

fn expect_spirv_magic(binary: []const u8) !void {
    try testing.expect(binary.len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));
}

test "if/else with both branches returning produces valid SPIR-V" {
    // Minimum repro for the pre-fix InvalidIr. With the fix, this
    // compiles because emit_stmt reports the .if_ as terminated when
    // both branches terminate, and emits OpUnreachable at the orphan
    // merge label.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<u32>;
        \\
        \\fn both_branches_return(x: u32) -> u32 {
        \\    if (x > 0u) {
        \\        return 1u;
        \\    } else {
        \\        return 0u;
        \\    }
        \\}
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
        \\    output[gid.x] = both_branches_return(gid.x);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
}

test "if/else both-return with trailing statement keeps compiling" {
    // Pre-fix this compiled via an incidental path: caller block
    // silently continued after the non-terminated .if_ and the trailing
    // return provided the merge-label's terminator. Lock the behavior.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<u32>;
        \\
        \\fn both_branches_with_trailing(x: u32) -> u32 {
        \\    if (x > 0u) {
        \\        return 1u;
        \\    } else {
        \\        return 0u;
        \\    }
        \\    return 99u;
        \\}
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
        \\    output[gid.x] = both_branches_with_trailing(gid.x);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
}

test "if-without-else then-returning stays compilable" {
    // This shape has always worked (merge_label is reached via the
    // BranchConditional's else path). Test locks that the fix does
    // not regress it.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<u32>;
        \\
        \\fn early_return_then_compute(x: u32) -> u32 {
        \\    if (x > 0u) {
        \\        return 1u;
        \\    }
        \\    return 0u;
        \\}
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
        \\    output[gid.x] = early_return_then_compute(gid.x);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
}

test "nested if-else both-return compiles" {
    // Nested both-return pattern: outer if/else where one branch is
    // itself a both-return if/else. Exercises the termination signal
    // propagating correctly up through nested .if_ emissions.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<u32>;
        \\
        \\fn nested_both(x: u32, y: u32) -> u32 {
        \\    if (x > 0u) {
        \\        if (y > 0u) {
        \\            return 2u;
        \\        } else {
        \\            return 3u;
        \\        }
        \\    } else {
        \\        return 0u;
        \\    }
        \\}
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
        \\    output[gid.x] = nested_both(gid.x, gid.y);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
}

test "if/else both-return inside a loop compiles" {
    // Loop body whose terminal statement is an if-else with both
    // branches returning. Makes sure the fix doesn't mis-identify a
    // loop body as function-terminal.
    const source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<u32>;
        \\@group(0) @binding(1) var<uniform> bound: u32;
        \\
        \\fn first_match(x: u32) -> u32 {
        \\    for (var i: u32 = 0u; i < bound; i = i + 1u) {
        \\        if (i == x) {
        \\            return i;
        \\        } else {
        \\            return 0xFFFFFFFFu;
        \\        }
        \\    }
        \\    return 0u;
        \\}
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
        \\    output[gid.x] = first_match(gid.x);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try expect_spirv_magic(out[0..len]);
}
