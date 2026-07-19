// Mechanical TSIR-to-WebGPU emitter.
//
// This emitter binds WebGPU-generic lowerings to a deterministic source-backed
// emitter identity. Realization-only calls keep emitting the contract skeleton;
// semantic-aware calls emit executable WGSL for supported TSIR body families.

const std = @import("std");
const targets = @import("../targets/mod.zig");
const schema = @import("schema.zig");
const kernel_body = @import("emit_kernel_body.zig");

const INITIAL_OUTPUT_CAPACITY: usize = 2048;
const HEX_DIGITS = "0123456789abcdef";
const NIBBLE_SHIFT: u3 = 4;
const NIBBLE_MASK: u8 = 0x0f;
const EMITTER_SOURCE = @embedFile("emit_webgpu.zig");
const BODY_SOURCE = @embedFile("emit_kernel_body.zig");

pub const EmitError = std.mem.Allocator.Error || kernel_body.EmitError || error{
    FunctionIndexOutOfRange,
    RejectedRealization,
    TargetDescriptorHashMismatch,
};

/// SHA-256 over this emitter's source text.
pub fn emitterCodeDigest() [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(EMITTER_SOURCE);
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
    if (realization.rejections.len != 0) return error.RejectedRealization;
    if (function_index >= realization.functions.len) return error.FunctionIndexOutOfRange;
    return emitFunction(allocator, realization.functions[function_index], descriptor);
}

pub fn emitSemantic(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    realization: schema.Realization,
    function_index: usize,
    descriptor: targets.TargetDescriptor,
) EmitError![]const u8 {
    if (realization.rejections.len != 0) return error.RejectedRealization;
    if (function_index >= realization.functions.len) return error.FunctionIndexOutOfRange;
    const function = realization.functions[function_index];
    if (function.semantic_index >= semantic.functions.len) return error.FunctionIndexOutOfRange;
    return emitSemanticFunction(
        allocator,
        semantic.functions[@intCast(function.semantic_index)],
        function,
        descriptor,
    );
}

pub fn emitSemanticFunction(
    allocator: std.mem.Allocator,
    semantic_function: schema.SemanticFunction,
    function: schema.RealizationFunction,
    descriptor: targets.TargetDescriptor,
) EmitError![]const u8 {
    const descriptor_hash = targets.descriptorHash(descriptor);
    if (!std.mem.eql(u8, &descriptor_hash, &function.target_descriptor_hash)) {
        return error.TargetDescriptorHashMismatch;
    }

    var out = try std.ArrayList(u8).initCapacity(allocator, INITIAL_OUTPUT_CAPACITY * 2);
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);

    try writeContractHeader(writer, function, descriptor, descriptor_hash);
    try writeResidency(writer, function.residency);
    try writeTiles(writer, function.tiles.per_axis);
    try writeCollectives(writer, function.collectives);
    try writeReductions(writer, function.reductions);
    try kernel_body.emit(writer, semantic_function, .webgpu);

    return out.toOwnedSlice(allocator);
}

pub fn emitFunction(
    allocator: std.mem.Allocator,
    function: schema.RealizationFunction,
    descriptor: targets.TargetDescriptor,
) EmitError![]const u8 {
    const descriptor_hash = targets.descriptorHash(descriptor);
    if (!std.mem.eql(u8, &descriptor_hash, &function.target_descriptor_hash)) {
        return error.TargetDescriptorHashMismatch;
    }

    var out = try std.ArrayList(u8).initCapacity(allocator, INITIAL_OUTPUT_CAPACITY);
    errdefer out.deinit(allocator);
    const writer = out.writer(allocator);

    try writeContractHeader(writer, function, descriptor, descriptor_hash);
    try writeResidency(writer, function.residency);
    try writeTiles(writer, function.tiles.per_axis);
    try writeCollectives(writer, function.collectives);
    try writeReductions(writer, function.reductions);
    try writer.writeAll("@compute @workgroup_size(1, 1, 1)\n");
    try writer.writeAll("fn main(@builtin(global_invocation_id) gid: vec3<u32>) {\n");
    try writer.writeAll("    _ = gid;\n");
    try writer.writeAll("    // tsir mechanical skeleton: kernel body is emitted by later lowering.\n");
    try writer.writeAll("}\n");

    return out.toOwnedSlice(allocator);
}

fn writeContractHeader(
    writer: anytype,
    function: schema.RealizationFunction,
    descriptor: targets.TargetDescriptor,
    descriptor_hash: [32]u8,
) !void {
    try writer.writeAll("// doe.tsir.webgpu_skeleton.version = 1\n");
    try writer.print("// target.name = {s}\n", .{descriptor.correctness.name});
    try writer.writeAll("// target.descriptor_hash = ");
    try writeHash(writer, descriptor_hash);
    try writer.writeAll("\n");
    try writer.print("// semantic_index = {d}\n", .{function.semantic_index});
    try writer.print("// pe_grid.width = {d}\n", .{function.pe_grid.width});
    try writer.print("// pe_grid.height = {d}\n", .{function.pe_grid.height});
    try writer.writeAll("// emitter_params_json = ");
    try writeQuoted(writer, function.emitter_params_json);
    try writer.writeAll("\n\n");
}

fn writeResidency(
    writer: anytype,
    residency: []const schema.ResidencyDecision,
) !void {
    try writer.print("// residency.count = {d}\n", .{residency.len});
    for (residency, 0..) |decision, index| {
        try writer.print("// residency[{d}].binding_index = {d}\n", .{ index, decision.binding_index });
        try writer.print("// residency[{d}].class = {s}\n", .{ index, @tagName(decision.class) });
        try writer.print("// residency[{d}].axis = ", .{index});
        try writeOptionalU32(writer, decision.axis);
        try writer.print("// residency[{d}].shards = ", .{index});
        try writeOptionalU32(writer, decision.shards);
        try writer.print("// residency[{d}].fabric_color = ", .{index});
        try writeOptionalU32(writer, decision.fabric_color);
        try writer.print("// residency[{d}].chunk_bytes = ", .{index});
        try writeOptionalU64(writer, decision.chunk_bytes);
    }
    try writer.writeAll("\n");
}

fn writeTiles(
    writer: anytype,
    tiles: []const u32,
) !void {
    try writer.print("// tiles.count = {d}\n", .{tiles.len});
    for (tiles, 0..) |tile, index| {
        try writer.print("// tiles.per_axis[{d}] = {d}\n", .{ index, tile });
    }
    try writer.writeAll("\n");
}

fn writeCollectives(
    writer: anytype,
    collectives: []const schema.CollectiveRealizationNode,
) !void {
    try writer.print("// collectives.count = {d}\n", .{collectives.len});
    for (collectives, 0..) |node, index| {
        try writer.print("// collectives[{d}].semantic_index = {d}\n", .{ index, node.semantic_index });
        try writer.print("// collectives[{d}].tree_shape = {s}\n", .{ index, @tagName(node.tree_shape) });
        try writer.print("// collectives[{d}].fabric_color = ", .{index});
        try writeOptionalU32(writer, node.fabric_color);
        try writer.print("// collectives[{d}].group_size = {d}\n", .{ index, node.group_size });
    }
    try writer.writeAll("\n");
}

fn writeReductions(
    writer: anytype,
    reductions: []const schema.ReductionRealizationNode,
) !void {
    try writer.print("// reductions.count = {d}\n", .{reductions.len});
    for (reductions, 0..) |node, index| {
        try writer.print("// reductions[{d}].semantic_index = {d}\n", .{ index, node.semantic_index });
        try writer.print("// reductions[{d}].tree_shape = {s}\n", .{ index, @tagName(node.tree_shape) });
    }
    try writer.writeAll("\n");
}

fn writeOptionalU32(writer: anytype, value: ?u32) !void {
    if (value) |v| {
        try writer.print("{d}\n", .{v});
    } else {
        try writer.writeAll("none\n");
    }
}

fn writeOptionalU64(writer: anytype, value: ?u64) !void {
    if (value) |v| {
        try writer.print("{d}\n", .{v});
    } else {
        try writer.writeAll("none\n");
    }
}

fn writeHash(writer: anytype, hash: [32]u8) !void {
    for (hash) |byte| {
        const high: usize = @intCast(byte >> NIBBLE_SHIFT);
        const low: usize = @intCast(byte & NIBBLE_MASK);
        const pair = [_]u8{ HEX_DIGITS[high], HEX_DIGITS[low] };
        try writer.writeAll(&pair);
    }
}

fn writeQuoted(writer: anytype, text: []const u8) !void {
    try writer.writeAll("\"");
    for (text) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeAll("\"");
}
