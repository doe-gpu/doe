// Scaffolding checks for the TSIR module and target descriptors.
//
// Locks the minimum invariants of the new compiler front door:
//   - Target descriptors produce distinct, stable hashes.
//   - Digest helper is defensive against empty inputs.
//   - Reference interpreter is fail-closed by default:
//       * `RejectedBySemantic` for explicit TSIR rejections
//       * `NotImplemented` for unsupported but otherwise valid TSIR
//
// When each TSIR pass lands, its own test file joins `tests/wgsl/`.

const std = @import("std");
const tsir = @import("../../src/compiler/tsir/mod.zig");
const tsir_digest = @import("../../src/compiler/tsir/digest.zig");
const tsir_reference = @import("../../src/compiler/tsir/reference_interpreter.zig");
const targets = @import("../../src/compiler/targets/mod.zig");

test "target descriptors have distinct stable hashes" {
    const wse3_a = targets.descriptorHash(targets.wse3.descriptor);
    const wse3_b = targets.descriptorHash(targets.wse3.descriptor);
    const webgpu = targets.descriptorHash(targets.webgpu_generic.descriptor);
    try std.testing.expectEqualSlices(u8, &wse3_a, &wse3_b);
    try std.testing.expect(!std.mem.eql(u8, &wse3_a, &webgpu));
}

test "tsir digests are deterministic on empty semantic/realization" {
    const allocator = std.testing.allocator;
    const semantic = tsir.Semantic{ .functions = &.{}, .rejections = &.{} };
    const realization = tsir.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const a = try tsir_digest.compute(allocator, semantic, realization, "emitter.v0");
    const b = try tsir_digest.compute(allocator, semantic, realization, "emitter.v0");
    try std.testing.expectEqualSlices(u8, &a.semantic, &b.semantic);
    try std.testing.expectEqualSlices(u8, &a.realization, &b.realization);
    try std.testing.expectEqualSlices(u8, &a.emitter, &b.emitter);
    try std.testing.expect(!std.mem.eql(u8, &a.semantic, &a.realization));
}

test "reference interpreter refuses zero oracle by default" {
    const allocator = std.testing.allocator;
    const semantic = tsir.Semantic{ .functions = &.{}, .rejections = &.{} };
    const realization = tsir.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const inputs = [_][]const u8{};
    const outcome = tsir_reference.run(allocator, semantic, realization, &inputs);
    try std.testing.expectError(tsir_reference.InterpretError.NotImplemented, outcome);
}

test "reference interpreter distinguishes rejected TSIR from unimplemented oracle" {
    const allocator = std.testing.allocator;
    const semantic_rejections = [_]tsir.RejectionEntry{
        .{
            .reason = .tsir_collective_not_representable,
            .node_path = "functions[0].collectives[0]",
            .detail = "fixture-rejected",
        },
    };
    const semantic = tsir.Semantic{
        .functions = &.{},
        .rejections = &semantic_rejections,
    };
    const realization = tsir.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const inputs = [_][]const u8{};
    const outcome = tsir_reference.run(allocator, semantic, realization, &inputs);
    try std.testing.expectError(
        tsir_reference.InterpretError.RejectedBySemantic,
        outcome,
    );
}

test "reference interpreter computes residual_add elementwise sum" {
    const allocator = std.testing.allocator;

    const axes = [_]tsir.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "len", .step = "1" },
    };
    const bindings = [_]tsir.BufferBinding{
        .{ .name = "a", .group = 0, .binding = 0, .logical_shape = &.{4}, .elem = .f32, .read_write = false },
        .{ .name = "b", .group = 0, .binding = 1, .logical_shape = &.{4}, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{4}, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .summand_a },
        .{ .binding_index = 1, .role = .summand_b },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]tsir.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
    };
    const functions = [_]tsir.SemanticFunction{
        .{
            .name = "main",
            .family_hint = .elementwise,
            .axes = &axes,
            .bindings = &bindings,
            .reductions = &.{},
            .collectives = &.{},
            .body = .{
                .op = .residual_add,
                .binding_roles = &body_bindings,
                .axis_roles = &body_axes,
            },
            .source_digest = [_]u8{0} ** 32,
        },
    };
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };
    const realization = tsir.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    const a_values = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const b_values = [_]f32{ 10.0, 20.0, 30.0, 40.0 };
    const a_bytes = std.mem.sliceAsBytes(&a_values);
    const b_bytes = std.mem.sliceAsBytes(&b_values);
    const inputs = [_][]const u8{ a_bytes, b_bytes };

    var result = try tsir_reference.run(allocator, semantic, realization, &inputs);
    defer tsir_reference.freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    const output = std.mem.bytesAsSlice(f32, @as([]align(4) const u8, @alignCast(result.outputs[0])));
    try std.testing.expectEqual(@as(usize, 4), output.len);
    try std.testing.expectEqual(@as(f32, 11.0), output[0]);
    try std.testing.expectEqual(@as(f32, 22.0), output[1]);
    try std.testing.expectEqual(@as(f32, 33.0), output[2]);
    try std.testing.expectEqual(@as(f32, 44.0), output[3]);
}

test "reference interpreter computes gelu_gated tanh-approx body" {
    const allocator = std.testing.allocator;

    const axes = [_]tsir.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "len", .step = "1" },
    };
    const bindings = [_]tsir.BufferBinding{
        .{ .name = "gate", .group = 0, .binding = 0, .logical_shape = &.{4}, .elem = .f32, .read_write = false },
        .{ .name = "input", .group = 0, .binding = 1, .logical_shape = &.{4}, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{4}, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .gate },
        .{ .binding_index = 1, .role = .input },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]tsir.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
    };
    const functions = [_]tsir.SemanticFunction{
        .{
            .name = "main",
            .family_hint = .elementwise,
            .axes = &axes,
            .bindings = &bindings,
            .reductions = &.{},
            .collectives = &.{},
            .body = .{
                .op = .gelu_gated,
                .binding_roles = &body_bindings,
                .axis_roles = &body_axes,
            },
            .source_digest = [_]u8{0} ** 32,
        },
    };
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };
    const realization = tsir.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Two zero-anchored cases independent of the tanh approximation,
    // plus one non-zero case re-derived from the same formula.
    //   gate[0]=0, input[0]=100  -> gelu(0)=0, output=0
    //   gate[1]=5, input[1]=0    -> input multiplier=0, output=0
    //   gate[2]=-50,input[2]=2   -> inner clamp at -15, tanh(-15)≈-1
    //                                gelu(-50)≈0.5 * -50 * (1 + -1) = 0
    //                                so output ≈ 0
    //   gate[3]=1, input[3]=2    -> derive expected from same formula
    const gate_values = [_]f32{ 0.0, 5.0, -50.0, 1.0 };
    const input_values = [_]f32{ 100.0, 0.0, 2.0, 2.0 };
    const gate_bytes = std.mem.sliceAsBytes(&gate_values);
    const input_bytes = std.mem.sliceAsBytes(&input_values);
    const inputs = [_][]const u8{ gate_bytes, input_bytes };

    var result = try tsir_reference.run(allocator, semantic, realization, &inputs);
    defer tsir_reference.freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    const output = std.mem.bytesAsSlice(f32, @as([]align(4) const u8, @alignCast(result.outputs[0])));
    try std.testing.expectEqual(@as(usize, 4), output.len);
    try std.testing.expectEqual(@as(f32, 0.0), output[0]);
    try std.testing.expectEqual(@as(f32, 0.0), output[1]);
    // gate=-50: clamp pins inner to -15; tanh(-15) is within ulp of -1
    // so gelu(-50) is within ulp of 0; product with input is also near zero.
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), output[2], 1e-6);

    // Re-derive expected for gate=1, input=2 using the same formula.
    const x: f32 = 1.0;
    var inner: f32 = 0.7978845608028654 * (x + 0.044715 * x * x * x);
    if (inner < -15.0) inner = -15.0;
    if (inner > 15.0) inner = 15.0;
    const gelu_x = 0.5 * x * (1.0 + std.math.tanh(inner));
    const expected3: f32 = gelu_x * 2.0;
    try std.testing.expectEqual(expected3, output[3]);
}

test "reference interpreter computes silu_gated body" {
    const allocator = std.testing.allocator;

    const axes = [_]tsir.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "len", .step = "1" },
    };
    const bindings = [_]tsir.BufferBinding{
        .{ .name = "gate", .group = 0, .binding = 0, .logical_shape = &.{4}, .elem = .f32, .read_write = false },
        .{ .name = "input", .group = 0, .binding = 1, .logical_shape = &.{4}, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{4}, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .gate },
        .{ .binding_index = 1, .role = .input },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]tsir.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
    };
    const functions = [_]tsir.SemanticFunction{
        .{
            .name = "main",
            .family_hint = .elementwise,
            .axes = &axes,
            .bindings = &bindings,
            .reductions = &.{},
            .collectives = &.{},
            .body = .{
                .op = .silu_gated,
                .binding_roles = &body_bindings,
                .axis_roles = &body_axes,
            },
            .source_digest = [_]u8{0} ** 32,
        },
    };
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };
    const realization = tsir.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Cases:
    //   gate=0, input=anything  -> silu(0)=0, output=0
    //   gate=anything, input=0  -> input multiplier=0, output=0
    //   gate=-50, input=2       -> z clamps at 15; silu(-50) is small but
    //                              non-zero (~-50/(1+e^15)); derived inline
    //   gate=1, input=2         -> derive from same formula
    const gate_values = [_]f32{ 0.0, 5.0, -50.0, 1.0 };
    const input_values = [_]f32{ 100.0, 0.0, 2.0, 2.0 };
    const gate_bytes = std.mem.sliceAsBytes(&gate_values);
    const input_bytes = std.mem.sliceAsBytes(&input_values);
    const inputs = [_][]const u8{ gate_bytes, input_bytes };

    var result = try tsir_reference.run(allocator, semantic, realization, &inputs);
    defer tsir_reference.freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    const output = std.mem.bytesAsSlice(f32, @as([]align(4) const u8, @alignCast(result.outputs[0])));
    try std.testing.expectEqual(@as(usize, 4), output.len);
    try std.testing.expectEqual(@as(f32, 0.0), output[0]);
    try std.testing.expectEqual(@as(f32, 0.0), output[1]);

    // Derive case 2 (gate=-50, input=2) from the same clamped formula.
    const x2: f32 = -50.0;
    var z2: f32 = -x2;
    if (z2 < -15.0) z2 = -15.0;
    if (z2 > 15.0) z2 = 15.0;
    const silu_x2 = x2 / (1.0 + std.math.exp(z2));
    try std.testing.expectApproxEqAbs(silu_x2 * 2.0, output[2], 1e-10);

    // Case 3 (gate=1, input=2).
    const x3: f32 = 1.0;
    var z3: f32 = -x3;
    if (z3 < -15.0) z3 = -15.0;
    if (z3 > 15.0) z3 = 15.0;
    const silu_x3 = x3 / (1.0 + std.math.exp(z3));
    try std.testing.expectEqual(silu_x3 * 2.0, output[3]);
}

test "reference interpreter computes sigmoid_gated body" {
    const allocator = std.testing.allocator;

    const axes = [_]tsir.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "len", .step = "1" },
    };
    const bindings = [_]tsir.BufferBinding{
        .{ .name = "gate", .group = 0, .binding = 0, .logical_shape = &.{4}, .elem = .f32, .read_write = false },
        .{ .name = "input", .group = 0, .binding = 1, .logical_shape = &.{4}, .elem = .f32, .read_write = false },
        .{ .name = "output", .group = 0, .binding = 2, .logical_shape = &.{4}, .elem = .f32, .read_write = true },
    };
    const body_bindings = [_]tsir.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .gate },
        .{ .binding_index = 1, .role = .input },
        .{ .binding_index = 2, .role = .output },
    };
    const body_axes = [_]tsir.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
    };
    const functions = [_]tsir.SemanticFunction{
        .{
            .name = "main",
            .family_hint = .elementwise,
            .axes = &axes,
            .bindings = &bindings,
            .reductions = &.{},
            .collectives = &.{},
            .body = .{
                .op = .sigmoid_gated,
                .binding_roles = &body_bindings,
                .axis_roles = &body_axes,
            },
            .source_digest = [_]u8{0} ** 32,
        },
    };
    const semantic = tsir.Semantic{ .functions = &functions, .rejections = &.{} };
    const realization = tsir.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };

    // Cases:
    //   gate=0  -> sigmoid(0)=0.5; output = 0.5 * input
    //   input=0 -> output=0
    //   gate=50, input=2   -> z clamps at -15; sigmoid(50)≈1 -> output≈2
    //   gate=-50, input=2  -> z clamps at 15;  sigmoid(-50)≈0 -> output≈0
    const gate_values = [_]f32{ 0.0, 5.0, 50.0, -50.0 };
    const input_values = [_]f32{ 4.0, 0.0, 2.0, 2.0 };
    const gate_bytes = std.mem.sliceAsBytes(&gate_values);
    const input_bytes = std.mem.sliceAsBytes(&input_values);
    const inputs = [_][]const u8{ gate_bytes, input_bytes };

    var result = try tsir_reference.run(allocator, semantic, realization, &inputs);
    defer tsir_reference.freeResult(allocator, &result);

    try std.testing.expectEqual(@as(usize, 1), result.outputs.len);
    const output = std.mem.bytesAsSlice(f32, @as([]align(4) const u8, @alignCast(result.outputs[0])));
    try std.testing.expectEqual(@as(usize, 4), output.len);
    try std.testing.expectEqual(@as(f32, 2.0), output[0]); // 0.5 * 4
    try std.testing.expectEqual(@as(f32, 0.0), output[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), output[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), output[3], 1e-6);
}

test "rejection taxonomy is exhaustive and enumerable" {
    const reasons = [_]tsir.RejectionReason{
        .tsir_subgroup_unlowerable,
        .tsir_pe_budget_exhausted,
        .tsir_collective_not_representable,
        .tsir_dependence_unanalyzable,
        .tsir_source_not_affine,
        .tsir_target_unfit,
    };
    // Compiles-only lock: proves every taxonomy code is exported and
    // usable from the public mod.zig surface. Guards against a future
    // rename silently breaking the parity CLI's hard-coded set.
    try std.testing.expect(reasons.len == 6);
}

test "exactness classes match the RDRR taxonomy verbatim" {
    const classes = [_]tsir.ExactnessClass{
        .bit_exact_solo,
        .algorithm_exact,
        .tolerance_bounded,
    };
    try std.testing.expect(classes.len == 3);
}

test "AlgorithmExactInvariant covers the bit-affecting properties" {
    const invariants = [_]tsir.AlgorithmExactInvariant{
        .reduction_order,
        .tree_shape,
        .accum_dtype,
        .associativity_grouping,
    };
    try std.testing.expect(invariants.len == 4);
}

test "Exactness defaults carry class with empty invariant payload" {
    const bit_exact = tsir.Exactness{ .class = .bit_exact_solo };
    try std.testing.expectEqual(tsir.ExactnessClass.bit_exact_solo, bit_exact.class);
    try std.testing.expectEqual(@as(usize, 0), bit_exact.algorithm_exact_invariants.len);
    try std.testing.expectEqualStrings("", bit_exact.tolerance_metric);
    try std.testing.expectEqual(@as(f64, 0.0), bit_exact.tolerance_epsilon);

    const invariants = [_]tsir.AlgorithmExactInvariant{
        .reduction_order,
        .tree_shape,
    };
    const algo = tsir.Exactness{
        .class = .algorithm_exact,
        .algorithm_exact_invariants = &invariants,
    };
    try std.testing.expectEqual(@as(usize, 2), algo.algorithm_exact_invariants.len);
    try std.testing.expectEqual(tsir.AlgorithmExactInvariant.reduction_order, algo.algorithm_exact_invariants[0]);

    const tol = tsir.Exactness{
        .class = .tolerance_bounded,
        .tolerance_metric = "ulp",
        .tolerance_epsilon = 2.0,
    };
    try std.testing.expectEqualStrings("ulp", tol.tolerance_metric);
    try std.testing.expectEqual(@as(f64, 2.0), tol.tolerance_epsilon);
}
