// TSIR-to-WebGPU skeleton emitter tests.

const std = @import("std");
const tsir = @import("../../src/compiler/tsir/mod.zig");
const targets = @import("../../src/compiler/targets/mod.zig");

test "tsir webgpu emitter exposes source-backed code digest" {
    const digest = tsir.emit_webgpu.emitterCodeDigest();
    var expected: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(@embedFile("../../src/compiler/tsir/emit_webgpu.zig"));
    h.update(@embedFile("../../src/compiler/tsir/emit_kernel_body.zig"));
    h.final(&expected);
    try std.testing.expectEqualSlices(u8, &expected, &digest);
    try std.testing.expect(!allZero(&digest));
}

test "tsir webgpu emitter serializes realization contract" {
    const allocator = std.testing.allocator;

    const tiles = [_]u32{ 32, 1 };
    const residency = [_]tsir.schema.ResidencyDecision{
        .{
            .binding_index = 0,
            .class = .host_copied,
            .chunk_bytes = 2048,
        },
    };
    const function = tsir.schema.RealizationFunction{
        .semantic_index = 3,
        .tiles = .{ .per_axis = &tiles },
        .pe_grid = .{ .width = 1, .height = 1 },
        .residency = &residency,
        .collectives = &.{},
        .reductions = &.{},
        .emitter_params_json = "{\"planner\":\"webgpu\"}",
        .target_descriptor_hash = targets.descriptorHash(targets.webgpu_generic.descriptor),
    };

    const wgsl = try tsir.emit_webgpu.emitFunction(
        allocator,
        function,
        targets.webgpu_generic.descriptor,
    );
    defer allocator.free(wgsl);

    try expectContains(wgsl, "// doe.tsir.webgpu_skeleton.version = 1\n");
    try expectContains(wgsl, "// target.name = webgpu-generic\n");
    try expectContains(wgsl, "// semantic_index = 3\n");
    try expectContains(wgsl, "// residency[0].class = host_copied\n");
    try expectContains(wgsl, "// residency[0].chunk_bytes = 2048\n");
    try expectContains(wgsl, "// tiles.per_axis[0] = 32\n");
    try expectContains(wgsl, "@compute @workgroup_size(1, 1, 1)\n");
}

test "tsir webgpu emitter rejects realization rejections" {
    const allocator = std.testing.allocator;
    const function = emptyFunction(targets.webgpu_generic.descriptor);
    const rejections = [_]tsir.RejectionEntry{
        .{
            .reason = .tsir_target_unfit,
            .node_path = "functions[0]",
            .detail = "target rejected bootstrap fixture",
        },
    };
    const realization = tsir.Realization{
        .functions = &[_]tsir.schema.RealizationFunction{function},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &rejections,
    };

    const outcome = tsir.emit_webgpu.emit(
        allocator,
        realization,
        0,
        targets.webgpu_generic.descriptor,
    );
    try std.testing.expectError(tsir.emit_webgpu.EmitError.RejectedRealization, outcome);
}

test "tsir webgpu emitter rejects target descriptor hash mismatch" {
    const allocator = std.testing.allocator;
    const function = emptyFunction(targets.wse3.descriptor);

    const outcome = tsir.emit_webgpu.emitFunction(
        allocator,
        function,
        targets.webgpu_generic.descriptor,
    );
    try std.testing.expectError(tsir.emit_webgpu.EmitError.TargetDescriptorHashMismatch, outcome);
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
