// TSIR backend skeleton emitter tests.

const std = @import("std");
const tsir = @import("../../src/compiler/tsir/mod.zig");
const targets = @import("../../src/compiler/targets/mod.zig");

test "tsir backend skeleton emitters expose source-backed code digests" {
    try expectDigest(
        tsir.emit_spir_v.emitterCodeDigest(),
        @embedFile("../../src/compiler/tsir/emit_spir_v.zig"),
        @embedFile("../../src/compiler/tsir/emit_text_skeleton.zig"),
        @embedFile("../../src/compiler/tsir/emit_kernel_body.zig"),
        @embedFile("../../src/compiler/tsir/emit_semantic_metadata.zig"),
    );
    try expectDigest(
        tsir.emit_msl.emitterCodeDigest(),
        @embedFile("../../src/compiler/tsir/emit_msl.zig"),
        @embedFile("../../src/compiler/tsir/emit_text_skeleton.zig"),
        @embedFile("../../src/compiler/tsir/emit_kernel_body.zig"),
        @embedFile("../../src/compiler/tsir/emit_semantic_metadata.zig"),
    );
    try expectDigest(
        tsir.emit_dxil.emitterCodeDigest(),
        @embedFile("../../src/compiler/tsir/emit_dxil.zig"),
        @embedFile("../../src/compiler/tsir/emit_text_skeleton.zig"),
        @embedFile("../../src/compiler/tsir/emit_kernel_body.zig"),
        @embedFile("../../src/compiler/tsir/emit_semantic_metadata.zig"),
    );
}

test "tsir emitter code digests are pairwise distinct across all five backends" {
    // Manifest-lowering entries bind (kernelRef, backend) pairs to an
    // emitter digest so replay can identify the exact emitter that
    // produced a backend artifact. If two emitters ever produce the
    // same code digest — a copy-paste left sources identical, or a
    // refactor collapsed two emitters into one without deleting one
    // side — the binding becomes ambiguous and replay would attribute
    // artifacts to the wrong backend silently. Lock the invariant
    // here so that collision becomes a test failure, not a production
    // ambiguity.
    const digests = [_][32]u8{
        tsir.emit_csl.emitterCodeDigest(),
        tsir.emit_webgpu.emitterCodeDigest(),
        tsir.emit_msl.emitterCodeDigest(),
        tsir.emit_dxil.emitterCodeDigest(),
        tsir.emit_spir_v.emitterCodeDigest(),
    };
    const names = [_][]const u8{ "csl", "webgpu", "msl", "dxil", "spir_v" };
    var i: usize = 0;
    while (i < digests.len) : (i += 1) {
        try std.testing.expect(!allZero(&digests[i]));
        var j: usize = i + 1;
        while (j < digests.len) : (j += 1) {
            if (std.mem.eql(u8, &digests[i], &digests[j])) {
                std.debug.print(
                    "emitter code digest collision: {s} == {s}\n",
                    .{ names[i], names[j] },
                );
                return error.EmitterCodeDigestCollision;
            }
        }
    }
}

test "tsir backend skeleton emitters serialize contract headers" {
    const allocator = std.testing.allocator;
    const function = fixtureFunction(targets.webgpu_generic.descriptor);

    const spir_v = try tsir.emit_spir_v.emitFunction(
        allocator,
        function,
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(spir_v);
    try expectContains(spir_v, "// doe.tsir.spir_v_skeleton.version = 1\n");
    try expectContains(spir_v, "; tsir mechanical skeleton: SPIR-V module body");

    const msl = try tsir.emit_msl.emitFunction(
        allocator,
        function,
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(msl);
    try expectContains(msl, "// doe.tsir.msl_skeleton.version = 1\n");
    try expectContains(msl, "// tsir mechanical skeleton: MSL kernel body");

    const dxil = try tsir.emit_dxil.emitFunction(
        allocator,
        function,
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(dxil);
    try expectContains(dxil, "// doe.tsir.dxil_skeleton.version = 1\n");
    try expectContains(dxil, "; tsir mechanical skeleton: DXIL module body");
}

test "tsir backend skeleton emitters fail closed" {
    const allocator = std.testing.allocator;
    const function = fixtureFunction(targets.webgpu_generic.descriptor);
    const rejections = [_]tsir.RejectionEntry{
        .{
            .reason = .tsir_target_unfit,
            .node_path = "functions[0]",
            .detail = "backend skeleton should not emit rejected realization",
        },
    };
    const realization = tsir.Realization{
        .functions = &[_]tsir.schema.RealizationFunction{function},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &rejections,
    };

    const rejected = tsir.emit_spir_v.emit(
        allocator,
        realization,
        0,
        targets.webgpu_generic.descriptor,
    );
    try std.testing.expectError(tsir.emit_spir_v.EmitError.RejectedRealization, rejected);

    const mismatch = tsir.emit_msl.emitFunction(
        allocator,
        function,
        targets.wse3.descriptor,
    );
    try std.testing.expectError(tsir.emit_msl.EmitError.TargetDescriptorHashMismatch, mismatch);
}

fn fixtureFunction(descriptor: targets.TargetDescriptor) tsir.schema.RealizationFunction {
    const tiles = struct {
        const data = [_]u32{ 16, 2 };
    }.data;
    const residency = struct {
        const data = [_]tsir.schema.ResidencyDecision{
            .{
                .binding_index = 0,
                .class = .host_copied,
                .chunk_bytes = 1024,
            },
        };
    }.data;
    return .{
        .semantic_index = 5,
        .tiles = .{ .per_axis = &tiles },
        .pe_grid = .{ .width = 1, .height = 1 },
        .residency = &residency,
        .collectives = &.{},
        .reductions = &.{},
        .emitter_params_json = "{\"planner\":\"portable\"}",
        .target_descriptor_hash = targets.descriptorHash(descriptor),
    };
}

fn expectDigest(
    actual: [32]u8,
    emitter_source: []const u8,
    common_source: []const u8,
    body_source: []const u8,
    semantic_metadata_source: []const u8,
) !void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(emitter_source);
    h.update(common_source);
    h.update(body_source);
    h.update(semantic_metadata_source);
    var expected: [32]u8 = undefined;
    h.final(&expected);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try std.testing.expect(!allZero(&actual));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing expected fragment:\n{s}\nfull output:\n{s}\n", .{ needle, haystack });
        return error.ExpectedFragmentMissing;
    }
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}
