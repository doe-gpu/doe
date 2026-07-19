// TSIR Step 5/6 planner tests.
//
// The planner consumes backend-independent TSIR semantic nodes and a
// target descriptor, then emits explicit realization decisions. These
// tests lock the correctness-first contract: fit decisions are
// deterministic, target limits produce typed rejections, and
// collectives/reductions are checked against descriptor-declared
// capability.

const std = @import("std");
const tsir = @import("../../src/compiler/tsir/mod.zig");
const targets = @import("../../src/compiler/targets/mod.zig");

test "planner replicates bindings that fit the target working budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const shape = [_]u64{1024};
    const bindings = [_]tsir.schema.BufferBinding{
        .{
            .name = "input",
            .group = 0,
            .binding = 0,
            .logical_shape = &shape,
            .elem = .f32,
            .read_write = false,
        },
    };
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&bindings, &.{}, &.{}, &.{})};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const realization = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.webgpu_generic.descriptor,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 1), realization.functions.len);
    try std.testing.expectEqual(@as(usize, 0), realization.rejections.len);
    const func = realization.functions[0];
    try std.testing.expectEqual(@as(usize, 0), func.tiles.per_axis.len);
    try std.testing.expectEqual(@as(u32, 1), func.pe_grid.width);
    try std.testing.expectEqual(@as(u32, 1), func.pe_grid.height);
    try std.testing.expectEqual(@as(usize, 1), func.residency.len);
    try std.testing.expectEqual(tsir.schema.ResidencyClass.pe_replicated, func.residency[0].class);
    try std.testing.expectEqual(@as(u32, 0), func.residency[0].binding_index);

    const expected_hash = targets.descriptorHash(targets.webgpu_generic.descriptor);
    try std.testing.expectEqualSlices(u8, &expected_hash, &func.target_descriptor_hash);
}

test "planner slices oversized bindings when per-shard footprint fits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const shape = [_]u64{ 8, 8192 };
    const bindings = [_]tsir.schema.BufferBinding{
        .{
            .name = "weights",
            .group = 0,
            .binding = 0,
            .logical_shape = &shape,
            .elem = .f32,
            .read_write = false,
        },
    };
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&bindings, &.{}, &.{}, &.{})};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const realization = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.wse3.descriptor,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 0), realization.rejections.len);
    const residency = realization.functions[0].residency;
    try std.testing.expectEqual(@as(usize, 1), residency.len);
    try std.testing.expectEqual(tsir.schema.ResidencyClass.pe_sliced, residency[0].class);
    try std.testing.expectEqual(@as(?u32, 1), residency[0].axis);
    try std.testing.expectEqual(@as(?u32, 8), residency[0].shards);
}

test "planner rejects oversized bindings without a legal slice or stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const shape = [_]u64{100_000};
    const bindings = [_]tsir.schema.BufferBinding{
        .{
            .name = "large",
            .group = 0,
            .binding = 0,
            .logical_shape = &shape,
            .elem = .f32,
            .read_write = false,
        },
    };
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&bindings, &.{}, &.{}, &.{})};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const realization = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.webgpu_generic.descriptor,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 0), realization.functions[0].residency.len);
    try std.testing.expectEqual(@as(usize, 1), realization.rejections.len);
    try std.testing.expectEqual(
        tsir.RejectionReason.tsir_pe_budget_exhausted,
        realization.rejections[0].reason,
    );
    try std.testing.expectEqualStrings("functions[0].bindings[0]", realization.rejections[0].node_path);
}

test "planner streams oversized bindings only when loader capabilities allow it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const shape = [_]u64{1_000_000};
    const bindings = [_]tsir.schema.BufferBinding{
        .{
            .name = "embedding",
            .group = 0,
            .binding = 0,
            .logical_shape = &shape,
            .elem = .f32,
            .read_write = false,
        },
    };
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&bindings, &.{}, &.{}, &.{})};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const realization = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.wse3.descriptor,
        .{
            .loader = .{
                .fabric_streaming = true,
                .max_stream_chunk_bytes = 64 * 1024,
            },
        },
    );

    const residency = realization.functions[0].residency;
    try std.testing.expectEqual(@as(usize, 1), residency.len);
    try std.testing.expectEqual(tsir.schema.ResidencyClass.fabric_streamed, residency[0].class);
    try std.testing.expectEqual(@as(?u32, 0), residency[0].fabric_color);
    try std.testing.expectEqual(@as(?u64, 38 * 1024), residency[0].chunk_bytes);
    try std.testing.expectEqual(@as(usize, 0), realization.rejections.len);
}

test "planner handles runtime-sized bindings by target policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const runtime_shape = [_]u64{0};
    const bindings = [_]tsir.schema.BufferBinding{
        .{
            .name = "runtime_buffer",
            .group = 0,
            .binding = 0,
            .logical_shape = &runtime_shape,
            .elem = .f32,
            .read_write = false,
        },
    };
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&bindings, &.{}, &.{}, &.{})};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const webgpu = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.webgpu_generic.descriptor,
        .{},
    );
    try std.testing.expectEqual(@as(usize, 0), webgpu.rejections.len);
    try std.testing.expectEqual(@as(usize, 1), webgpu.functions[0].residency.len);
    try std.testing.expectEqual(
        tsir.schema.ResidencyClass.host_copied,
        webgpu.functions[0].residency[0].class,
    );

    const wse3_without_loader = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.wse3.descriptor,
        .{},
    );
    try std.testing.expectEqual(@as(usize, 0), wse3_without_loader.functions[0].residency.len);
    try std.testing.expectEqual(@as(usize, 1), wse3_without_loader.rejections.len);
    try std.testing.expectEqual(
        tsir.RejectionReason.tsir_pe_budget_exhausted,
        wse3_without_loader.rejections[0].reason,
    );

    const wse3_with_loader = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.wse3.descriptor,
        .{
            .loader = .{
                .fabric_streaming = true,
                .max_stream_chunk_bytes = 4096,
            },
        },
    );
    try std.testing.expectEqual(@as(usize, 0), wse3_with_loader.rejections.len);
    try std.testing.expectEqual(@as(usize, 1), wse3_with_loader.functions[0].residency.len);
    try std.testing.expectEqual(
        tsir.schema.ResidencyClass.fabric_streamed,
        wse3_with_loader.functions[0].residency[0].class,
    );
    try std.testing.expectEqual(@as(?u64, 4096), wse3_with_loader.functions[0].residency[0].chunk_bytes);
}

test "planner synthesizes descriptor-supported collectives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const axes = [_]tsir.schema.IterationAxis{
        .{
            .name = "i",
            .lower_bound = "0",
            .upper_bound = "128",
            .step = "1",
        },
    };
    const collectives = [_]tsir.schema.CollectiveSemanticNode{
        .{
            .kind = .subgroup_add,
            .axis = 0,
            .exactness = .{
                .class = .algorithm_exact,
                .algorithm_exact_invariants = &.{
                    .reduction_order,
                    .tree_shape,
                    .accum_dtype,
                    .associativity_grouping,
                },
            },
            .dtype = .f32,
        },
    };
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&.{}, &axes, &.{}, &collectives)};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const realization = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.wse3.descriptor,
        .{},
    );

    const out = realization.functions[0].collectives;
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u32, 0), out[0].semantic_index);
    try std.testing.expectEqual(tsir.schema.ReductionTreeShape.linear, out[0].tree_shape);
    try std.testing.expectEqual(@as(?u32, null), out[0].fabric_color);
    try std.testing.expectEqual(@as(u32, 64), out[0].group_size);
    try std.testing.expectEqual(@as(usize, 0), realization.rejections.len);
}

test "planner rejects collectives absent from the target descriptor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const collectives = [_]tsir.schema.CollectiveSemanticNode{
        .{
            .kind = .subgroup_add,
            .axis = -1,
            .exactness = .{ .class = .algorithm_exact },
            .dtype = .f32,
        },
    };
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&.{}, &.{}, &.{}, &collectives)};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const realization = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.webgpu_generic.descriptor,
        .{},
    );

    try std.testing.expectEqual(@as(usize, 0), realization.functions[0].collectives.len);
    try std.testing.expectEqual(@as(usize, 1), realization.rejections.len);
    try std.testing.expectEqual(
        tsir.RejectionReason.tsir_collective_not_representable,
        realization.rejections[0].reason,
    );
    try std.testing.expectEqualStrings("functions[0].collectives[0]", realization.rejections[0].node_path);
}

test "planner accepts workgroup barriers without numerical dtype support" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const collectives = [_]tsir.schema.CollectiveSemanticNode{
        .{
            .kind = .workgroup_barrier,
            .axis = -1,
            .exactness = .{ .class = .algorithm_exact },
            .dtype = .u32,
        },
    };
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&.{}, &.{}, &.{}, &collectives)};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const realization = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.webgpu_generic.descriptor,
        .{},
    );

    const out = realization.functions[0].collectives;
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u32, 0), out[0].semantic_index);
    try std.testing.expectEqual(@as(?u32, null), out[0].fabric_color);
    try std.testing.expectEqual(@as(u32, 256), out[0].group_size);
    try std.testing.expectEqual(@as(usize, 0), realization.rejections.len);
}

test "planner emits reduction tree choices only for associative reductions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const reductions = [_]tsir.schema.ReductionRegion{
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .associative_allowed,
                .nan_inf = .propagate,
            },
            .target_binding = 0,
        },
        .{
            .axis = 0,
            .op = .sum,
            .contract = .{
                .accumulation = .f32,
                .associativity = .strict_ordered,
                .nan_inf = .propagate,
            },
            .target_binding = 0,
        },
    };
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&.{}, &.{}, &reductions, &.{})};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const realization = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.wse3.descriptor,
        .{},
    );

    const out = realization.functions[0].reductions;
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u32, 0), out[0].semantic_index);
    try std.testing.expectEqual(tsir.schema.ReductionTreeShape.linear, out[0].tree_shape);
    try std.testing.expectEqual(@as(usize, 0), realization.rejections.len);
}

test "planner assigns distinct fabric colors and rejects once the budget is exhausted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const budget = targets.wse3.descriptor.correctness.fabric_color_count;
    try std.testing.expect(budget > 0);
    const count: usize = @as(usize, budget) + 1;

    const collectives = try allocator.alloc(tsir.schema.CollectiveSemanticNode, count);
    for (collectives) |*c| {
        c.* = .{
            .kind = .fabric_reduce,
            .axis = -1,
            .exactness = .{
                .class = .algorithm_exact,
                .algorithm_exact_invariants = &.{
                    .reduction_order,
                    .tree_shape,
                    .accum_dtype,
                    .associativity_grouping,
                },
            },
            .dtype = .f32,
        };
    }
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&.{}, &.{}, &.{}, collectives)};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const realization = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.wse3.descriptor,
        .{},
    );

    const out = realization.functions[0].collectives;
    try std.testing.expectEqual(@as(usize, budget), out.len);
    for (out, 0..) |node, i| {
        try std.testing.expectEqual(@as(u32, @intCast(i)), node.semantic_index);
        try std.testing.expectEqual(@as(?u32, @intCast(i)), node.fabric_color);
    }

    try std.testing.expectEqual(@as(usize, 1), realization.rejections.len);
    try std.testing.expectEqual(
        tsir.RejectionReason.tsir_collective_not_representable,
        realization.rejections[0].reason,
    );
    const expected_path = try std.fmt.allocPrint(
        allocator,
        "functions[0].collectives[{d}]",
        .{budget},
    );
    try std.testing.expectEqualStrings(expected_path, realization.rejections[0].node_path);
    try std.testing.expectEqualStrings(
        "target fabric color budget exhausted",
        realization.rejections[0].detail,
    );
}

test "planner accepts a bit_exact_solo capability for a tolerance_bounded semantic collective" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const collectives = [_]tsir.schema.CollectiveSemanticNode{
        .{
            .kind = .fabric_broadcast,
            .axis = -1,
            .exactness = .{
                .class = .tolerance_bounded,
                .tolerance_metric = "ulp",
                .tolerance_epsilon = 4.0,
            },
            .dtype = .f32,
        },
    };
    const functions = [_]tsir.schema.SemanticFunction{semanticFunction(&.{}, &.{}, &.{}, &collectives)};
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };

    const realization = try tsir.planner.planRealization(
        allocator,
        semantic,
        targets.wse3.descriptor,
        .{},
    );

    const out = realization.functions[0].collectives;
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqual(@as(u32, 0), out[0].semantic_index);
    try std.testing.expectEqual(@as(?u32, 0), out[0].fabric_color);
    try std.testing.expectEqual(@as(usize, 0), realization.rejections.len);
}

fn semanticFunction(
    bindings: []const tsir.schema.BufferBinding,
    axes: []const tsir.schema.IterationAxis,
    reductions: []const tsir.schema.ReductionRegion,
    collectives: []const tsir.schema.CollectiveSemanticNode,
) tsir.schema.SemanticFunction {
    return .{
        .name = "kernel",
        .family_hint = .unknown,
        .axes = axes,
        .bindings = bindings,
        .reductions = reductions,
        .collectives = collectives,
        .source_digest = [_]u8{0x42} ** 32,
    };
}
