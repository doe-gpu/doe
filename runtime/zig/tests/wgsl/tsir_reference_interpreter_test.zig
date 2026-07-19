const std = @import("std");
const reference = @import("../../src/compiler/tsir/reference_interpreter.zig");
const schema = @import("../../src/compiler/tsir/schema.zig");
const scalar = @import("../../src/compiler/tsir/reference_scalar.zig");

const InterpretError = reference.InterpretError;
const Result = reference.Result;
const freeResult = reference.freeResult;
const run = reference.run;
const f32ToBf16Rne = scalar.f32ToBf16Rne;
const readF32FromBytes = scalar.readF32FromBytes;
const writeF32AsElem = scalar.writeF32AsElem;

test "reference interpreter refuses zero oracle by default" {
    const allocator = std.testing.allocator;
    const semantic = schema.Semantic{ .functions = &.{}, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const inputs = [_][]const u8{};
    const outcome = run(allocator, semantic, realization, &inputs);
    try std.testing.expectError(InterpretError.NotImplemented, outcome);
}

test "reference interpreter rejects semantic or realization rejections before execution" {
    const allocator = std.testing.allocator;
    const semantic_rejections = [_]schema.RejectionEntry{
        .{
            .reason = .tsir_target_unfit,
            .node_path = "functions[0]",
            .detail = "fixture-rejected",
        },
    };
    const semantic = schema.Semantic{
        .functions = &.{},
        .rejections = &semantic_rejections,
    };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const inputs = [_][]const u8{};
    const outcome = run(allocator, semantic, realization, &inputs);
    try std.testing.expectError(InterpretError.RejectedBySemantic, outcome);
}

test "identity kernel copies input bytes and hashes output" {
    const allocator = std.testing.allocator;
    const shape = [_]u64{8};
    const bindings = [_]schema.BufferBinding{
        .{
            .name = "in",
            .group = 0,
            .binding = 0,
            .logical_shape = &shape,
            .elem = .u32,
            .read_write = false,
        },
        .{
            .name = "out",
            .group = 0,
            .binding = 1,
            .logical_shape = &shape,
            .elem = .u32,
            .read_write = true,
        },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "8", .step = "1" },
    };
    const func = schema.SemanticFunction{
        .name = "identity",
        .family_hint = .elementwise,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    const payload = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 };
    const inputs = [_][]const u8{&payload};
    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqualSlices(u8, &payload, result.outputs[0]);

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&payload, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &result.reference_hash);
}

test "identity refuses when input byte count disagrees with declared shape" {
    const allocator = std.testing.allocator;
    const shape = [_]u64{8};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &shape, .elem = .u32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &shape, .elem = .u32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "8", .step = "1" },
    };
    const func = schema.SemanticFunction{
        .name = "identity",
        .family_hint = .elementwise,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    // Declared shape u32[8] = 32 bytes; provide 16 bytes and 64 bytes to
    // verify both under-sized and over-sized inputs are rejected rather
    // than silently hashed.
    const too_small = [_]u8{0} ** 16;
    const inputs_small = [_][]const u8{&too_small};
    try std.testing.expectError(
        InterpretError.NotImplemented,
        run(allocator, semantic, realization, &inputs_small),
    );
    const too_large = [_]u8{0} ** 64;
    const inputs_large = [_][]const u8{&too_large};
    try std.testing.expectError(
        InterpretError.NotImplemented,
        run(allocator, semantic, realization, &inputs_large),
    );
}

test "zero-binding kernel interprets as observable nop with empty-string hash" {
    const allocator = std.testing.allocator;
    const func = schema.SemanticFunction{
        .name = "nop",
        .family_hint = .elementwise,
        .axes = &.{},
        .bindings = &.{},
        .reductions = &.{},
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const inputs = [_][]const u8{};
    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);
    try std.testing.expectEqual(@as(usize, 0), result.outputs.len);
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&[_]u8{}, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &result.reference_hash);
}

test "zero-binding refuses when non-empty inputs are supplied" {
    const allocator = std.testing.allocator;
    const func = schema.SemanticFunction{
        .name = "nop",
        .family_hint = .elementwise,
        .axes = &.{},
        .bindings = &.{},
        .reductions = &.{},
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    // A nop kernel consumes no inputs; supplying one is a mismatch
    // between declared bindings and caller contract.
    const payload = [_]u8{1};
    const inputs = [_][]const u8{&payload};
    try std.testing.expectError(
        InterpretError.NotImplemented,
        run(allocator, semantic, realization, &inputs),
    );
}

test "strict_ordered f32 sum reduces [4]f32 to [1]f32 with matching hash" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // input = [1.0, 2.0, 3.0, 4.0] as little-endian f32 bytes.
    var input_bytes: [16]u8 = undefined;
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 4), result.outputs[0].len);

    const out_word = std.mem.readInt(u32, result.outputs[0][0..4], .little);
    const out_val: f32 = @bitCast(out_word);
    try std.testing.expectEqual(@as(f32, 10.0), out_val);

    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.outputs[0], &expected_hash, .{});
    try std.testing.expectEqualSlices(u8, &expected_hash, &result.reference_hash);
}

test "associative_allowed with linear realization tree folds as left-fold" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .associative_allowed,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4_assoc",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };

    // Build a matching realization with declared tree shape = linear.
    const red_nodes = [_]schema.ReductionRealizationNode{
        .{ .semantic_index = 0, .tree_shape = .linear },
    };
    const rfuncs = [_]schema.RealizationFunction{
        .{
            .semantic_index = 0,
            .tiles = .{ .per_axis = &.{} },
            .pe_grid = .{ .width = 1, .height = 1 },
            .residency = &.{},
            .collectives = &.{},
            .reductions = &red_nodes,
            .emitter_params_json = "{}",
            .target_descriptor_hash = [_]u8{0} ** 32,
        },
    };
    const realization = schema.Realization{
        .functions = &rfuncs,
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var input_bytes: [16]u8 = undefined;
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);
    const out_word = std.mem.readInt(u32, result.outputs[0][0..4], .little);
    const out_val: f32 = @bitCast(out_word);
    try std.testing.expectEqual(@as(f32, 10.0), out_val);
}

test "associative_allowed without realization tree shape falls through" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .associative_allowed,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4_assoc_nodecl",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    // No matching realization function.
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const payload = [_]u8{0} ** 16;
    const inputs = [_][]const u8{&payload};
    try std.testing.expectError(
        InterpretError.NotImplemented,
        run(allocator, semantic, realization, &inputs),
    );
}

test "associative_allowed with binomial tree folds rank-1 pairwise" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };

    const red_nodes = [_]schema.ReductionRealizationNode{
        .{ .semantic_index = 0, .tree_shape = .binomial },
    };
    const rfuncs = [_]schema.RealizationFunction{
        .{
            .semantic_index = 0,
            .tiles = .{ .per_axis = &.{} },
            .pe_grid = .{ .width = 1, .height = 1 },
            .residency = &.{},
            .collectives = &.{},
            .reductions = &red_nodes,
            .emitter_params_json = "{}",
            .target_descriptor_hash = [_]u8{0} ** 32,
        },
    };
    const realization = schema.Realization{
        .functions = &rfuncs,
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Cover sum, product, min, max on small integers where both tree
    // shapes must agree bit-for-bit (integer values representable exactly).
    const cases = [_]struct { op: schema.ReductionOp, expected: f32 }{
        .{ .op = .sum, .expected = 10.0 },
        .{ .op = .product, .expected = 24.0 },
        .{ .op = .min, .expected = 1.0 },
        .{ .op = .max, .expected = 4.0 },
    };

    var input_bytes: [16]u8 = undefined;
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    for (cases) |case| {
        const reductions = [_]schema.ReductionRegion{
            .{
                .axis = 0,
                .op = case.op,
                .contract = .{
                    .accumulation = .f32,
                    .associativity = .associative_allowed,
                    .nan_inf = .propagate,
                },
                .target_binding = 1,
            },
        };
        const func = schema.SemanticFunction{
            .name = "reduce4_binomial",
            .family_hint = .reduction,
            .axes = &axes,
            .bindings = &bindings,
            .reductions = &reductions,
            .collectives = &.{},
            .source_digest = [_]u8{0} ** 32,
        };
        const funcs = [_]schema.SemanticFunction{func};
        const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };

        var result = try run(allocator, semantic, realization, &inputs);
        defer freeResult(allocator, &result);
        const word = std.mem.readInt(u32, result.outputs[0][0..4], .little);
        const v: f32 = @bitCast(word);
        try std.testing.expectEqual(case.expected, v);
    }
}

test "associative_allowed with binomial on rank-2 folds per output position" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{ 2, 4 };
    const out_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "j", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .associative_allowed,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum24_binomial",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const red_nodes = [_]schema.ReductionRealizationNode{
        .{ .semantic_index = 0, .tree_shape = .binomial },
    };
    const rfuncs = [_]schema.RealizationFunction{
        .{
            .semantic_index = 0,
            .tiles = .{ .per_axis = &.{} },
            .pe_grid = .{ .width = 1, .height = 1 },
            .residency = &.{},
            .collectives = &.{},
            .reductions = &red_nodes,
            .emitter_params_json = "{}",
            .target_descriptor_hash = [_]u8{0} ** 32,
        },
    };
    const realization = schema.Realization{
        .functions = &rfuncs,
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Row 0: [1,2,3,4] binomial-sum → (1+2) + (3+4) = 10.
    // Row 1: [5,6,7,8] binomial-sum → (5+6) + (7+8) = 26.
    var input_bytes: [32]u8 = undefined;
    const vals = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);
    const expected = [_]f32{ 10.0, 26.0 };
    for (expected, 0..) |e, i| {
        const word = std.mem.readInt(u32, result.outputs[0][i * 4 ..][0..4], .little);
        const v: f32 = @bitCast(word);
        try std.testing.expectEqual(e, v);
    }
}

test "associative_allowed with binomial on rank-3 folds per output position" {
    const allocator = std.testing.allocator;
    // Shape [2, 2, 4], reduce axis 2 → [2, 2] of binomial row-sums.
    // Each [4]-element row binomial-sums as (v0+v1)+(v2+v3).
    // Row 0: 1+2,3+4 → 3,7 → 10. Row 1: 5+6,7+8 → 11,15 → 26.
    // Row 2: 9+10,11+12 → 19,23 → 42. Row 3: 13+14,15+16 → 27,31 → 58.
    const in_shape = [_]u64{ 2, 2, 4 };
    const out_shape = [_]u64{ 2, 2 };
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "a", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "b", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "c", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 2,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .associative_allowed,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum3d_binomial_axis2",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const red_nodes = [_]schema.ReductionRealizationNode{
        .{ .semantic_index = 0, .tree_shape = .binomial },
    };
    const rfuncs = [_]schema.RealizationFunction{
        .{
            .semantic_index = 0,
            .tiles = .{ .per_axis = &.{} },
            .pe_grid = .{ .width = 1, .height = 1 },
            .residency = &.{},
            .collectives = &.{},
            .reductions = &red_nodes,
            .emitter_params_json = "{}",
            .target_descriptor_hash = [_]u8{0} ** 32,
        },
    };
    const realization = schema.Realization{
        .functions = &rfuncs,
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var input_bytes: [64]u8 = undefined;
    for (0..16) |i| {
        const v: f32 = @floatFromInt(i + 1);
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[i * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);
    const expected = [_]f32{ 10.0, 26.0, 42.0, 58.0 };
    for (expected, 0..) |e, i| {
        const word = std.mem.readInt(u32, result.outputs[0][i * 4 ..][0..4], .little);
        const v: f32 = @bitCast(word);
        try std.testing.expectEqual(e, v);
    }
}

test "associative_allowed with ring tree shape folds identically to linear on a single PE" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .associative_allowed,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4_assoc_ring",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const red_nodes = [_]schema.ReductionRealizationNode{
        .{ .semantic_index = 0, .tree_shape = .ring },
    };
    const rfuncs = [_]schema.RealizationFunction{
        .{
            .semantic_index = 0,
            .tiles = .{ .per_axis = &.{} },
            .pe_grid = .{ .width = 1, .height = 1 },
            .residency = &.{},
            .collectives = &.{},
            .reductions = &red_nodes,
            .emitter_params_json = "{}",
            .target_descriptor_hash = [_]u8{0} ** 32,
        },
    };
    const realization = schema.Realization{
        .functions = &rfuncs,
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var input_bytes: [16]u8 = undefined;
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);
    const out_word = std.mem.readInt(u32, result.outputs[0][0..4], .little);
    const out_val: f32 = @bitCast(out_word);
    try std.testing.expectEqual(@as(f32, 10.0), out_val);
}

test "associative_allowed with ring tree shape works on rank-2" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{ 2, 3 };
    const out_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "j", .lower_bound = "0", .upper_bound = "3", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .associative_allowed,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum23_ring",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const red_nodes = [_]schema.ReductionRealizationNode{
        .{ .semantic_index = 0, .tree_shape = .ring },
    };
    const rfuncs = [_]schema.RealizationFunction{
        .{
            .semantic_index = 0,
            .tiles = .{ .per_axis = &.{} },
            .pe_grid = .{ .width = 1, .height = 1 },
            .residency = &.{},
            .collectives = &.{},
            .reductions = &red_nodes,
            .emitter_params_json = "{}",
            .target_descriptor_hash = [_]u8{0} ** 32,
        },
    };
    const realization = schema.Realization{
        .functions = &rfuncs,
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var input_bytes: [24]u8 = undefined;
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);
    const expected = [_]f32{ 6.0, 15.0 };
    for (expected, 0..) |e, i| {
        const word = std.mem.readInt(u32, result.outputs[0][i * 4 ..][0..4], .little);
        const v: f32 = @bitCast(word);
        try std.testing.expectEqual(e, v);
    }
}

test "simple reduction refuses non-strict associativity" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .associative_allowed,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4_assoc",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const payload = [_]u8{0} ** 16;
    const inputs = [_][]const u8{&payload};
    try std.testing.expectError(
        InterpretError.NotImplemented,
        run(allocator, semantic, realization, &inputs),
    );
}

test "strict_ordered f32 product / min / max reductions match their op semantics" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Input [1.0, 2.0, 3.0, 4.0]
    var input_bytes: [16]u8 = undefined;
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    const cases = [_]struct { op: schema.ReductionOp, expected: f32 }{
        .{ .op = .product, .expected = 24.0 },
        .{ .op = .min, .expected = 1.0 },
        .{ .op = .max, .expected = 4.0 },
    };

    for (cases) |case| {
        const reductions = [_]schema.ReductionRegion{
            .{
                .axis = 0,
                .op = case.op,
                .contract = .{
                    .accumulation = .f32,
                    .associativity = .strict_ordered,
                    .nan_inf = .propagate,
                },
                .target_binding = 1,
            },
        };
        const func = schema.SemanticFunction{
            .name = "reduce4",
            .family_hint = .reduction,
            .axes = &axes,
            .bindings = &bindings,
            .reductions = &reductions,
            .collectives = &.{},
            .source_digest = [_]u8{0} ** 32,
        };
        const funcs = [_]schema.SemanticFunction{func};
        const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };

        var result = try run(allocator, semantic, realization, &inputs);
        defer freeResult(allocator, &result);

        const out_word = std.mem.readInt(u32, result.outputs[0][0..4], .little);
        const out_val: f32 = @bitCast(out_word);
        try std.testing.expectEqual(case.expected, out_val);
    }
}

test "f16 input sum reduces to f32 scalar under fp32 accumulation" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f16, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4_f16",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Input [1.0, 2.0, 3.0, 4.0] as f16 bytes (2 bytes each = 8 bytes total).
    var input_bytes: [8]u8 = undefined;
    const vals = [_]f16{ 1.0, 2.0, 3.0, 4.0 };
    for (vals, 0..) |v, idx| {
        const word: u16 = @bitCast(v);
        std.mem.writeInt(u16, input_bytes[idx * 2 ..][0..2], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 4), result.outputs[0].len);
    const out_word = std.mem.readInt(u32, result.outputs[0][0..4], .little);
    const out_val: f32 = @bitCast(out_word);
    // f16 representations of 1/2/3/4 are exact; sum = 10 exactly.
    try std.testing.expectEqual(@as(f32, 10.0), out_val);
}

test "bf16 input sum reduces to f32 scalar under fp32 accumulation" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .bf16, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4_bf16",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // bf16 encoding: take the high 16 bits of the f32 bit pattern.
    // Integers 1/2/3/4 as f32 have mantissa low bits zero, so
    // truncating to bf16 and back is exact; sum = 10 bit-identical.
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    var input_bytes: [8]u8 = undefined;
    for (vals, 0..) |v, idx| {
        const f32_bits: u32 = @bitCast(v);
        const high16: u16 = @intCast(f32_bits >> 16);
        std.mem.writeInt(u16, input_bytes[idx * 2 ..][0..2], high16, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    const out_word = std.mem.readInt(u32, result.outputs[0][0..4], .little);
    const out_val: f32 = @bitCast(out_word);
    try std.testing.expectEqual(@as(f32, 10.0), out_val);
}

test "f16 output downcasts f32 accumulator to [1]f16" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f16, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4_out_f16",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var input_bytes: [16]u8 = undefined;
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);
    try std.testing.expectEqual(@as(usize, 2), result.outputs[0].len);

    const out_word = std.mem.readInt(u16, result.outputs[0][0..2], .little);
    const out_val: f16 = @bitCast(out_word);
    try std.testing.expectEqual(@as(f16, 10.0), out_val);
}

test "bf16 output downcasts f32 accumulator with round-to-nearest-even" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{4};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .bf16, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4_out_bf16",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var input_bytes: [16]u8 = undefined;
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);
    try std.testing.expectEqual(@as(usize, 2), result.outputs[0].len);

    // bf16(10.0) = high 16 bits of f32(10.0) = 0x41200000 >> 16 = 0x4120.
    // Reading back: 0x4120 << 16 = 0x41200000 = 10.0 f32 exact.
    const out_bits = std.mem.readInt(u16, result.outputs[0][0..2], .little);
    try std.testing.expectEqual(@as(u16, 0x4120), out_bits);
}

test "f32ToBf16Rne handles NaN without turning into Inf" {
    // Quiet NaN f32 bits: exponent all ones, mantissa non-zero with
    // high bit set.
    const nan_bits: u32 = 0x7fc00001;
    const nan_val: f32 = @bitCast(nan_bits);
    const out = f32ToBf16Rne(nan_val);
    // Expand the bf16 back to f32 and verify it's still NaN.
    const reconstructed_bits: u32 = @as(u32, out) << 16;
    const reconstructed: f32 = @bitCast(reconstructed_bits);
    try std.testing.expect(std.math.isNan(reconstructed));
}

test "f32ToBf16Rne rounds ties-to-even on exact half values" {
    // Value with low 16 bits = 0x8000 (exact half) and bit 16 of bit
    // pattern = 0 should round DOWN (even).
    // Pick bits = 0x3F808000 → value between 1.0 and 1.0078..., mid.
    // Bit 16 is 0 (high bits 0x3F80 ends with 0), so RTNE rounds down.
    const down_bits: u32 = 0x3f808000;
    const down_val: f32 = @bitCast(down_bits);
    const out_down = f32ToBf16Rne(down_val);
    try std.testing.expectEqual(@as(u16, 0x3f80), out_down);

    // Value with low 16 bits = 0x8000 and bit 16 = 1 should round UP (even).
    // Pick bits = 0x3F818000 → bit 16 = 1, so RTNE rounds up to 0x3F82.
    const up_bits: u32 = 0x3f818000;
    const up_val: f32 = @bitCast(up_bits);
    const out_up = f32ToBf16Rne(up_val);
    try std.testing.expectEqual(@as(u16, 0x3f82), out_up);
}

test "4-D f32 sum reduces via generic N-D fallback" {
    const allocator = std.testing.allocator;
    // Input shape [2, 2, 2, 2] with values 1..16. axis 3 (innermost)
    // → output [2, 2, 2] of pairwise sums: (1+2, 3+4, ...) = [3,7,11,15,19,23,27,31].
    const in_shape = [_]u64{ 2, 2, 2, 2 };
    const out_shape = [_]u64{ 2, 2, 2 };
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "a", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "b", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "c", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "d", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 3,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4d_axis3",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var input_bytes: [64]u8 = undefined;
    for (0..16) |i| {
        const v: f32 = @floatFromInt(i + 1);
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[i * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);
    try std.testing.expectEqual(@as(usize, 32), result.outputs[0].len);

    const expected = [_]f32{ 3.0, 7.0, 11.0, 15.0, 19.0, 23.0, 27.0, 31.0 };
    for (expected, 0..) |e, i| {
        const word = std.mem.readInt(u32, result.outputs[0][i * 4 ..][0..4], .little);
        const v: f32 = @bitCast(word);
        try std.testing.expectEqual(e, v);
    }
}

test "4-D f32 sum reduces along a non-innermost axis" {
    const allocator = std.testing.allocator;
    // Shape [2, 3, 1, 2], reduce axis 1 → [2, 1, 2] of column sums
    // per (a, c, d). Input values 1..12.
    // in[a, b, c, d]: stride [6, 2, 2, 1], so flat = 6a + 2b + 2c + d.
    // Wait: actually with shape [2, 3, 1, 2]:
    //   strides: last=1, then 1*2=2 (c), 2*1=2 (b), 2*3=6 (a). So
    //   flat = a*6 + b*2 + c*2 + d.
    // For a=0, c=0, d=0: b=0→in[0]=1, b=1→in[2]=3, b=2→in[4]=5; sum=9.
    // For a=0, c=0, d=1: b=0→in[1]=2, b=1→in[3]=4, b=2→in[5]=6; sum=12.
    // For a=1, c=0, d=0: b=0→in[6]=7, b=1→in[8]=9, b=2→in[10]=11; sum=27.
    // For a=1, c=0, d=1: b=0→in[7]=8, b=1→in[9]=10, b=2→in[11]=12; sum=30.
    const in_shape = [_]u64{ 2, 3, 1, 2 };
    const out_shape = [_]u64{ 2, 1, 2 };
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "a", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "b", .lower_bound = "0", .upper_bound = "3", .step = "1" },
        .{ .name = "c", .lower_bound = "0", .upper_bound = "1", .step = "1" },
        .{ .name = "d", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum4d_axis1",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var input_bytes: [48]u8 = undefined;
    for (0..12) |i| {
        const v: f32 = @floatFromInt(i + 1);
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[i * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    const expected = [_]f32{ 9.0, 12.0, 27.0, 30.0 };
    for (expected, 0..) |e, i| {
        const word = std.mem.readInt(u32, result.outputs[0][i * 4 ..][0..4], .little);
        const v: f32 = @bitCast(word);
        try std.testing.expectEqual(e, v);
    }
}

test "3-D f32 sum reduces over each axis with correct row-major offsets" {
    const allocator = std.testing.allocator;
    // Input [[[1,2],[3,4]],[[5,6],[7,8]]] shape [2, 2, 2].
    const in_shape = [_]u64{ 2, 2, 2 };
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    var input_bytes: [32]u8 = undefined;
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "a", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "b", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "c", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };

    // axis=0: reduce first dim → [2,2].
    // out[b,c] = in[0,b,c] + in[1,b,c]
    // out[0,0]=1+5=6, out[0,1]=2+6=8, out[1,0]=3+7=10, out[1,1]=4+8=12.
    // axis=1: reduce middle dim → [2,2].
    // out[a,c] = in[a,0,c] + in[a,1,c]
    // out[0,0]=1+3=4, out[0,1]=2+4=6, out[1,0]=5+7=12, out[1,1]=6+8=14.
    // axis=2: reduce last dim → [2,2].
    // out[a,b] = in[a,b,0] + in[a,b,1]
    // out[0,0]=1+2=3, out[0,1]=3+4=7, out[1,0]=5+6=11, out[1,1]=7+8=15.
    const cases = [_]struct {
        axis: u32,
        out_shape: [2]u64,
        expected: [4]f32,
    }{
        .{ .axis = 0, .out_shape = .{ 2, 2 }, .expected = .{ 6.0, 8.0, 10.0, 12.0 } },
        .{ .axis = 1, .out_shape = .{ 2, 2 }, .expected = .{ 4.0, 6.0, 12.0, 14.0 } },
        .{ .axis = 2, .out_shape = .{ 2, 2 }, .expected = .{ 3.0, 7.0, 11.0, 15.0 } },
    };

    for (cases) |case| {
        const out_shape = case.out_shape;
        const bindings = [_]schema.BufferBinding{
            .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
            .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
        };
        const reductions = [_]schema.ReductionRegion{
            .{
                .axis = case.axis,
                .op = .sum,
                .contract = .{
                    .accumulation = .f32,
                    .associativity = .strict_ordered,
                    .nan_inf = .propagate,
                },
                .target_binding = 1,
            },
        };
        const func = schema.SemanticFunction{
            .name = "sum3d",
            .family_hint = .reduction,
            .axes = &axes,
            .bindings = &bindings,
            .reductions = &reductions,
            .collectives = &.{},
            .source_digest = [_]u8{0} ** 32,
        };
        const funcs = [_]schema.SemanticFunction{func};
        const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };

        var result = try run(allocator, semantic, realization, &inputs);
        defer freeResult(allocator, &result);
        try std.testing.expectEqual(@as(usize, 16), result.outputs[0].len);

        for (case.expected, 0..) |e, i| {
            const word = std.mem.readInt(u32, result.outputs[0][i * 4 ..][0..4], .little);
            const v: f32 = @bitCast(word);
            try std.testing.expectEqual(e, v);
        }
    }
}

test "2-D f32 sum reduces over axis 0 yielding per-column sums" {
    const allocator = std.testing.allocator;
    // Input [[1,2,3],[4,5,6]] shape [2,3]; axis 0 → [5,7,9] shape [3].
    const in_shape = [_]u64{ 2, 3 };
    const out_shape = [_]u64{3};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "j", .lower_bound = "0", .upper_bound = "3", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum_axis0",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var input_bytes: [24]u8 = undefined;
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 12), result.outputs[0].len);

    const expected = [_]f32{ 5.0, 7.0, 9.0 };
    for (expected, 0..) |e, i| {
        const word = std.mem.readInt(u32, result.outputs[0][i * 4 ..][0..4], .little);
        const v: f32 = @bitCast(word);
        try std.testing.expectEqual(e, v);
    }
}

test "2-D f32 sum reduces over axis 1 yielding per-row sums" {
    const allocator = std.testing.allocator;
    // Same input; axis 1 → [6, 15] shape [2].
    const in_shape = [_]u64{ 2, 3 };
    const out_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "j", .lower_bound = "0", .upper_bound = "3", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum_axis1",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var input_bytes: [24]u8 = undefined;
    const vals = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    for (vals, 0..) |v, idx| {
        const word: u32 = @bitCast(v);
        std.mem.writeInt(u32, input_bytes[idx * 4 ..][0..4], word, .little);
    }
    const inputs = [_][]const u8{&input_bytes};

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 8), result.outputs[0].len);

    const expected = [_]f32{ 6.0, 15.0 };
    for (expected, 0..) |e, i| {
        const word = std.mem.readInt(u32, result.outputs[0][i * 4 ..][0..4], .little);
        const v: f32 = @bitCast(word);
        try std.testing.expectEqual(e, v);
    }
}

test "empty f32 reduction returns identity for each op" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{0};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "0", .step = "1" },
    };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const empty_bytes = [_]u8{};
    const inputs = [_][]const u8{&empty_bytes};

    const cases = [_]struct { op: schema.ReductionOp, expected: f32 }{
        .{ .op = .sum, .expected = 0.0 },
        .{ .op = .product, .expected = 1.0 },
        .{ .op = .min, .expected = std.math.inf(f32) },
        .{ .op = .max, .expected = -std.math.inf(f32) },
    };

    for (cases) |case| {
        const reductions = [_]schema.ReductionRegion{
            .{
                .axis = 0,
                .op = case.op,
                .contract = .{
                    .accumulation = .f32,
                    .associativity = .strict_ordered,
                    .nan_inf = .propagate,
                },
                .target_binding = 1,
            },
        };
        const func = schema.SemanticFunction{
            .name = "empty_reduce",
            .family_hint = .reduction,
            .axes = &axes,
            .bindings = &bindings,
            .reductions = &reductions,
            .collectives = &.{},
            .source_digest = [_]u8{0} ** 32,
        };
        const funcs = [_]schema.SemanticFunction{func};
        const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };

        var result = try run(allocator, semantic, realization, &inputs);
        defer freeResult(allocator, &result);

        const out_word = std.mem.readInt(u32, result.outputs[0][0..4], .little);
        const out_val: f32 = @bitCast(out_word);
        try std.testing.expectEqual(case.expected, out_val);
    }
}

test "simple reduction over empty input returns sum identity 0.0" {
    const allocator = std.testing.allocator;
    const in_shape = [_]u64{0};
    const out_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &in_shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &out_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "0", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "sum0",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const empty_bytes = [_]u8{};
    const inputs = [_][]const u8{&empty_bytes};
    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);
    const out_word = std.mem.readInt(u32, result.outputs[0][0..4], .little);
    const out_val: f32 = @bitCast(out_word);
    try std.testing.expectEqual(@as(f32, 0.0), out_val);
}

test "ReductionOp covers the four cases the interpreter must dispatch" {
    const ops = [_]schema.ReductionOp{ .sum, .product, .min, .max };
    try std.testing.expectEqual(@as(usize, 4), ops.len);
}

test "ReductionRegion defaults op to sum for backwards-compatible fixtures" {
    const region = schema.ReductionRegion{
        .axis = 0,
        .contract = .{
            .accumulation = .f32,
            .associativity = .strict_ordered,
            .nan_inf = .propagate,
        },
        .target_binding = 1,
    };
    try std.testing.expectEqual(schema.ReductionOp.sum, region.op);
}

test "ReductionRegion accepts explicit op override" {
    const region = schema.ReductionRegion{
        .axis = 1,
        .op = .max,
        .contract = .{
            .accumulation = .f32,
            .associativity = .associative_allowed,
            .nan_inf = .propagate,
        },
        .target_binding = 0,
    };
    try std.testing.expectEqual(schema.ReductionOp.max, region.op);
}

test "ScalarKind byte sizes match the declared numerical contract" {
    try std.testing.expectEqual(@as(u8, 4), schema.ScalarKind.f32.byteSize());
    try std.testing.expectEqual(@as(u8, 4), schema.ScalarKind.i32.byteSize());
    try std.testing.expectEqual(@as(u8, 4), schema.ScalarKind.u32.byteSize());
    try std.testing.expectEqual(@as(u8, 2), schema.ScalarKind.f16.byteSize());
    try std.testing.expectEqual(@as(u8, 2), schema.ScalarKind.bf16.byteSize());
}

test "identity refuses when reductions are present" {
    const allocator = std.testing.allocator;
    const shape = [_]u64{4};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "in", .group = 0, .binding = 0, .logical_shape = &shape, .elem = .f32, .read_write = false },
        .{ .name = "out", .group = 0, .binding = 1, .logical_shape = &shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 0,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 1,
        },
    };
    const func = schema.SemanticFunction{
        .name = "reduce",
        .family_hint = .reduction,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const payload = [_]u8{0} ** 16;
    const inputs = [_][]const u8{&payload};
    const outcome = run(allocator, semantic, realization, &inputs);
    try std.testing.expectError(InterpretError.NotImplemented, outcome);
}

test "fused_gemv f32 strict_ordered computes y[i] = sum_k W[i,k] * x[k]" {
    const allocator = std.testing.allocator;
    const matrix_shape = [_]u64{ 2, 3 };
    const vector_shape = [_]u64{3};
    const output_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "W", .group = 0, .binding = 0, .logical_shape = &matrix_shape, .elem = .f32, .read_write = false },
        .{ .name = "x", .group = 0, .binding = 1, .logical_shape = &vector_shape, .elem = .f32, .read_write = false },
        .{ .name = "y", .group = 0, .binding = 2, .logical_shape = &output_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "k", .lower_bound = "0", .upper_bound = "3", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{ .accumulation = .f32, .associativity = .strict_ordered, .nan_inf = .propagate },
            .target_binding = 2,
        },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .matrix },
        .{ .binding_index = 1, .role = .vector },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .output },
        .{ .axis_index = 1, .role = .reduction },
    };
    const body = schema.SemanticBody{
        .op = .fused_gemv,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
    };
    const func = schema.SemanticFunction{
        .name = "gemv",
        .family_hint = .fused_gemv,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // W = [[1,2,3],[4,5,6]] row-major; x = [10,100,1000].
    var matrix_bytes: [24]u8 = undefined;
    writeF32AsElem(&matrix_bytes, 0, 1.0, .f32);
    writeF32AsElem(&matrix_bytes, 1, 2.0, .f32);
    writeF32AsElem(&matrix_bytes, 2, 3.0, .f32);
    writeF32AsElem(&matrix_bytes, 3, 4.0, .f32);
    writeF32AsElem(&matrix_bytes, 4, 5.0, .f32);
    writeF32AsElem(&matrix_bytes, 5, 6.0, .f32);
    var vector_bytes: [12]u8 = undefined;
    writeF32AsElem(&vector_bytes, 0, 10.0, .f32);
    writeF32AsElem(&vector_bytes, 1, 100.0, .f32);
    writeF32AsElem(&vector_bytes, 2, 1000.0, .f32);
    // Inputs are ordered by ascending read-only binding index: matrix (0), vector (1).
    const inputs = [_][]const u8{ &matrix_bytes, &vector_bytes };

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 8), result.outputs[0].len);

    const y0 = readF32FromBytes(result.outputs[0], .f32, 0);
    const y1 = readF32FromBytes(result.outputs[0], .f32, 1);
    try std.testing.expectEqual(@as(f32, 3210.0), y0);
    try std.testing.expectEqual(@as(f32, 6540.0), y1);

    // Reference hash is SHA-256 of the output bytes verbatim.
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.outputs[0], &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &result.reference_hash);
}

test "fused_gemv associative_allowed consumes realization tree shape" {
    const allocator = std.testing.allocator;
    const matrix_shape = [_]u64{ 1, 4 };
    const vector_shape = [_]u64{4};
    const output_shape = [_]u64{1};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "W", .group = 0, .binding = 0, .logical_shape = &matrix_shape, .elem = .f32, .read_write = false },
        .{ .name = "x", .group = 0, .binding = 1, .logical_shape = &vector_shape, .elem = .f32, .read_write = false },
        .{ .name = "y", .group = 0, .binding = 2, .logical_shape = &output_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "1", .step = "1" },
        .{ .name = "k", .lower_bound = "0", .upper_bound = "4", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .associative_allowed,
                .nan_inf = .propagate,
            },
            .target_binding = 2,
        },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .matrix },
        .{ .binding_index = 1, .role = .vector },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .output },
        .{ .axis_index = 1, .role = .reduction },
    };
    const body = schema.SemanticBody{
        .op = .fused_gemv,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
    };
    const func = schema.SemanticFunction{
        .name = "gemv_assoc",
        .family_hint = .fused_gemv,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };

    var matrix_bytes: [16]u8 = undefined;
    writeF32AsElem(&matrix_bytes, 0, 1.0e20, .f32);
    writeF32AsElem(&matrix_bytes, 1, 3.0, .f32);
    writeF32AsElem(&matrix_bytes, 2, -1.0e20, .f32);
    writeF32AsElem(&matrix_bytes, 3, 4.0, .f32);
    var vector_bytes: [16]u8 = undefined;
    writeF32AsElem(&vector_bytes, 0, 1.0, .f32);
    writeF32AsElem(&vector_bytes, 1, 1.0, .f32);
    writeF32AsElem(&vector_bytes, 2, 1.0, .f32);
    writeF32AsElem(&vector_bytes, 3, 1.0, .f32);
    const inputs = [_][]const u8{ &matrix_bytes, &vector_bytes };

    const missing_realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    try std.testing.expectError(
        InterpretError.NotImplemented,
        run(allocator, semantic, missing_realization, &inputs),
    );

    const red_nodes = [_]schema.ReductionRealizationNode{
        .{ .semantic_index = 0, .tree_shape = .binomial },
    };
    const rfuncs = [_]schema.RealizationFunction{
        .{
            .semantic_index = 0,
            .tiles = .{ .per_axis = &.{} },
            .pe_grid = .{ .width = 1, .height = 1 },
            .residency = &.{},
            .collectives = &.{},
            .reductions = &red_nodes,
            .emitter_params_json = "{}",
            .target_descriptor_hash = [_]u8{0} ** 32,
        },
    };
    const binomial_realization = schema.Realization{
        .functions = &rfuncs,
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var result = try run(allocator, semantic, binomial_realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(f32, 0.0), readF32FromBytes(result.outputs[0], .f32, 0));
}

test "fused_gemv recognizer falls through on wrong body op" {
    const allocator = std.testing.allocator;
    const matrix_shape = [_]u64{ 2, 3 };
    const vector_shape = [_]u64{3};
    const output_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "W", .group = 0, .binding = 0, .logical_shape = &matrix_shape, .elem = .f32, .read_write = false },
        .{ .name = "x", .group = 0, .binding = 1, .logical_shape = &vector_shape, .elem = .f32, .read_write = false },
        .{ .name = "y", .group = 0, .binding = 2, .logical_shape = &output_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "k", .lower_bound = "0", .upper_bound = "3", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{ .accumulation = .f32, .associativity = .strict_ordered, .nan_inf = .propagate },
            .target_binding = 2,
        },
    };
    // Body op left at `.unknown`; fused_gemv recognizer must fall
    // through, and no other dispatch path matches a 3-binding kernel,
    // so `run` returns NotImplemented rather than silently honoring an
    // undeclared body.
    const func = schema.SemanticFunction{
        .name = "gemv_unlabeled",
        .family_hint = .fused_gemv,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    const matrix_bytes = [_]u8{0} ** 24;
    const vector_bytes = [_]u8{0} ** 12;
    const inputs = [_][]const u8{ &matrix_bytes, &vector_bytes };
    const outcome = run(allocator, semantic, realization, &inputs);
    try std.testing.expectError(InterpretError.NotImplemented, outcome);
}

test "gather f32 copies table rows selected by u32 token indices" {
    const allocator = std.testing.allocator;
    const index_shape = [_]u64{3};
    const table_shape = [_]u64{ 4, 2 };
    const output_shape = [_]u64{ 3, 2 };
    const bindings = [_]schema.BufferBinding{
        .{ .name = "indices", .group = 0, .binding = 0, .logical_shape = &index_shape, .elem = .u32, .read_write = false },
        .{ .name = "table", .group = 0, .binding = 1, .logical_shape = &table_shape, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &output_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "t", .lower_bound = "0", .upper_bound = "3", .step = "1" },
        .{ .name = "h", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .indices },
        .{ .binding_index = 1, .role = .table },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .token },
        .{ .axis_index = 1, .role = .hidden },
    };
    const body = schema.SemanticBody{
        .op = .gather,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
    };
    const func = schema.SemanticFunction{
        .name = "gather",
        .family_hint = .gather,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var indices_bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, indices_bytes[0..4], 2, .little);
    std.mem.writeInt(u32, indices_bytes[4..8], 0, .little);
    std.mem.writeInt(u32, indices_bytes[8..12], 3, .little);

    var table_bytes: [32]u8 = undefined;
    writeF32AsElem(&table_bytes, 0, 10.0, .f32);
    writeF32AsElem(&table_bytes, 1, 11.0, .f32);
    writeF32AsElem(&table_bytes, 2, 20.0, .f32);
    writeF32AsElem(&table_bytes, 3, 21.0, .f32);
    writeF32AsElem(&table_bytes, 4, 30.0, .f32);
    writeF32AsElem(&table_bytes, 5, 31.0, .f32);
    writeF32AsElem(&table_bytes, 6, 40.0, .f32);
    writeF32AsElem(&table_bytes, 7, 41.0, .f32);

    const inputs = [_][]const u8{ &indices_bytes, &table_bytes };
    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 24), result.outputs[0].len);
    const expected = [_]f32{ 30.0, 31.0, 10.0, 11.0, 40.0, 41.0 };
    for (expected, 0..) |want, i| {
        const got = readF32FromBytes(result.outputs[0], .f32, i);
        try std.testing.expectEqual(want, got);
    }

    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.outputs[0], &expected_hash, .{});
    try std.testing.expectEqualSlices(u8, &expected_hash, &result.reference_hash);
}

test "gather rejects out-of-range token index instead of clamping" {
    const allocator = std.testing.allocator;
    const index_shape = [_]u64{1};
    const table_shape = [_]u64{ 2, 1 };
    const output_shape = [_]u64{ 1, 1 };
    const bindings = [_]schema.BufferBinding{
        .{ .name = "indices", .group = 0, .binding = 0, .logical_shape = &index_shape, .elem = .u32, .read_write = false },
        .{ .name = "table", .group = 0, .binding = 1, .logical_shape = &table_shape, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &output_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "t", .lower_bound = "0", .upper_bound = "1", .step = "1" },
        .{ .name = "h", .lower_bound = "0", .upper_bound = "1", .step = "1" },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .indices },
        .{ .binding_index = 1, .role = .table },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .token },
        .{ .axis_index = 1, .role = .hidden },
    };
    const body = schema.SemanticBody{
        .op = .gather,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
    };
    const func = schema.SemanticFunction{
        .name = "gather_oob",
        .family_hint = .gather,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    var indices_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, indices_bytes[0..4], 2, .little);
    var table_bytes: [8]u8 = undefined;
    writeF32AsElem(&table_bytes, 0, 1.0, .f32);
    writeF32AsElem(&table_bytes, 1, 2.0, .f32);
    const inputs = [_][]const u8{ &indices_bytes, &table_bytes };

    const outcome = run(allocator, semantic, realization, &inputs);
    try std.testing.expectError(InterpretError.NotImplemented, outcome);
}

test "rms_norm f32 literal epsilon computes normalized scaled output" {
    const allocator = std.testing.allocator;
    const hidden_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &hidden_shape, .elem = .f32, .read_write = false },
        .{ .name = "weight", .group = 0, .binding = 1, .logical_shape = &hidden_shape, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &hidden_shape, .elem = .f32, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "d", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{ .accumulation = .f32, .associativity = .strict_ordered, .nan_inf = .propagate },
            .target_binding = 2,
        },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .input },
        .{ .binding_index = 1, .role = .scale },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
        .{ .axis_index = 1, .role = .reduction },
    };
    const body = schema.SemanticBody{
        .op = .rms_norm,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
        .rms_norm = .{
            .formula = .sum_squares_mean_epsilon_rsqrt_scale,
            .epsilon = .{ .source = .literal_f32, .path = "", .literal_f32 = 0.0 },
            .hidden_extent_axis = 0,
            .reduction_target = .intermediate_scalar,
        },
    };
    const func = schema.SemanticFunction{
        .name = "rms_norm",
        .family_hint = .rms_norm,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // input = [2, 2], mean(square(input)) = 4, inv_rms = 0.5.
    // weight = [3, 4], so output = [3, 4].
    var input_bytes: [8]u8 = undefined;
    writeF32AsElem(&input_bytes, 0, 2.0, .f32);
    writeF32AsElem(&input_bytes, 1, 2.0, .f32);
    var scale_bytes: [8]u8 = undefined;
    writeF32AsElem(&scale_bytes, 0, 3.0, .f32);
    writeF32AsElem(&scale_bytes, 1, 4.0, .f32);
    const inputs = [_][]const u8{ &input_bytes, &scale_bytes };

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 8), result.outputs[0].len);
    try std.testing.expectEqual(@as(f32, 3.0), readF32FromBytes(result.outputs[0], .f32, 0));
    try std.testing.expectEqual(@as(f32, 4.0), readF32FromBytes(result.outputs[0], .f32, 1));

    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.outputs[0], &expected_hash, .{});
    try std.testing.expectEqualSlices(u8, &expected_hash, &result.reference_hash);
}

test "rms_norm uniform epsilon reads explicit binding bytes" {
    const allocator = std.testing.allocator;
    const hidden_shape = [_]u64{2};
    const uniform_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &hidden_shape, .elem = .f32, .read_write = false },
        .{ .name = "weight", .group = 0, .binding = 1, .logical_shape = &hidden_shape, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &hidden_shape, .elem = .f32, .read_write = true },
        .{ .name = "u", .group = 0, .binding = 3, .logical_shape = &uniform_shape, .elem = .u32, .read_write = false },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "d", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{ .accumulation = .f32, .associativity = .strict_ordered, .nan_inf = .propagate },
            .target_binding = 2,
        },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .input },
        .{ .binding_index = 1, .role = .scale },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
        .{ .axis_index = 1, .role = .reduction },
    };
    const body = schema.SemanticBody{
        .op = .rms_norm,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
        .rms_norm = .{
            .formula = .sum_squares_mean_epsilon_rsqrt_scale,
            .epsilon = .{
                .source = .uniform_field,
                .path = "uniform:u.eps",
                .binding_index = 3,
                .byte_offset = 4,
                .literal_f32 = null,
            },
            .hidden_extent_axis = 0,
            .reduction_target = .intermediate_scalar,
        },
    };
    const func = schema.SemanticFunction{
        .name = "rms_norm_uniform_eps",
        .family_hint = .rms_norm,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    var input_bytes: [8]u8 = undefined;
    writeF32AsElem(&input_bytes, 0, 2.0, .f32);
    writeF32AsElem(&input_bytes, 1, 2.0, .f32);
    var scale_bytes: [8]u8 = undefined;
    writeF32AsElem(&scale_bytes, 0, 3.0, .f32);
    writeF32AsElem(&scale_bytes, 1, 4.0, .f32);
    var uniform_bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, uniform_bytes[0..4], 2, .little);
    writeF32AsElem(&uniform_bytes, 1, 0.0, .f32);
    const inputs = [_][]const u8{ &input_bytes, &scale_bytes, &uniform_bytes };

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 8), result.outputs[0].len);
    try std.testing.expectEqual(@as(f32, 3.0), readF32FromBytes(result.outputs[0], .f32, 0));
    try std.testing.expectEqual(@as(f32, 4.0), readF32FromBytes(result.outputs[0], .f32, 1));

    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(result.outputs[0], &expected_hash, .{});
    try std.testing.expectEqualSlices(u8, &expected_hash, &result.reference_hash);

    const missing_uniform_inputs = [_][]const u8{ &input_bytes, &scale_bytes };
    const missing = run(allocator, semantic, realization, &missing_uniform_inputs);
    try std.testing.expectError(InterpretError.NotImplemented, missing);
}

test "fused_gemv f16 strict_ordered exercises upcast/downcast path" {
    const allocator = std.testing.allocator;
    const matrix_shape = [_]u64{ 2, 2 };
    const vector_shape = [_]u64{2};
    const output_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "W", .group = 0, .binding = 0, .logical_shape = &matrix_shape, .elem = .f16, .read_write = false },
        .{ .name = "x", .group = 0, .binding = 1, .logical_shape = &vector_shape, .elem = .f16, .read_write = false },
        .{ .name = "y", .group = 0, .binding = 2, .logical_shape = &output_shape, .elem = .f16, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "k", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{ .accumulation = .f32, .associativity = .strict_ordered, .nan_inf = .propagate },
            .target_binding = 2,
        },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .matrix },
        .{ .binding_index = 1, .role = .vector },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .output },
        .{ .axis_index = 1, .role = .reduction },
    };
    const body = schema.SemanticBody{
        .op = .fused_gemv,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
    };
    const func = schema.SemanticFunction{
        .name = "gemv_f16",
        .family_hint = .fused_gemv,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // W = [[1,2],[4,8]] f16; x = [1, 2] f16. Values picked to be exactly
    // representable in f16 so the test pins an exact output, not a
    // tolerance-bounded one — the intent is to exercise the f16
    // upcast/downcast path, not test rounding.
    var matrix_bytes: [8]u8 = undefined;
    writeF32AsElem(&matrix_bytes, 0, 1.0, .f16);
    writeF32AsElem(&matrix_bytes, 1, 2.0, .f16);
    writeF32AsElem(&matrix_bytes, 2, 4.0, .f16);
    writeF32AsElem(&matrix_bytes, 3, 8.0, .f16);
    var vector_bytes: [4]u8 = undefined;
    writeF32AsElem(&vector_bytes, 0, 1.0, .f16);
    writeF32AsElem(&vector_bytes, 1, 2.0, .f16);
    const inputs = [_][]const u8{ &matrix_bytes, &vector_bytes };

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 4), result.outputs[0].len);

    // y[0] = 1*1 + 2*2 = 5; y[1] = 4*1 + 8*2 = 20.
    const y0 = readF32FromBytes(result.outputs[0], .f16, 0);
    const y1 = readF32FromBytes(result.outputs[0], .f16, 1);
    try std.testing.expectEqual(@as(f32, 5.0), y0);
    try std.testing.expectEqual(@as(f32, 20.0), y1);
}

test "fused_gemv bf16 strict_ordered exercises upcast/downcast path" {
    const allocator = std.testing.allocator;
    const matrix_shape = [_]u64{ 2, 2 };
    const vector_shape = [_]u64{2};
    const output_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "W", .group = 0, .binding = 0, .logical_shape = &matrix_shape, .elem = .bf16, .read_write = false },
        .{ .name = "x", .group = 0, .binding = 1, .logical_shape = &vector_shape, .elem = .bf16, .read_write = false },
        .{ .name = "y", .group = 0, .binding = 2, .logical_shape = &output_shape, .elem = .bf16, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "k", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{ .accumulation = .f32, .associativity = .strict_ordered, .nan_inf = .propagate },
            .target_binding = 2,
        },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .matrix },
        .{ .binding_index = 1, .role = .vector },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .output },
        .{ .axis_index = 1, .role = .reduction },
    };
    const body = schema.SemanticBody{
        .op = .fused_gemv,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
    };
    const func = schema.SemanticFunction{
        .name = "gemv_bf16",
        .family_hint = .fused_gemv,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Exactly-representable bf16 values (small powers of two × small
    // odd integers). bf16 has f32's exponent range but only 7 mantissa
    // bits; values here all have a mantissa that fits.
    var matrix_bytes: [8]u8 = undefined;
    writeF32AsElem(&matrix_bytes, 0, 1.0, .bf16);
    writeF32AsElem(&matrix_bytes, 1, 2.0, .bf16);
    writeF32AsElem(&matrix_bytes, 2, 4.0, .bf16);
    writeF32AsElem(&matrix_bytes, 3, 8.0, .bf16);
    var vector_bytes: [4]u8 = undefined;
    writeF32AsElem(&vector_bytes, 0, 1.0, .bf16);
    writeF32AsElem(&vector_bytes, 1, 2.0, .bf16);
    const inputs = [_][]const u8{ &matrix_bytes, &vector_bytes };

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 4), result.outputs[0].len);

    const y0 = readF32FromBytes(result.outputs[0], .bf16, 0);
    const y1 = readF32FromBytes(result.outputs[0], .bf16, 1);
    try std.testing.expectEqual(@as(f32, 5.0), y0);
    try std.testing.expectEqual(@as(f32, 20.0), y1);
}

test "gather f16 copies table rows in the declared element dtype" {
    const allocator = std.testing.allocator;
    const indices_shape = [_]u64{2};
    const table_shape = [_]u64{ 2, 2 };
    const output_shape = [_]u64{ 2, 2 };
    const bindings = [_]schema.BufferBinding{
        .{ .name = "indices", .group = 0, .binding = 0, .logical_shape = &indices_shape, .elem = .u32, .read_write = false },
        .{ .name = "table", .group = 0, .binding = 1, .logical_shape = &table_shape, .elem = .f16, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &output_shape, .elem = .f16, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "t", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "h", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .indices },
        .{ .binding_index = 1, .role = .table },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .token },
        .{ .axis_index = 1, .role = .hidden },
    };
    const body = schema.SemanticBody{
        .op = .gather,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
    };
    const func = schema.SemanticFunction{
        .name = "gather_f16",
        .family_hint = .gather,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Indices = [1, 0]; Table = [[1.5, 2.5], [3.5, 4.5]] f16.
    // Expected output = [[3.5, 4.5], [1.5, 2.5]] f16.
    var indices_bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, indices_bytes[0..4], 1, .little);
    std.mem.writeInt(u32, indices_bytes[4..8], 0, .little);
    var table_bytes: [8]u8 = undefined;
    writeF32AsElem(&table_bytes, 0, 1.5, .f16);
    writeF32AsElem(&table_bytes, 1, 2.5, .f16);
    writeF32AsElem(&table_bytes, 2, 3.5, .f16);
    writeF32AsElem(&table_bytes, 3, 4.5, .f16);
    const inputs = [_][]const u8{ &indices_bytes, &table_bytes };

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 8), result.outputs[0].len);
    try std.testing.expectEqual(@as(f32, 3.5), readF32FromBytes(result.outputs[0], .f16, 0));
    try std.testing.expectEqual(@as(f32, 4.5), readF32FromBytes(result.outputs[0], .f16, 1));
    try std.testing.expectEqual(@as(f32, 1.5), readF32FromBytes(result.outputs[0], .f16, 2));
    try std.testing.expectEqual(@as(f32, 2.5), readF32FromBytes(result.outputs[0], .f16, 3));
}

test "gather bf16 copies table rows in the declared element dtype" {
    const allocator = std.testing.allocator;
    const indices_shape = [_]u64{2};
    const table_shape = [_]u64{ 2, 2 };
    const output_shape = [_]u64{ 2, 2 };
    const bindings = [_]schema.BufferBinding{
        .{ .name = "indices", .group = 0, .binding = 0, .logical_shape = &indices_shape, .elem = .u32, .read_write = false },
        .{ .name = "table", .group = 0, .binding = 1, .logical_shape = &table_shape, .elem = .bf16, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &output_shape, .elem = .bf16, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "t", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "h", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .indices },
        .{ .binding_index = 1, .role = .table },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .token },
        .{ .axis_index = 1, .role = .hidden },
    };
    const body = schema.SemanticBody{
        .op = .gather,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
    };
    const func = schema.SemanticFunction{
        .name = "gather_bf16",
        .family_hint = .gather,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &.{},
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Integer-valued bf16 (exactly representable): 1, 2, 3, 4.
    var indices_bytes: [8]u8 = undefined;
    std.mem.writeInt(u32, indices_bytes[0..4], 1, .little);
    std.mem.writeInt(u32, indices_bytes[4..8], 0, .little);
    var table_bytes: [8]u8 = undefined;
    writeF32AsElem(&table_bytes, 0, 1.0, .bf16);
    writeF32AsElem(&table_bytes, 1, 2.0, .bf16);
    writeF32AsElem(&table_bytes, 2, 3.0, .bf16);
    writeF32AsElem(&table_bytes, 3, 4.0, .bf16);
    const inputs = [_][]const u8{ &indices_bytes, &table_bytes };

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 8), result.outputs[0].len);
    try std.testing.expectEqual(@as(f32, 3.0), readF32FromBytes(result.outputs[0], .bf16, 0));
    try std.testing.expectEqual(@as(f32, 4.0), readF32FromBytes(result.outputs[0], .bf16, 1));
    try std.testing.expectEqual(@as(f32, 1.0), readF32FromBytes(result.outputs[0], .bf16, 2));
    try std.testing.expectEqual(@as(f32, 2.0), readF32FromBytes(result.outputs[0], .bf16, 3));
}

test "rms_norm f16 literal epsilon exercises upcast/downcast path" {
    const allocator = std.testing.allocator;
    const hidden_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &hidden_shape, .elem = .f16, .read_write = false },
        .{ .name = "weight", .group = 0, .binding = 1, .logical_shape = &hidden_shape, .elem = .f16, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &hidden_shape, .elem = .f16, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "d", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{ .accumulation = .f32, .associativity = .strict_ordered, .nan_inf = .propagate },
            .target_binding = 2,
        },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .input },
        .{ .binding_index = 1, .role = .scale },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
        .{ .axis_index = 1, .role = .reduction },
    };
    const body = schema.SemanticBody{
        .op = .rms_norm,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
        .rms_norm = .{
            .formula = .sum_squares_mean_epsilon_rsqrt_scale,
            .epsilon = .{ .source = .literal_f32, .path = "", .literal_f32 = 0.0 },
            .hidden_extent_axis = 0,
            .reduction_target = .intermediate_scalar,
        },
    };
    const func = schema.SemanticFunction{
        .name = "rms_norm_f16",
        .family_hint = .rms_norm,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // input = [2, 2] f16 → mean_sq = 4.0 exactly, inv_rms = 0.5 exactly.
    // scale = [3, 4] f16 → output = [3, 4] f16, all exactly representable.
    var input_bytes: [4]u8 = undefined;
    writeF32AsElem(&input_bytes, 0, 2.0, .f16);
    writeF32AsElem(&input_bytes, 1, 2.0, .f16);
    var scale_bytes: [4]u8 = undefined;
    writeF32AsElem(&scale_bytes, 0, 3.0, .f16);
    writeF32AsElem(&scale_bytes, 1, 4.0, .f16);
    const inputs = [_][]const u8{ &input_bytes, &scale_bytes };

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 4), result.outputs[0].len);
    try std.testing.expectEqual(@as(f32, 3.0), readF32FromBytes(result.outputs[0], .f16, 0));
    try std.testing.expectEqual(@as(f32, 4.0), readF32FromBytes(result.outputs[0], .f16, 1));
}

test "rms_norm bf16 literal epsilon exercises upcast/downcast path" {
    const allocator = std.testing.allocator;
    const hidden_shape = [_]u64{2};
    const bindings = [_]schema.BufferBinding{
        .{ .name = "input", .group = 0, .binding = 0, .logical_shape = &hidden_shape, .elem = .bf16, .read_write = false },
        .{ .name = "weight", .group = 0, .binding = 1, .logical_shape = &hidden_shape, .elem = .bf16, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &hidden_shape, .elem = .bf16, .read_write = true },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "d", .lower_bound = "0", .upper_bound = "2", .step = "1" },
        .{ .name = "i", .lower_bound = "0", .upper_bound = "2", .step = "1" },
    };
    const reductions = [_]schema.ReductionRegion{
        .{
            .axis = 1,
            .op = .sum,
            .contract = .{ .accumulation = .f32, .associativity = .strict_ordered, .nan_inf = .propagate },
            .target_binding = 2,
        },
    };
    const body_bindings = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .input },
        .{ .binding_index = 1, .role = .scale },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
        .{ .axis_index = 1, .role = .reduction },
    };
    const body = schema.SemanticBody{
        .op = .rms_norm,
        .binding_roles = &body_bindings,
        .axis_roles = &body_axes,
        .rms_norm = .{
            .formula = .sum_squares_mean_epsilon_rsqrt_scale,
            .epsilon = .{ .source = .literal_f32, .path = "", .literal_f32 = 0.0 },
            .hidden_extent_axis = 0,
            .reduction_target = .intermediate_scalar,
        },
    };
    const func = schema.SemanticFunction{
        .name = "rms_norm_bf16",
        .family_hint = .rms_norm,
        .axes = &axes,
        .bindings = &bindings,
        .reductions = &reductions,
        .collectives = &.{},
        .body = body,
        .source_digest = [_]u8{0} ** 32,
    };
    const funcs = [_]schema.SemanticFunction{func};
    const semantic = schema.Semantic{ .functions = &funcs, .rejections = &.{} };
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Same small-integer shape: input = [2, 2] bf16 → mean_sq = 4.0
    // exactly (the f32 accumulator doesn't lose precision on two bf16 2.0
    // squared-and-summed), inv_rms = 0.5 exactly; scale = [3, 4] bf16 →
    // output = [3, 4] bf16, all exactly representable.
    var input_bytes: [4]u8 = undefined;
    writeF32AsElem(&input_bytes, 0, 2.0, .bf16);
    writeF32AsElem(&input_bytes, 1, 2.0, .bf16);
    var scale_bytes: [4]u8 = undefined;
    writeF32AsElem(&scale_bytes, 0, 3.0, .bf16);
    writeF32AsElem(&scale_bytes, 1, 4.0, .bf16);
    const inputs = [_][]const u8{ &input_bytes, &scale_bytes };

    var result = try run(allocator, semantic, realization, &inputs);
    defer freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    try std.testing.expectEqual(@as(usize, 4), result.outputs[0].len);
    try std.testing.expectEqual(@as(f32, 3.0), readF32FromBytes(result.outputs[0], .bf16, 0));
    try std.testing.expectEqual(@as(f32, 4.0), readF32FromBytes(result.outputs[0], .bf16, 1));
}
