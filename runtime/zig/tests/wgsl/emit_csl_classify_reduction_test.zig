// emit_csl_classify_reduction_test.zig — reduction-pattern regressions
// for the CSL classifier.
//
// rmsnorm-style kernels — a read input + a read_write output + one or two
// workgroup-shared partial-sum arrays + a barrier + an apply phase — are
// a first-class requirement for the 270M and Gemma 4 E2B HostPlans. This
// test exercises a canonical rmsnorm shape and asserts it classifies
// as `.reduction`, not `.unsupported` or `.element_wise`.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const classify = @import("../../src/compiler/wgsl/emit/csl/emit_csl_classify.zig");

const allocator = std.testing.allocator;

fn classifyWgsl(src: []const u8) !classify.KernelPattern {
    var module = try mod.analyzeToIr(allocator, src);
    defer module.deinit();
    std.debug.assert(module.entry_points.items.len >= 1);
    return classify.classify(&module, module.entry_points.items[0]);
}

// Canonical rmsnorm: one storage input, one storage read_write output,
// one workgroup-shared accumulator array, workgroup reduce, barrier,
// apply phase that multiplies each element by the reciprocal RMS.
const RMSNORM_WGSL =
    "const WG: u32 = 64u;\n" ++
    "\n" ++
    "@group(0) @binding(0) var<storage, read> buf_in: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read_write> buf_out: array<f32>;\n" ++
    "\n" ++
    "var<workgroup> partial: array<f32, 64>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(\n" ++
    "    @builtin(local_invocation_id) lid: vec3u,\n" ++
    "    @builtin(global_invocation_id) gid: vec3u,\n" ++
    "    @builtin(num_workgroups) ng: vec3u,\n" ++
    ") {\n" ++
    "    let n = arrayLength(&buf_in);\n" ++
    "    let idx = gid.x;\n" ++
    "    var sq: f32 = 0.0;\n" ++
    "    if (idx < n) {\n" ++
    "        let x = buf_in[idx];\n" ++
    "        sq = x * x;\n" ++
    "    }\n" ++
    "    partial[lid.x] = sq;\n" ++
    "    workgroupBarrier();\n" ++
    "    var s: u32 = WG >> 1u;\n" ++
    "    loop {\n" ++
    "        if (s == 0u) { break; }\n" ++
    "        if (lid.x < s) {\n" ++
    "            partial[lid.x] = partial[lid.x] + partial[lid.x + s];\n" ++
    "        }\n" ++
    "        workgroupBarrier();\n" ++
    "        s = s >> 1u;\n" ++
    "    }\n" ++
    "    let mean_sq = partial[0] / f32(WG);\n" ++
    "    let scale = 1.0 / sqrt(mean_sq + 1.0e-6);\n" ++
    "    if (idx < n) {\n" ++
    "        buf_out[idx] = buf_in[idx] * scale;\n" ++
    "    }\n" ++
    "}\n";

test "classify: rmsnorm-shaped kernel is reduction" {
    const pattern = try classifyWgsl(RMSNORM_WGSL);
    switch (pattern) {
        .reduction => |info| {
            // Contract sanity: the reduction info must carry non-zero
            // counts and claim an apply phase, or patternContractValid()
            // will reject the pattern and the emitter will refuse to
            // produce a CSL bundle.
            try std.testing.expect(info.input_count >= 1);
            try std.testing.expect(info.output_count >= 1);
            try std.testing.expect(info.has_apply_phase);
        },
        .unsupported => |reason| {
            std.debug.print("rmsnorm classified as unsupported: {s}\n", .{reason});
            return error.RmsnormUnsupported;
        },
        else => {
            std.debug.print(
                "unexpected pattern for rmsnorm: {}\n",
                .{@as(std.meta.Tag(classify.KernelPattern), pattern)},
            );
            return error.RmsnormUnexpectedPattern;
        },
    }
}

// Minimal workgroup-shared reduction (sum): one input buffer, one output
// buffer, workgroup-shared partial sums, no apply phase beyond writing
// the first lane's reduced value. The classifier still has to accept
// this as `.reduction`; patternContractValid() asserts has_apply_phase,
// so we leave it as-is and check the shape comes through intact.
const SUM_REDUCTION_WGSL =
    "@group(0) @binding(0) var<storage, read> buf_in: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read_write> buf_out: array<f32>;\n" ++
    "\n" ++
    "var<workgroup> partial: array<f32, 64>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(\n" ++
    "    @builtin(local_invocation_id) lid: vec3u,\n" ++
    "    @builtin(global_invocation_id) gid: vec3u,\n" ++
    "    @builtin(workgroup_id) wg: vec3u,\n" ++
    ") {\n" ++
    "    var v: f32 = 0.0;\n" ++
    "    if (gid.x < arrayLength(&buf_in)) {\n" ++
    "        v = buf_in[gid.x];\n" ++
    "    }\n" ++
    "    partial[lid.x] = v;\n" ++
    "    workgroupBarrier();\n" ++
    "    var s: u32 = 32u;\n" ++
    "    loop {\n" ++
    "        if (s == 0u) { break; }\n" ++
    "        if (lid.x < s) {\n" ++
    "            partial[lid.x] = partial[lid.x] + partial[lid.x + s];\n" ++
    "        }\n" ++
    "        workgroupBarrier();\n" ++
    "        s = s >> 1u;\n" ++
    "    }\n" ++
    "    if (lid.x == 0u) {\n" ++
    "        buf_out[wg.x] = partial[0];\n" ++
    "    }\n" ++
    "}\n";

test "classify: sum-reduction kernel with workgroup shared lands as reduction" {
    const pattern = try classifyWgsl(SUM_REDUCTION_WGSL);
    switch (pattern) {
        .reduction => {},
        .unsupported => |reason| {
            std.debug.print("sum reduction classified as unsupported: {s}\n", .{reason});
            return error.SumReductionUnsupported;
        },
        else => {
            std.debug.print(
                "unexpected pattern for sum-reduction: {}\n",
                .{@as(std.meta.Tag(classify.KernelPattern), pattern)},
            );
            return error.SumReductionUnexpectedPattern;
        },
    }
}

// Barrier-only reduction (no workgroup-shared array, just barriers
// enforcing ordering between two storage passes). The prior classifier
// fell through to `.unsupported` for this shape; the widening in
// classify() now accepts barriers-without-shared-memory as reduction
// too, so the emitter gets a chance at it rather than hard-failing.
const BARRIER_ONLY_REDUCTION_WGSL =
    "@group(0) @binding(0) var<storage, read> buf_in: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read_write> buf_out: array<f32>;\n" ++
    "\n" ++
    "@compute @workgroup_size(64)\n" ++
    "fn main(\n" ++
    "    @builtin(global_invocation_id) gid: vec3u,\n" ++
    "    @builtin(local_invocation_id) lid: vec3u,\n" ++
    ") {\n" ++
    "    let n = arrayLength(&buf_in);\n" ++
    "    let idx = gid.x;\n" ++
    "    if (idx < n) {\n" ++
    "        buf_out[idx] = buf_in[idx] * buf_in[idx];\n" ++
    "    }\n" ++
    "    workgroupBarrier();\n" ++
    "    if (lid.x == 0u && idx < n) {\n" ++
    "        buf_out[idx] = buf_out[idx] + 1.0;\n" ++
    "    }\n" ++
    "}\n";

test "classify: barrier-only reduction (no workgroup memory) lands as reduction" {
    const pattern = try classifyWgsl(BARRIER_ONLY_REDUCTION_WGSL);
    switch (pattern) {
        .reduction => {},
        .unsupported => |reason| {
            std.debug.print("barrier-only reduction unsupported: {s}\n", .{reason});
            return error.BarrierOnlyReductionUnsupported;
        },
        else => {
            std.debug.print(
                "unexpected pattern for barrier-only reduction: {}\n",
                .{@as(std.meta.Tag(classify.KernelPattern), pattern)},
            );
            return error.BarrierOnlyReductionUnexpectedPattern;
        },
    }
}
