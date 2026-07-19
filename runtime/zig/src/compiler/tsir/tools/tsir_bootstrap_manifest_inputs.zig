// Emit schema-tool inputs for TSIR bootstrap manifest lowering fixtures.

const std = @import("std");
const doe = @import("doe");
const tsir = doe.compiler.tsir();
const targets = doe.compiler.targets();
const parser = doe.compiler.wgsl_frontend.parser();
const sema = doe.compiler.wgsl_frontend.sema();
const ir_builder = doe.compiler.wgsl_ir.builder();

const FRONTEND_VERSION = "frontend-bootstrap-pipeline-v1";
const COMPILER_VERSION = "doe-tsir-bootstrap-2026-04-24";
const WSE3_STREAM_CHUNK_BYTES: u64 = 4096;
const MAX_BOOTSTRAP_WGSL_BYTES: usize = 1 << 20;

const KernelSpec = struct {
    name: []const u8,
    wgsl_path: []const u8,
    exactness_class: []const u8,
    algorithm_exact_invariants: []const []const u8 = &.{},
    tolerance_metric: []const u8 = "",
    tolerance_epsilon: []const u8 = "0",
};

const TargetSpec = struct {
    backend: []const u8,
    descriptor: targets.TargetDescriptor,
    emitter_digest: [32]u8,
    fabric_streaming: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const kernels = [_]KernelSpec{
        .{
            .name = "fused_gemv",
            .wgsl_path = "runtime/zig/tests/tsir/bootstrap/fused_gemv.wgsl",
            .exactness_class = "algorithm_exact",
            .algorithm_exact_invariants = &.{ "reduction_order", "accum_dtype" },
        },
        .{
            .name = "rms_norm",
            .wgsl_path = "runtime/zig/tests/tsir/bootstrap/rms_norm.wgsl",
            .exactness_class = "tolerance_bounded",
            .tolerance_metric = "max_abs",
            .tolerance_epsilon = "0.000001",
        },
        .{
            .name = "gather",
            .wgsl_path = "runtime/zig/tests/tsir/bootstrap/gather.wgsl",
            .exactness_class = "bit_exact_solo",
        },
    };
    const target_specs = [_]TargetSpec{
        .{
            .backend = "webgpu-generic",
            .descriptor = targets.webgpu_generic.descriptor,
            .emitter_digest = tsir.emit_webgpu.emitterCodeDigest(),
        },
        .{
            .backend = "wse3",
            .descriptor = targets.wse3.descriptor,
            .emitter_digest = tsir.emit_csl.emitterCodeDigest(),
            .fabric_streaming = true,
        },
        .{
            .backend = "msl",
            .descriptor = targets.msl.descriptor,
            .emitter_digest = tsir.emit_msl.emitterCodeDigest(),
        },
        .{
            .backend = "spir-v",
            .descriptor = targets.spir_v.descriptor,
            .emitter_digest = tsir.emit_spir_v.emitterCodeDigest(),
        },
    };

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.writeAll("[\n");
    var emitted: usize = 0;
    for (kernels) |kernel| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        const wgsl_source = try std.fs.cwd().readFileAlloc(
            arena_allocator,
            kernel.wgsl_path,
            MAX_BOOTSTRAP_WGSL_BYTES,
        );
        const semantic = try lowerBootstrapWgsl(
            arena_allocator,
            wgsl_source,
        );
        if (semantic.rejections.len != 0) return error.SemanticRejected;
        for (target_specs) |target_spec| {
            const realization = try planBootstrapTarget(
                arena_allocator,
                semantic,
                target_spec,
            );
            if (realization.rejections.len != 0) return error.RealizationRejected;
            const digests = try tsir.digest.computeWithEmitterDigest(
                arena_allocator,
                semantic,
                realization,
                target_spec.emitter_digest,
            );

            if (emitted != 0) try stdout.writeAll(",\n");
            try writeEntryInput(stdout, kernel, target_spec, digests);
            emitted += 1;
        }
    }
    try stdout.writeAll("\n]\n");
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

fn planBootstrapTarget(
    allocator: std.mem.Allocator,
    semantic: tsir.Semantic,
    target_spec: TargetSpec,
) !tsir.Realization {
    if (target_spec.fabric_streaming) {
        return tsir.planner.planRealization(
            allocator,
            semantic,
            target_spec.descriptor,
            .{
                .emitter_digest = target_spec.emitter_digest,
                .loader = .{
                    .fabric_streaming = true,
                    .max_stream_chunk_bytes = WSE3_STREAM_CHUNK_BYTES,
                },
            },
        );
    }
    return tsir.planner.planRealization(
        allocator,
        semantic,
        target_spec.descriptor,
        .{ .emitter_digest = target_spec.emitter_digest },
    );
}

fn writeEntryInput(
    writer: anytype,
    kernel: KernelSpec,
    target_spec: TargetSpec,
    digests: tsir.Digests,
) !void {
    try writer.writeAll("  {\n");
    try writer.print("    \"backend\": \"{s}\",\n", .{target_spec.backend});
    try writer.print("    \"compilerVersion\": \"{s}\",\n", .{COMPILER_VERSION});
    try writer.writeAll("    \"emitterDigest\": \"");
    try writeHex(writer, digests.emitter);
    try writer.writeAll("\",\n");
    try writer.print("    \"exactnessClass\": \"{s}\",\n", .{kernel.exactness_class});
    try writer.writeAll("    \"algorithmExactInvariants\": ");
    try writeStringArray(writer, kernel.algorithm_exact_invariants);
    try writer.writeAll(",\n");
    try writer.print("    \"toleranceMetric\": \"{s}\",\n", .{kernel.tolerance_metric});
    try writer.print("    \"toleranceEpsilon\": {s},\n", .{kernel.tolerance_epsilon});
    try writer.print("    \"frontendVersion\": \"{s}\",\n", .{FRONTEND_VERSION});
    try writer.print("    \"kernelRef\": \"doe.tsir.bootstrap.{s}\",\n", .{kernel.name});
    try writer.writeAll("    \"rejectionReasons\": [],\n");
    try writer.writeAll("    \"targetDescriptorCorrectnessHash\": \"");
    try writeHex(writer, targets.descriptorHash(target_spec.descriptor));
    try writer.writeAll("\",\n");
    try writer.writeAll("    \"tsirRealizationDigest\": \"");
    try writeHex(writer, digests.realization);
    try writer.writeAll("\",\n");
    try writer.writeAll("    \"tsirSemanticDigest\": \"");
    try writeHex(writer, digests.semantic);
    try writer.writeAll("\"\n");
    try writer.writeAll("  }");
}

fn writeStringArray(writer: anytype, values: []const []const u8) !void {
    try writer.writeAll("[");
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("\"{s}\"", .{value});
    }
    try writer.writeAll("]");
}

fn writeHex(writer: anytype, bytes: [32]u8) !void {
    const digits = "0123456789abcdef";
    for (bytes) |byte| {
        const high: usize = @intCast(byte >> 4);
        const low: usize = @intCast(byte & 0x0f);
        const pair = [_]u8{ digits[high], digits[low] };
        try writer.writeAll(&pair);
    }
}
