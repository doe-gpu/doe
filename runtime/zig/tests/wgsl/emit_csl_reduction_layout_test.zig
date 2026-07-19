// emit_csl_reduction_layout_test.zig — regression test for the
// single-PE reduction layout routing contract.
//
// Prior to iteration 17, emitReductionLayout wrote an east-west
// allreduce chain whose middle-PE entry declared
//   .routes = .{ .rx = .{WEST, RAMP}, .tx = .{EAST} }
// which wse3 rejects with "expected at most 1 input direction(s)".
// The layout is also semantically wrong: the non-distributed
// reduction PE program (emit_csl_reduction.zig) runs each PE
// independently and never consumes the chained value.
//
// This test locks in the replacement: the single-PE reduction layout
// must NOT declare any fabric routing with multiple rx directions on
// a single color.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");

const allocator = std.testing.allocator;

const RMSNORM_WGSL =
    "@group(0) @binding(0) var<storage, read> input: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n" ++
    "\n" ++
    "var<workgroup> partial: array<f32, 64>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(\n" ++
    "    @builtin(local_invocation_id) lid: vec3u,\n" ++
    "    @builtin(global_invocation_id) gid: vec3u,\n" ++
    ") {\n" ++
    "    partial[lid.x] = input[gid.x] * input[gid.x];\n" ++
    "    workgroupBarrier();\n" ++
    "    if (lid.x == 0u) {\n" ++
    "        var s: f32 = 0.0;\n" ++
    "        for (var i: u32 = 0u; i < 64u; i = i + 1u) {\n" ++
    "            s = s + partial[i];\n" ++
    "        }\n" ++
    "        output[gid.x] = s;\n" ++
    "    }\n" ++
    "}\n";

test "emit_csl_reduction_layout: no multi-rx route configs (wse3 compatible)" {
    var buf: [32 * 1024]u8 = undefined;
    const written = try mod.translateToCsl(allocator, RMSNORM_WGSL, &buf);
    const csl = buf[0..written];

    // Hard reject the pre-fix pattern. `.rx = .{WEST, RAMP}` and any
    // other two-direction rx spec on a single route config is invalid
    // on wse3 (the canonical SDK 1.4 target).
    const broken_patterns = [_][]const u8{
        ".rx = .{WEST, RAMP}",
        ".rx = .{RAMP, WEST}",
        ".rx = .{WEST, EAST}",
        ".rx = .{EAST, WEST}",
        ".rx = .{EAST, RAMP}",
        ".rx = .{RAMP, EAST}",
    };
    for (broken_patterns) |pat| {
        if (std.mem.indexOf(u8, csl, pat) != null) {
            std.debug.print("found multi-rx route config `{s}` (rejected on wse3):\n{s}\n", .{ pat, csl });
            return error.MultiRxRouteLeaked;
        }
    }

    // Positive signal: the single-PE reduction layout comment should be
    // present and the pre-fix "east-west allreduce chain" should not.
    if (std.mem.indexOf(u8, csl, "single-PE reduction") == null) {
        std.debug.print("expected single-PE reduction layout marker. Output:\n{s}\n", .{csl});
        return error.SinglePeLayoutMarkerMissing;
    }
    if (std.mem.indexOf(u8, csl, "east-west allreduce chain") != null) {
        return error.StaleAllreduceCommentLeaked;
    }
}
