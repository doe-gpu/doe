// Step 4 tests: the WGSL → TSIR frontend end-to-end.
//
// Parse + analyze + build IR + lower to TSIR. The frontend now
// recovers full TSIR semantic for the Phase A bootstrap families —
// iteration axes, buffer bindings, reduction regions, collective
// semantic nodes, typed rejections, kernel-family hints, and
// per-family `SemanticBody` payloads for fused_gemv / rms_norm /
// gather. These tests lock those structural invariants.

const std = @import("std");
const tsir = @import("../../src/compiler/tsir/mod.zig");
const parser = @import("../../src/compiler/wgsl/frontend/parser.zig");
const sema = @import("../../src/compiler/wgsl/frontend/sema.zig");
const ir_builder = @import("../../src/compiler/wgsl/ir/ir_builder.zig");

test "frontend lowers a WGSL module with one entrypoint to Semantic with one function" {
    const allocator = std.testing.allocator;
    const wgsl_source =
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const source_digest: [32]u8 = [_]u8{0xAB} ** 32;
    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        source_digest,
        "frontend-0.0.1",
    );

    try std.testing.expectEqual(@as(u32, tsir.CONTRACT_VERSION), semantic.contract_version);
    try std.testing.expectEqualStrings("frontend-0.0.1", semantic.frontend_version);
    try std.testing.expectEqual(@as(usize, 1), semantic.functions.len);
    try std.testing.expectEqualStrings("main", semantic.functions[0].name);
    try std.testing.expectEqual(tsir.KernelFamilyHint.unknown, semantic.functions[0].family_hint);
    try std.testing.expectEqualSlices(u8, &source_digest, &semantic.functions[0].source_digest);
    // Bindings / axes / reductions / collectives stay empty in this
    // first increment; extending any of them is a future iteration.
    try std.testing.expectEqual(@as(usize, 0), semantic.functions[0].axes.len);
    try std.testing.expectEqual(@as(usize, 0), semantic.functions[0].bindings.len);
    try std.testing.expectEqual(@as(usize, 0), semantic.functions[0].reductions.len);
    try std.testing.expectEqual(@as(usize, 0), semantic.functions[0].collectives.len);
    try std.testing.expectEqual(@as(usize, 0), semantic.rejections.len);
}

test "frontend extracts buffer bindings from module globals" {
    const allocator = std.testing.allocator;
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    output[0] = input[0];
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const source_digest: [32]u8 = [_]u8{0} ** 32;
    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        source_digest,
        "frontend-0.0.2",
    );

    try std.testing.expectEqual(@as(usize, 1), semantic.functions.len);
    const func = semantic.functions[0];
    try std.testing.expectEqualStrings("main", func.name);
    try std.testing.expectEqual(@as(usize, 2), func.bindings.len);

    // Bindings preserve group/binding and read/write polarity.
    const input_binding = findBinding(func.bindings, "input") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), input_binding.group);
    try std.testing.expectEqual(@as(u32, 0), input_binding.binding);
    try std.testing.expectEqual(false, input_binding.read_write);
    try std.testing.expectEqual(tsir.ScalarKind.f32, input_binding.elem);
    // array<f32> with no length → logical_shape = [0] (runtime-sized
    // in WGSL; semantic shape has one dim of unknown length).
    try std.testing.expectEqual(@as(usize, 1), input_binding.logical_shape.len);
    try std.testing.expectEqual(@as(u64, 0), input_binding.logical_shape[0]);

    const output_binding = findBinding(func.bindings, "output") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0), output_binding.group);
    try std.testing.expectEqual(@as(u32, 1), output_binding.binding);
    try std.testing.expectEqual(true, output_binding.read_write);
    try std.testing.expectEqual(tsir.ScalarKind.f32, output_binding.elem);
}

fn findBinding(
    bindings: []const tsir.schema.BufferBinding,
    name: []const u8,
) ?tsir.schema.BufferBinding {
    for (bindings) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

test "frontend recovers iteration axes from top-level for loops" {
    const allocator = std.testing.allocator;
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\    for (var j: u32 = 0u; j < 8u; j = j + 1u) {
        \\        output[j] = output[j] + 1.0;
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const source_digest: [32]u8 = [_]u8{0} ** 32;
    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        source_digest,
        "frontend-0.0.3",
    );

    try std.testing.expectEqual(@as(usize, 1), semantic.functions.len);
    const func = semantic.functions[0];
    // Two top-level for loops → two recovered axes. Names match the
    // induction variables declared in the init statements.
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    try std.testing.expectEqualStrings("i", func.axes[0].name);
    try std.testing.expectEqualStrings("j", func.axes[1].name);
    // Lower bound and step remain placeholder strings this iteration.
    // Upper bound is now extracted from literal `i < N` conditions:
    // `i < 4u` → "4", `j < 8u` → "8". This is the visible contract
    // change the earlier comment anticipated.
    try std.testing.expectEqualStrings("0", func.axes[0].lower_bound);
    try std.testing.expectEqualStrings("4", func.axes[0].upper_bound);
    try std.testing.expectEqualStrings("1", func.axes[0].step);
    try std.testing.expectEqualStrings("8", func.axes[1].upper_bound);
}

test "frontend narrows bindings to those the function actually references" {
    const allocator = std.testing.allocator;
    // Three bindings declared at module scope, but the entry
    // point only reads `input` and writes `output`; `unused`
    // should NOT appear in the per-function bindings slice
    // after reachability narrowing.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\@group(0) @binding(2) var<storage, read> unused: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.12",
    );
    const func = semantic.functions[0];
    // `input` + `output` are referenced; `unused` is not.
    try std.testing.expectEqual(@as(usize, 2), func.bindings.len);
    try std.testing.expectEqualStrings("input", func.bindings[0].name);
    try std.testing.expectEqualStrings("output", func.bindings[1].name);
}

test "frontend maps mirror polarity > and >= to equivalent upper bound" {
    const allocator = std.testing.allocator;
    // `N > i` and `N >= i` are semantic mirrors of `i < N` /
    // `i <= N`. The literal upper-bound extractor must map both
    // mirror forms to the same exclusive-bound string as their
    // canonical counterparts.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; 4u > i; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\    for (var j: u32 = 0u; 3u >= j; j = j + 1u) {
        \\        output[j] = input[j];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.25",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    // `4u > i` → `i < 4u` → upper_bound "4"
    try std.testing.expectEqualStrings("4", func.axes[0].upper_bound);
    // `3u >= j` → `j <= 3u` → upper_bound "4"
    try std.testing.expectEqualStrings("4", func.axes[1].upper_bound);
}

test "frontend maps less_equal literal bound to exclusive upper via +1" {
    const allocator = std.testing.allocator;
    // `i <= 3u` iterates 0..=3 = four iterations. Under the
    // exclusive-bound convention the frontend uses for
    // `upper_bound`, this must map to "4" — same as `i < 4u`.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i <= 3u; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.11",
    );
    try std.testing.expectEqual(@as(usize, 1), semantic.functions[0].axes.len);
    try std.testing.expectEqualStrings(
        "4",
        semantic.functions[0].axes[0].upper_bound,
    );
}

test "frontend rejects decreasing for-loops instead of emitting a mismatched axis" {
    const allocator = std.testing.allocator;
    // `for (var i = 10u; i > 0u; i = i - 1u)` counts down. TSIR's
    // half-open `[lower, upper)` iteration model doesn't
    // represent this; the walker must skip emitting an axis and
    // emit a `tsir_source_not_affine` rejection at the loop's
    // location. Axes.len stays at 0, and the reduction/collective
    // walkers' axis counters stay in sync with the axes slice.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 10u; i > 0u; i = i - 1u) {
        \\        output[i] = input[i];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.31",
    );
    try std.testing.expectEqual(@as(usize, 0), semantic.functions[0].axes.len);
    try std.testing.expectEqual(@as(usize, 1), semantic.rejections.len);
    try std.testing.expectEqual(
        tsir.RejectionReason.tsir_source_not_affine,
        semantic.rejections[0].reason,
    );
    try std.testing.expectEqualStrings(
        "functions[0].body[0]",
        semantic.rejections[0].node_path,
    );
    try std.testing.expectEqualStrings(
        "decreasing for-loop does not fit half-open iteration model",
        semantic.rejections[0].detail,
    );
}

test "frontend extracts real step from for-loop continuing clause" {
    const allocator = std.testing.allocator;
    // Three loops: literal step 2 via `i = i + 2u` (expanded),
    // literal step 4 via `j += 4u` (compound), and an
    // override-based stride via `k = k + stride` (expanded,
    // symbolic). The step must flow through to the axis field
    // instead of collapsing to "1" for all three.
    const wgsl_source =
        \\override stride: u32 = 3u;
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 8u; i = i + 2u) {
        \\        output[i] = input[i];
        \\    }
        \\    for (var j: u32 = 0u; j < 16u; j += 4u) {
        \\        output[j] = input[j];
        \\    }
        \\    for (var k: u32 = 0u; k < 32u; k = k + stride) {
        \\        output[k] = input[k];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.24",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 3), func.axes.len);
    try std.testing.expectEqualStrings("2", func.axes[0].step);
    try std.testing.expectEqualStrings("4", func.axes[1].step);
    try std.testing.expectEqualStrings("override:stride", func.axes[2].step);
}

test "frontend extracts real lower_bound from the for-loop init expression" {
    const allocator = std.testing.allocator;
    // Non-zero literal init and an override-bounded init must both
    // flow through to `lower_bound` instead of collapsing to "0".
    // A canonical `i = 0u` kernel still produces "0" via the
    // literal path, so the digest-stable default behavior is
    // preserved.
    const wgsl_source =
        \\override start_offset: u32 = 16u;
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 4u; i < 12u; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\    for (var j: u32 = start_offset; j < 32u; j = j + 1u) {
        \\        output[j] = input[j];
        \\    }
        \\    for (var k: u32 = 0u; k < 8u; k = k + 1u) {
        \\        output[k] = input[k];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.23",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 3), func.axes.len);
    try std.testing.expectEqualStrings("4", func.axes[0].lower_bound);
    try std.testing.expectEqualStrings("override:start_offset", func.axes[1].lower_bound);
    try std.testing.expectEqualStrings("0", func.axes[2].lower_bound);
}

test "frontend resolves override and uniform-field mirror-polarity bounds" {
    const allocator = std.testing.allocator;
    // `trip_count > i` should resolve to `"override:trip_count"`
    // same as `i < trip_count`, and `params.count >= j` should
    // resolve to `"uniform:params.count+1"` same as
    // `j <= params.count`.
    const wgsl_source =
        \\struct Uniforms { count: u32 }
        \\override trip_count: u32 = 16u;
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\@group(0) @binding(2) var<uniform> params: Uniforms;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; trip_count > i; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\    for (var j: u32 = 0u; params.count >= j; j = j + 1u) {
        \\        output[j] = input[j];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.26",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    try std.testing.expectEqualStrings(
        "override:trip_count",
        func.axes[0].upper_bound,
    );
    try std.testing.expectEqualStrings(
        "uniform:params.count+1",
        func.axes[1].upper_bound,
    );
}

test "frontend resolves override with @id to override@id:N form" {
    const allocator = std.testing.allocator;
    // `@id(7) override trip_count: u32` must produce
    // `"override@id:7"` so kernel identity survives renames of
    // the override. Overrides without `@id` keep the
    // `"override:<name>"` form — the other override test locks
    // that.
    const wgsl_source =
        \\@id(7) override trip_count: u32 = 16u;
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < trip_count; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.30",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 1), func.axes.len);
    try std.testing.expectEqualStrings(
        "override@id:7",
        func.axes[0].upper_bound,
    );
}

test "frontend resolves override-bounded upper to a symbolic override:name" {
    const allocator = std.testing.allocator;
    // `i < trip_count` where `trip_count` is a WGSL override
    // constant must resolve to `"override:trip_count"` instead of
    // the `"upper_bound"` placeholder. `i <= trip_count` must
    // resolve to `"override:trip_count+1"` under the same
    // exclusive-bound convention the literal path uses.
    const wgsl_source =
        \\override trip_count: u32 = 16u;
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < trip_count; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\    for (var j: u32 = 0u; j <= trip_count; j = j + 1u) {
        \\        output[j] = input[j];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.19",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    try std.testing.expectEqualStrings(
        "override:trip_count",
        func.axes[0].upper_bound,
    );
    try std.testing.expectEqualStrings(
        "override:trip_count+1",
        func.axes[1].upper_bound,
    );
}

test "frontend resolves uniform-struct field bound to uniform:name.field" {
    const allocator = std.testing.allocator;
    // `i < params.count` where `params` is a uniform struct must
    // resolve to `"uniform:params.count"`. `i <= params.count`
    // must resolve to `"uniform:params.count+1"` under the same
    // exclusive-bound convention.
    const wgsl_source =
        \\struct Uniforms { count: u32 }
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\@group(0) @binding(2) var<uniform> params: Uniforms;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < params.count; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\    for (var j: u32 = 0u; j <= params.count; j = j + 1u) {
        \\        output[j] = input[j];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.20",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    try std.testing.expectEqualStrings(
        "uniform:params.count",
        func.axes[0].upper_bound,
    );
    try std.testing.expectEqualStrings(
        "uniform:params.count+1",
        func.axes[1].upper_bound,
    );
}

test "frontend keeps placeholder upper_bound for non-literal loop conditions" {
    const allocator = std.testing.allocator;
    // Condition reads from a storage-buffer element rather than an
    // override / const / uniform-struct field, so none of the
    // symbolic resolvers fire and the axis must keep the
    // placeholder. Locks the honest-fallback property: only
    // overrides, consts, and uniform struct-field reads resolve to
    // a symbolic name; storage reads and arithmetic expressions
    // stay on the placeholder path.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> counts: array<u32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < counts[0]; i = i + 1u) {
        \\        output[i] = f32(i);
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.7",
    );
    try std.testing.expectEqual(@as(usize, 1), semantic.functions[0].axes.len);
    try std.testing.expectEqualStrings(
        "upper_bound",
        semantic.functions[0].axes[0].upper_bound,
    );
}

test "frontend recovers a nested reduction with axis pointing at the inner for loop" {
    const allocator = std.testing.allocator;
    // Canonical GEMV-shape kernel: outer loop over output rows
    // (axis 0 = i), inner loop over the reduction dimension
    // (axis 1 = k). The `acc = acc + ...` pattern inside the
    // inner body must recover as a reduction on axis 1, with
    // `output[i] = acc` (in the OUTER loop body, after the inner
    // for loop) resolving target_binding = 1.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        var acc: f32 = 0.0;
        \\        for (var k: u32 = 0u; k < 8u; k = k + 1u) {
        \\            acc = acc + input[k];
        \\        }
        \\        output[i] = acc;
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.14",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    try std.testing.expectEqualStrings("i", func.axes[0].name);
    try std.testing.expectEqualStrings("k", func.axes[1].name);
    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    const red = func.reductions[0];
    try std.testing.expectEqual(@as(u32, 1), red.axis);
    try std.testing.expectEqual(tsir.schema.ReductionOp.sum, red.op);
    try std.testing.expectEqual(@as(u32, 1), red.target_binding);
    // No rejections because writeback + scalar accumulation resolve.
    try std.testing.expectEqual(@as(usize, 0), semantic.rejections.len);
}

test "frontend keeps dispatch.x placeholder when no early-return guard follows the gid decl" {
    const allocator = std.testing.allocator;
    // `let i = gid.x` with NO `if (i >= bound) return;` guard.
    // The axis should exist but its upper_bound must stay on
    // the `"dispatch.x"` placeholder — the frontend won't make
    // up a bound it can't see.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
        \\    let i: u32 = gid.x;
        \\    output[i] = input[i];
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.28",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 1), func.axes.len);
    try std.testing.expectEqualStrings("dispatch.x", func.axes[0].upper_bound);
}

test "frontend emits dispatch-grid axis from let i = gid.x with axis indices shifted in reductions" {
    const allocator = std.testing.allocator;
    // Canonical GEMV dispatch-grid shape: outer axis comes from
    // gid.x via an early-return guard, inner axis is a for loop.
    // The frontend must emit two axes in pre-order [i (dispatch),
    // k (for-loop)], and attribute the inner reduction to axis 1
    // (k), not 0 (i).
    const wgsl_source =
        \\struct Uniforms { M: u32, K: u32 }
        \\@group(0) @binding(0) var<storage, read> W: array<f32>;
        \\@group(0) @binding(1) var<storage, read> x: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> y: array<f32>;
        \\@group(0) @binding(3) var<uniform> u: Uniforms;
        \\
        \\@compute @workgroup_size(64, 1, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
        \\    let i: u32 = gid.x;
        \\    if (i >= u.M) { return; }
        \\    var acc: f32 = 0.0;
        \\    for (var k: u32 = 0u; k < u.K; k = k + 1u) {
        \\        acc = acc + x[k];
        \\    }
        \\    y[i] = acc;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.27",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    try std.testing.expectEqualStrings("i", func.axes[0].name);
    // The early-return guard `if (i >= u.M) { return; }` now
    // refines the placeholder `"dispatch.x"` into the real
    // upper bound `"uniform:u.M"`.
    try std.testing.expectEqualStrings("uniform:u.M", func.axes[0].upper_bound);
    try std.testing.expectEqualStrings("k", func.axes[1].name);
    try std.testing.expectEqualStrings("uniform:u.K", func.axes[1].upper_bound);

    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    try std.testing.expectEqual(@as(u32, 1), func.reductions[0].axis);
}

test "frontend recovers nested for loops in pre-order" {
    const allocator = std.testing.allocator;
    // Canonical nested-reduction iteration space: outer loop over
    // output rows (i), inner loop over the reduction dimension (k).
    // Axes must appear in pre-order [i, k] — outer first, inner
    // second — so downstream planning knows which is the containing
    // axis and which is the reduction axis.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        for (var k: u32 = 0u; k < 8u; k = k + 1u) {
        \\            output[i] = output[i] + input[k];
        \\        }
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.13",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    try std.testing.expectEqualStrings("i", func.axes[0].name);
    try std.testing.expectEqualStrings("4", func.axes[0].upper_bound);
    try std.testing.expectEqualStrings("k", func.axes[1].name);
    try std.testing.expectEqualStrings("8", func.axes[1].upper_bound);
}

test "frontend ignores non-for-loop iteration forms" {
    const allocator = std.testing.allocator;
    // `while` has no induction variable in the init position, so the
    // axis recovery pass must not emit an axis for it.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var k: u32 = 0u;
        \\    while (k < 4u) {
        \\        output[k] = input[k];
        \\        k = k + 1u;
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.3",
    );
    try std.testing.expectEqual(@as(usize, 0), semantic.functions[0].axes.len);
    // The frontend must not silently drop the `while` loop — it
    // must reject with a typed taxonomy reason (Step 4).
    try std.testing.expectEqual(@as(usize, 1), semantic.rejections.len);
    try std.testing.expectEqual(
        tsir.RejectionReason.tsir_dependence_unanalyzable,
        semantic.rejections[0].reason,
    );
    try std.testing.expectEqualStrings(
        "functions[0].body[1]",
        semantic.rejections[0].node_path,
    );
    try std.testing.expectEqualStrings(
        "while loop",
        semantic.rejections[0].detail,
    );
}

test "frontend infers collective axis from enclosing for-loop scope" {
    const allocator = std.testing.allocator;
    // Two subgroup calls: one at the top level (no enclosing for
    // loop → axis = -1, whole-workgroup sentinel), one inside an
    // outer for loop (axis = 0, the position of that for loop in
    // the axes slice). Locks both the sentinel and the inferred
    // axis so future changes that touch the walker must update
    // both paths explicitly.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    let v: f32 = input[0];
        \\    let pre: f32 = subgroupAdd(v);
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        let inner: f32 = subgroupAdd(input[i]);
        \\        output[i] = inner + pre;
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.18",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 1), func.axes.len);
    try std.testing.expectEqualStrings("i", func.axes[0].name);

    try std.testing.expectEqual(@as(usize, 2), func.collectives.len);
    // Top-level subgroupAdd appears first in statement order.
    try std.testing.expectEqual(tsir.CollectiveKind.subgroup_add, func.collectives[0].kind);
    try std.testing.expectEqual(@as(i32, -1), func.collectives[0].axis);
    // Nested subgroupAdd is scoped to the outer for loop → axis 0.
    try std.testing.expectEqual(tsir.CollectiveKind.subgroup_add, func.collectives[1].kind);
    try std.testing.expectEqual(@as(i32, 0), func.collectives[1].axis);
}

test "frontend rejects non-scalar collective dtype with u32 shape-preserving fallback" {
    const allocator = std.testing.allocator;
    // `subgroupBallot` returns `vec4<u32>`. The current
    // `NumericalContract`-adjacent `dtype` field on
    // `CollectiveSemanticNode` is a single `ScalarKind`, so the
    // vec return type cannot be represented faithfully. The
    // frontend emits a `tsir_collective_not_representable`
    // rejection at the collective node and keeps `dtype = .u32`
    // as the shape-preserving default. `workgroupBarrier` in
    // the same kernel stays silent because it's exempt from
    // the dtype check by construction.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read_write> output: array<u32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    let b: vec4<u32> = subgroupBallot(true);
        \\    workgroupBarrier();
        \\    output[0] = b.x;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.17",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.collectives.len);
    try std.testing.expectEqual(tsir.CollectiveKind.subgroup_ballot, func.collectives[0].kind);
    try std.testing.expectEqual(tsir.ScalarKind.u32, func.collectives[0].dtype);

    try std.testing.expectEqual(@as(usize, 1), semantic.rejections.len);
    try std.testing.expectEqual(
        tsir.RejectionReason.tsir_collective_not_representable,
        semantic.rejections[0].reason,
    );
    try std.testing.expectEqualStrings(
        "functions[0].collectives[0]",
        semantic.rejections[0].node_path,
    );
    try std.testing.expectEqualStrings(
        "collective return type is not representable as a single-scalar dtype",
        semantic.rejections[0].detail,
    );
}

test "frontend canonicalizes subgroup builtins into CollectiveSemanticNode entries" {
    const allocator = std.testing.allocator;
    // Two recognized subgroup/workgroup builtins: `subgroupAdd`
    // reducing an f32 and `workgroupBarrier` (no dtype). The
    // frontend must produce two collectives in source order,
    // each tagged with the right CollectiveKind, the whole-
    // workgroup axis sentinel (-1), and the default
    // `algorithm_exact` exactness with the Step-4 invariants.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    let v: f32 = input[0];
        \\    let reduced: f32 = subgroupAdd(v);
        \\    workgroupBarrier();
        \\    output[0] = reduced;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.16",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.collectives.len);

    const add_node = func.collectives[0];
    try std.testing.expectEqual(tsir.CollectiveKind.subgroup_add, add_node.kind);
    try std.testing.expectEqual(@as(i32, -1), add_node.axis);
    try std.testing.expectEqual(tsir.ScalarKind.f32, add_node.dtype);
    try std.testing.expectEqual(tsir.ExactnessClass.algorithm_exact, add_node.exactness.class);
    try std.testing.expectEqual(
        @as(usize, 2),
        add_node.exactness.algorithm_exact_invariants.len,
    );

    const barrier_node = func.collectives[1];
    try std.testing.expectEqual(tsir.CollectiveKind.workgroup_barrier, barrier_node.kind);
}

test "frontend disambiguates if-then vs if-else in non-for rejection node paths" {
    const allocator = std.testing.allocator;
    // Two `while` loops at the same positional location — one
    // inside `if` then-branch, one inside the else-branch. Both
    // must produce distinct node_paths via `.then` / `.else`
    // segments so downstream consumers can tell them apart.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    if (input[0] > 0.0) {
        \\        var k: u32 = 0u;
        \\        while (k < 4u) {
        \\            output[k] = input[k];
        \\            k = k + 1u;
        \\        }
        \\    } else {
        \\        var m: u32 = 0u;
        \\        while (m < 8u) {
        \\            output[m] = -input[m];
        \\            m = m + 1u;
        \\        }
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.22",
    );
    try std.testing.expectEqual(@as(usize, 2), semantic.rejections.len);
    // Each rejection's node_path must include the distinguishing
    // branch segment. The while in each branch sits at position
    // 1 inside its block (position 0 is the `var k` / `var m`).
    try std.testing.expectEqualStrings(
        "functions[0].body[0].then.body[1]",
        semantic.rejections[0].node_path,
    );
    try std.testing.expectEqualStrings(
        "functions[0].body[0].else.body[1]",
        semantic.rejections[1].node_path,
    );
}

test "frontend rejects a while loop nested inside a for loop with a structured node path" {
    const allocator = std.testing.allocator;
    // The outer `for` is axis-recoverable; the `while` inside it
    // is NOT, so the frontend must descend and emit a
    // rejection with a `.body[...].body[...]` path that
    // navigates into the outer for_loop's body.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        var k: u32 = 0u;
        \\        while (k < 8u) {
        \\            output[i] = input[k];
        \\            k = k + 1u;
        \\        }
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.15",
    );
    // One axis (the outer for), one rejection (the nested while).
    try std.testing.expectEqual(@as(usize, 1), semantic.functions[0].axes.len);
    try std.testing.expectEqual(@as(usize, 1), semantic.rejections.len);
    try std.testing.expectEqual(
        tsir.RejectionReason.tsir_dependence_unanalyzable,
        semantic.rejections[0].reason,
    );
    // The while is at position 1 inside the outer for's body
    // (position 0 is the `var k` local_decl).
    try std.testing.expectEqualStrings(
        "functions[0].body[0].body[1]",
        semantic.rejections[0].node_path,
    );
    try std.testing.expectEqualStrings(
        "while loop",
        semantic.rejections[0].detail,
    );
}

test "frontend emits no rejections when all top-level loops are for loops" {
    const allocator = std.testing.allocator;
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\    for (var j: u32 = 0u; j < 8u; j = j + 1u) {
        \\        output[j] = output[j] + 1.0;
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.6",
    );
    try std.testing.expectEqual(@as(usize, 2), semantic.functions[0].axes.len);
    try std.testing.expectEqual(@as(usize, 0), semantic.rejections.len);
}

test "frontend recovers min and max reductions with commutative-swapped arg order" {
    const allocator = std.testing.allocator;
    // `acc = max(x, acc)` / `acc = min(x, acc)` — accumulator
    // on the second arg instead of the first. Semantically
    // identical since min/max are commutative; must still
    // recover as `.max` / `.min` reductions.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out_max: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> out_min: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var hi: f32 = -1e30;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        hi = max(input[i], hi);
        \\    }
        \\    out_max[0] = hi;
        \\
        \\    var lo: f32 = 1e30;
        \\    for (var j: u32 = 0u; j < 4u; j = j + 1u) {
        \\        lo = min(input[j], lo);
        \\    }
        \\    out_min[0] = lo;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.33",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.reductions.len);
    try std.testing.expectEqual(tsir.schema.ReductionOp.max, func.reductions[0].op);
    try std.testing.expectEqual(tsir.schema.ReductionOp.min, func.reductions[1].op);
    try std.testing.expectEqual(@as(usize, 0), semantic.rejections.len);
}

test "frontend recovers min and max reductions from builtin call self-updates" {
    const allocator = std.testing.allocator;
    // `acc = max(acc, x)` and `acc = min(acc, x)` are the
    // canonical numerical-stability patterns (softmax max-reduce,
    // clamp reductions, etc.). Both must produce the right
    // ReductionOp (.max / .min) instead of being silently dropped.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out_max: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> out_min: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var hi: f32 = -1e30;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        hi = max(hi, input[i]);
        \\    }
        \\    out_max[0] = hi;
        \\
        \\    var lo: f32 = 1e30;
        \\    for (var j: u32 = 0u; j < 4u; j = j + 1u) {
        \\        lo = min(lo, input[j]);
        \\    }
        \\    out_min[0] = lo;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.32",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.reductions.len);
    try std.testing.expectEqual(tsir.schema.ReductionOp.max, func.reductions[0].op);
    try std.testing.expectEqual(tsir.schema.ReductionOp.min, func.reductions[1].op);
    try std.testing.expectEqual(@as(usize, 0), semantic.rejections.len);
}

test "frontend recovers a reduction from an expanded self-update" {
    const allocator = std.testing.allocator;
    // Classic `acc = acc + input[i]` inside a for loop.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var acc: f32 = 0.0;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        acc = acc + input[i];
        \\    }
        \\    output[0] = acc;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.4",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 1), func.axes.len);
    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    const red = func.reductions[0];
    try std.testing.expectEqual(@as(u32, 0), red.axis);
    try std.testing.expectEqual(tsir.schema.ReductionOp.sum, red.op);
    try std.testing.expectEqual(tsir.ScalarKind.f32, red.contract.accumulation);
    try std.testing.expectEqual(tsir.ReductionAssociativity.strict_ordered, red.contract.associativity);
    try std.testing.expectEqual(tsir.NanInfPolicy.propagate, red.contract.nan_inf);
}

test "frontend recovers a reduction from a compound-assign product" {
    const allocator = std.testing.allocator;
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var acc: f32 = 1.0;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        acc *= input[i];
        \\    }
        \\    output[0] = acc;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.4",
    );
    try std.testing.expectEqual(@as(usize, 1), semantic.functions[0].reductions.len);
    try std.testing.expectEqual(
        tsir.schema.ReductionOp.product,
        semantic.functions[0].reductions[0].op,
    );
}

test "frontend emits no reduction when loop body has no accumulator update" {
    const allocator = std.testing.allocator;
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.4",
    );
    try std.testing.expectEqual(@as(usize, 1), semantic.functions[0].axes.len);
    try std.testing.expectEqual(@as(usize, 0), semantic.functions[0].reductions.len);
}

test "frontend preserves frontendVersion in semantic digest pipeline" {
    const allocator = std.testing.allocator;
    const wgsl_source =
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const source_digest: [32]u8 = [_]u8{0} ** 32;
    const semantic_v1 = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        source_digest,
        "v1",
    );
    const semantic_v2 = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        source_digest,
        "v2",
    );
    const realization = tsir.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const d_v1 = try tsir.digest.compute(allocator, semantic_v1, realization, "emitter");
    const d_v2 = try tsir.digest.compute(allocator, semantic_v2, realization, "emitter");
    try std.testing.expect(!std.mem.eql(u8, &d_v1.semantic, &d_v2.semantic));
}

test "frontend rejects non-scalar accumulators and keeps f32 as shape default" {
    const allocator = std.testing.allocator;
    // `acc: vec2<f32>` is a non-scalar accumulator. The current
    // NumericalContract cannot represent a vector-typed
    // accumulation faithfully, so the frontend must emit a typed
    // rejection pointing at the reduction node and keep
    // `contract.accumulation = .f32` as the shape-preserving
    // default.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<vec2<f32>>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<vec2<f32>>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var acc: vec2<f32> = vec2<f32>(0.0, 0.0);
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        acc = acc + input[i];
        \\    }
        \\    output[0] = acc;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.10",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    try std.testing.expectEqual(
        tsir.ScalarKind.f32,
        func.reductions[0].contract.accumulation,
    );
    try std.testing.expectEqual(@as(usize, 1), semantic.rejections.len);
    try std.testing.expectEqual(
        tsir.RejectionReason.tsir_dependence_unanalyzable,
        semantic.rejections[0].reason,
    );
    try std.testing.expectEqualStrings(
        "functions[0].reductions[0]",
        semantic.rejections[0].node_path,
    );
    try std.testing.expectEqualStrings(
        "reduction accumulator type is not representable as a single-scalar accumulation",
        semantic.rejections[0].detail,
    );
}

test "frontend resolves accumulation dtype from the accumulator's declared type" {
    const allocator = std.testing.allocator;
    // `acc: i32` should propagate into `contract.accumulation = .i32`
    // instead of the previous hardcoded `.f32` default.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<i32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<i32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var acc: i32 = 0;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        acc = acc + input[i];
        \\    }
        \\    output[0] = acc;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.9",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    try std.testing.expectEqual(
        tsir.ScalarKind.i32,
        func.reductions[0].contract.accumulation,
    );
}

test "frontend resolves target_binding from a post-loop writeback" {
    const allocator = std.testing.allocator;
    // `acc` is written into `output` (binding index 1) after the
    // reduction loop; `scratch` (binding index 0) is read-only and
    // unrelated. The resolver must pick binding 1, not the default 0.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> scratch: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var acc: f32 = 0.0;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        acc = acc + scratch[i];
        \\    }
        \\    output[0] = acc;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.8",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.bindings.len);
    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    try std.testing.expectEqual(@as(u32, 1), func.reductions[0].target_binding);
}

test "frontend accepts rhs-binary writebacks that contain an accumulator load" {
    const allocator = std.testing.allocator;
    // Canonical post-reduction epilogue: `output[0] = acc * scale`.
    // The writeback rhs is a binary expression, not a pure
    // `load(acc)`. The resolver must walk the rhs tree, find the
    // accumulator load, and attribute `target_binding` to the
    // final store — this is what RMSNorm / fused GEMV with bias
    // actually look like in source.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var acc: f32 = 0.0;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        acc = acc + input[i];
        \\    }
        \\    let scale: f32 = 0.5;
        \\    output[0] = acc * scale;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.29",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    try std.testing.expectEqual(@as(u32, 1), func.reductions[0].target_binding);
    try std.testing.expectEqual(@as(usize, 0), semantic.rejections.len);
}

test "frontend resolves target_binding through a let-alias writeback hop" {
    const allocator = std.testing.allocator;
    // Reduction writes through a `let tmp = acc;` alias before the
    // store. The resolver must follow the alias to the binding and
    // NOT emit an unresolved-writeback rejection.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var acc: f32 = 0.0;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        acc = acc + input[i];
        \\    }
        \\    let tmp: f32 = acc;
        \\    output[0] = tmp;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.21",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    try std.testing.expectEqual(@as(u32, 1), func.reductions[0].target_binding);
    // No rejection — alias chain was followed successfully.
    try std.testing.expectEqual(@as(usize, 0), semantic.rejections.len);
}

test "frontend resolves target_binding through scalar-tail aliases" {
    const allocator = std.testing.allocator;
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var acc: f32 = 0.0;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        acc = acc + input[i];
        \\    }
        \\    let mean: f32 = acc / 4.0;
        \\    let shifted: f32 = mean + 1.0;
        \\    output[0] = shifted * 2.0;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.38",
    );

    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    try std.testing.expectEqual(@as(u32, 1), func.reductions[0].target_binding);
    try std.testing.expectEqual(@as(usize, 0), semantic.rejections.len);
}

test "frontend rejects and falls back to target_binding 0 when no writeback is visible" {
    const allocator = std.testing.allocator;
    // No post-loop assign from `acc` to any binding → resolver returns
    // null; the frontend emits a typed tsir_dependence_unanalyzable
    // rejection pointing at the reduction node and keeps
    // `target_binding = 0` as the honest fallback.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var acc: f32 = 0.0;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        acc = acc + input[i];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.8",
    );
    try std.testing.expectEqual(@as(usize, 1), semantic.functions[0].reductions.len);
    try std.testing.expectEqual(
        @as(u32, 0),
        semantic.functions[0].reductions[0].target_binding,
    );
    try std.testing.expectEqual(@as(usize, 1), semantic.rejections.len);
    try std.testing.expectEqual(
        tsir.RejectionReason.tsir_dependence_unanalyzable,
        semantic.rejections[0].reason,
    );
    try std.testing.expectEqualStrings(
        "functions[0].reductions[0]",
        semantic.rejections[0].node_path,
    );
    try std.testing.expectEqualStrings(
        "reduction accumulator has no post-loop writeback to a bound global",
        semantic.rejections[0].detail,
    );
}

test "frontend infers reduction family hint from a detected reduction region" {
    const allocator = std.testing.allocator;
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    var acc: f32 = 0.0;
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        acc = acc + input[i];
        \\    }
        \\    output[0] = acc;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.5",
    );
    try std.testing.expectEqual(@as(usize, 1), semantic.functions[0].reductions.len);
    try std.testing.expectEqual(
        tsir.KernelFamilyHint.reduction,
        semantic.functions[0].family_hint,
    );
}

test "frontend lowers the Phase A fused_gemv bootstrap kernel end-to-end" {
    const allocator = std.testing.allocator;
    const wgsl_source = @embedFile("../tsir/bootstrap/fused_gemv.wgsl");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.36",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    try std.testing.expectEqualStrings("i", func.axes[0].name);
    try std.testing.expectEqualStrings("uniform:u.M", func.axes[0].upper_bound);
    try std.testing.expectEqualStrings("k", func.axes[1].name);
    try std.testing.expectEqualStrings("uniform:u.K", func.axes[1].upper_bound);
    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    try std.testing.expectEqual(@as(u32, 1), func.reductions[0].axis);
    try std.testing.expectEqual(tsir.schema.ReductionOp.sum, func.reductions[0].op);
    try std.testing.expectEqual(tsir.KernelFamilyHint.fused_gemv, func.family_hint);
    try std.testing.expectEqual(@as(usize, 0), semantic.rejections.len);
}

test "frontend lowers the Phase A rms_norm bootstrap kernel end-to-end" {
    const allocator = std.testing.allocator;
    const wgsl_source = @embedFile("../tsir/bootstrap/rms_norm.wgsl");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.36",
    );
    const func = semantic.functions[0];
    try std.testing.expectEqual(@as(usize, 4), func.bindings.len);
    try std.testing.expectEqualStrings("input", func.bindings[0].name);
    try std.testing.expectEqualStrings("weight", func.bindings[1].name);
    try std.testing.expectEqualStrings("output", func.bindings[2].name);
    try std.testing.expectEqualStrings("u", func.bindings[3].name);
    try std.testing.expect(!func.bindings[3].read_write);
    // dispatch-axis d + for-axis i, both bounded by u.hidden_size.
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    try std.testing.expectEqualStrings("d", func.axes[0].name);
    try std.testing.expectEqualStrings("uniform:u.hidden_size", func.axes[0].upper_bound);
    try std.testing.expectEqualStrings("i", func.axes[1].name);
    try std.testing.expectEqualStrings("uniform:u.hidden_size", func.axes[1].upper_bound);
    // Reduction on axis 1 (sum of squares).
    try std.testing.expectEqual(@as(usize, 1), func.reductions.len);
    try std.testing.expectEqual(@as(u32, 1), func.reductions[0].axis);
    try std.testing.expectEqual(tsir.schema.ReductionOp.sum, func.reductions[0].op);
    // RMSNorm has no single matrix-style access depending on both
    // axes (`input[i]` and `input[d]` are separate accesses), so the
    // coarse hint remains `.reduction`. The semantic body carries the
    // narrower RMSNorm contract consumed by oracle/emitter work.
    try std.testing.expectEqual(tsir.KernelFamilyHint.reduction, func.family_hint);
    try std.testing.expectEqual(tsir.schema.SemanticBodyOp.rms_norm, func.body.op);
    try std.testing.expect(func.body.rms_norm != null);
    const rms_norm = func.body.rms_norm.?;
    try std.testing.expectEqual(
        tsir.schema.RmsNormFormula.sum_squares_mean_epsilon_rsqrt_scale,
        rms_norm.formula,
    );
    try std.testing.expectEqual(
        tsir.schema.RmsNormReductionTarget.intermediate_scalar,
        rms_norm.reduction_target,
    );
    try std.testing.expectEqual(@as(u32, 0), rms_norm.hidden_extent_axis);
    try std.testing.expectEqual(
        tsir.schema.RmsNormEpsilonSource.uniform_field,
        rms_norm.epsilon.source,
    );
    try std.testing.expectEqualStrings("uniform:u.eps", rms_norm.epsilon.path);
    try std.testing.expectEqual(@as(?u32, 3), rms_norm.epsilon.binding_index);
    try std.testing.expectEqual(@as(?u32, 4), rms_norm.epsilon.byte_offset);
    try std.testing.expectEqual(@as(?f64, null), rms_norm.epsilon.literal_f32);
}

test "frontend lowers the Phase A gather bootstrap kernel end-to-end" {
    const allocator = std.testing.allocator;
    const wgsl_source = @embedFile("../tsir/bootstrap/gather.wgsl");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.36",
    );
    const func = semantic.functions[0];
    // Two dispatch axes (t = gid.y, h = gid.x). Multi-axis
    // dispatch-guard scan now walks past the interleaved `let h`
    // and the unrelated `if (t >= ...)` to find each axis's
    // real guard, so both bounds resolve to real uniform refs.
    try std.testing.expectEqual(@as(usize, 2), func.axes.len);
    try std.testing.expectEqualStrings("t", func.axes[0].name);
    try std.testing.expectEqualStrings("uniform:u.num_tokens", func.axes[0].upper_bound);
    try std.testing.expectEqualStrings("h", func.axes[1].name);
    try std.testing.expectEqualStrings("uniform:u.hidden", func.axes[1].upper_bound);
    // No reductions — pure elementwise with indirect lookup.
    try std.testing.expectEqual(@as(usize, 0), func.reductions.len);
    try std.testing.expectEqual(tsir.KernelFamilyHint.gather, func.family_hint);
    try std.testing.expectEqual(tsir.schema.SemanticBodyOp.gather, func.body.op);
}

test "frontend refines reduction hint to fused_gemv for canonical 2-axis shape" {
    const allocator = std.testing.allocator;
    // Canonical GEMV: dispatch-grid outer `i`, for-loop inner
    // `k`, reduction on the inner axis, and one matrix-style
    // access (`W[i * u.K + k]`) depending on both axes. The
    // family hint must promote to `.fused_gemv` instead of the
    // coarse `.reduction`.
    const wgsl_source =
        \\struct Uniforms { M: u32, K: u32 }
        \\@group(0) @binding(0) var<storage, read> W: array<f32>;
        \\@group(0) @binding(1) var<storage, read> x: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> y: array<f32>;
        \\@group(0) @binding(3) var<uniform> u: Uniforms;
        \\
        \\@compute @workgroup_size(64, 1, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
        \\    let i: u32 = gid.x;
        \\    if (i >= u.M) { return; }
        \\    var acc: f32 = 0.0;
        \\    for (var k: u32 = 0u; k < u.K; k = k + 1u) {
        \\        acc = acc + W[i * u.K + k] * x[k];
        \\    }
        \\    y[i] = acc;
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.35",
    );
    try std.testing.expectEqual(
        tsir.KernelFamilyHint.fused_gemv,
        semantic.functions[0].family_hint,
    );
}

test "frontend keeps reduction hint for fixed-literal outer bound" {
    const allocator = std.testing.allocator;
    // Same two-axis + axis-1-reduction shape as the fused_gemv
    // test, but the outer bound is a fixed literal `4u` rather
    // than a dispatch / uniform / override. The family hint
    // must stay on the coarse `.reduction` — the planner
    // benefits from seeing `.fused_gemv` only when the
    // iteration extent is driven by pipeline inputs.
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        var acc: f32 = 0.0;
        \\        for (var k: u32 = 0u; k < 8u; k = k + 1u) {
        \\            acc = acc + input[k];
        \\        }
        \\        output[i] = acc;
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.35",
    );
    try std.testing.expectEqual(
        tsir.KernelFamilyHint.reduction,
        semantic.functions[0].family_hint,
    );
}

test "frontend infers gather family hint from indirect buffer access" {
    const allocator = std.testing.allocator;
    // `output[i] = input[indices[i]]` — the index into `input`
    // is itself loaded from `indices`, the canonical gather
    // shape. Must produce `family_hint == .gather` despite
    // the kernel having axes and no reductions (which would
    // otherwise collapse it to .elementwise).
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read> indices: array<u32>;
        \\@group(0) @binding(2) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        output[i] = input[indices[i]];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.34",
    );
    try std.testing.expectEqual(
        tsir.KernelFamilyHint.gather,
        semantic.functions[0].family_hint,
    );
}

test "frontend infers elementwise family hint for a kernel with loops but no reductions" {
    const allocator = std.testing.allocator;
    const wgsl_source =
        \\@group(0) @binding(0) var<storage, read> input: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main() {
        \\    for (var i: u32 = 0u; i < 4u; i = i + 1u) {
        \\        output[i] = input[i];
        \\    }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var tree = try parser.parseSource(arena_allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(arena_allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(arena_allocator, &tree, &semantic_module);
    defer module.deinit();

    const semantic = try tsir.frontend.lowerIrToTsir(
        arena_allocator,
        &module,
        [_]u8{0} ** 32,
        "frontend-0.0.5",
    );
    try std.testing.expectEqual(@as(usize, 1), semantic.functions[0].axes.len);
    try std.testing.expectEqual(@as(usize, 0), semantic.functions[0].reductions.len);
    try std.testing.expectEqual(
        tsir.KernelFamilyHint.elementwise,
        semantic.functions[0].family_hint,
    );
}
