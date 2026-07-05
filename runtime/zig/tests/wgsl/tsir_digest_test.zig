const std = @import("std");
const digest = @import("../../src/tsir/digest.zig");
const schema = @import("../../src/tsir/schema.zig");

const canonicalizeManifestLoweringEntry = digest.canonicalizeManifestLoweringEntry;
const compute = digest.compute;
const computeWithEmitterDigest = digest.computeWithEmitterDigest;
const manifestLoweringEntryDigest = digest.manifestLoweringEntryDigest;

test "digest is stable and distinct for semantic vs realization" {
    const allocator = std.testing.allocator;
    const semantic = schema.Semantic{
        .functions = &.{},
        .rejections = &.{},
    };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const d1 = try compute(allocator, semantic, realization, "emitter.v0");
    const d2 = try compute(allocator, semantic, realization, "emitter.v0");
    try std.testing.expectEqualSlices(u8, &d1.semantic, &d2.semantic);
    try std.testing.expectEqualSlices(u8, &d1.realization, &d2.realization);
    try std.testing.expect(!std.mem.eql(u8, &d1.semantic, &d1.realization));
}

test "precomputed emitter digest participates verbatim" {
    const allocator = std.testing.allocator;
    const semantic = schema.Semantic{
        .functions = &.{},
        .rejections = &.{},
    };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0x11} ** 32,
        .rejections = &.{},
    };
    const emitter_digest = [_]u8{0xA5} ** 32;
    const d = try computeWithEmitterDigest(
        allocator,
        semantic,
        realization,
        emitter_digest,
    );
    try std.testing.expectEqualSlices(u8, &emitter_digest, &d.emitter);
}

test "frontendVersion participates in semantic digest" {
    const allocator = std.testing.allocator;
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    const unversioned = schema.Semantic{
        .functions = &.{},
        .rejections = &.{},
    };
    const versioned_v1 = schema.Semantic{
        .frontend_version = "frontend-0.1.0",
        .functions = &.{},
        .rejections = &.{},
    };
    const versioned_v2 = schema.Semantic{
        .frontend_version = "frontend-0.2.0",
        .functions = &.{},
        .rejections = &.{},
    };

    const d_unversioned = try compute(allocator, unversioned, realization, "emitter.v0");
    const d_v1 = try compute(allocator, versioned_v1, realization, "emitter.v0");
    const d_v1_again = try compute(allocator, versioned_v1, realization, "emitter.v0");
    const d_v2 = try compute(allocator, versioned_v2, realization, "emitter.v0");

    try std.testing.expectEqualSlices(u8, &d_v1.semantic, &d_v1_again.semantic);
    try std.testing.expect(!std.mem.eql(u8, &d_v1.semantic, &d_v2.semantic));
    try std.testing.expect(!std.mem.eql(u8, &d_unversioned.semantic, &d_v1.semantic));
}

test "manifest lowering entry canonicalizes with lex-sorted keys" {
    const allocator = std.testing.allocator;
    const invariants = [_]schema.AlgorithmExactInvariant{
        .reduction_order,
        .tree_shape,
    };
    const entry = schema.ManifestLoweringEntry{
        .kernel_ref = "gemma-4-e2b.rmsnorm",
        .backend = "wse3",
        .target_descriptor_correctness_hash = [_]u8{0x11} ** 32,
        .frontend_version = "frontend-0.1.0",
        .tsir_semantic_digest = [_]u8{0x22} ** 32,
        .tsir_realization_digest = [_]u8{0x33} ** 32,
        .emitter_digest = [_]u8{0x44} ** 32,
        .compiler_version = "doe-0.3.2",
        .exactness = .{
            .class = .algorithm_exact,
            .algorithm_exact_invariants = &invariants,
        },
        .rejection_reasons = &.{},
    };
    const bytes = try canonicalizeManifestLoweringEntry(allocator, entry);
    defer allocator.free(bytes);

    const expected =
        "{\"backend\":\"wse3\"," ++
        "\"compilerVersion\":\"doe-0.3.2\"," ++
        "\"emitterDigest\":\"4444444444444444444444444444444444444444444444444444444444444444\"," ++
        "\"exactness\":{" ++
        "\"algorithmExactInvariants\":[\"reduction_order\",\"tree_shape\"]," ++
        "\"class\":\"algorithm_exact\"," ++
        "\"toleranceEpsilon\":0," ++
        "\"toleranceMetric\":\"\"}," ++
        "\"frontendVersion\":\"frontend-0.1.0\"," ++
        "\"kernelRef\":\"gemma-4-e2b.rmsnorm\"," ++
        "\"rejectionReasons\":[]," ++
        "\"targetDescriptorCorrectnessHash\":\"1111111111111111111111111111111111111111111111111111111111111111\"," ++
        "\"tsirRealizationDigest\":\"3333333333333333333333333333333333333333333333333333333333333333\"," ++
        "\"tsirSemanticDigest\":\"2222222222222222222222222222222222222222222222222222222222222222\"}";
    try std.testing.expectEqualStrings(expected, bytes);
}

test "manifest lowering entry with rejection reasons is digest-distinct from pass entry" {
    const allocator = std.testing.allocator;
    const pass_entry = schema.ManifestLoweringEntry{
        .kernel_ref = "x.kernel",
        .backend = "wse3",
        .target_descriptor_correctness_hash = [_]u8{0} ** 32,
        .frontend_version = "v1",
        .tsir_semantic_digest = [_]u8{0} ** 32,
        .tsir_realization_digest = [_]u8{0} ** 32,
        .emitter_digest = [_]u8{0} ** 32,
        .compiler_version = "doe-0.3.2",
        .exactness = .{ .class = .bit_exact_solo },
        .rejection_reasons = &.{},
    };
    const rejected_reasons = [_]schema.RejectionReason{.tsir_pe_budget_exhausted};
    const rejected_entry = schema.ManifestLoweringEntry{
        .kernel_ref = "x.kernel",
        .backend = "wse3",
        .target_descriptor_correctness_hash = [_]u8{0} ** 32,
        .frontend_version = "v1",
        .tsir_semantic_digest = [_]u8{0} ** 32,
        .tsir_realization_digest = [_]u8{0} ** 32,
        .emitter_digest = [_]u8{0} ** 32,
        .compiler_version = "doe-0.3.2",
        .exactness = .{ .class = .bit_exact_solo },
        .rejection_reasons = &rejected_reasons,
    };

    const d_pass = try manifestLoweringEntryDigest(allocator, pass_entry);
    const d_rejected = try manifestLoweringEntryDigest(allocator, rejected_entry);
    try std.testing.expect(!std.mem.eql(u8, &d_pass, &d_rejected));

    // Stability within a role.
    const d_pass_again = try manifestLoweringEntryDigest(allocator, pass_entry);
    try std.testing.expectEqualSlices(u8, &d_pass, &d_pass_again);
}

test "realization digest changes when tree shape changes" {
    const allocator = std.testing.allocator;
    const semantic = schema.Semantic{
        .functions = &.{},
        .rejections = &.{},
    };

    const red_linear = [_]schema.ReductionRealizationNode{
        .{ .semantic_index = 0, .tree_shape = .linear },
    };
    const red_binomial = [_]schema.ReductionRealizationNode{
        .{ .semantic_index = 0, .tree_shape = .binomial },
    };
    const rfuncs_linear = [_]schema.RealizationFunction{
        .{
            .semantic_index = 0,
            .tiles = .{ .per_axis = &.{} },
            .pe_grid = .{ .width = 1, .height = 1 },
            .residency = &.{},
            .collectives = &.{},
            .reductions = &red_linear,
            .emitter_params_json = "",
            .target_descriptor_hash = [_]u8{0} ** 32,
        },
    };
    const rfuncs_binomial = [_]schema.RealizationFunction{
        .{
            .semantic_index = 0,
            .tiles = .{ .per_axis = &.{} },
            .pe_grid = .{ .width = 1, .height = 1 },
            .residency = &.{},
            .collectives = &.{},
            .reductions = &red_binomial,
            .emitter_params_json = "",
            .target_descriptor_hash = [_]u8{0} ** 32,
        },
    };
    const realization_linear = schema.Realization{
        .functions = &rfuncs_linear,
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const realization_binomial = schema.Realization{
        .functions = &rfuncs_binomial,
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    const d_linear = try compute(allocator, semantic, realization_linear, "emitter.v0");
    const d_binomial = try compute(allocator, semantic, realization_binomial, "emitter.v0");

    // Same semantic, different realization tree shape → different realization digest.
    try std.testing.expect(!std.mem.eql(u8, &d_linear.realization, &d_binomial.realization));
    // Semantic digest stays identical — this is the split-digest contract.
    try std.testing.expectEqualSlices(u8, &d_linear.semantic, &d_binomial.semantic);
}
