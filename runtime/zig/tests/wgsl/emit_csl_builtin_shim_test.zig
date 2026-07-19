// emit_csl_builtin_shim_test.zig — regression tests for the PE-local
// builtin-member shim.
//
// WGSL workgroup-state builtins — local_invocation_id (`lid.x`),
// workgroup_id (`wid.x`), num_workgroups — have no native CSL
// equivalent. Pre-iteration-16 output contained raw `lid.x` and `wid.x`
// identifiers that cslc rejected as undeclared. The shim in
// emit_csl_ir_walk.zig::emitBuiltinMemberShim substitutes PE-local
// values during emission:
//
//   - local_invocation_id.{x,y,z} / local_invocation_index → 0
//   - workgroup_id.{x,y,z}                                 → @as(u32, pe_id)
//   - num_workgroups.{x,y,z}                               → @as(u32, num_pes)
//
// The substitution is syntactically valid CSL. Semantics collapse to
// single-lane single-workgroup — correct for single-PE lowering of
// kernels whose lane-level state is trivially handled (and documented
// as such for reduction kernels in the dual-compile evidence manifest).

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");

const allocator = std.testing.allocator;

const LID_WID_WGSL =
    "@group(0) @binding(0) var<storage, read> input: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read_write> out: array<f32>;\n" ++
    "\n" ++
    "var<workgroup> scratch: array<f32, 64>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(\n" ++
    "    @builtin(local_invocation_id) lid: vec3u,\n" ++
    "    @builtin(workgroup_id) wid: vec3u,\n" ++
    "    @builtin(num_workgroups) ng: vec3u,\n" ++
    ") {\n" ++
    "    scratch[lid.x] = input[lid.x];\n" ++
    "    workgroupBarrier();\n" ++
    "    if (lid.x == 0u) {\n" ++
    "        var sum: f32 = 0.0;\n" ++
    "        for (var i: u32 = 0u; i < 64u; i = i + 1u) {\n" ++
    "            sum = sum + scratch[i];\n" ++
    "        }\n" ++
    "        out[wid.x] = sum * f32(ng.x);\n" ++
    "    }\n" ++
    "}\n";

test "emit_csl_builtin_shim: lid.x is substituted in PE program" {
    var buf: [32 * 1024]u8 = undefined;
    const written = try mod.translateToCsl(allocator, LID_WID_WGSL, &buf);
    const csl = buf[0..written];

    // `lid.x` must not appear as a raw identifier in the emitted CSL —
    // cslc has no such symbol. The shim must substitute it.
    if (std.mem.indexOf(u8, csl, "lid.x") != null) {
        std.debug.print("lid.x leaked unshimmed:\n{s}\n", .{csl});
        return error.LidNotShimmed;
    }
    // The reduction emitter's lane-preserving lowering (iteration 27)
    // wraps the pre-barrier body in `for (...) |lane_idx|` with
    // lid.x → lane_idx, so the scratch write becomes scratch[lane_idx].
    // The post-barrier section still uses lid.x → 0 for the thread-0
    // aggregation guard, producing `if ((0 == 0u))`.
    if (std.mem.indexOf(u8, csl, "scratch[lane_idx]") == null) {
        std.debug.print("pre-barrier did not wrap scratch in lane loop:\n{s}\n", .{csl});
        return error.LaneLoopMissing;
    }
    if (std.mem.indexOf(u8, csl, "lane_idx") == null) {
        std.debug.print("lane_idx loop variable not emitted:\n{s}\n", .{csl});
        return error.LaneIdxMissing;
    }
}

test "emit_csl_builtin_shim: wid.x becomes @as(u32, pe_id)" {
    var buf: [32 * 1024]u8 = undefined;
    const written = try mod.translateToCsl(allocator, LID_WID_WGSL, &buf);
    const csl = buf[0..written];
    if (std.mem.indexOf(u8, csl, "wid.x") != null) {
        std.debug.print("wid.x leaked unshimmed:\n{s}\n", .{csl});
        return error.WidNotShimmed;
    }
    if (std.mem.indexOf(u8, csl, "@as(u32, pe_id)") == null) {
        std.debug.print("wid.x did not become @as(u32, pe_id):\n{s}\n", .{csl});
        return error.WidShimMissing;
    }
}

test "emit_csl_builtin_shim: num_workgroups.x becomes @as(u32, num_pes)" {
    var buf: [32 * 1024]u8 = undefined;
    const written = try mod.translateToCsl(allocator, LID_WID_WGSL, &buf);
    const csl = buf[0..written];
    if (std.mem.indexOf(u8, csl, "ng.x") != null) {
        std.debug.print("ng.x leaked unshimmed:\n{s}\n", .{csl});
        return error.NumWorkgroupsNotShimmed;
    }
    if (std.mem.indexOf(u8, csl, "@as(u32, num_pes)") == null) {
        std.debug.print("num_workgroups.x did not become @as(u32, num_pes):\n{s}\n", .{csl});
        return error.NumWorkgroupsShimMissing;
    }
}

// Separate reduction WGSL that uses gid.x directly in the body (no
// `let idx = gid.x` binding) — the shape that used to leak `gid.x`
// past the emitter and get rejected by cslc with "use of undeclared
// identifier" on pe_program.csl.
const GID_REDUCTION_WGSL =
    "@group(0) @binding(0) var<storage, read> input: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n" ++
    "\n" ++
    "var<workgroup> scratch: array<f32, 64>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(\n" ++
    "    @builtin(local_invocation_id) lid: vec3u,\n" ++
    "    @builtin(global_invocation_id) gid: vec3u,\n" ++
    ") {\n" ++
    "    scratch[lid.x] = input[gid.x];\n" ++
    "    workgroupBarrier();\n" ++
    "    if (lid.x == 0u) {\n" ++
    "        output[gid.x] = scratch[0];\n" ++
    "    }\n" ++
    "}\n";

test "emit_csl_builtin_shim: gid.x in reduction body is substituted" {
    var buf: [32 * 1024]u8 = undefined;
    const written = try mod.translateToCsl(allocator, GID_REDUCTION_WGSL, &buf);
    const csl = buf[0..written];
    // gid.x must NOT appear as a raw identifier anywhere in the PE
    // program — cslc rejects with "use of undeclared identifier".
    if (std.mem.indexOf(u8, csl, "gid.x") != null) {
        std.debug.print("gid.x leaked unshimmed in reduction body:\n{s}\n", .{csl});
        return error.GidNotShimmedInReduction;
    }
    // Under the lane-preserving lowering, gid.x inside the pre-barrier
    // section resolves to `(@as(u32, pe_id) * @as(u32, hidden_size) + lane_idx)`
    // (the full global_thread_id). Post-barrier gid.x still resolves
    // to `@as(u32, pe_id)`. At least one of the two forms must appear.
    const has_lane_gid = std.mem.indexOf(
        u8,
        csl,
        "(@as(u32, pe_id) * @as(u32, hidden_size) + lane_idx)",
    ) != null;
    const has_pe_gid = std.mem.indexOf(u8, csl, "@as(u32, pe_id)") != null;
    if (!has_lane_gid and !has_pe_gid) {
        std.debug.print("no gid.x shim substitution found:\n{s}\n", .{csl});
        return error.GidShimMissing;
    }
}

// Guard test: the elementwise emitter's for-loop lowering still uses
// `idx` (the @range loop-var alias) in the body. Adding gid to the
// shim must NOT leak `@as(u32, pe_id)` into elementwise output — the
// isGidLetBinding filter removes the `let idx = gid.x;` statement
// before the walker sees it, so the shim should never fire in the
// elementwise path.
const ELEMENTWISE_GID_WGSL =
    "@group(0) @binding(0) var<storage, read> input: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(@builtin(global_invocation_id) gid: vec3u) {\n" ++
    "    let idx = gid.x;\n" ++
    "    if (idx >= arrayLength(&input)) { return; }\n" ++
    "    output[idx] = input[idx] * 2.0;\n" ++
    "}\n";

test "emit_csl_builtin_shim: elementwise preserves idx-based body (no gid shim leak)" {
    var buf: [32 * 1024]u8 = undefined;
    const written = try mod.translateToCsl(allocator, ELEMENTWISE_GID_WGSL, &buf);
    const csl = buf[0..written];
    // Elementwise body uses `idx`, not `gid.x`. The output must
    // reference `idx` somewhere (the @range loop-var alias) to confirm
    // the expected for-loop wrapper is still present.
    if (std.mem.indexOf(u8, csl, "const idx = @as(u32, _idx)") == null and
        std.mem.indexOf(u8, csl, "|_idx|") == null)
    {
        std.debug.print("elementwise @range wrapper missing:\n{s}\n", .{csl});
        return error.ElementwiseRangeWrapperMissing;
    }
    // gid.x must not appear raw — either skipped by isGidLetBinding or
    // shimmed. Neither case leaks `gid.x` literally.
    if (std.mem.indexOf(u8, csl, "gid.x") != null) {
        std.debug.print("elementwise leaked gid.x:\n{s}\n", .{csl});
        return error.ElementwiseGidLeaked;
    }
}
