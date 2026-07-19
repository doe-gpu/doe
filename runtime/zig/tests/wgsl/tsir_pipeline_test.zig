// TSIR bootstrap pipeline tests.
//
// These tests exercise the Phase A compiler-only path: pinned bootstrap
// WGSL -> Doe IR -> TSIR semantic -> target realization -> split digests.
// They intentionally stop before backend execution or parity receipts; the
// per-kernel-family parity step owns simulator/hardware proof.

const std = @import("std");
const tsir = @import("../../src/compiler/tsir/mod.zig");
const targets = @import("../../src/compiler/targets/mod.zig");
const parser = @import("../../src/compiler/wgsl/frontend/parser.zig");
const sema = @import("../../src/compiler/wgsl/frontend/sema.zig");
const ir_builder = @import("../../src/compiler/wgsl/ir/ir_builder.zig");

const FRONTEND_VERSION = "frontend-bootstrap-pipeline-v1";

test "Phase A bootstrap kernels lower to stable WebGPU and WSE-3 TSIR digests" {
    try expectBootstrapKernel(
        "fused_gemv",
        @embedFile("../tsir/bootstrap/fused_gemv.wgsl"),
        .fused_gemv,
    );
    try expectBootstrapKernel(
        "rms_norm",
        @embedFile("../tsir/bootstrap/rms_norm.wgsl"),
        .rms_norm,
    );
    try expectBootstrapKernel(
        "gather",
        @embedFile("../tsir/bootstrap/gather.wgsl"),
        .gather,
    );
}

fn expectBootstrapKernel(
    name: []const u8,
    wgsl_source: []const u8,
    expected_body: tsir.schema.SemanticBodyOp,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const semantic = try lowerBootstrapWgsl(allocator, wgsl_source);
    errdefer for (semantic.rejections) |rejection| {
        std.debug.print(
            "TSIR bootstrap semantic rejection kernel={s} reason={s} path={s} detail={s}\n",
            .{
                name,
                @tagName(rejection.reason),
                rejection.node_path,
                rejection.detail,
            },
        );
    };
    try std.testing.expectEqual(@as(usize, 0), semantic.rejections.len);
    try std.testing.expectEqual(@as(usize, 1), semantic.functions.len);
    try std.testing.expectEqual(expected_body, semantic.functions[0].body.op);

    const webgpu_a = try planWebGpu(allocator, semantic);
    const webgpu_b = try planWebGpu(allocator, semantic);
    try assertCleanRealization(name, "webgpu-generic", webgpu_a);
    try assertCleanRealization(name, "webgpu-generic-repeat", webgpu_b);
    try assertHasResidency(webgpu_a, .host_copied);

    const wse3_a = try planWse3(allocator, semantic);
    const wse3_b = try planWse3(allocator, semantic);
    try assertCleanRealization(name, "wse3", wse3_a);
    try assertCleanRealization(name, "wse3-repeat", wse3_b);
    try assertHasResidency(wse3_a, .fabric_streamed);

    const webgpu_emitter_digest = tsir.emit_webgpu.emitterCodeDigest();
    const csl_emitter_digest = tsir.emit_csl.emitterCodeDigest();
    try std.testing.expectEqualSlices(u8, &webgpu_emitter_digest, &webgpu_a.emitter_digest);
    try std.testing.expectEqualSlices(u8, &csl_emitter_digest, &wse3_a.emitter_digest);

    const webgpu_digest_a = try tsir.digest.computeWithEmitterDigest(
        allocator,
        semantic,
        webgpu_a,
        webgpu_emitter_digest,
    );
    const webgpu_digest_b = try tsir.digest.computeWithEmitterDigest(
        allocator,
        semantic,
        webgpu_b,
        webgpu_emitter_digest,
    );
    const wse3_digest_a = try tsir.digest.computeWithEmitterDigest(
        allocator,
        semantic,
        wse3_a,
        csl_emitter_digest,
    );
    const wse3_digest_b = try tsir.digest.computeWithEmitterDigest(
        allocator,
        semantic,
        wse3_b,
        csl_emitter_digest,
    );

    try std.testing.expectEqualSlices(u8, &webgpu_digest_a.semantic, &webgpu_digest_b.semantic);
    try std.testing.expectEqualSlices(u8, &webgpu_digest_a.realization, &webgpu_digest_b.realization);
    try std.testing.expectEqualSlices(u8, &wse3_digest_a.semantic, &wse3_digest_b.semantic);
    try std.testing.expectEqualSlices(u8, &wse3_digest_a.realization, &wse3_digest_b.realization);
    try std.testing.expectEqualSlices(u8, &webgpu_digest_a.semantic, &wse3_digest_a.semantic);
    try std.testing.expect(!std.mem.eql(u8, &webgpu_digest_a.realization, &wse3_digest_a.realization));
    try std.testing.expectEqualSlices(u8, &webgpu_emitter_digest, &webgpu_digest_a.emitter);
    try std.testing.expectEqualSlices(u8, &csl_emitter_digest, &wse3_digest_a.emitter);
    try std.testing.expect(!allZero(&webgpu_digest_a.semantic));
    try std.testing.expect(!allZero(&webgpu_digest_a.realization));
    try std.testing.expect(!allZero(&wse3_digest_a.realization));
}

fn lowerBootstrapWgsl(
    allocator: std.mem.Allocator,
    wgsl_source: []const u8,
) !tsir.Semantic {
    var tree = try parser.parseSource(allocator, wgsl_source);
    defer tree.deinit();
    var semantic_module = try sema.analyze(allocator, &tree);
    defer semantic_module.deinit();
    var module = try ir_builder.build(allocator, &tree, &semantic_module);
    defer module.deinit();

    var source_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wgsl_source, &source_digest, .{});
    return tsir.frontend.lowerIrToTsir(
        allocator,
        &module,
        source_digest,
        FRONTEND_VERSION,
    );
}

fn planWebGpu(
    allocator: std.mem.Allocator,
    semantic: tsir.Semantic,
) !tsir.Realization {
    return tsir.planner.planRealization(
        allocator,
        semantic,
        targets.webgpu_generic.descriptor,
        .{ .emitter_digest = tsir.emit_webgpu.emitterCodeDigest() },
    );
}

fn planWse3(
    allocator: std.mem.Allocator,
    semantic: tsir.Semantic,
) !tsir.Realization {
    return tsir.planner.planRealization(
        allocator,
        semantic,
        targets.wse3.descriptor,
        .{
            .emitter_digest = tsir.emit_csl.emitterCodeDigest(),
            .loader = .{
                .fabric_streaming = true,
                .max_stream_chunk_bytes = 4096,
            },
        },
    );
}

fn assertCleanRealization(
    kernel_name: []const u8,
    target_name: []const u8,
    realization: tsir.Realization,
) !void {
    errdefer std.debug.print(
        "TSIR bootstrap lowering rejected kernel={s} target={s}\n",
        .{ kernel_name, target_name },
    );
    try std.testing.expectEqual(@as(usize, 0), realization.rejections.len);
    try std.testing.expectEqual(@as(usize, 1), realization.functions.len);
}

fn assertHasResidency(
    realization: tsir.Realization,
    expected: tsir.schema.ResidencyClass,
) !void {
    for (realization.functions[0].residency) |decision| {
        if (decision.class == expected) return;
    }
    return error.ExpectedResidencyClassMissing;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}
