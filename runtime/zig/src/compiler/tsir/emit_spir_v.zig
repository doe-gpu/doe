// Mechanical TSIR-to-SPIR-V skeleton emitter.

const std = @import("std");
const targets = @import("../targets/mod.zig");
const schema = @import("schema.zig");
const common = @import("emit_text_skeleton.zig");

const EMITTER_SOURCE = @embedFile("emit_spir_v.zig");
const COMMON_SOURCE = @embedFile("emit_text_skeleton.zig");
const BODY_SOURCE = @embedFile("emit_kernel_body.zig");
const SPEC = common.BackendTextSpec{
    .version_key = "doe.tsir.spir_v_skeleton.version",
    .body_comment = "; tsir mechanical skeleton: SPIR-V module body is emitted by later lowering.",
    .backend = .spir_v,
};

pub const EmitError = common.EmitError;

pub fn emitterCodeDigest() [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(EMITTER_SOURCE);
    h.update(COMMON_SOURCE);
    h.update(BODY_SOURCE);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn emit(
    allocator: std.mem.Allocator,
    realization: schema.Realization,
    function_index: usize,
    descriptor: targets.TargetDescriptor,
) EmitError![]const u8 {
    return common.emit(allocator, realization, function_index, descriptor, SPEC);
}

pub fn emitFunction(
    allocator: std.mem.Allocator,
    function: schema.RealizationFunction,
    descriptor: targets.TargetDescriptor,
) EmitError![]const u8 {
    return common.emitFunction(allocator, function, descriptor, SPEC);
}

pub fn emitSemantic(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    realization: schema.Realization,
    function_index: usize,
    descriptor: targets.TargetDescriptor,
) EmitError![]const u8 {
    return common.emitSemantic(allocator, semantic, realization, function_index, descriptor, SPEC);
}

pub fn emitSemanticFunction(
    allocator: std.mem.Allocator,
    semantic_function: schema.SemanticFunction,
    function: schema.RealizationFunction,
    descriptor: targets.TargetDescriptor,
) EmitError![]const u8 {
    return common.emitSemanticFunction(
        allocator,
        semantic_function,
        function,
        descriptor,
        SPEC,
    );
}
