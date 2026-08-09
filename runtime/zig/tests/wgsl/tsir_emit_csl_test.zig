// TSIR-to-CSL skeleton emitter tests.
//
// The emitter is a contract serializer for planned TSIR realization data. It
// must reflect the realization decisions exactly and fail closed when planning
// has already rejected the target.

const std = @import("std");
const tsir = @import("../../src/compiler/tsir/mod.zig");
const targets = @import("../../src/compiler/targets/mod.zig");

test "tsir csl emitter exposes source-backed code digest" {
    const digest = tsir.emit_csl.emitterCodeDigest();
    var expected: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(@embedFile("../../src/compiler/tsir/emit_csl.zig"));
    h.update(@embedFile("../../src/compiler/tsir/emit_kernel_body.zig"));
    h.update(@embedFile("../../src/compiler/tsir/emit_semantic_metadata.zig"));
    h.final(&expected);
    try std.testing.expectEqualSlices(u8, &expected, &digest);
    try std.testing.expect(!allZero(&digest));
}

test "tsir csl emitter serializes residency grid tiles and collectives" {
    const allocator = std.testing.allocator;

    const tiles = [_]u32{ 64, 8 };
    const residency = [_]tsir.schema.ResidencyDecision{
        .{
            .binding_index = 0,
            .class = .pe_replicated,
        },
        .{
            .binding_index = 1,
            .class = .pe_sliced,
            .axis = 1,
            .shards = 8,
        },
        .{
            .binding_index = 2,
            .class = .fabric_streamed,
            .fabric_color = 3,
            .chunk_bytes = 4096,
        },
    };
    const collectives = [_]tsir.schema.CollectiveRealizationNode{
        .{
            .semantic_index = 0,
            .tree_shape = .linear,
            .fabric_color = 2,
            .group_size = 64,
        },
    };
    const reductions = [_]tsir.schema.ReductionRealizationNode{
        .{
            .semantic_index = 1,
            .tree_shape = .binomial,
        },
    };
    const function = tsir.schema.RealizationFunction{
        .semantic_index = 7,
        .tiles = .{ .per_axis = &tiles },
        .pe_grid = .{ .width = 8, .height = 2 },
        .residency = &residency,
        .collectives = &collectives,
        .reductions = &reductions,
        .emitter_params_json = "{\"planner\":\"test\"}",
        .target_descriptor_hash = targets.descriptorHash(targets.wse3.descriptor),
    };

    const csl = try tsir.emit_csl.emitFunction(allocator, function, targets.wse3.descriptor);
    defer allocator.free(csl);

    try expectContains(csl, "//--- layout.csl ---\n");
    try expectContains(csl, "//--- pe_program.csl ---\n");
    try expectContains(csl, "// target.name = wse3\n");
    try expectContains(csl, "// semantic_index = 7\n");
    try expectContains(csl, "// pe_grid.width = 8\n");
    try expectContains(csl, "// pe_grid.height = 2\n");
    try expectContains(csl, "@set_rectangle(width, height);\n");
    try expectContains(csl, "// tiles.per_axis[0] = 64\n");
    try expectContains(csl, "// tiles.per_axis[1] = 8\n");
    try expectContains(csl, "// residency[0].class = pe_replicated\n");
    try expectContains(csl, "// residency[1].class = pe_sliced\n");
    try expectContains(csl, "// residency[1].axis = 1\n");
    try expectContains(csl, "// residency[1].shards = 8\n");
    try expectContains(csl, "// residency[2].class = fabric_streamed\n");
    try expectContains(csl, "// residency[2].fabric_color = 3\n");
    try expectContains(csl, "// residency[2].chunk_bytes = 4096\n");
    try expectContains(csl, "// collectives[0].semantic_index = 0\n");
    try expectContains(csl, "// collectives[0].tree_shape = linear\n");
    try expectContains(csl, "// collectives[0].fabric_color = 2\n");
    try expectContains(csl, "// collectives[0].group_size = 64\n");
    try expectContains(csl, "// reductions[0].tree_shape = binomial\n");
}

test "tsir csl emitter rejects realization rejections" {
    const allocator = std.testing.allocator;
    const function = emptyFunction(targets.wse3.descriptor);
    const rejections = [_]tsir.RejectionEntry{
        .{
            .reason = .tsir_collective_not_representable,
            .node_path = "functions[0].collectives[0]",
            .detail = "target lacks native collective exactness",
        },
    };
    const realization = tsir.Realization{
        .functions = &[_]tsir.schema.RealizationFunction{function},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &rejections,
    };

    const outcome = tsir.emit_csl.emit(
        allocator,
        realization,
        0,
        targets.wse3.descriptor,
    );
    try std.testing.expectError(tsir.emit_csl.EmitError.RejectedRealization, outcome);
}

test "tsir csl emitter rejects target descriptor hash mismatch" {
    const allocator = std.testing.allocator;
    const function = emptyFunction(targets.webgpu_generic.descriptor);

    const outcome = tsir.emit_csl.emitFunction(
        allocator,
        function,
        targets.wse3.descriptor,
    );
    try std.testing.expectError(tsir.emit_csl.EmitError.TargetDescriptorHashMismatch, outcome);
}

fn emptyFunction(descriptor: targets.TargetDescriptor) tsir.schema.RealizationFunction {
    return .{
        .semantic_index = 0,
        .tiles = .{ .per_axis = &.{} },
        .pe_grid = .{ .width = 1, .height = 1 },
        .residency = &.{},
        .collectives = &.{},
        .reductions = &.{},
        .emitter_params_json = "{}",
        .target_descriptor_hash = targets.descriptorHash(descriptor),
    };
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
